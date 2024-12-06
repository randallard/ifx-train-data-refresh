# Database Export and Scrubbing Tool

## Overview
Exports and scrubs data from a live Informix database for training environment use, including essential records and a configurable percentage of the full dataset.

## Configuration
Create `config.yml`:
```yaml
databases:
  source:
    name: this_live
    dsn: live_dsn
  target:
    name: this_train
    dsn: train_dsn

# Export settings
export:
  # Percentage of non-essential records to export (0-100)
  sample_percentage: 20
  # Random seed for consistent sampling
  random_seed: 42
  # Batch size for processing
  batch_size: 1000

# Essential records to always include
essential_records:
  main_table:
    - id: 1001
    - id: 1002
    include_dependencies: true

# Tables to exclude from export
excluded_tables:
  - training_config
  - train_specific_data

# Fields to scrub
scrubbing:
  randomize_names:
    - table: customers
      fields: [first_name, last_name]
    - table: employees
      fields: [name]
  
  standardize:
    address:
      value: "123 Training St, Test City, ST 12345"
      fields:
        - table: customers
          field: address
        - table: employees
          field: address
    
    phone:
      value: "555-0123"
      fields:
        - table: customers
          field: phone
        - table: employees
          field: phone
    
    email:
      value: "test@example.com"
      fields:
        - table: customers
          field: email
        - table: employees
          field: email

  github_style_names:
    - table: projects
      field: project_name
    - table: repositories
      field: repo_name
```

Updated `export.sh`:
```bash
#!/bin/bash

set -e

CONFIG_FILE="config.yml"
EXPORT_FILE="db_export.sql"
SCRUBBED_FILE="db_export_scrubbed.sql"

# Load configuration
source ./scripts/yaml_parser.sh
parse_yaml "$CONFIG_FILE"

# Set random seed for consistent sampling
RANDOM=$(yq e '.export.random_seed' "$CONFIG_FILE")

# Export database schema
dbschema -d ${databases_source_name} -o schema.sql

# Export essential records and their dependencies
echo "Exporting essential records..."
for id in $(yq e '.essential_records.main_table[].id' "$CONFIG_FILE"); do
    dbexport -d ${databases_source_name} \
             -o essential_$id.sql \
             -t "SELECT * FROM main_table WHERE id = $id"
    
    if [[ $(yq e '.essential_records.main_table.include_dependencies' "$CONFIG_FILE") == "true" ]]; then
        for table in $(dbschema -d ${databases_source_name} -t main_table -r); do
            dbexport -d ${databases_source_name} \
                     -a essential_$id.sql \
                     -t "SELECT DISTINCT $table.* FROM $table 
                         JOIN main_table ON main_table.id = $table.main_id 
                         WHERE main_table.id = $id"
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
                     WHERE id NOT IN (SELECT id FROM essential_records)"
        offset=$(( offset + current_batch ))
    done
done

# Combine exports
cat schema.sql essential_*.sql sample_*.sql > "$EXPORT_FILE"

# Apply data scrubbing
./scripts/scrub_data.sh "$EXPORT_FILE" "$SCRUBBED_FILE"

echo "Export and scrubbing complete. Output: $SCRUBBED_FILE"
```

## Usage
1. Configure `config.yml` with:
   - Database connection details
   - Export percentage (how much of the database to sample)
   - Essential record IDs
   - Scrubbing rules
2. Place word lists (adjectives.txt, nouns.txt) in the same directory
3. Run export on source server:
   ```bash
   ./export.sh
   ```
4. Transfer scrubbed export to target server
5. Run import:
   ```bash
   ./import.sh
   ```

## Features
- Exports essential records with dependencies
- Samples configurable percentage of remaining records
- Excludes specified tables
- Scrubs sensitive data:
  - Randomizes names
  - Standardizes contact information
  - Generates GitHub-style names
- Preserves training-specific data

## Dependencies
- Informix database tools (dbaccess, dbexport, dbschema)
- yq (YAML parser)
- Standard Linux tools (sed, grep)