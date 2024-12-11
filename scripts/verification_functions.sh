#!/bin/bash

# Helper function for logging
log() {
    local level=$1
    local message=$2
    local log_file=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
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

# Get string columns for a table (with debug output)
get_table_columns() {
    local db=$1
    local table=$2
    
    log "DEBUG" "Looking for string columns in table $table" "$LOG_FILE"
    
    # Show table metadata first
    show_table_info "$db" "$table"
    
    # Try getting the first string column
    local query="database $db;
    SELECT FIRST 1 colname 
    FROM syscolumns 
    WHERE tabid = (
        SELECT tabid 
        FROM systables 
        WHERE tabname = '${table}'
    )
    AND coltype IN (0, 40, 45)
    AND collength > 0;"
    
    log "DEBUG" "Executing query: $query" "$LOG_FILE"
    
    local result=$(echo "$query" | dbaccess - 2>&1)
    log "DEBUG" "Query result: $result" "$LOG_FILE"
    
    echo "$result" | grep -v "colname" | grep -v "^$" | tr -d ' '
}

# Mark table data and store original values
mark_table_data() {
    local db=$1
    local table=$2
    local marker=$3
    local sample_count=$4
    local backup_file="$WORK_DIR/${table}_original_values.txt"
    
    # Get the first string column with debug output
    local first_column=$(get_table_columns "$db" "$table")
    
    if [ -z "$first_column" ]; then
        log "WARNING" "No string columns found in table $table" "$LOG_FILE"
        return 1
    fi
    
    log "DEBUG" "Using column '$first_column' for marking in table '$table'" "$LOG_FILE"
    
    # Show sample of current data
    echo "database $db;
    SELECT FIRST 1 ${first_column} 
    FROM ${table};" | dbaccess - 2>&1 | tee -a "$LOG_FILE"
    
    # Backup original values before marking
    echo "database $db;
    SELECT FIRST ${sample_count} ${first_column} 
    FROM ${table};" | dbaccess - | grep -v "^$" | grep -v "${first_column}" > "$backup_file"
    
    log "DEBUG" "Stored original values for $table in $backup_file" "$LOG_FILE"
    
    # Mark the records
    local update_query="database $db;
    UPDATE FIRST ${sample_count} ${table} 
    SET ${first_column} = '${marker}' || ${first_column};"
    
    log "DEBUG" "Executing update: $update_query" "$LOG_FILE"
    echo "$update_query" | dbaccess - 2>&1 | tee -a "$LOG_FILE"
    
    # Verify the update happened
    local count_query="database $db;
    SELECT COUNT(*) FROM ${table} 
    WHERE ${first_column} LIKE '${marker}%';"
    
    log "DEBUG" "Checking count with: $count_query" "$LOG_FILE"
    local marked_count=$(echo "$count_query" | dbaccess - | grep -v "^$" | grep -v "count" | tr -d ' ')
    
    log "INFO" "Marked $marked_count records in $table" "$LOG_FILE"
    
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

# Function to check if table exists
check_table_exists() {
    local db=$1
    local table=$2
    local exists=$(echo "database $db; SELECT tabname FROM systables WHERE tabname='$table';" | \
                  dbaccess - 2>/dev/null | grep -v "tabname" | grep -v "^$" | grep "$table")
    [ -n "$exists" ]
    return $?
}

# Verify marked records persist through export/import
verify_marked_records() {
    local db=$1
    local table=$2
    local marker=$3
    local expected_count=$4
    local backup_file="$WORK_DIR/${table}_original_values.txt"
    
    # Get the first string column (reuse the same function)
    local first_column=$(get_table_columns "$db" "$table")
    
    if [ -z "$first_column" ]; then
        log "WARNING" "No string columns found in table $table" "$LOG_FILE"
        return 1
    fi
    
    # Check marked records exist
    local marked_count=$(echo "database $db;
    SELECT COUNT(*) FROM ${table} 
    WHERE ${first_column} LIKE '${marker}%';" | dbaccess - | grep -v "^$" | grep -v "count" | tr -d ' ')
    
    if [ -z "$marked_count" ] || [ "$marked_count" -lt "$expected_count" ]; then
        log "ERROR" "Table $table verification failed: Expected $expected_count marked records, found ${marked_count:-0}" "$LOG_FILE"
        return 1
    fi
    
    # Verify the marked values match original values (with marker)
    local mismatch_count=0
    while IFS= read -r original_value; do
        local expected_value="${marker}${original_value}"
        local found=$(echo "database $db;
        SELECT COUNT(*) FROM ${table}
        WHERE ${first_column} = '${expected_value}';" | dbaccess - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ "$found" -ne 1 ]; then
            ((mismatch_count++))
            log "ERROR" "Value mismatch in $table: Expected '$expected_value'" "$LOG_FILE"
        fi
    done < "$backup_file"
    
    if [ "$mismatch_count" -gt 0 ]; then
        log "ERROR" "Found $mismatch_count value mismatches in $table" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Table $table verified successfully: Found $marked_count marked records with matching values" "$LOG_FILE"
    return 0
}

# Run all verifications
run_all_verifications() {
    local db=$1
    local status=0
    
    # Create work directory for verification files
    mkdir -p "$WORK_DIR"
    
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
        local count=$(echo "database $db;
        SELECT COUNT(*) FROM ${PRIMARY_TABLE} 
        WHERE ${PRIMARY_KEY} = $id;" | dbaccess - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -z "$count" ] || [ "$count" -ne 1 ]; then
            log "ERROR" "Essential record $id not found in table $PRIMARY_TABLE" "$LOG_FILE"
            status=1
        else
            log "INFO" "Essential record $id verified in table $PRIMARY_TABLE" "$LOG_FILE"
        fi
    done < <(yq e '.essential_records.records[].id' "$CONFIG_FILE")
    
    return $status
}