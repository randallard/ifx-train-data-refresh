#!/bin/bash

# Helper script to remove excluded tables from export

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <config_file> <input_sql> <output_sql>"
    exit 1
fi

CONFIG_FILE="$1"
INPUT_SQL="$2"
OUTPUT_SQL="$3"

# Verify arguments exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

if [ ! -f "$INPUT_SQL" ]; then
    echo "ERROR: Input SQL file not found: $INPUT_SQL"
    exit 1
fi

if [ -z "$SOURCE_DB" ] || [ -z "$WORK_DIR" ]; then
    echo "ERROR: Required environment variables SOURCE_DB and WORK_DIR must be set"
    exit 1
fi

# Create array of excluded table names
mapfile -t EXCLUDED_TABLES < <(yq e '.excluded_tables[]' "$CONFIG_FILE")

# Function to extract UNL filenames for a table from the SQL file
get_unl_file_for_table() {
    local table_name="$1"
    local sql_file="$INPUT_SQL"    

    # Find the unload file name line that follows the TABLE line for this table name
    # First find the TABLE line for our table, then get the next line with "unload file name"
    awk -v table="$table_name" '
        $0 ~ "TABLE.*\"" table "\"" {found=1; next}
        found && $0 ~ "unload file name" {
            match($0, /unload file name = ([^ ]*\.unl)/, arr)
            if (arr[1]) {
                print arr[1]
                exit
            }
            found=0
        }
    ' "$sql_file"
}

# Create associative array for table to UNL file mapping
declare -A TABLE_UNL_FILES

# Initialize the mapping
for table in "${EXCLUDED_TABLES[@]}"; do
    unl_files=$(get_unl_file_for_table "$table")
    if [ -n "$unl_files" ]; then
        TABLE_UNL_FILES["$table"]="$unl_files"
        echo "INFO: Mapped table '$table' to UNL file(s): ${unl_files}"
    fi
done

# Create array of just the UNL files for excluded tables
mapfile -t EXCLUDED_UNL_FILES < <(
    for table in "${EXCLUDED_TABLES[@]}"; do
        if [ -n "${TABLE_UNL_FILES[$table]}" ]; then
            echo "${TABLE_UNL_FILES[$table]}"
        fi
    done | sort -u
)

# Remove excluded tables' UNL files
for unl_file in "${EXCLUDED_UNL_FILES[@]}"; do
    if [ -f "$WORK_DIR/${SOURCE_DB}.exp/$unl_file" ]; then
        echo "INFO: Removing UNL file: $unl_file"
        rm -f "$WORK_DIR/${SOURCE_DB}.exp/$unl_file"
    fi
done

# Create new SQL file without excluded tables
{
    echo "database ${TARGET_DB:-$SOURCE_DB};"
    echo

    while IFS= read -r line || [ -n "$line" ]; do
        skip_line=0
        for table in "${EXCLUDED_TABLES[@]}"; do
            if echo "$line" | grep -iE "(CREATE TABLE|DROP TABLE|INSERT INTO|LOAD FROM).*${table}($|[[:space:]]|\()" >/dev/null; then
                skip_line=1
                break
            fi
        done

        if [ $skip_line -eq 0 ]; then
            echo "$line"
        fi
    done < "$INPUT_SQL"
} > "$OUTPUT_SQL"

echo "INFO: SQL file cleaned and UNL files removed for excluded tables"