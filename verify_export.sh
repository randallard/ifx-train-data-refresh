#!/bin/bash

set -e

# Get script directory for relative paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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

# Create directories
mkdir -p "$LOG_DIR"
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"

# Logging function
log() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Test database connection function
test_db_connection() {
    local db_name=$1
    if ! echo "database $db_name; SELECT FIRST 1 * FROM systables;" | dbaccess - >/dev/null 2>&1; then
        log "ERROR" "Cannot connect to database: $db_name"
        exit 1
    fi
}

# Function to check if table exists
check_table_exists() {
    local db=$1
    local table=$2
    echo "database $db; SELECT tabname FROM systables WHERE tabname='$table';" | dbaccess - 2>/dev/null | grep -q "$table"
}

log "INFO" "Starting verification process"
log "INFO" "Test database: $TEST_DB"
log "INFO" "Verification database: $TEMP_VERIFY"

# Test database connections
log "INFO" "Testing database connections"
test_db_connection "$TEST_DB"

# STEP 1: Create verification database
log "INFO" "Creating verification database"
dbaccess sysmaster << EOF
DROP DATABASE IF EXISTS $TEMP_VERIFY;
CREATE DATABASE $TEMP_VERIFY WITH LOG;
EOF

# Give the database a moment to initialize
sleep 1

# STEP 2: Export from test database and import to verification database
log "INFO" "Exporting data from $TEST_DB..."
cd "$WORK_DIR"
rm -rf test_live.exp
dbexport -d "$TEST_DB" || {
    log "ERROR" "Failed to export data"
    exit 1
}

log "INFO" "Importing data to $TEMP_VERIFY..."
dbaccess "$TEMP_VERIFY" "$WORK_DIR/test_live.exp/test_live.sql" || {
    log "ERROR" "Failed to import data"
    log "DEBUG" "Check $WORK_DIR/test_live.exp/test_live.sql for details"
    exit 1
}

# Verify import was successful by checking for a table
if ! check_table_exists "$TEMP_VERIFY" "customers"; then
    log "ERROR" "Import appears to have failed - customers table not found"
    exit 1
fi

cd "$SCRIPT_DIR"  # Return to script directory for config access

# STEP 3: Mark records in excluded tables
log "INFO" "Marking records in excluded tables"
while IFS= read -r table; do
    log "INFO" "Processing excluded table: $table"
    
    # Mark first N records
    dbaccess "$TEMP_VERIFY" << EOF
    UPDATE $table 
    SET config_key = '$MARKER' || config_key,
        config_value = '$MARKER' || config_value;
EOF
    
    # Mark last N records
    dbaccess "$TEMP_VERIFY" << EOF
    UPDATE $table 
    SET config_key = '$MARKER' || config_key,
        config_value = '$MARKER' || config_value;
EOF
    
    log "INFO" "Marked $((SAMPLE_COUNT * 2)) records in $table"
done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")

# STEP 4: Verify the results
log "INFO" "Verifying results"

# Verify excluded tables
log "INFO" "Checking excluded tables"
while IFS= read -r table; do
    count=$(dbaccess "$TEMP_VERIFY" << EOF
    SELECT COUNT(*) FROM $table 
    WHERE ${columns%|*} LIKE '${MARKER}%';
EOF
    )
    
    if [ "$count" -ne $((SAMPLE_COUNT * 2)) ]; then
        log "ERROR" "Excluded table $table verification failed: Expected $((SAMPLE_COUNT * 2)) marked records, found $count"
        exit 1
    fi
    log "INFO" "Excluded table $table verified successfully"
done < <(yq e '.excluded_tables[]' "$CONFIG_FILE")

# Verify essential records exist
log "INFO" "Checking essential records"
while IFS= read -r id; do
    count=$(dbaccess "$TEMP_VERIFY" << EOF
    SELECT COUNT(*) FROM $(yq e '.tables.primary_table.name' "$CONFIG_FILE")
    WHERE $(yq e '.tables.primary_table.primary_key' "$CONFIG_FILE") = $id;
EOF
    )
    
    if [ "$count" -ne 1 ]; then
        log "ERROR" "Essential record $id not found"
        exit 1
    fi
    log "INFO" "Essential record $id verified"
done < <(yq e '.essential_records.records[].id' "$CONFIG_FILE")

log "INFO" "Verification completed successfully"

# Close any open connections to the database
echo "DATABASE sysmaster;" | dbaccess -

# Prompt for cleanup
read -p "Would you like to remove the temporary verification database now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "INFO" "Removing temporary verification database"
    echo "DATABASE $TEMP_VERIFY; DROP DATABASE $TEMP_VERIFY;" | dbaccess -
else
    log "INFO" "Temporary database kept. To remove it later, run: echo 'DATABASE $TEMP_VERIFY; DROP DATABASE $TEMP_VERIFY;' | dbaccess -"
fi