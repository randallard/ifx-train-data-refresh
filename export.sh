#!/bin/bash

set -e

CONFIG_FILE="config.yml"
EXPORT_FILE="db_export.sql"
SCRUBBED_FILE="db_export_scrubbed.sql"

# Load configuration
source ./scripts/yaml_parser.sh
parse_yaml "$CONFIG_FILE"

# Get table configuration
PRIMARY_TABLE=$(yq e '.tables.primary_table.name' "$CONFIG_FILE")
PRIMARY_KEY=$(yq e '.tables.primary_table.primary_key' "$CONFIG_FILE")
FOREIGN_KEY=$(yq e '.tables.dependencies.foreign_key_column' "$CONFIG_FILE")
DEPENDENT_PRIMARY_KEY=$(yq e '.tables.dependencies.primary_key' "$CONFIG_FILE")

# Set random seed for consistent sampling
RANDOM=$(yq e '.export.random_seed' "$CONFIG_FILE")

# Export database schema
dbschema -d ${databases_source_name} -o schema.sql

# Export essential records and their dependencies
echo "Exporting essential records..."
for id in $(yq e '.essential_records.records[].id' "$CONFIG_FILE"); do
    dbexport -d ${databases_source_name} \
             -o essential_$id.sql \
             -t "SELECT * FROM $PRIMARY_TABLE WHERE $PRIMARY_KEY = $id"
    
    if [[ $(yq e '.essential_records.include_dependencies' "$CONFIG_FILE") == "true" ]]; then
        for table in $(dbschema -d ${databases_source_name} -t $PRIMARY_TABLE -r); do
            dbexport -d ${databases_source_name} \
                     -a essential_$id.sql \
                     -t "SELECT DISTINCT $table.* FROM $table 
                         JOIN $PRIMARY_TABLE ON $PRIMARY_TABLE.$PRIMARY_KEY = $table.$FOREIGN_KEY 
                         WHERE $PRIMARY_TABLE.$PRIMARY_KEY = $id"
        done
    fi
done

# Export sampled data
sample_percentage=$(yq e '.export.sample_percentage' "$CONFIG_FILE")
batch_size=$(yq e '.export.batch_size' "$CONFIG_FILE")

echo "Exporting ${sample_percentage}% of non-essential records..."
for table in $(dbschema -d ${databases_source_name} -t); do
    # Skip excluded tables
    if echo "$table" | grep -qf <(yq e '.excluded_tables[]' "$CONFIG_FILE"); then
        continue
    fi
    
    # Get total count
    total_rows=$(echo "SELECT COUNT(*) FROM $table" | dbaccess ${databases_source_name} - | tail -n 1)
    sample_size=$(( total_rows * sample_percentage / 100 ))
    
    # Export in batches
    offset=0
    while [ $offset -lt $sample_size ]; do
        current_batch=$(( batch_size < (sample_size - offset) ? batch_size : (sample_size - offset) ))
        dbexport -d ${databases_source_name} \
                 -a sample_$table.sql \
                 -t "SELECT FIRST $current_batch SKIP $offset * FROM $table 
                     WHERE $DEPENDENT_PRIMARY_KEY NOT IN (SELECT $PRIMARY_KEY FROM essential_records)"
        offset=$(( offset + current_batch ))
    done
done

# Combine exports
cat schema.sql essential_*.sql sample_*.sql > "$EXPORT_FILE"

# Apply data scrubbing
./scripts/scrub_data.sh "$EXPORT_FILE" "$SCRUBBED_FILE"

echo "Export and scrubbing complete. Output: $SCRUBBED_FILE"