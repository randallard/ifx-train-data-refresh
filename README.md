# Database Export and Scrubbing Tool

## Overview
Exports and scrubs data from a live Informix database for training environment use, including essential records and a configurable percentage of the full dataset.

## Configuration
Create `config.yml`:
```yaml
databases:
  source:
    name: this_live
  target:
    name: this_train
  testing:
    test_db: test_live        # Database to use as mock production
    temp_verify: temp_verify  # Temporary verification database
    verification_marker: "VERIFY_TEST_STRING_XYZ_"  # Marker for excluded tables
    cleanup_script: remove_verify_db.sh  # Script to remove verification database

tables:
  primary_table:
    name: "your_table_name"  # Your main table name
    primary_key: "id"        # Primary key column of your main table
  dependencies:
    foreign_key_column: "primary_id"  # Column other tables use to reference primary table
    primary_key: "id"                 # Primary key column in dependent tables

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
  records:
    - id: 1001
    - id: 1002
  include_dependencies: true

# Tables to exclude from export
excluded_tables:
  - training_config
  - train_specific_data

# Fields to scrub
scrubbing:
  # Random name generation for fields
  random_names:
    - table: customers
      fields: [first_name, last_name]
      style: github  # Optional: defaults to github if not specified
    - table: employees
      fields: [name]
      style: github
    - table: projects
      fields: [project_name]
      style: github
    - table: repositories
      fields: [repo_name]
      style: github
  
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

  # Combine multiple fields with custom separators
  combination_fields:
    - table: projects
      fields:
        - source_field: name1
          random_style: github
        - source_field: name2
          random_style: github
      separator: "-&-"
      target_field: combo_name
    - table: repositories
      fields:
        - source_field: owner_name
          random_style: github
        - source_field: repo_name
          random_style: github
      separator: "/"
      target_field: full_path
```

## Table Configuration
The tool now supports fully configurable table and key field names:

1. Primary Table Settings:
   - `tables.primary_table.name`: Your main table name
   - `tables.primary_table.primary_key`: The primary key column name in your main table

2. Dependency Settings:
   - `tables.dependencies.foreign_key_column`: The column name that dependent tables use to reference the primary table
   - `tables.dependencies.primary_key`: The primary key column name used in dependent tables

## Usage
1. Configure `config.yml` with:
   - Database connection details
   - Table and key field names
   - Export percentage (how much of the database to sample)
   - Essential record IDs
   - Scrubbing rules:
     - Random name generation
     - Field standardization
     - Field combinations with custom separators
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

## Testing and Verification
The tool includes comprehensive testing capabilities to verify the export and scrubbing process:

1. Run verification:
   ```bash
   ./verify_export.sh
   ```

### Verification Process
The verification script performs these steps:

1. Creates a temporary verification database
   - Copies schema and data from test database
   - Marks excluded tables for verification

2. Runs export and import process
   - Exports from test database
   - Scrubs the data
   - Imports to verification database

3. Verifies:
   - Excluded tables remain unchanged
   - Fields are properly scrubbed
   - Essential records and dependencies exist
   - Source database integrity

### Verification Configuration
Configure testing parameters in config.yml:
```yaml
verification:
  logging:
    directory: logs
    prefix: verify_
  checksums:
    enabled: true
    algorithm: md5sum
  record_counts:
    enabled: true
    sample_tables:
      - customers
      - employees
  excluded_table_samples: 3
```

### Logging
- Detailed logs are created in the specified logging directory
- Includes timestamps and success/failure status
- Logs all verification steps and results

## Features
- Configurable table names and key fields
- Exports essential records with dependencies
- Samples configurable percentage of remaining records
- Excludes specified tables
- Scrubs sensitive data:
  - Generates random names in various styles (default: github-style)
  - Standardizes contact information
  - Combines multiple fields with custom separators
- Preserves training-specific data
- Consistent data generation using configurable random seed
- Comprehensive testing and verification

## Name Generation Styles
Currently supports:
- GitHub-style (default): Combines a random adjective and noun with a hyphen (e.g., "hungry-hippo")
- Additional styles can be added by extending the `generate_name()` function in scrub_data.sh

## Field Combinations
Allows combining multiple fields with custom separators:
- Source fields can use random name generation
- Custom separator between fields
- Results stored in a specified target field
- Example: Combining owner and repository names with "/" separator

## Dependencies
- Informix database tools (dbaccess, dbexport, dbschema)
- yq (YAML parser)
- Standard Linux tools (sed, grep)