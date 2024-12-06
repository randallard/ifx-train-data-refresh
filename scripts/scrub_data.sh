#!/bin/bash

set -e

INPUT_FILE=$1
OUTPUT_FILE=$2
CONFIG_FILE="config.yml"

# Load word lists
ADJECTIVES=($(cat adjectives.txt))
NOUNS=($(cat nouns.txt))

# Generate random github-style name
generate_name() {
    adj=${ADJECTIVES[$RANDOM % ${#ADJECTIVES[@]}]}
    noun=${NOUNS[$RANDOM % ${#NOUNS[@]}]}
    echo "${adj}-${noun}"
}

# Process the export file
while IFS= read -r line; do
    # Skip excluded tables
    if echo "$line" | grep -qf <(yq e '.excluded_tables[]' "$CONFIG_FILE"); then
        continue
    fi
    
    # Apply scrubbing rules
    for table in $(yq e '.scrubbing.randomize_names[].table' "$CONFIG_FILE"); do
        fields=($(yq e ".scrubbing.randomize_names[] | select(.table == \"$table\") | .fields[]" "$CONFIG_FILE"))
        for field in "${fields[@]}"; do
            line=$(echo "$line" | sed "s/'[^']*'/'$(generate_name)'/g")
        done
    done
    
    # Apply standardization rules
    while IFS= read -r rule; do
        table=$(echo "$rule" | yq e '.table' -)
        field=$(echo "$rule" | yq e '.field' -)
        value=$(echo "$rule" | yq e '.value' -)
        line=$(echo "$line" | sed "s/'[^']*'/'$value'/g")
    done < > "$OUTPUT_FILE"
done < "$INPUT_FILE"