#!/bin/bash
# Installed on Hetzner as ~/tmp/bin/coolify-aisl-auto-deploy.sh.
set -euo pipefail
exec python3 "$HOME/tmp/bin/aisl-auto-deploy.py" --apply
