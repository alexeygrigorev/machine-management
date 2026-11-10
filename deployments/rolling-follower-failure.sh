#!/usr/bin/env bash
# Fixed, sanitized notification: never send API bodies or runtime environment.
set -euo pipefail
printf 'To: dev@dtcdev.click\nFrom: DTC Alerts <alerts@dtcdev.click>\nSubject: [infra] production release follower failed\n\nThe production release follower failed. Current serving containers are retained. Inspect journalctl --user -u coolify-rolling-web.service on the operator host.\n' \
  | ssh -o BatchMode=yes -o ConnectTimeout=10 contabo-a sudo msmtp -a alerts dev@dtcdev.click
