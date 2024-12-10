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

# Clean table name
clean_table_name() {
    echo "$1" | sed 's/^expression[[:space:]]*//g' | sed 's/^([[:space:]]*//' | sed 's/[[:space:]]*)//' | tr -d '()'
}

# Get list of user tables
get_user_tables() {
    local db=$1
    echo "SELECT TRIM(tabname) FROM systables 
          WHERE tabtype='T' 
          AND tabid > 99
          ORDER BY tabname;" | \
    dbaccess "$db" - 2>/dev/null | \
    grep -v "^$" | grep -v "tabname" | \
    while read -r table; do
        clean_table_name "$table"
    done
}

# Verify excluded tables haven't changed
verify_excluded_tables() {
    local db=$1
    local status=0
    
    log "INFO" "Checking excluded tables"
    
    # Remove any existing duplicate data in excluded tables
    for table in training_config train_specific_data; do
        echo "DELETE FROM $table;" | dbaccess "$db" - >/dev/null 2>&1
    done
    
    # Reload excluded tables data
    cd "$HOME/work/${TEST_DB}.exp"
    
    echo "LOAD FROM 'train00104.unl' DELIMITER '|' INSERT INTO training_config;" | \
    dbaccess "$db" - >/dev/null 2>&1
    
    echo "LOAD FROM 'train00105.unl' DELIMITER '|' INSERT INTO train_specific_data;" | \
    dbaccess "$db" - >/dev/null 2>&1
    
    cd "$SCRIPT_DIR"
    
    while IFS= read -r table; do
        log "DEBUG" "Verifying excluded table: $table"
        
        # Compare record counts
        local orig_count=$(echo "SELECT COUNT(*) FROM $table;" | \
                         dbaccess test_live - | grep -v "^$" | grep -v "count" | tr -d ' ')
        local new_count=$(echo "SELECT COUNT(*) FROM $table;" | \
                         dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ "$orig_count" != "$new_count" ]; then
            log "ERROR" "Record count mismatch in table $table (orig: $orig_count, new: $new_count)"
            status=1
        else
            log "INFO" "Record count verified for table $table"
        fi
        
        # Compare data with appropriate columns for each table
        if [ "$table" = "training_config" ]; then
            local query="SELECT SUM(LENGTH(TRIM(config_value))) FROM $table;"
        else
            local query="SELECT SUM(LENGTH(TRIM(data_value))) FROM $table;"
        fi
        
        local orig_sum=$(echo "$query" | dbaccess test_live - | grep -v "^$" | grep -v "sum" | tr -d ' ')
        local new_sum=$(echo "$query" | dbaccess "$db" - | grep -v "^$" | grep -v "sum" | tr -d ' ')
        
        if [ "$orig_sum" != "$new_sum" ]; then
            log "ERROR" "Content changed in excluded table $table"
            status=1
        else
            log "INFO" "Content verified for table $table"
        fi
    done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")
    
    return $status
}

# Verify essential records exist
verify_essential_records() {
    local db=$1
    local status=0
    
    log "INFO" "Checking essential records"
    
    while IFS= read -r id; do
        log "DEBUG" "Checking for record with id = $id"
        
        local count=$(echo "SELECT COUNT(*) FROM customers WHERE id = $id;" | \
                     dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -z "$count" ] || [ "$count" -eq 0 ]; then
            log "ERROR" "Essential record $id not found"
            status=1
        else
            log "INFO" "Essential record $id verified"
        fi
    done < <(yq e '.essential_records.records[].id' "$CONFIG_FILE")
    
    return $status
}

# Verify record counts
verify_record_counts() {
    local db=$1
    local status=0
    
    log "INFO" "Verifying record counts"
    
    while read -r table; do
        # Skip excluded tables
        if yq e '.excluded_tables[]' "$CONFIG_FILE" | grep -q "^$table$"; then
            continue
        fi
        
        table=$(clean_table_name "$table")
        log "DEBUG" "Verifying record count for table: $table"
        
        local count=$(echo "SELECT COUNT(*) FROM $table;" | \
                     dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -z "$count" ] || [ "$count" -lt 1 ]; then
            log "ERROR" "Table $table has no records"
            status=1
        else
            log "INFO" "Table $table has $count records"
        fi
    done < <(get_user_tables "$db")
    
    return $status
}

# Verify standardized fields
verify_standardization() {
    local db=$1
    local status=0
    
    log "INFO" "Verifying standardized fields"
    
    # Verify addresses
    while read -r entry; do
        local table=$(echo "$entry" | yq e '.table' -)
        local field=$(echo "$entry" | yq e '.field' -)
        local expected=$(yq e '.scrubbing.standardize.address.value' "$CONFIG_FILE")
        
        log "DEBUG" "Checking standardized address in $table.$field"
        
        local query="SELECT COUNT(DISTINCT $field) FROM $table;"
        local distinct_count=$(echo "$query" | dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -z "$distinct_count" ] || [ "$distinct_count" -ne 1 ]; then
            log "ERROR" "Found multiple distinct addresses in $table.$field"
            status=1
        else
            log "INFO" "Address standardization verified for $table.$field"
        fi
    done < <(yq e -o=json '.scrubbing.standardize.address.fields[]' "$CONFIG_FILE" | jq -c '.')
    
    # Verify emails with the same pattern
    while read -r entry; do
        local table=$(echo "$entry" | yq e '.table' -)
        local field=$(echo "$entry" | yq e '.field' -)
        local expected=$(yq e '.scrubbing.standardize.email.value' "$CONFIG_FILE")
        
        log "DEBUG" "Checking standardized email in $table.$field"
        
        local query="SELECT COUNT(DISTINCT $field) FROM $table;"
        local distinct_count=$(echo "$query" | dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -z "$distinct_count" ] || [ "$distinct_count" -ne 1 ]; then
            log "ERROR" "Found multiple distinct emails in $table.$field"
            status=1
        else
            log "INFO" "Email standardization verified for $table.$field"
        fi
    done < <(yq e -o=json '.scrubbing.standardize.email.fields[]' "$CONFIG_FILE" | jq -c '.')
    
    return $status
}

# Verify combination fields
verify_combinations() {
    local db=$1
    local status=0
    
    log "INFO" "Verifying combination fields"
    
    while IFS= read -r table; do
        local target_field=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .target_field" "$CONFIG_FILE")
        local separator=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .separator" "$CONFIG_FILE")
        
        log "DEBUG" "Checking combination field $target_field in table $table"
        
        # Check for NULL values
        local query="SELECT COUNT(*) FROM $table WHERE $target_field IS NULL;"
        local null_count=$(echo "$query" | dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -n "$null_count" ] && [ "$null_count" -gt 0 ]; then
            log "ERROR" "Found $null_count NULL values in combination field $table.$target_field"
            status=1
        fi
        
        # Check for separator presence
        local query="SELECT COUNT(*) FROM $table WHERE $target_field NOT LIKE '%${separator}%';"
        local missing_separator=$(echo "$query" | dbaccess "$db" - | grep -v "^$" | grep -v "count" | tr -d ' ')
        
        if [ -n "$missing_separator" ] && [ "$missing_separator" -gt 0 ]; then
            log "ERROR" "Found $missing_separator records without separator in $table.$target_field"
            status=1
        fi
    done < <(yq e '.scrubbing.combination_fields[].table' "$CONFIG_FILE")
    
    return $status
}

# Run all verifications
run_all_verifications() {
    local db=$1
    local status=0
    
    verify_excluded_tables "$db" || status=1
    verify_essential_records "$db" || status=1
    verify_record_counts "$db" || status=1
    verify_standardization "$db" || status=1
    verify_combinations "$db" || status=1
    
    return $status
}