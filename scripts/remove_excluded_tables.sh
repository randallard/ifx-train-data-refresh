#!/bin/bash

# Enable error handling
set -e
set -o pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <config_file> <input_sql> <output_sql>"
    exit 1
fi

CONFIG_FILE="$1"
INPUT_SQL="$2"
OUTPUT_SQL="$3"

# Verify required files and environment variables
for file in "$CONFIG_FILE" "$INPUT_SQL"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: Required file not found: $file"
        exit 1
    fi
done

if [ -z "$SOURCE_DB" ] || [ -z "$WORK_DIR" ]; then
    echo "ERROR: SOURCE_DB and WORK_DIR environment variables must be set"
    exit 1
fi

# Create temp directory for processing
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Get excluded tables from config
mapfile -t EXCLUDED_TABLES < <(yq e '.excluded_tables[]' "$CONFIG_FILE")
for table in "${EXCLUDED_TABLES[@]}"; do
    echo "INFO: found excluded table '$table'"
done

# Function to extract UNL filename for a table
get_unl_filename() {
    local table_name="$1"
    local sql_file="$2"
    
    awk -v table="$table_name" '
        # Match either exact table name or schema-qualified table name
        $0 ~ "TABLE.*[\.|\"]" table "[\"| ]" {in_table=1; next}
        in_table && $0 ~ "unload file name" {
            match($0, /unload file name = ([^ ]*\.unl)/, arr)
            if (arr[1]) {
                print arr[1]
                exit
            }
            in_table=0
        }
    ' "$sql_file"
}

# Create mapping of tables to UNL files
declare -A TABLE_UNL_FILES
for table in "${EXCLUDED_TABLES[@]}"; do
    echo "INFO: remove processing excluded table '$table'"
    unl_file=$(get_unl_filename "$table" "$INPUT_SQL")
    if [ -n "$unl_file" ]; then
        TABLE_UNL_FILES["$table"]="$unl_file"
        echo "INFO: Mapped excluded table '$table' to UNL file: $unl_file"
    else
        echo "ERROR: Failed to find UNL file for $table: $unl_file"
        exit 1
    fi
done

# Remove UNL files for excluded tables
for table in "${!TABLE_UNL_FILES[@]}"; do
    unl_file="${TABLE_UNL_FILES[$table]}"
    if [ -f "$WORK_DIR/${SOURCE_DB}.exp/$unl_file" ]; then
        echo "INFO: Removing UNL file for excluded table $table: $unl_file"
        rm -f "$WORK_DIR/${SOURCE_DB}.exp/$unl_file"
    fi
done

# verify Removal of UNL files for excluded tables
for table in "${!TABLE_UNL_FILES[@]}"; do
    unl_file="${TABLE_UNL_FILES[$table]}"
    echo "INFO: verify unl file removed for excluded table $table: $unl_file"
    if [ -f "$WORK_DIR/${SOURCE_DB}.exp/$unl_file" ]; then
        echo "ERROR: unl file still exists for excluded table $table: $unl_file"
        exit 1
    else
        echo "INFO: verified unl file removed for excluded table $table: $unl_file"
    fi
done

echo "INFO: Completed removing excluded tables"