#!/bin/bash
# Compile Blueprint files to UI XML

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/resources/ui"
OUTPUT_DIR="$PROJECT_DIR/src/ui"

mkdir -p "$OUTPUT_DIR"

for blp_file in "$RESOURCES_DIR"/*.blp; do
    if [ -f "$blp_file" ]; then
        filename=$(basename "$blp_file" .blp)
        echo "Compiling $filename.blp -> $filename.ui"
        blueprint-compiler compile "$blp_file" --output "$OUTPUT_DIR/$filename.ui"
    fi
done

echo "Blueprint compilation complete"
