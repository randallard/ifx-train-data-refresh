#!/bin/bash

# Helper function for logging
log() {
    local level=$1
    local message=$2
    local log_file=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
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
    
    case "$table" in
        "training_config")
            echo "config_value"
            return 0
            ;;
        "train_specific_data")
            echo "data_value"
            return 0
            ;;
        *)
            local result
            result=$(run_sql "$db" "SELECT TRIM(c.colname) as colname
            FROM syscolumns c, systables t
            WHERE c.tabid = t.tabid 
            AND t.tabname = '${table}'
            AND t.tabtype = 'T'
            AND c.coltype IN (0, 13)
            AND c.collength > 0
            ORDER BY c.colno
            FETCH FIRST 1 ROW ONLY;")
            
            local column
            column=$(echo "$result" | grep -v "^$" | grep -v "colname" | grep -v "Database" | tr -d ' ')
            
            if [ -z "$column" ]; then
                return 1
            fi
            echo "$column"
            return 0
            ;;
    esac
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
    local backup_query="SELECT FIRST ${sample_count} TRIM($column) as value 
    FROM $table 
    WHERE $column IS NOT NULL 
    ORDER BY id;"
    
    log "DEBUG" "Running backup query:" "$LOG_FILE"
    log "DEBUG" "$backup_query" "$LOG_FILE"
    
    # Save original values for verification
    run_sql "$db" "$backup_query" | grep -v "^$" | grep -v "Database" | grep -v "value" | grep -v "row" > "$backup_file"
    
    # Show backup contents
    log "DEBUG" "Backup file contents:" "$LOG_FILE"
    cat "$backup_file" >> "$LOG_FILE"
    
    # Update the values
    local update_query="UPDATE $table 
    SET $column = '${marker}' || TRIM($column)
    WHERE $column IS NOT NULL;"
    
    log "DEBUG" "Running update query:" "$LOG_FILE"
    log "DEBUG" "$update_query" "$LOG_FILE"
    
    local update_result
    update_result=$(run_sql "$db" "$update_query")
    log "DEBUG" "Update result: $update_result" "$LOG_FILE"
    
    # Verify the update
    local check_query="SELECT COUNT(*) as count FROM $table WHERE $column LIKE '${marker}%';"
    local marked_count_result
    marked_count_result=$(run_sql "$db" "$check_query")
    log "DEBUG" "Count query result: $marked_count_result" "$LOG_FILE"
    
    local marked_count
    marked_count=$(echo "$marked_count_result" | grep -v "^$" | grep -v "count" | grep -v "Database" | grep -v "row" | tr -d ' ')
    
    if [[ ! "$marked_count" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Failed to get valid count: $marked_count" "$LOG_FILE"
        marked_count=0
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
    local marked_count
    marked_count=$(run_sql "$db" "SELECT COUNT(*) as count FROM $table WHERE $column LIKE '${marker}%';" | 
                  grep -v "^$" | grep -v "count" | grep -v "Database" | grep -v "row" | tr -d ' ')
    
    if [ -z "$marked_count" ] || [ "$marked_count" -lt "$expected_count" ]; then
        log "ERROR" "Expected $expected_count marked records, found ${marked_count:-0}" "$LOG_FILE"
        return 1
    fi
    
    # Verify values match original + marker
    local mismatch_count=0
    while IFS= read -r original_value || [ -n "$original_value" ]; do
        [ -z "$original_value" ] && continue
        
        # Clean the value and check if it exists in the table
        original_value=$(echo "$original_value" | tr -d '\r' | tr -d '\n' | xargs)
        local marked_value="${marker}${original_value}"
        
        local verify_query="SELECT COUNT(*) FROM $table WHERE TRIM($column) = '${marked_value}';"
        local found
        found=$(run_sql "$db" "$verify_query" | grep -v "^$" | grep -v "count" | grep -v "Database" | grep -v "row" | tr -d ' ')
        
        if [ "${found:-0}" -lt 1 ]; then
            ((mismatch_count++))
            log "ERROR" "Value not found: Expected '$marked_value'" "$LOG_FILE"
        fi
    done < "$backup_file"
    
    if [ "$mismatch_count" -gt 0 ]; then
        log "ERROR" "Found $mismatch_count value mismatches in $table" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Table $table verified successfully" "$LOG_FILE"
    return 0
}

# Run all verifications (same as before)
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
    done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")
    
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

# Test database connection
test_db_connection() {
    local db_name=$1
    if ! echo "database $db_name; SELECT FIRST 1 * FROM systables;" | dbaccess - >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to database: $db_name" "$LOG_FILE"
        return 1
    fi
    return 0
}

# Function to check if table exists
check_table_exists() {
    local db=$1
    local table=$2
    local exists=$(echo "database $db; SELECT tabname FROM systables WHERE tabname='$table';" | \
                  dbaccess - 2>/dev/null | grep -v "tabname" | grep -v "^$" | grep "$table")
    [ -n "$exists" ]
    return $?
}

