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

# Function to generate a properly formatted name
generate_record() {
    local id=$1
    local project_id=$2
    local style=${3:-github}
    local new_owner=$(generate_name "$style")
    local new_repo=$(generate_name "$style")
    echo "$id|$project_id|$new_owner|$new_repo|$new_owner/$new_repo|"
}

# Process repositories handling with proper record structure
process_repository() {
    local id=$1
    local project_id=$2
    local owner_name=$3
    local repo_name=$4
    local rest=$5
    local temp_file=$6

    # Check if this repository belongs to a project of an essential customer
    local customer_id=$(yq e ".essential_records.records[].id" "$CONFIG_FILE" | while read -r eid; do
        if [ -f "$WORK_DIR/${SOURCE_DB}.exp/proje"*".unl" ]; then
            grep "^[^|]*|${eid}|" "$WORK_DIR/${SOURCE_DB}.exp/proje"*".unl" | grep "^${project_id}|" >/dev/null && echo "$eid" && break
        fi
    done)

    if [ -n "$customer_id" ]; then
        log "DEBUG" "Preserving repository for project $project_id (customer $customer_id)" "$LOG_FILE"
        echo "$id|$project_id|$owner_name|$repo_name|$owner_name/$repo_name|$rest" >> "$temp_file"
    else
        # Generate new names with proper record structure
        local new_owner=$(generate_name "github")
        local new_repo=$(generate_name "github")
        echo "$id|$project_id|$new_owner|$new_repo|$new_owner/$new_repo|$rest" >> "$temp_file"
    fi
}

# Function to read a line and handle trailing empty field
read_record() {
    local line="$1"
    local num_fields="$2"
    local result=()
    
    # Remove trailing pipe if present
    line="${line%|}"
    
    IFS='|' read -ra fields <<< "$line"
    
    # Account for the removed trailing pipe in field count
    if [ ${#fields[@]} -ne $((num_fields-1)) ]; then
        return 1
    fi
    
    # Copy fields
    for ((i=0; i<${#fields[@]}; i++)); do
        result[$i]="${fields[$i]}"
    done
    
    # Build output with trailing pipe
    local output=""
    for ((i=0; i<${#fields[@]}; i++)); do
        output+="${result[$i]}|"
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

process_unl_file() {
    local unl_file=$1
    local table_name=$2
    local temp_file=$(mktemp)
    
    log "INFO" "Processing $table_name data from $unl_file" "$LOG_FILE"
    
    case "$table_name" in
        customers)
            while IFS='|' read -r id first_name last_name email addr phone rest; do
                [ -z "$id" ] && continue
                
                if yq e ".essential_records.records[] | select(.id == $id) | .id" "$CONFIG_FILE" >/dev/null 2>&1; then
                    log "DEBUG" "Preserving essential customer record $id" "$LOG_FILE"
                    echo "${id}|${first_name}|${last_name}|${email}|${addr}|${phone}|" >> "$temp_file"
                else
                    local new_first=$(generate_name "github")
                    local new_last=$(generate_name "github")
                    echo "${id}|${new_first}|${new_last}|test@example.com|123 Training St, Test City, ST 12345|555-0123|" >> "$temp_file"
                fi
            done < "$unl_file"
            ;;
            
        employees)
            while IFS='|' read -r id customer_id name email addr phone rest; do
                [ -z "$id" ] && continue
                
                if yq e ".essential_records.records[] | select(.id == $customer_id) | .id" "$CONFIG_FILE" >/dev/null 2>&1; then
                    log "DEBUG" "Preserving employee for essential customer $customer_id" "$LOG_FILE"
                    echo "${id}|${customer_id}|${name}|test@example.com|123 Training St, Test City, ST 12345|555-0123|" >> "$temp_file"
                else
                    local new_name=$(generate_name "github")
                    echo "${id}|${customer_id}|${new_name}|test@example.com|123 Training St, Test City, ST 12345|555-0123|" >> "$temp_file"
                fi
            done < "$unl_file"
            ;;
            
        projects)
            while IFS='|' read -r id customer_id project_name name1 name2 combo_name rest; do
                [ -z "$id" ] && continue
                
                if yq e ".essential_records.records[] | select(.id == $customer_id) | .id" "$CONFIG_FILE" >/dev/null 2>&1; then
                    log "DEBUG" "Preserving project for essential customer $customer_id" "$LOG_FILE"
                    echo "${id}|${customer_id}|${project_name}|${name1}|${name2}|${name1}-&-${name2}|" >> "$temp_file"
                else
                    local new_name1=$(generate_name "github")
                    local new_name2=$(generate_name "github")
                    echo "${id}|${customer_id}|${project_name}|${new_name1}|${new_name2}|${new_name1}-&-${new_name2}|" >> "$temp_file"
                fi
            done < "$unl_file"
            ;;
            
        repositories)
            while IFS='|' read -r id project_id owner_name repo_name full_path rest; do
                [ -z "$id" ] && continue
                
                # Check if this is a repository for an essential project
                local customer_id=""
                if [ -f "$WORK_DIR/${SOURCE_DB}.exp/proje"*".unl" ]; then
                    customer_id=$(grep "^${project_id}|" "$WORK_DIR/${SOURCE_DB}.exp/proje"*".unl" | cut -d'|' -f2 | while read -r cid; do
                        yq e ".essential_records.records[] | select(.id == $cid) | .id" "$CONFIG_FILE" 2>/dev/null && break
                    done)
                fi
                
                if [ -n "$customer_id" ]; then
                    log "DEBUG" "Preserving repository for project $project_id (customer $customer_id)" "$LOG_FILE"
                    echo "${id}|${project_id}|${owner_name}|${repo_name}|${owner_name}/${repo_name}|" >> "$temp_file"
                else
                    local new_owner=$(generate_name "github")
                    local new_repo=$(generate_name "github")
                    echo "${id}|${project_id}|${new_owner}|${new_repo}|${new_owner}/${new_repo}|" >> "$temp_file"
                fi
            done < "$unl_file"
            ;;
            
        training_config|train_specific_data)
            # Just copy excluded tables as-is
            cp "$unl_file" "$temp_file"
            ;;
            
        *)
            log "WARNING" "Unknown table $table_name - copying without modification" "$LOG_FILE"
            cp "$unl_file" "$temp_file"
            ;;
    esac
    
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

log "DEBUG" "Processing files in: $(pwd)" "$LOG_FILE"
log "DEBUG" "Files found:" "$LOG_FILE"
ls -la >> "$LOG_FILE"

# Process each UNL file
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
            log "INFO" "Processing $table_name ($unl_file)" "$LOG_FILE"
            process_unl_file "$unl_file" "$table_name"
        else
            log "WARNING" "Could not determine table name for $unl_file" "$LOG_FILE"
        fi
    fi
done

# Copy schema file to output
cp "${SOURCE_DB}.sql" "$OUTPUT_FILE"

log "INFO" "Data scrubbing completed successfully" "$LOG_FILE"