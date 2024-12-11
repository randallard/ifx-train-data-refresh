#!/bin/bash

# Enable error tracing
set -e
set -o pipefail

# Get script directory for relative paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$(dirname "$SCRIPT_DIR")"  # Move up one directory

# Argument validation
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <input_file> <output_file>"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"
CONFIG_FILE="config.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"

# Source verification functions
source "./scripts/verification_functions.sh"

LOG_PREFIX="scrub_"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"

# Load word lists with error handling
if [ ! -f "adjectives.txt" ] || [ ! -f "nouns.txt" ]; then
    log "ERROR" "Word list files not found" "$LOG_FILE"
    exit 1
fi

ADJECTIVES=($(cat "adjectives.txt"))
NOUNS=($(cat "nouns.txt"))

# Helper function to escape special characters for sed
escape_for_sed() {
    echo "$1" | sed 's/[&/\]/\\&/g'
}

# Generate random name based on style using verified random number generation
generate_name() {
    local style=${1:-github}
    case $style in
        github)
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

# Function to process combination fields for a table
process_combination_fields() {
    local table=$1
    local temp_file=$2
    
    log "INFO" "Processing combination fields for table: $table" "$LOG_FILE"
    
    local fields=($(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .fields[].source_field" "$CONFIG_FILE"))
    local separator=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .separator" "$CONFIG_FILE")
    local target_field=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .target_field" "$CONFIG_FILE")
    
    # Generate and store random names for each source field
    declare -A field_values
    for field in "${fields[@]}"; do
        local style=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .fields[] | select(.source_field == \"$field\") | .random_style" "$CONFIG_FILE")
        if [ -n "$style" ]; then
            local name=$(generate_name "$style")
            field_values[$field]=$(escape_for_sed "$name")
            log "DEBUG" "Generated name for $field: $name" "$LOG_FILE"
        else
            field_values[$field]="\1"
        fi
    done
    
    # Combine field values with separator
    local combined_value=""
    local separator_escaped=$(escape_for_sed "$separator")
    for field in "${fields[@]}"; do
        if [ -n "$combined_value" ]; then
            combined_value="${combined_value}${separator_escaped}${field_values[$field]}"
        else
            combined_value="${field_values[$field]}"
        fi
    done
    
    # Update using sed with error checking
    if ! sed -i "s|'[^']*'|'$combined_value'|g" "$temp_file"; then
        log "ERROR" "Failed to update combination fields for table $table" "$LOG_FILE"
        return 1
    fi
    
    return 0
}

# Function to process random name fields for a table
process_random_names() {
    local table=$1
    local temp_file=$2
    
    log "INFO" "Processing random names for table: $table" "$LOG_FILE"
    
    local fields=($(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .fields[]" "$CONFIG_FILE"))
    local style=$(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .style" "$CONFIG_FILE")
    
    [ -z "$style" ] && style="github"
    
    for field in "${fields[@]}"; do
        local name=$(generate_name "$style")
        local escaped_name=$(escape_for_sed "$name")
        if ! sed -i "s|'[^']*'|'$escaped_name'|g" "$temp_file"; then
            log "ERROR" "Failed to update random names for table $table, field $field" "$LOG_FILE"
            return 1
        fi
    done
    
    return 0
}

# Function to process standardization rules
process_standardization() {
    local rule=$1
    local temp_file=$2
    
    local table=$(echo "$rule" | yq e '.table' -)
    local field=$(echo "$rule" | yq e '.field' -)
    local value=$(echo "$rule" | yq e '.value' -)
    
    log "INFO" "Standardizing $field in table $table" "$LOG_FILE"
    
    local value_escaped=$(escape_for_sed "$value")
    if ! sed -i "s|'[^']*'|'$value_escaped'|g" "$temp_file"; then
        log "ERROR" "Failed to update standardized value for table $table, field $field" "$LOG_FILE"
        return 1
    fi
    
    return 0
}

log "INFO" "Starting data scrubbing process" "$LOG_FILE"

# Create temporary file for processing using mktemp
TEMP_FILE=$(mktemp)
cp "$INPUT_FILE" "$TEMP_FILE" || {
    log "ERROR" "Failed to create temporary file" "$LOG_FILE"
    exit 1
}

# Process combination fields first
log "INFO" "Processing combination fields..." "$LOG_FILE"
while IFS= read -r table; do
    if ! process_combination_fields "$table" "$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        exit 1
    fi
done < <(yq e '.scrubbing.combination_fields[].table' "$CONFIG_FILE")

# Process random name fields
log "INFO" "Processing random name fields..." "$LOG_FILE"
while IFS= read -r table; do
    if ! process_random_names "$table" "$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        exit 1
    fi
done < <(yq e '.scrubbing.random_names[].table' "$CONFIG_FILE")

# Process standardization rules
log "INFO" "Processing standardization rules..." "$LOG_FILE"
while IFS= read -r rule; do
    if ! process_standardization "$rule" "$TEMP_FILE"; then
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