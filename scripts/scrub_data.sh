#!/bin/bash

set -e

INPUT_FILE=$1
OUTPUT_FILE=$2
CONFIG_FILE="config.yml"

# Load word lists
ADJECTIVES=($(cat adjectives.txt))
NOUNS=($(cat nouns.txt))

# Generate random name based on style
generate_name() {
    local style=${1:-github}
    case $style in
        github)
            adj=${ADJECTIVES[$RANDOM % ${#ADJECTIVES[@]}]}
            noun=${NOUNS[$RANDOM % ${#NOUNS[@]}]}
            echo "${adj}-${noun}"
            ;;
        # Add other name styles here if needed in the future
        *)
            echo "Unknown style: $style" >&2
            exit 1
            ;;
    esac
}

# Create temporary file for processing
TEMP_FILE=$(mktemp)
cp "$INPUT_FILE" "$TEMP_FILE"

# Process combination fields first
echo "Processing combination fields..."
while IFS= read -r table; do
    fields=($(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .fields[].source_field" "$CONFIG_FILE"))
    separator=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .separator" "$CONFIG_FILE")
    target_field=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .target_field" "$CONFIG_FILE")
    
    # Generate and store random names for each source field
    declare -A field_values
    for field in "${fields[@]}"; do
        style=$(yq e ".scrubbing.combination_fields[] | select(.table == \"$table\") | .fields[] | select(.source_field == \"$field\") | .random_style" "$CONFIG_FILE")
        if [ -n "$style" ]; then
            field_values[$field]=$(generate_name "$style")
        else
            # Use existing value if no style specified
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
    
    # Update the target field
    sed -i "s/'[^']*'/'$combined_value'/g" "$TEMP_FILE"
done < <(yq e '.scrubbing.combination_fields[].table' "$CONFIG_FILE")

# Process the regular random name fields
while IFS= read -r table; do
    fields=($(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .fields[]" "$CONFIG_FILE"))
    style=$(yq e ".scrubbing.random_names[] | select(.table == \"$table\") | .style" "$CONFIG_FILE")
    
    # Default to github style if not specified
    [ -z "$style" ] && style="github"
    
    for field in "${fields[@]}"; do
        sed -i "s/'[^']*'/'$(generate_name "$style")'/g" "$TEMP_FILE"
    done
done < <(yq e '.scrubbing.random_names[].table' "$CONFIG_FILE")

# Process standardization rules
while IFS= read -r rule; do
    table=$(echo "$rule" | yq e '.table' -)
    field=$(echo "$rule" | yq e '.field' -)
    value=$(echo "$rule" | yq e '.value' -)
    sed -i "s/'[^']*'/'$value'/g" "$TEMP_FILE"
done < <(yq e '.scrubbing.standardize.*.fields[]' "$CONFIG_FILE")

# Move processed file to output
mv "$TEMP_FILE" "$OUTPUT_FILE"