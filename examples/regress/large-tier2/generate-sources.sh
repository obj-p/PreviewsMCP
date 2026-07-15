#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$ROOT/Sources/LargeTier2/Generated"
FILE_COUNT="${FILE_COUNT:-800}"
LAST_INDEX="$((FILE_COUNT - 1))"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

for index in $(seq -w 0 "$LAST_INDEX"); do
    printf 'enum GeneratedValue%s { static let value = %s }\n' \
        "$index" "$((10#$index))" \
        > "$OUTPUT/GeneratedValue${index}.swift"
done

printf 'enum GeneratedCatalog { static let fileCount = %s }\n' "$FILE_COUNT" \
    > "$OUTPUT/GeneratedCatalog.swift"
