#!/bin/bash

set -e

# Get script directory for relative paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/scripts/verification_functions.sh"

# Configuration and logging setup
CONFIG_FILE="$SCRIPT_DIR/config.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR=~/logs
LOG_PREFIX=$(yq e '.verification.logging.prefix' "$CONFIG_FILE")
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"

# Load database names from config
TEST_DB=$(yq e '.databases.testing.test_live' "$CONFIG_FILE")
TEMP_VERIFY=$(yq e '.databases.testing.temp_verify' "$CONFIG_FILE")
MARKER=$(yq e '.databases.testing.verification_marker' "$CONFIG_FILE")
SAMPLE_COUNT=$(yq e '.verification.excluded_table_samples' "$CONFIG_FILE")

# Create required directories
mkdir -p "$LOG_DIR"
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"

# Start verification process
log "INFO" "Starting verification process"
log "INFO" "Test database: $TEST_DB"
log "INFO" "Verification database: $TEMP_VERIFY"
log "INFO" "Working directory: $WORK_DIR"

# Test database connections
log "INFO" "Testing database connections"
test_db_connection "$TEST_DB" || exit 1

# STEP 1: Create verification database
log "INFO" "Creating verification database"
dbaccess sysmaster << EOF
DROP DATABASE IF EXISTS $TEMP_VERIFY;
CREATE DATABASE $TEMP_VERIFY WITH LOG;
EOF

# Give the database a moment to initialize
sleep 1

# STEP 2: Export data
log "INFO" "Exporting data from $TEST_DB..."
cd "$WORK_DIR"
rm -rf "${TEST_DB}.exp"
dbexport -d "$TEST_DB" > "$WORK_DIR/dbexport.log" 2>&1 || {
    log "ERROR" "Failed to export data"
    log "DEBUG" "dbexport log:"
    cat "$WORK_DIR/dbexport.log"
    exit 1
}

EXPORT_DIR="$WORK_DIR/${TEST_DB}.exp"
cd "$EXPORT_DIR"

# First run the full SQL to set up schema and permissions
cd "$HOME/work/test_live.exp" && \
dbaccess temp_verify test_live.sql

# Then load all the data
echo "LOAD FROM 'custo00100.unl' DELIMITER '|' INSERT INTO customers;
LOAD FROM 'emplo00101.unl' DELIMITER '|' INSERT INTO employees;
LOAD FROM 'proje00102.unl' DELIMITER '|' INSERT INTO projects;
LOAD FROM 'repos00103.unl' DELIMITER '|' INSERT INTO repositories;
LOAD FROM 'train00104.unl' DELIMITER '|' INSERT INTO training_config;
LOAD FROM 'train00105.unl' DELIMITER '|' INSERT INTO train_specific_data;" | dbaccess temp_verify -

for table in "${!table_files[@]}"; do
    unl_file="${table_files[$table]}"
    if [ -f "$unl_file" ]; then
        log "DEBUG" "Loading data for table $table from $unl_file"
        echo "LOAD FROM '$unl_file' DELIMITER '|' INSERT INTO $table;" | dbaccess "$TEMP_VERIFY" - || {
            log "ERROR" "Failed to load data into table $table"
            continue
        }
    else
        log "WARNING" "Data file $unl_file not found for table $table"
    fi
done

cd "$SCRIPT_DIR"

# STEP 5: Verify data was imported correctly
log "INFO" "Verifying data import..."
for table in "${!table_files[@]}"; do
    orig_count=$(echo "SELECT COUNT(*) FROM $table;" | dbaccess "$TEST_DB" - | grep -v "^$" | grep -v "count" | tr -d ' ')
    new_count=$(echo "SELECT COUNT(*) FROM $table;" | dbaccess "$TEMP_VERIFY" - | grep -v "^$" | grep -v "count" | tr -d ' ')
    log "DEBUG" "Table $table - Original: $orig_count, Imported: $new_count"
    
    if [ "$orig_count" != "$new_count" ]; then
        log "ERROR" "Count mismatch in table $table"
        log "ERROR" "Original: $orig_count, Imported: $new_count"
        exit 1
    fi
done

# STEP 6: Run verifications
verify_excluded_tables "$TEMP_VERIFY" "$MARKER" "$SAMPLE_COUNT" || {
    log "ERROR" "Excluded tables verification failed"
    exit 1
}

verify_essential_records "$TEMP_VERIFY" || {
    log "ERROR" "Essential records verification failed"
    exit 1
}

log "INFO" "Verification completed successfully"

# Close connections
echo "DATABASE sysmaster;" | dbaccess -

# Prompt for cleanup
read -p "Would you like to remove the temporary verification database now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "INFO" "Removing temporary verification database"
    dbaccess sysmaster << EOF
        DROP DATABASE $TEMP_VERIFY;
EOF
    log "INFO" "Temporary database removed"
else
    log "INFO" "Temporary database kept. To remove it later, run:"
    echo "echo 'DATABASE sysmaster; DROP DATABASE $TEMP_VERIFY;' | dbaccess -"
fi