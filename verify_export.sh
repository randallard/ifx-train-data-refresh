#!/bin/bash

set -e

CONFIG_FILE="config.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR=$(yq e '.verification.logging.directory' "$CONFIG_FILE")
LOG_PREFIX=$(yq e '.verification.logging.prefix' "$CONFIG_FILE")
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Logging function
log() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Database connection test function
test_db_connection() {
    local db_name=$1
    if ! dbaccess "$db_name" "SELECT FIRST 1 * FROM systables;" >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to database: $db_name"
        exit 1
    fi
}

# Load database names from config
TEST_DB=$(yq e '.databases.testing.test_db' "$CONFIG_FILE")
TEMP_VERIFY=$(yq e '.databases.testing.temp_verify' "$CONFIG_FILE")
MARKER=$(yq e '.databases.testing.verification_marker' "$CONFIG_FILE")
SAMPLE_COUNT=$(yq e '.verification.excluded_table_samples' "$CONFIG_FILE")

log "INFO" "Starting verification process"
log "INFO" "Test database: $TEST_DB"
log "INFO" "Verification database: $TEMP_VERIFY"

# Test database connections
log "INFO" "Testing database connections"
test_db_connection "$TEST_DB"

# STEP 1: Create verification database
log "INFO" "STEP 1: Creating verification database"

# Create new database
log "INFO" "Creating $TEMP_VERIFY database"
echo "DATABASE $TEMP_VERIFY;" | dbaccess - || {
    log "ERROR" "Failed to create $TEMP_VERIFY database"
    exit 1
}

# Copy schema and data from test database
log "INFO" "Copying schema and data from $TEST_DB to $TEMP_VERIFY"
dbexport -d "$TEST_DB" -o schema.sql
dbaccess "$TEMP_VERIFY" schema.sql || {
    log "ERROR" "Failed to copy schema to $TEMP_VERIFY"
    exit 1
}

# Modify excluded tables in temp_verify
log "INFO" "Modifying excluded tables in $TEMP_VERIFY"
while IFS= read -r table; do
    log "INFO" "Modifying excluded table: $table"
    
    # Get columns for concatenation
    columns=$(dbschema -d "$TEMP_VERIFY" -t "$table" -c | grep -v "^$")
    concat_cols=$(echo "$columns" | tr '\n' '||')
    
    # Modify top records
    dbaccess "$TEMP_VERIFY" << EOF
    UPDATE FIRST $SAMPLE_COUNT $table 
    SET ${columns%|*} = '$MARKER' || $concat_cols;
EOF
    
    # Modify bottom records
    dbaccess "$TEMP_VERIFY" << EOF
    UPDATE FIRST $SAMPLE_COUNT $table 
    WHERE id IN (SELECT id FROM $table ORDER BY id DESC FIRST $SAMPLE_COUNT)
    SET ${columns%|*} = '$MARKER' || $concat_cols;
EOF
    
    log "INFO" "Modified $((SAMPLE_COUNT * 2)) records in $table"
done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")

# STEP 2: Run export and import
log "INFO" "STEP 2: Running export and import process"

# Save original database checksums if enabled
if [ "$(yq e '.verification.checksums.enabled' "$CONFIG_FILE")" = "true" ]; then
    log "INFO" "Calculating original database checksums"
    CHECKSUM_ALGO=$(yq e '.verification.checksums.algorithm' "$CONFIG_FILE")
    while IFS= read -r table; do
        dbexport -d "$TEST_DB" -t "SELECT * FROM $table ORDER BY id" -o "${table}_orig.dat"
        $CHECKSUM_ALGO "${table}_orig.dat" > "${table}_orig.checksum"
    done < <(dbschema -d "$TEST_DB" -t)
fi

# Run export script
log "INFO" "Running export script on $TEST_DB"
./export.sh || {
    log "ERROR" "Export script failed"
    exit 1
}

# Run import script to temp_verify
log "INFO" "Running import script to $TEMP_VERIFY"
DATABASES_TARGET_NAME="$TEMP_VERIFY" ./import.sh || {
    log "ERROR" "Import script failed"
    exit 1
}

# STEP 3: Verification
log "INFO" "STEP 3: Running verifications"

# Verify excluded tables
log "INFO" "Verifying excluded tables"
while IFS= read -r table; do
    log "INFO" "Checking excluded table: $table"
    count=$(dbaccess "$TEMP_VERIFY" << EOF
    SELECT COUNT(*) FROM $table 
    WHERE ${columns%|*} LIKE '${MARKER}%';
EOF
    )
    
    if [ "$count" -ne $((SAMPLE_COUNT * 2)) ]; then
        log "ERROR" "Excluded table $table verification failed: Expected $((SAMPLE_COUNT * 2)) marked records, found $count"
    else
        log "INFO" "Excluded table $table verified successfully"
    fi
done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")

# Verify scrubbed fields
log "INFO" "Verifying scrubbed fields"

# Check random name fields
while IFS= read -r table; do
    fields=($(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .fields[]" "$CONFIG_FILE"))
    for field in "${fields[@]}"; do
        log "INFO" "Checking random names in $table.$field"
        # Verify field contains only expected patterns (adjective-noun for github style)
        invalid_count=$(dbaccess "$TEMP_VERIFY" << EOF
        SELECT COUNT(*) FROM $table 
        WHERE $field NOT LIKE '%-%' 
        OR $field LIKE '% %';
EOF
        )
        if [ "$invalid_count" -gt 0 ]; then
            log "ERROR" "Found $invalid_count invalid random names in $table.$field"
        else
            log "INFO" "Random names in $table.$field verified successfully"
        fi
    done
done < <(yq e '.scrubbing.random_names[].table' "$CONFIG_FILE")

# Check standardized fields
while IFS= read -r rule; do
    table=$(echo "$rule" | yq e '.table' -)
    field=$(echo "$rule" | yq e '.field' -)
    value=$(echo "$rule" | yq e '.value' -)
    log "INFO" "Checking standardized field $table.$field"
    
    invalid_count=$(dbaccess "$TEMP_VERIFY" << EOF
    SELECT COUNT(*) FROM $table 
    WHERE $field != '$value';
EOF
    )
    
    if [ "$invalid_count" -gt 0 ]; then
        log "ERROR" "Found $invalid_count non-standardized values in $table.$field"
    else
        log "INFO" "Standardized field $table.$field verified successfully"
    fi
done < <(yq e '.scrubbing.standardize.*.fields[]' "$CONFIG_FILE")

# Verify essential records
log "INFO" "Verifying essential records"
while IFS= read -r id; do
    log "INFO" "Checking essential record ID: $id"
    
    # Check main record
    count=$(dbaccess "$TEMP_VERIFY" << EOF
    SELECT COUNT(*) FROM main_table 
    WHERE id = $id;
EOF
    )
    
    if [ "$count" -ne 1 ]; then
        log "ERROR" "Essential record $id not found in main_table"
    else
        log "INFO" "Essential record $id verified successfully"
        
        # Check dependencies if enabled
        if [ "$(yq e '.essential_records.main_table.include_dependencies' "$CONFIG_FILE")" = "true" ]; then
            while IFS= read -r dep_table; do
                dep_count=$(dbaccess "$TEMP_VERIFY" << EOF
                SELECT COUNT(*) FROM $dep_table 
                WHERE main_id = $id;
EOF
                )
                orig_count=$(dbaccess "$TEST_DB" << EOF
                SELECT COUNT(*) FROM $dep_table 
                WHERE main_id = $id;
EOF
                )
                
                if [ "$dep_count" -ne "$orig_count" ]; then
                    log "ERROR" "Dependency mismatch for record $id in $dep_table: Expected $orig_count, found $dep_count"
                else
                    log "INFO" "Dependencies for record $id in $dep_table verified successfully"
                fi
            done < <(dbschema -d "$TEST_DB" -t main_table -r)
        fi
    fi
done < <(yq e '.essential_records.main_table[].id' "$CONFIG_FILE")

# Verify source database unchanged
if [ "$(yq e '.verification.checksums.enabled' "$CONFIG_FILE")" = "true" ]; then
    log "INFO" "Verifying source database integrity"
    while IFS= read -r table; do
        dbexport -d "$TEST_DB" -t "SELECT * FROM $table ORDER BY id" -o "${table}_new.dat"
        if ! $CHECKSUM_ALGO -c "${table}_orig.checksum"; then
            log "ERROR" "Source database table $table has been modified"
        else
            log "INFO" "Source database table $table integrity verified"
        fi
        rm "${table}_orig.dat" "${table}_new.dat" "${table}_orig.checksum"
    done < <(dbschema -d "$TEST_DB" -t)
fi

# Create cleanup script
cat > "$(yq e '.databases.testing.cleanup_script' "$CONFIG_FILE")" << EOF
#!/bin/bash
echo "Dropping database $TEMP_VERIFY"
echo "DATABASE $TEMP_VERIFY; DROP DATABASE $TEMP_VERIFY;" | dbaccess -
EOF
chmod +x "$(yq e '.databases.testing.cleanup_script' "$CONFIG_FILE")"

# Prompt for cleanup
read -p "Would you like to remove the temporary verification database now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "INFO" "Removing temporary verification database"
    echo "DATABASE $TEMP_VERIFY; DROP DATABASE $TEMP_VERIFY;" | dbaccess -
else
    log "INFO" "Temporary database kept. To remove it later, run: echo 'DATABASE $TEMP_VERIFY; DROP DATABASE $TEMP_VERIFY;' | dbaccess -"
fi