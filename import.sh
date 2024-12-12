#!/bin/bash

# Enable error tracing to match verify_export.sh and export.sh
set -e
set -o pipefail

# Get script directory for relative paths (matching verify_export.sh pattern)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "DEBUG[1]: SCRIPT_DIR=$SCRIPT_DIR"

# Set up work directory (matching export.sh pattern)
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"

# Configuration and logging setup (matching verify_export.sh pattern)
CONFIG_FILE="$SCRIPT_DIR/config.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"

# Source verification functions (matching other scripts)
source "$SCRIPT_DIR/scripts/verification_functions.sh"

# Load configuration (matching verify_export.sh pattern)
LOG_PREFIX="import_"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"
SOURCE_DB=$(yq e '.databases.source.name' "$CONFIG_FILE")
TARGET_DB=$(yq e '.databases.target.name' "$CONFIG_FILE")

log "INFO" "Starting import process" "$LOG_FILE"
log "INFO" "Source database: $SOURCE_DB" "$LOG_FILE"
log "INFO" "Target database: $TARGET_DB" "$LOG_FILE"

# Create target database if it doesn't exist (matching verify_export.sh pattern)
log "INFO" "Initializing target database..." "$LOG_FILE"
echo "database sysmaster;
DROP DATABASE IF EXISTS $TARGET_DB;
CREATE DATABASE $TARGET_DB WITH LOG;" | dbaccess - 2>> "$LOG_FILE" || {
    log "ERROR" "Failed to create target database" "$LOG_FILE"
    exit 1
}

# Give the database a moment to initialize
sleep 1

# Debug: Show file existence check
log "DEBUG" "Checking for scrubbed SQL file in: $WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}_scrubbed.sql" "$LOG_FILE"
if [ ! -d "$WORK_DIR/${SOURCE_DB}.exp" ]; then
    log "ERROR" "Export directory not found: $WORK_DIR/${SOURCE_DB}.exp" "$LOG_FILE"
    # Check if there's a combined SQL file
    if [ -f "$WORK_DIR/combined.sql" ]; then
        log "INFO" "Found combined.sql file" "$LOG_FILE"
        IMPORT_FILE="$WORK_DIR/combined.sql"
    else
        log "ERROR" "No SQL files found for import" "$LOG_FILE"
        exit 1
    fi
else
    # Look for available SQL files
    log "DEBUG" "Listing available SQL files:" "$LOG_FILE"
    ls -la "$WORK_DIR/${SOURCE_DB}.exp"/*.sql >> "$LOG_FILE" 2>&1 || true

    # Check for scrubbed SQL file
    if [ ! -f "$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}_scrubbed.sql" ]; then
        # Check if we have the regular SQL file as fallback
        if [ -f "$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}.sql" ]; then
            log "INFO" "Using non-scrubbed SQL file as fallback" "$LOG_FILE"
            IMPORT_FILE="$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}.sql"
        else
            # Check for combined.sql as final fallback
            if [ -f "$WORK_DIR/combined.sql" ]; then
                log "INFO" "Using combined.sql file" "$LOG_FILE"
                IMPORT_FILE="$WORK_DIR/combined.sql"
            else
                log "ERROR" "No SQL file found for import" "$LOG_FILE"
                exit 1
            fi
        fi
    else
        IMPORT_FILE="$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}_scrubbed.sql"
    fi
fi

# Import data with proper error handling
log "INFO" "Importing data from $IMPORT_FILE to $TARGET_DB..." "$LOG_FILE"
if ! dbaccess "$TARGET_DB" "$IMPORT_FILE" > "$WORK_DIR/dbaccess.log" 2>&1; then
    log "ERROR" "Failed to import data to $TARGET_DB" "$LOG_FILE"
    log "ERROR" "dbaccess output:" "$LOG_FILE"
    cat "$WORK_DIR/dbaccess.log" >> "$LOG_FILE"
    exit 1
fi

# Verify essential records after import (matching verification_functions.sh pattern)
log "INFO" "Verifying essential records..." "$LOG_FILE"
if ! verify_essential_dependencies "$TARGET_DB"; then
    log "ERROR" "Essential record verification failed" "$LOG_FILE"
    exit 1
fi

# Verify excluded tables maintained integrity (matching verification_functions.sh pattern)
while IFS= read -r table; do
    log "INFO" "Verifying excluded table: $table" "$LOG_FILE"
    if ! check_table_exists "$TARGET_DB" "$table"; then
        log "ERROR" "Excluded table $table not found in target database" "$LOG_FILE"
        exit 1
    fi
done < <(get_excluded_tables)

log "INFO" "Import completed successfully" "$LOG_FILE"