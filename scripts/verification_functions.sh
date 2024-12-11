#!/bin/bash

# Helper function for logging
log() {
    local level=$1
    local message=$2
    local log_file=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
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

# Get columns for a table
get_table_columns() {
    local db=$1
    local table=$2
    echo "database $db;
    SELECT TRIM(c.colname) as colname
    FROM syscolumns c, systables t
    WHERE c.tabid = t.tabid
        AND t.tabname = '$table'
        AND t.tabtype = 'T'
        AND c.colno > 0
        AND c.coltype IN (0, 1, 45)
    ORDER BY c.colno;" | dbaccess - | grep -v "colname" | grep -v "^$" | tr -d ' '
}

# Mark table data
mark_table_data() {
    local db=$1
    local table=$2
    local marker=$3
    local sample_count=$4
    
    local first_column=$(get_table_columns "$db" "$table" | head -1)
    
    if [ -z "$first_column" ]; then
        log "WARNING" "No string columns found in table $table" "$LOG_FILE"
        return 1
    fi
    
    log "DEBUG" "Found column '$first_column' in table '$table'" "$LOG_FILE"
    
    echo "database $db;
    UPDATE FIRST ${sample_count} ${table} 
    SET ${first_column} = '${marker}' || ${first_column};" | dbaccess - >/dev/null 2>&1
    
    return $?
}

# Verify marked records
verify_marked_records() {
    local db=$1
    local table=$2
    local marker=$3
    local expected_count=$4
    
    local first_column=$(get_table_columns "$db" "$table" | head -1)
    
    if [ -z "$first_column" ]; then
        log "WARNING" "No string columns found in table $table" "$LOG_FILE"
        return 1
    fi
    
    local marked_count=$(echo "database $db;
    SELECT COUNT(*) FROM ${table} 
    WHERE ${first_column} LIKE '${marker}%';" | dbaccess - | grep -v "^$" | grep -v "count" | tr -d ' ')
    
    if [ -z "$marked_count" ] || [ "$marked_count" -lt "$expected_count" ]; then
        log "ERROR" "Table $table verification failed: Expected $expected_count marked records, found ${marked_count:-0}" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Table $table verified successfully: Found $marked_count marked records" "$LOG_FILE"
    return 0
}

# Run all verifications
run_all_verifications() {
    local db=$1
    local status=0
    
    # Verify excluded tables
    while IFS= read -r table; do
        if ! mark_table_data "$db" "$table" "$MARKER" "$SAMPLE_COUNT"; then
            continue
        fi
        
        if ! verify_marked_records "$db" "$table" "$MARKER" "$SAMPLE_COUNT"; then
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