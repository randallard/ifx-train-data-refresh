#!/bin/bash

# Enable error tracing
set -e
set -o pipefail

# Get script directory for relative paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Argument validation
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <input_file> <output_file>"
    exit 1
fi

INPUT_FILE=$1
OUTPUT_FILE=$2
CONFIG_FILE="$SCRIPT_DIR/config.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"

# Source verification functions for consistent logging and SQL handling
source "$SCRIPT_DIR/scripts/verification_functions.sh"

LOG_PREFIX="scrub_"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"

# Load word lists with error handling
if [ ! -f "$SCRIPT_DIR/adjectives.txt" ] || [ ! -f "$SCRIPT_DIR/nouns.txt" ]; then
    log "ERROR" "Word list files not found" "$LOG_FILE"
    exit 1
fi

ADJECTIVES=($(cat "$SCRIPT_DIR/adjectives.txt"))
NOUNS=($(cat "$SCRIPT_DIR/nouns.txt"))

# Generate random name based on style using verified random number generation
generate_name() {
    local style=${1:-github}
    case $style in
        github)
            # Use the same RANDOM seed approach as verify_export
            local seed=$(yq e '.export.random_seed' "$CONFIG_FILE")
            RANDOM=$seed
            
            local adj=${ADJECTIVES[$RANDOM % ${#ADJECTIVES[@]}]}
            local noun=${NOUNS[$RANDOM % ${#NOUNS[@]}]}
            echo "${adj}-${noun}"
            ;;
        *)
            log "ERROR" "Unknown name style: $style" "$LOG_FILE"
            exit 1
            ;;
    esac
}

log "INFO" "Starting data scrubbing process" "$LOG_FILE"

# Create temporary file for processing using mktemp as in verify_export
TEMP_FILE=$(mktemp)
cp "$INPUT_FILE" "$TEMP_FILE" || {
    log "ERROR" "Failed to create temporary file" "$LOG_FILE"
    exit 1
}

# Process combination fields first
log "INFO" "Processing combination fields..." "$LOG_FILE"
while IFS= read -r table; do
    log "INFO" "Processing combination fields for table: $table" "$LOG_FILE"
    
    fields=($(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .fields[].source_field" "$CONFIG_FILE"))
    separator=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .separator" "$CONFIG_FILE")
    target_field=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .target_field" "$CONFIG_FILE")
    
    # Generate and store random names for each source field
    declare -A field_values
    for field in "${fields[@]}"; do
        style=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .fields[] | select(.source_field == \"$field\") | .random_style" "$CONFIG_FILE")
        if [ -n "$style" ]; then
            field_values[$field]=$(generate_name "$style")
            log "DEBUG" "Generated name for $field: ${field_values[$field]}" "$LOG_FILE"
        else
            field_values[$field]="\1"
        fi
    done
    
    # Combine field values with separator
    combined_value=""
    for field in "${fields[@]}"; do
        if [ -n "$combined_value" ]; then
            combined_value="${combined_value}${separator}${field_values[$field]}"
        else
            combined_value="${field_values[$field]}"
        fi
    done
    
    # Update using sed with error checking
    if ! sed -i "s/'[^']*'/'$combined_value'/g" "$TEMP_FILE"; then
        log "ERROR" "Failed to update combination fields for table $table" "$LOG_FILE"
        rm -f "$TEMP_FILE"
        exit 1
    fi
done < <(yq e '.scrubbing.combination_fields[].table' "$CONFIG_FILE")

# Process random name fields
log "INFO" "Processing random name fields..." "$LOG_FILE"
while IFS= read -r table; do
    log "INFO" "Processing random names for table: $table" "$LOG_FILE"
    
    fields=($(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .fields[]" "$CONFIG_FILE"))
    style=$(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .style" "$CONFIG_FILE")
    
    [ -z "$style" ] && style="github"
    
    for field in "${fields[@]}"; do
        if ! sed -i "s/'[^']*'/'$(generate_name "$style")'/g" "$TEMP_FILE"; then
            log "ERROR" "Failed to update random names for table $table, field $field" "$LOG_FILE"
            rm -f "$TEMP_FILE"
            exit 1
        fi
    done
done < <(yq e '.scrubbing.random_names[].table' "$CONFIG_FILE")

# Process standardization rules
log "INFO" "Processing standardization rules..." "$LOG_FILE"
while IFS= read -r rule; do
    table=$(echo "$rule" | yq e '.table' -)
    field=$(echo "$rule" | yq e '.field' -)
    value=$(echo "$rule" | yq e '.value' -)
    
    log "INFO" "Standardizing $field in table $table" "$LOG_FILE"
    
    if ! sed -i "s/'[^']*'/'$value'/g" "$TEMP_FILE"; then
        log "ERROR" "Failed to update standardized value for table $table, field $field" "$LOG_FILE"
        rm -f "$TEMP_FILE"
        exit 1
    fi
done < <(yq e '.scrubbing.standardize.*.fields[]' "$CONFIG_FILE")

# Move processed file to output with error checking
if ! mv "$TEMP_FILE" "$OUTPUT_FILE"; then
    log "ERROR" "Failed to move processed file to output location" "$LOG_FILE"
    rm -f "$TEMP_FILE"
    exit 1
fi

log "INFO" "Data scrubbing completed successfully" "$LOG_FILE"