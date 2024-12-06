#!/bin/bash

set -e

CONFIG_FILE="config.yml"
IMPORT_FILE="db_export_scrubbed.sql"

# Load configuration
source ./scripts/yaml_parser.sh
parse_yaml "$CONFIG_FILE"

# Import scrubbed data
dbaccess ${databases_target_name} "$IMPORT_FILE"

echo "Import complete"