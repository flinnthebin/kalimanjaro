#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:-ruby_gems.txt}"
FOUND="found_gems.txt"
NOTFOUND="notfound_gems.txt"

[[ -f "$INPUT" ]] || { echo "No file: $INPUT" >&2; exit 1; }

: > "$FOUND"
: > "$NOTFOUND"

while IFS= read -r gemname; do
    gemname="${gemname// /}"   # remove spaces
    [[ -z "$gemname" ]] && continue

    # Do a quiet exact match
    if gem search -r -q "^${gemname}$" | grep -q "^${gemname} "; then
        echo "$gemname" | tee -a "$FOUND"
    else
        echo "$gemname" | tee -a "$NOTFOUND"
    fi
done < "$INPUT"

echo "=== Summary ==="
echo "Found:     $(wc -l < "$FOUND") → $FOUND"
echo "Not found: $(wc -l < "$NOTFOUND") → $NOTFOUND"
