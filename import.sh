#!/bin/bash

set -e

CONFIG_FILE="config.yml"
WORK_DIR="$HOME/work"

# Load configuration
source ./scripts/yaml_parser.sh
parse_yaml "$CONFIG_FILE"

# Import scrubbed data
dbaccess ${databases_target_name} "$WORK_DIR/combined.sql" || {
    echo "Failed to import data to ${databases_target_name}"
    exit 1
}

echo "Import complete"