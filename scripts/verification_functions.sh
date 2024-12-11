#!/bin/bash

# Helper function for logging
log() {
    local level=$1
    local message=$2
    local log_file=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
}

# Helper function to get table names from config
get_excluded_tables() {
    yq e '.excluded_tables[]' "$CONFIG_FILE"
}

# Helper function to get field mapping for a table
get_table_field_mapping() {
    local table=$1
    
    # For known tables, return their specific value columns
    case "$table" in
        "training_config")
            echo "config_value"
            return 0
            ;;
        "train_specific_data")
            echo "data_value"
            return 0
            ;;
    esac
    
    # First check random_names section
    local field=$(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .fields[0]" "$CONFIG_FILE")
    
    # If not found, check standardize section
    if [ -z "$field" ]; then
        for type in "address" "phone" "email"; do
            field=$(yq e ".scrubbing.standardize.$type.fields[] | select(.table == \"$table\") | .field" "$CONFIG_FILE")
            if [ -n "$field" ]; then
                break
            fi
        done
    fi
    
    # If still not found, check combination_fields
    if [ -z "$field" ]; then
        field=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .target_field" "$CONFIG_FILE")
    fi
    
    echo "$field"
}

# Helper function to clean SQL output
clean_sql_output() {
    local input=$1
    echo "$input" | grep -v "^$" | grep -v "Database" | grep -v "row" | grep -v "^[[:space:]]*$" | 
    sed -n '/^[[:space:]]*[^[:space:]]/p' | # Only lines that start with optional spaces followed by non-space
    sed 's/^[[:space:]]*[^[:space:]]*[[:space:]]*//g' | # Remove column name and spaces
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' # Trim leading/trailing spaces
}

# Helper function to run SQL and get results
run_sql() {
    local db=$1
    local query=$2
    local tmp_file
    tmp_file=$(mktemp)
    
    echo "database $db;
    $query" | dbaccess - > "$tmp_file" 2>&1
    
    local result
    result=$(cat "$tmp_file")
    rm -f "$tmp_file"
    echo "$result"
}

# Function to get the appropriate string column for a table
get_first_string_column() {
    local db=$1
    local table=$2
    
    # First try to get the mapped field from config
    local mapped_field
    mapped_field=$(get_table_field_mapping "$table")
    
    if [ -n "$mapped_field" ]; then
        echo "$mapped_field"
        return 0
    fi
    
    # If no mapping found, fall back to first VARCHAR column
    local result
    result=$(run_sql "$db" "
        SELECT FIRST 1 TRIM(c.colname) as colname
        FROM syscolumns c
        JOIN systables t ON c.tabid = t.tabid 
        WHERE t.tabname = '${table}'
        AND t.tabtype = 'T'
        AND c.coltype = 13
        ORDER BY c.colno;")
    
    local column
    column=$(echo "$result" | clean_sql_output)
    
    if [ -z "$column" ]; then
        return 1
    fi
    echo "$column"
    return 0
}

# Mark table data and store original values
mark_table_data() {
    local db=$1
    local table=$2
    local marker=$3
    local sample_count=$4
    local backup_file="$WORK_DIR/${table}_original_values.txt"
    
    # Get target column
    local column
    column=$(get_first_string_column "$db" "$table")
    local ret=$?
    
    if [ $ret -ne 0 ] || [ -z "$column" ]; then
        log "ERROR" "No suitable column found for marking in table $table" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Using column '$column' for marking in table '$table'" "$LOG_FILE"
    
    # First, backup the values we're going to modify
    local backup_query="SELECT FIRST ${sample_count} $column FROM $table 
        WHERE $column IS NOT NULL 
        ORDER BY id;"
    
    log "DEBUG" "Running backup query:" "$LOG_FILE"
    log "DEBUG" "$backup_query" "$LOG_FILE"
    
    # Save original values for verification
    run_sql "$db" "$backup_query" | clean_sql_output > "$backup_file"
    
    # Show backup contents
    log "DEBUG" "Backup file contents:" "$LOG_FILE"
    cat "$backup_file" >> "$LOG_FILE"
    
    # Update the values
    local update_query="UPDATE $table 
        SET $column = '${marker}' || $column
        WHERE $column IS NOT NULL;"
    
    log "DEBUG" "Running update query:" "$LOG_FILE"
    log "DEBUG" "$update_query" "$LOG_FILE"
    
    run_sql "$db" "$update_query"
    
    # Verify the update
    local check_query="SELECT COUNT(*) as count FROM $table WHERE $column LIKE '${marker}%';"
    local marked_count
    marked_count=$(run_sql "$db" "$check_query" | clean_sql_output)
    
    if [[ ! "$marked_count" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Failed to get valid count after update" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Marked $marked_count records in $table" "$LOG_FILE"
    
    # Show sample data after marking
    local sample_data
    sample_data=$(run_sql "$db" "SELECT FIRST 3 $column FROM $table WHERE $column LIKE '${marker}%';")
    log "DEBUG" "Sample data after marking:" "$LOG_FILE"
    log "DEBUG" "$sample_data" "$LOG_FILE"
    
    if [ "$marked_count" -gt 0 ]; then
        return 0
    fi
    return 1
}

# Verify marked records persist
verify_marked_records() {
    local db=$1
    local table=$2
    local marker=$3
    local expected_count=$4
    local backup_file="$WORK_DIR/${table}_original_values.txt"
    
    # Get the column name
    local column
    column=$(get_first_string_column "$db" "$table")
    local ret=$?
    
    if [ $ret -ne 0 ] || [ -z "$column" ]; then
        log "ERROR" "No string column found for verification in table $table" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Verifying marks in column '$column' for table '$table'" "$LOG_FILE"
    
    # Check marked records exist
    local check_query="SELECT COUNT(*) FROM $table WHERE $column LIKE '${marker}%';"
    local marked_count
    marked_count=$(run_sql "$db" "$check_query" | clean_sql_output)
    
    if [ -z "$marked_count" ] || [ "$marked_count" -lt "$expected_count" ]; then
        log "ERROR" "Expected $expected_count marked records, found ${marked_count:-0}" "$LOG_FILE"
        return 1
    fi
    
    # Verify values match original + marker
    local mismatch_count=0
    while IFS= read -r original_value || [ -n "$original_value" ]; do
        [ -z "$original_value" ] && continue
        
        # Clean the value
        original_value=$(echo "$original_value" | clean_sql_output)
        local marked_value="${marker}${original_value}"
        
        local verify_query="SELECT COUNT(*) FROM $table WHERE $column = '${marked_value}';"
        local found
        found=$(run_sql "$db" "$verify_query" | clean_sql_output)
        
        if [ "${found:-0}" -lt 1 ]; then
            ((mismatch_count++))
            log "ERROR" "Value not found: '$marked_value'" "$LOG_FILE"
        fi
    done < "$backup_file"
    
    if [ "$mismatch_count" -gt 0 ]; then
        log "ERROR" "Found $mismatch_count value mismatches in $table" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Table $table verified successfully" "$LOG_FILE"
    return 0
}

# Function to check if table exists
check_table_exists() {
    local db=$1
    local table=$2
    local exists=$(run_sql "$db" "SELECT tabname FROM systables WHERE tabname='$table';" | clean_sql_output)
    [ -n "$exists" ]
    return $?
}

# Test database connection
test_db_connection() {
    local db_name=$1
    if ! echo "database $db_name; SELECT FIRST 1 * FROM systables;" | dbaccess - >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to database: $db_name" "$LOG_FILE"
        return 1
    fi
    return 0
}

# Run all verifications
run_all_verifications() {
    local db=$1
    local status=0
    
    mkdir -p "$WORK_DIR"
    chmod 755 "$WORK_DIR"
    
    # Verify excluded tables
    while IFS= read -r table; do
        log "INFO" "Processing excluded table: $table" "$LOG_FILE"
        
        if ! mark_table_data "$db" "$table" "$MARKER" "$SAMPLE_COUNT"; then
            log "ERROR" "Failed to mark table: $table" "$LOG_FILE"
            status=1
            continue
        fi
        
        if ! verify_marked_records "$db" "$table" "$MARKER" "$SAMPLE_COUNT"; then
            log "ERROR" "Failed to verify marked records in table: $table" "$LOG_FILE"
            status=1
        fi
    done < <(get_excluded_tables)
    
    # Verify essential records
    while IFS= read -r id; do
        local count
        count=$(echo "database $db;
        SELECT COUNT(*) FROM ${PRIMARY_TABLE} 
        WHERE ${PRIMARY_KEY} = $id;" | dbaccess - 2>/dev/null | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ "${count:-0}" -ne 1 ]; then
            log "ERROR" "Essential record $id not found in table $PRIMARY_TABLE" "$LOG_FILE"
            status=1
        else
            log "INFO" "Essential record $id verified in table $PRIMARY_TABLE" "$LOG_FILE"
        fi
    done < <(yq e '.essential_records.records[].id' "$CONFIG_FILE")
    
    return $status
}

# Debug function to show table columns
show_table_columns() {
    local db=$1
    local table=$2
    local tmp_file
    tmp_file=$(mktemp)
    
    echo "database $db;
    SELECT TRIM(c.colname) as colname, c.coltype, c.collength
    FROM syscolumns c, systables t
    WHERE c.tabid = t.tabid 
    AND t.tabname = '${table}'
    ORDER BY c.colno;" | dbaccess - > "$tmp_file" 2>/dev/null
    
    log "DEBUG" "Columns for table $table:" "$LOG_FILE"
    cat "$tmp_file" | grep -v "^$" >> "$LOG_FILE"
    rm -f "$tmp_file"
}

# Debug function for showing table metadata
show_table_info() {
    local db=$1
    local table=$2
    
    log "DEBUG" "Getting metadata for table: $table" "$LOG_FILE"
    
    # Show table ID
    echo "database $db;
    SELECT tabid, tabname, owner 
    FROM systables 
    WHERE tabname = '${table}';" | dbaccess - 2>&1 | tee -a "$LOG_FILE"
    
    # Show column information
    echo "database $db;
    SELECT colno, colname, coltype, collength
    FROM syscolumns c
    WHERE tabid = (
        SELECT tabid 
        FROM systables 
        WHERE tabname = '${table}'
    )
    ORDER BY colno;" | dbaccess - 2>&1 | tee -a "$LOG_FILE"
}

# Get string columns for a table (fixed for correct Informix types)
get_table_columns() {
    local db=$1
    local table=$2
    
    log "DEBUG" "Looking for string columns in table $table" "$LOG_FILE"
    
    # Get the first VARCHAR column (type 13)
    local result=$(echo "database $db;
    SELECT FIRST 1 TRIM(colname) as colname
    FROM syscolumns c, systables t
    WHERE c.tabid = t.tabid 
    AND t.tabname = '${table}'
    AND t.tabtype = 'T'
    AND c.coltype = 13
    AND c.collength > 0
    ORDER BY c.colno;" | dbaccess - | grep -v "colname" | grep -v "^$" | tr -d ' ')
    
    echo "$result"
}

