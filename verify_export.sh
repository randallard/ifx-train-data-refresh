#!/bin/bash

# Enable error tracing
set -e
set -o pipefail

# Get script directory for relative paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "DEBUG[1]: SCRIPT_DIR=$SCRIPT_DIR"

# Set up work directory
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"

# Configuration and logging setup
CONFIG_FILE="$SCRIPT_DIR/config.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"

# Source verification functions
source "$SCRIPT_DIR/scripts/verification_functions.sh"

# Load configuration
LOG_PREFIX=$(yq e '.verification.logging.prefix' "$CONFIG_FILE")
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"
TEST_DB=$(yq e '.databases.testing.test_live' "$CONFIG_FILE")
TEMP_VERIFY=$(yq e '.databases.testing.temp_verify' "$CONFIG_FILE")
MARKER=$(yq e '.databases.testing.verification_marker' "$CONFIG_FILE")
SAMPLE_COUNT=$(yq e '.verification.excluded_table_samples' "$CONFIG_FILE")
PRIMARY_TABLE=$(yq e '.tables.primary_table.name' "$CONFIG_FILE")
PRIMARY_KEY=$(yq e '.tables.primary_table.primary_key' "$CONFIG_FILE")

# Start verification process
log "INFO" "Starting verification process" "$LOG_FILE"
log "INFO" "Test database: $TEST_DB" "$LOG_FILE"
log "INFO" "Verification database: $TEMP_VERIFY" "$LOG_FILE"

# Test database connections
log "INFO" "Testing database connections" "$LOG_FILE"
test_db_connection "$TEST_DB" || exit 1

# Create verification database
log "INFO" "Creating verification database" "$LOG_FILE"
echo "database sysmaster;
DROP DATABASE IF EXISTS $TEMP_VERIFY;
CREATE DATABASE $TEMP_VERIFY WITH LOG;" | dbaccess - 

# Give the database a moment to initialize
sleep 1

# Export and import test data
log "INFO" "Exporting test data..." "$LOG_FILE"
cd "$WORK_DIR"
rm -rf "${TEST_DB}.exp"
dbexport -d "$TEST_DB" > "$WORK_DIR/dbexport.log" 2>&1 || {
    log "ERROR" "Failed to export data" "$LOG_FILE"
    cat "$WORK_DIR/dbexport.log"
    exit 1
}

# Import to verification database
cd "$HOME/work/${TEST_DB}.exp"
log "INFO" "Importing schema..." "$LOG_FILE"
dbaccess "$TEMP_VERIFY" "${TEST_DB}.sql" || {
    log "ERROR" "Failed to import schema" "$LOG_FILE"
    exit 1
}

# Load data files
for unl_file in *.unl; do
    if [ -f "$unl_file" ]; then
        base_name=$(echo "$unl_file" | sed 's/\([[:alpha:]]*\)[0-9]*\.unl$/\1/')
        table_name=""
        
        case "$base_name" in
            custo) table_name="customers" ;;
            emplo) table_name="employees" ;;
            proje) table_name="projects" ;;
            repos) table_name="repositories" ;;
            train)
                if [[ "$unl_file" == *"00104"* ]]; then
                    table_name="training_config"
                else
                    table_name="train_specific_data"
                fi
                ;;
        esac
        
        if [ -n "$table_name" ]; then
            log "INFO" "Loading data for $table_name..." "$LOG_FILE"
            echo "LOAD FROM '$unl_file' DELIMITER '|' INSERT INTO $table_name;" | \
            dbaccess "$TEMP_VERIFY" - || {
                log "ERROR" "Failed to load data from $unl_file" "$LOG_FILE"
                exit 1
            }
        fi
    fi
done

# Run verifications
log "INFO" "Running verifications..." "$LOG_FILE"
cd "$SCRIPT_DIR"
if ! run_all_verifications "$TEMP_VERIFY"; then
    log "ERROR" "Verification failed" "$LOG_FILE"
    exit 1
fi

log "INFO" "All verifications completed successfully" "$LOG_FILE"

# Prompt for cleanup
read -p "Would you like to remove the temporary verification database now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "INFO" "Removing temporary verification database" "$LOG_FILE"
    echo "database sysmaster;
    DROP DATABASE $TEMP_VERIFY;" | dbaccess -
    log "INFO" "Temporary database removed" "$LOG_FILE"
else
    log "INFO" "Temporary database kept" "$LOG_FILE"
    echo "To remove later, run: echo 'database sysmaster; DROP DATABASE $TEMP_VERIFY;' | dbaccess -"
fi