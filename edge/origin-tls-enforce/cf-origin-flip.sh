#!/usr/bin/env bash
# One scoped origin transport change. See README.md for rollback prerequisites.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/origin_transport.py" "$@"
