#!/usr/bin/env bash
# pypi_search.sh
# Check a list of (exact) PyPI package names and output matches.
# Usage:
#   ./pypi_search.sh <infile> [outfile]
# Options (env vars):
#   THREADS   - parallel requests (default: 8)
#   SHOW_INFO - if set to 1, include "name version" instead of just name
#   TIMEOUT   - curl timeout seconds (default: 10)
#   UA        - custom User-Agent (default: pypi_search.sh)

set -Eeuo pipefail
IFS=$'\n\t'

INFILE="${1:-}"
OUTFILE="${2:-matches.txt}"
[[ -n "$INFILE" && -f "$INFILE" ]] || { echo "Usage: $0 <infile> [outfile]" >&2; exit 1; }

THREADS="${THREADS:-8}"
SHOW_INFO="${SHOW_INFO:-0}"
TIMEOUT="${TIMEOUT:-10}"
UA="${UA:-pypi_search.sh}"

# Use jq if available; fall back to grep/sed parsing
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# Clean output file
: > "$OUTFILE"

# Worker: reads a single package name on stdin, writes a line to OUTFILE on success
worker() {
  local pkg="$1"
  [[ -z "$pkg" ]] && return 0
  [[ "$pkg" =~ ^# ]] && return 0
  # PyPI exact-name JSON endpoint
  local url="https://pypi.org/pypi/${pkg}/json"
  # -f: fail on HTTP errors; -sS: quiet but show errors; -m TIMEOUT
  if json="$(curl -sS -f -m "$TIMEOUT" -H "User-Agent: ${UA}" "$url" 2>/dev/null)"; then
    if [[ "$SHOW_INFO" -eq 1 ]]; then
      if (( have_jq )); then
        # name can differ in case; prefer info.name + info.version
        name=$(printf '%s' "$json" | jq -r '.info.name // empty')
        ver=$(printf '%s' "$json" | jq -r '.info.version // empty')
      else
        # crude fallback parsing
        name=$(printf '%s' "$json" | grep -o '"name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"name":[[:space:]]*"([^"]*)".*/\1/')
        ver=$(printf '%s' "$json" | grep -o '"version":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"version":[[:space:]]*"([^"]*)".*/\1/')
      fi
      if [[ -n "$name" && -n "$ver" ]]; then
        printf "%s %s\n" "$name" "$ver" >> "$OUTFILE"
      else
        # fallback to the queried name if parsing failed
        printf "%s\n" "$pkg" >> "$OUTFILE"
      fi
    else
      printf "%s\n" "$pkg" >> "$OUTFILE"
    fi
  fi
}

export -f worker
export OUTFILE SHOW_INFO TIMEOUT UA

# Read terms, strip whitespace, skip blanks/comments, de-dup to reduce requests
mapfile -t terms < <(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' "$INFILE" | awk 'NF && $0 !~ /^#/ {print tolower($0)}' | sort -u)

# Parallelize with xargs
printf "%s\n" "${terms[@]}" | xargs -n1 -P "${THREADS}" bash -lc 'worker "$@"' _

echo "[✓] Matches written to $OUTFILE"

