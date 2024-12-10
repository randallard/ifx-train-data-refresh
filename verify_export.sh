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

# Define table name mappings (truncated to full)
declare -A TABLE_MAPPINGS=(
    ["custo"]="customers"
    ["emplo"]="employees"
    ["proje"]="projects"
    ["repos"]="repositories"
    ["train"]="training_config"
    ["train"]="train_specific_data"
)

# Start verification process
log "INFO" "Starting verification process"
log "INFO" "Test database: $TEST_DB"
log "INFO" "Verification database: $TEMP_VERIFY"
log "INFO" "Working directory: $WORK_DIR"

# Test database connections
log "INFO" "Testing database connections"
test_db_connection "$TEST_DB" || exit 1

# Create verification database
log "INFO" "Creating verification database"
dbaccess sysmaster << EOF
DROP DATABASE IF EXISTS $TEMP_VERIFY;
CREATE DATABASE $TEMP_VERIFY WITH LOG;
EOF

# Give the database a moment to initialize
sleep 1

# Export and import test data
log "INFO" "Exporting and importing test data..."
cd "$WORK_DIR"
rm -rf "${TEST_DB}.exp"
dbexport -d "$TEST_DB" > "$WORK_DIR/dbexport.log" 2>&1 || {
    log "ERROR" "Failed to export data"
    log "DEBUG" "dbexport log:"
    cat "$WORK_DIR/dbexport.log"
    exit 1
}

# Import to verification database
cd "$HOME/work/${TEST_DB}.exp"
dbaccess "$TEMP_VERIFY" "${TEST_DB}.sql" || {
    log "ERROR" "Failed to import database tables"
    exit 1
}

# Get list of tables from the database
tables=($(echo "SELECT TRIM(tabname) FROM systables WHERE tabtype='T' AND tabid > 99;" | \
          dbaccess "$TEMP_VERIFY" - 2>/dev/null | grep -v "^$" | grep -v "tabname"))

# Load all data files
for unl_file in *.unl; do
    if [ -f "$unl_file" ]; then
        # Extract the base name without sequence number and .unl
        base_name=$(echo "$unl_file" | sed 's/\([[:alpha:]]*\)[0-9]*\.unl$/\1/')
        
        # Find the matching full table name
        table_name=""
        for t in "${tables[@]}"; do
            if [[ "$t" == "$base_name"* ]]; then
                table_name="$t"
                break
            fi
        done
        
        if [ -z "$table_name" ]; then
            log "WARNING" "Could not find matching table for $unl_file, skipping..."
            continue
        fi
        
        log "DEBUG" "Loading data for table $table_name from $unl_file"
        echo "LOAD FROM '$unl_file' DELIMITER '|' INSERT INTO $table_name;" | \
        dbaccess "$TEMP_VERIFY" - || {
            log "ERROR" "Failed to load data from $unl_file into table $table_name"
            exit 1
        }
    fi
done

cd "$SCRIPT_DIR"

# Run all verifications
log "INFO" "Running verifications..."
if ! run_all_verifications "$TEMP_VERIFY"; then
    log "ERROR" "One or more verifications failed"
    exit 1
fi

log "INFO" "All verifications completed successfully"

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