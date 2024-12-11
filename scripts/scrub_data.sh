#!/bin/bash

echo "SCRUB[1]: Script starting"
echo "SCRUB[2]: Args: $@"

if [ $# -ne 1 ]; then
    echo "SCRUB[ERROR]: Usage: $0 <data_directory>"
    exit 1
fi

DATA_DIR="$1"
echo "SCRUB[3]: Data directory: $DATA_DIR"

if [ ! -d "$DATA_DIR" ]; then
    echo "SCRUB[ERROR]: Directory $DATA_DIR does not exist"
    exit 1
fi

echo "SCRUB[4]: Directory exists, exiting successfully"
exit 0