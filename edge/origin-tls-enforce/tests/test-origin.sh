#!/usr/bin/env bash
# Read-only live acceptance matrix; no credential values in output.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/../verify_origin.py" "$@"
