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

# Verify required environment variables
if [ -z "$SOURCE_DB" ]; then
    echo "ERROR: SOURCE_DB environment variable not set"
    exit 1
fi

if [ -z "$WORK_DIR" ]; then
    echo "ERROR: WORK_DIR environment variable not set"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"
CONFIG_FILE="$(dirname "$SCRIPT_DIR")/config.yml"  # Store full path to config
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"

# Source verification functions
source "./scripts/verification_functions.sh"

LOG_PREFIX="scrub_"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}${TIMESTAMP}.log"

# Debug directory structure and config location
log "DEBUG" "Current directory: $(pwd)" "$LOG_FILE"
log "DEBUG" "WORK_DIR: $WORK_DIR" "$LOG_FILE"
log "DEBUG" "SOURCE_DB: $SOURCE_DB" "$LOG_FILE"
log "DEBUG" "Export directory: $WORK_DIR/${SOURCE_DB}.exp" "$LOG_FILE"
log "DEBUG" "Config file location: $CONFIG_FILE" "$LOG_FILE"

# Verify config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR" "Config file not found at: $CONFIG_FILE" "$LOG_FILE"
    exit 1
fi

# Verify export directory exists
if [ ! -d "$WORK_DIR/${SOURCE_DB}.exp" ]; then
    log "ERROR" "Export directory not found: $WORK_DIR/${SOURCE_DB}.exp" "$LOG_FILE"
    exit 1
fi

# Load word lists with error handling
WORDLIST_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -f "$WORDLIST_DIR/adjectives.txt" ] || [ ! -f "$WORDLIST_DIR/nouns.txt" ]; then
    log "ERROR" "Word list files not found in $WORDLIST_DIR" "$LOG_FILE"
    exit 1
fi

ADJECTIVES=($(cat "$WORDLIST_DIR/adjectives.txt"))
NOUNS=($(cat "$WORDLIST_DIR/nouns.txt"))

# Set the random seed once at the start
RANDOM_SEED=$(yq e '.export.random_seed' "$CONFIG_FILE")
RANDOM=$RANDOM_SEED
log "INFO" "Initialized random seed to: $RANDOM_SEED" "$LOG_FILE"

# Function to clean a string for rewriting
clean_string() {
    echo "$1" | sed 's/|/\\|/g'
}

# Generate random name based on style
generate_name() {
    local style=${1:-github}
    case $style in
        github)
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

# Function to read a line and handle trailing empty field
read_record() {
    local line="$1"
    local num_fields="$2"
    
    # Remove trailing pipe if present
    line="${line%|}"
    
    IFS='|' read -ra fields <<< "$line"
    
    # Check if we have the correct number of fields
    if [ ${#fields[@]} -ne "$num_fields" ]; then
        return 1
    fi
    
    # Output fields with trailing pipe
    local output=""
    for ((i=0; i<${#fields[@]}; i++)); do
        output+="${fields[$i]}|"
    done
    
    echo "$output"
}

# Function to write a record with proper UNL format
write_record() {
    local temp_file="$1"
    shift
    local fields=("$@")
    
    local output=""
    for ((i=0; i<${#fields[@]}; i++)); do
        output+="${fields[$i]}|"
    done
    
    echo "$output" >> "$temp_file"
}

# Function to get table name from SQL file
get_table_name_from_sql() {
    local unl_base=$(basename "$1" | sed 's/[0-9]*\.unl$//')
    local sql_file="$2"

    awk -v base="$unl_base" '
        $0 ~ "TABLE.*\"informix\"" {
            match($0, /TABLE "informix"\.([^ ]+)/, arr)
            table=arr[1]
        }
        $0 ~ "unload file name" {
            match($0, /unload file name = ([^ ]*\.unl)/, arr)
            if (arr[1] ~ "^"base) {
                print table
                exit
            }
        }
    ' "$sql_file"
}

# Modified process_unl_file function
process_unl_file() {
    local unl_file=$1
    local sql_file="$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}.sql"
    local table_name=$(get_table_name_from_sql "$unl_file" "$sql_file")
    local temp_file=$(mktemp)
    
    if [ -z "$table_name" ]; then
        log "ERROR" "Could not determine table name for $unl_file" "$LOG_FILE"
        return 1
    fi
    
    log "INFO" "Processing $table_name data from $unl_file" "$LOG_FILE"

    # Get scrubbing config for this table
    local scrub_config=$(yq e ".scrubbing.random_names[] | select(.table == \"$table_name\")" "$CONFIG_FILE")
    
    if [ -z "$scrub_config" ]; then
        # No fields to scrub, copy as-is
        cp "$unl_file" "$temp_file"
    else
        # Get field indices and styles from SQL file
        declare -A field_indices
        declare -A field_styles
        
        # Get style for table, default to github if not specified
        local table_style=$(yq e ".style // \"github\"" <<< "$scrub_config")
        log "DEBUG" "Table style: $table_style" "$LOG_FILE"

        # Get fields and their positions
        log "DEBUG" "Getting fields from config:" "$LOG_FILE"
        yq e '.fields[]' <<< "$scrub_config" >> "$LOG_FILE"
        # Get fields and their positions


# Get fields and their positions
while read -r field; do
    log "DEBUG" "Processing field: $field" "$LOG_FILE"
    
    # Get just the field definitions for our specific table
    local table_def
    table_def=$(awk -v table="$table_name" '
        $0 ~ "TABLE.*\"informix\"." table " " {p=1; next}
        p==1 && /^\s*\(/ {b=1; next}
        p==1 && /^\s*\)/ {exit}
        p==1 && b==1 && /^\s*[a-zA-Z]/ {
            match($0, /^\s*([a-zA-Z][a-zA-Z0-9_]*)/, arr)
            printf "%s\n", arr[1]
        }
    ' "$sql_file")
    log "DEBUG" "Found table def:\n$table_def" "$LOG_FILE"

    # Convert table_def to array for safer processing
    mapfile -t fields <<< "$table_def"

    log "DEBUG" "Found table def with ${#fields[@]} fields" "$LOG_FILE"
    log "DEBUG" "--Looking for first_name" "$LOG_FILE"

    for line in "${fields[@]}"; do
        log "DEBUG" "checking $line" "$LOG_FILE"
        if [ "$line" = "first_name" ]; then
            log "DEBUG" "Found first_name at line number $index" "$LOG_FILE"
            break
        fi
        ((index++))
    done < <(printf '%s\n' "$table_def")

    log "DEBUG" "Done looking for first_name" "$LOG_FILE"


    
    # Reset index counter
    local index=0
    local found=false
    
    while IFS= read -r line; do
        log "DEBUG" "Found field: $field_name at index $index" "$LOG_FILE"        
        if [ "$line" = "$field" ]; then
            field_indices[$field]=$index
            field_styles[$field]="$table_style"
            log "DEBUG" "Matched field $field at index $index with style ${field_styles[$field]}" "$LOG_FILE"
            found=true
            break
        fi
        ((index++))
    done < <(echo "$table_def")
    
    if ! $found; then
        log "ERROR" "Could not find position for field $field in table $table_name" "$LOG_FILE"
        return 1
    fi
done < <(yq e '.fields[]' <<< "$scrub_config")



        # Show field mappings
        log "DEBUG" "Field indices:" "$LOG_FILE"
        for field in "${!field_indices[@]}"; do
            log "DEBUG" "  $field -> ${field_indices[$field]} (style: ${field_styles[$field]})" "$LOG_FILE"
        done

        # Count total fields in SQL definition
        local total_fields=$(grep -A20 "TABLE.*$table_name" "$sql_file" | 
            sed -n '/^[[:space:]]*[^[:space:]].*,$/p' | wc -l)
        total_fields=$((total_fields + 1))  # Add 1 for the last field without comma
        log "DEBUG" "Total fields found: $total_fields" "$LOG_FILE"

        # Process each line
        log "DEBUG" "Processing records from UNL file:" "$LOG_FILE"
        while IFS= read -r line; do
            log "DEBUG" "Processing line: $line" "$LOG_FILE"
            if record=$(read_record "$line" "$total_fields"); then
                local fields=()
                IFS='|' read -ra fields <<< "${record%|}"

                # Scrub specified fields
                for field in "${!field_indices[@]}"; do
                    local idx=${field_indices[$field]}
                    local style=${field_styles[$field]}
                    local new_value=$(generate_name "$style")
                    fields[$idx]="$new_value"  # Replace field at correct index
                    log "DEBUG" "Scrubbed field $field ($idx): ${fields[$idx]}" "$LOG_FILE"
                done
                
                # Write record with proper field alignment
                write_record "$temp_file" "${fields[@]}"
            else
                log "DEBUG" "Failed to parse record: $line" "$LOG_FILE"   
            fi
        done < "$unl_file"
    fi

    # Verify the temp file
    if [ ! -s "$temp_file" ]; then
        log "ERROR" "Generated empty file for $table_name" "$LOG_FILE"
        return 1
    fi
    
    mv "$temp_file" "$unl_file"
    return 0
}

# Main processing starts here
log "INFO" "Starting data scrubbing process" "$LOG_FILE"

# Move to export directory
cd "$WORK_DIR/${SOURCE_DB}.exp" || {
    log "ERROR" "Failed to change to export directory" "$LOG_FILE"
    exit 1
}

# Remove excluded tables from export
log "INFO" "Removing excluded tables from export..." "$LOG_FILE"
"$SCRIPT_DIR/remove_excluded_tables.sh" \
    "$CONFIG_FILE" \
    "$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}.sql" \
    "$WORK_DIR/${SOURCE_DB}.exp/${SOURCE_DB}_cleaned.sql" || {
    log "ERROR" "Failed to remove excluded tables" "$LOG_FILE"
    exit 1
}

log "DEBUG" "Processing files in: $(pwd)" "$LOG_FILE"
log "DEBUG" "Files found:" "$LOG_FILE"
ls -la >> "$LOG_FILE"

# Process each UNL file
for unl_file in *.unl; do
    log "INFO" "processing UNL file $unl_file" "$LOG_FILE"
    process_unl_file "$unl_file" 
done

# Copy schema file to output
cp "${SOURCE_DB}.sql" "$OUTPUT_FILE"

log "INFO" "Data scrubbing completed successfully" "$LOG_FILE"