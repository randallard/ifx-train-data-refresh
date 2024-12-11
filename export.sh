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
LOG_PREFIX="export_"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"
SOURCE_DB=$(yq e '.databases.source.name' "$CONFIG_FILE")
TARGET_DB=$(yq e '.databases.target.name' "$CONFIG_FILE")

# Start export process
log "INFO" "Starting export process" "$LOG_FILE"
log "INFO" "Source database: $SOURCE_DB" "$LOG_FILE"
log "INFO" "Target database: $TARGET_DB" "$LOG_FILE"

# Test database connections
log "INFO" "Testing database connections" "$LOG_FILE"
test_db_connection "$SOURCE_DB" || {
    log "ERROR" "Cannot connect to source database: $SOURCE_DB" "$LOG_FILE"
    exit 1
}

# Create work directory for export
cd "$WORK_DIR"
rm -rf "${SOURCE_DB}.exp"

# Export the database
log "INFO" "Exporting source data..." "$LOG_FILE"
dbexport -d "$SOURCE_DB" > "$WORK_DIR/dbexport.log" 2>&1 || {
    log "ERROR" "Failed to export data" "$LOG_FILE"
    cat "$WORK_DIR/dbexport.log"
    exit 1
}

# Move to export directory
cd "$HOME/work/${SOURCE_DB}.exp"

# Apply data scrubbing if scrub_data.sh exists
if [ -f "$SCRIPT_DIR/scripts/scrub_data.sh" ]; then
    log "INFO" "Applying data scrubbing..." "$LOG_FILE"
    "$SCRIPT_DIR/scripts/scrub_data.sh" "${SOURCE_DB}.sql" "${SOURCE_DB}_scrubbed.sql" || {
        log "ERROR" "Data scrubbing failed" "$LOG_FILE"
        exit 1
    }
else
    log "WARNING" "scrub_data.sh not found - skipping data scrubbing" "$LOG_FILE"
    cp "${SOURCE_DB}.sql" "${SOURCE_DB}_scrubbed.sql"
fi

log "INFO" "Export process completed successfully" "$LOG_FILE"
echo "Export completed. Output file: ${WORK_DIR}/${SOURCE_DB}.exp/${SOURCE_DB}_scrubbed.sql"