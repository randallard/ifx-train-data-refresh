#!/bin/bash

# Helper function for logging
log() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Test database connection
test_db_connection() {
    local db_name=$1
    if ! echo "database $db_name; SELECT FIRST 1 * FROM systables;" | dbaccess - >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to database: $db_name"
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

# Get columns for a table, including type information
get_table_columns() {
    local db=$1
    local table=$2
    dbaccess "$db" << EOF | grep -E '^[[:space:]]*[[:alnum:]_]+[[:space:]]+(0|1|45)' | awk '{print $1}'
SELECT TRIM(c.colname) as colname, c.coltype, c.collength
FROM syscolumns c, systables t
WHERE c.tabid = t.tabid
    AND t.tabname = '$table'
    AND t.tabtype = 'T'           -- User table only
    AND c.colno > 0               -- Skip system columns
    AND c.coltype IN (0, 1, 45)   -- CHAR, VARCHAR, TEXT types only
ORDER BY c.colno;
EOF
}

# Mark table data based on available columns
mark_table_data() {
    local db=$1
    local table=$2
    local marker=$3
    local sample_count=$4
    
    # Get first string column
    local first_column=$(get_table_columns "$db" "$table")
    
    if [ -z "$first_column" ]; then
        log "WARNING" "No string columns found in table $table"
        return 1
    fi
    
    log "DEBUG" "Found column '$first_column' in table '$table'"
    
    local sql="UPDATE FIRST ${sample_count} ${table} SET ${first_column} = '${marker}' || ${first_column};"
    log "DEBUG" "Executing SQL: $sql"
    
    # Mark first N records
    dbaccess "$db" << EOF
BEGIN WORK;
$sql
COMMIT WORK;
EOF
    local result=$?
    
    if [ $result -ne 0 ]; then
        log "ERROR" "Failed to update table $table"
        return 1
    fi
    
    return 0
}

# Verify marked records in a table
verify_marked_records() {
    local db=$1
    local table=$2
    local marker=$3
    local expected_count=$4
    
    # Get first string column
    local first_column=$(get_table_columns "$db" "$table")
    
    if [ -z "$first_column" ]; then
        log "WARNING" "No string columns found in table $table"
        return 1
    fi
    
    log "DEBUG" "Checking marks in column '$first_column' of table '$table'"
    
    local sql="SELECT COUNT(*) FROM ${table} WHERE ${first_column} LIKE '${marker}%';"
    log "DEBUG" "Executing SQL: $sql"
    
    local marked_count=$(dbaccess "$db" << EOF | grep -v "^$" | grep -v "count" | tr -d ' '
$sql
EOF
    )
    
    if [ -z "$marked_count" ] || [ "$marked_count" -lt "$expected_count" ]; then
        log "ERROR" "Table $table verification failed: Expected $expected_count marked records, found ${marked_count:-0}"
        return 1
    fi
    
    log "INFO" "Table $table verified successfully: Found $marked_count marked records"
    return 0
}

# Verify essential records
verify_essential_records() {
    local db=$1
    local status=0
    local table=$(yq e '.tables.primary_table.name' "$CONFIG_FILE")
    local key_field=$(yq e '.tables.primary_table.primary_key' "$CONFIG_FILE")
    
    log "INFO" "Checking essential records in table $table"
    
    while IFS= read -r id; do
        log "DEBUG" "Checking for record with $key_field = $id"
        
        local sql="SELECT COUNT(*) FROM $table WHERE $key_field = $id;"
        local count=$(dbaccess "$db" << EOF | grep -v "^$" | grep -v "count" | tr -d ' '
$sql
EOF
        )
        
        if [ -z "$count" ] || [ "$count" -ne 1 ]; then
            log "ERROR" "Essential record $id not found in table $table"
            status=1
        else
            log "INFO" "Essential record $id verified in table $table"
        fi
    done < <(yq e '.essential_records.records[].id' "$CONFIG_FILE")
    
    return $status
}

# Verify all excluded tables
verify_excluded_tables() {
    local db=$1
    local marker=$2
    local sample_count=$3
    
    log "INFO" "Checking excluded tables"
    
    while IFS= read -r table; do
        if ! mark_table_data "$db" "$table" "$marker" "$sample_count"; then
            continue  # Skip verification if marking failed
        fi
        
        if ! verify_marked_records "$db" "$table" "$marker" "$sample_count"; then
            return 1  # Return error if verification fails
        fi
    done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")
    
    return 0
}