#!/bin/bash

# Helper function for logging
log() {
    local level=$1
    local message=$2
    local log_file=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
}

# Helper function to extract a count from SQL output
get_count_from_sql() {
    local output="$1"
    local count
    
    # First try to extract update count
    count=$(echo "$output" | grep "row(s) updated" | grep -o "[0-9]\+" | head -1)
    if [ -n "$count" ]; then
        echo "$count"
        return 0
    fi
    
    # Try to extract retrieval count
    count=$(echo "$output" | grep "row(s) retrieved" | grep -o "[0-9]\+" | head -1)
    if [ -n "$count" ]; then
        echo "$count"
        return 0
    fi
    
    # Try to extract load count
    count=$(echo "$output" | grep "row(s) loaded" | grep -o "[0-9]\+" | head -1)
    if [ -n "$count" ]; then
        echo "$count"
        return 0
    fi
    
    # If no row count found, try to get first number that's not preceded by numbers
    # This handles COUNT(*) results which just return a number
    count=$(echo "$output" | grep -v "row(s)" | grep -o "[0-9]\+" | head -1)
    echo "${count:-0}"
}

# Helper function to get count from COUNT(*) query
get_simple_count() {
    local db=$1
    local query=$2
    local result
    result=$(run_sql "$db" "$query")
    # Clean the output to get just the number
    echo "$result" | grep -v "^$" | grep -v "Database" | grep -v "count" | grep -v "row" | tr -d ' ' | grep -o "[0-9]\+"
}

# ... (mark_table_data function remains the same) ...

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
    
    # Check marked records exist using simpler count extraction
    local marked_count
    marked_count=$(get_simple_count "$db" "SELECT COUNT(*) as count FROM $table WHERE $column LIKE '${marker}%';")
    
    if [ -z "$marked_count" ] || [ "$marked_count" -lt "$expected_count" ]; then
        log "ERROR" "Expected $expected_count marked records, found ${marked_count:-0}" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Found $marked_count marked records" "$LOG_FILE"
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
    
    local update_result
    update_result=$(run_sql "$db" "$update_query")
    log "DEBUG" "Update result: $update_result" "$LOG_FILE"
    
    # Extract count from update result
    local marked_count
    marked_count=$(get_count_from_sql "$update_result")
    
    if [ -z "$marked_count" ] || [ "$marked_count" -eq 0 ]; then
        log "ERROR" "No records were updated" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Marked $marked_count records in $table" "$LOG_FILE"
    
    # Show sample data after marking
    local sample_data
    sample_data=$(run_sql "$db" "SELECT FIRST 3 $column FROM $table WHERE $column LIKE '${marker}%';")
    log "DEBUG" "Sample data after marking:" "$LOG_FILE"
    log "DEBUG" "$sample_data" "$LOG_FILE"
    
    return 0
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

# Function to verify dependent records for essential records
verify_dependent_records() {
    local db=$1
    local primary_id=$2
    local status=0
    
    # Get dependency configuration
    local primary_table=$(yq e '.tables.primary_table.name' "$CONFIG_FILE")
    local foreign_key=$(yq e '.tables.dependencies.foreign_key_column' "$CONFIG_FILE")
    
    # Get all tables that might have dependencies
    local dependent_tables
    dependent_tables=$(run_sql "$db" "
        SELECT DISTINCT t.tabname 
        FROM syscolumns c
        JOIN systables t ON c.tabid = t.tabid 
        WHERE t.tabtype = 'T'
        AND c.colname = '${foreign_key}'
        AND t.tabname != '${primary_table}';" | clean_sql_output)
    
    if [ -z "$dependent_tables" ]; then
        log "WARNING" "No dependent tables found with foreign key: ${foreign_key}" "$LOG_FILE"
        return 0
    fi
    
    log "INFO" "Checking dependencies for record ${primary_id} in tables: ${dependent_tables}" "$LOG_FILE"
    
    # Check each table for dependent records
    echo "$dependent_tables" | while read -r table; do
        local count
        count=$(get_simple_count "$db" "
            SELECT COUNT(*) 
            FROM $table 
            WHERE $foreign_key = $primary_id;")
        
        if [ "${count:-0}" -eq 0 ]; then
            log "WARNING" "No dependent records found in $table for ${primary_id}" "$LOG_FILE"
            status=1
        else
            log "INFO" "Found ${count} dependent record(s) in $table for ${primary_id}" "$LOG_FILE"
        fi
    done
    
    return $status
}

# Add this at the top of verification_functions.sh with other functions

# Get all dependent tables that have the specified foreign key
get_dependent_tables() {
    local db=$1
    local foreign_key=$2
    
    run_sql "$db" "
        SELECT DISTINCT TRIM(t.tabname) 
        FROM syscolumns c
        JOIN systables t ON c.tabid = t.tabid 
        WHERE t.tabtype = 'T'
        AND TRIM(c.colname) = '${foreign_key}';" | clean_sql_output
}

# Verify dependencies for a single essential record
verify_record_dependencies() {
    local db=$1
    local record_id=$2
    local status=0
    
    # Expected dependencies based on our test data structure
    declare -A expected_counts=(
        ["employees"]=">=1"    # At least 1 employee
        ["projects"]=">=1"     # At least 1 project
        ["repositories"]=">=1"  # At least 1 repository linked via projects
    )
    
    # Check direct dependencies (employees and projects)
    for table in "employees" "projects"; do
        local count
        count=$(get_simple_count "$db" "
            SELECT COUNT(*) FROM $table 
            WHERE customer_id = $record_id;")
        
        local expected="${expected_counts[$table]}"
        local min_count="${expected#>=}"
        
        if [ "${count:-0}" -lt "$min_count" ]; then
            log "ERROR" "Essential record $record_id: Expected ${expected} ${table}, found ${count:-0}" "$LOG_FILE"
            status=1
        else
            log "INFO" "Essential record $record_id: Found ${count} ${table}" "$LOG_FILE"
        fi
    done
    
    # Check indirect dependencies (repositories linked through projects)
    local repo_count
    repo_count=$(get_simple_count "$db" "
        SELECT COUNT(DISTINCT r.id) 
        FROM repositories r 
        JOIN projects p ON r.project_id = p.id 
        WHERE p.customer_id = $record_id;")
    
    local expected="${expected_counts["repositories"]}"
    local min_count="${expected#>=}"
    
    if [ "${repo_count:-0}" -lt "$min_count" ]; then
        log "ERROR" "Essential record $record_id: Expected ${expected} repositories, found ${repo_count:-0}" "$LOG_FILE"
        status=1
    else
        log "INFO" "Essential record $record_id: Found ${repo_count} repositories" "$LOG_FILE"
    fi
    
    return $status
}

# Verify all essential record dependencies
verify_essential_dependencies() {
    local db=$1
    local status=0
    
    log "INFO" "Verifying dependencies for essential records..." "$LOG_FILE"
    
    while IFS= read -r id; do
        if ! verify_record_dependencies "$db" "$id"; then
            log "ERROR" "Dependency verification failed for essential record ${id}" "$LOG_FILE"
            status=1
        fi
    done < <(yq e '.essential_records.records[].id' "$CONFIG_FILE")
    
    return $status
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
    
    # After verifying essential records
    if ! verify_essential_dependencies "$db"; then
        log "ERROR" "Essential record dependency verification failed" "$LOG_FILE"
        status=1
    fi

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

