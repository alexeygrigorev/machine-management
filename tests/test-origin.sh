#!/usr/bin/env bash
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/../edge/origin-tls-enforce/tests/test-origin.sh" "$@"
