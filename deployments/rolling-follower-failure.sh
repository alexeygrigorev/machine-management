#!/usr/bin/env bash
# Fixed, sanitized notification: never send API bodies or runtime environment.
# Each OnFailure unit names its own component so an alert points at the unit
# that actually failed (the CMP poller used to reuse the follower's message).
set -euo pipefail
case "${1:-coolify-rolling-web}" in
  coolify-rolling-web)
    subject='[infra] production release follower failed'
    body='The production release follower failed. Current serving containers are retained. Inspect journalctl --user -u coolify-rolling-web.service on the operator host.'
    ;;
  cmp-release-poller)
    subject='[infra] CMP release poller failed'
    body='The CMP release poller failed. Running CMP containers are unchanged. Inspect journalctl --user -u cmp-release-poller.service on the operator host.'
    ;;
  *)
    echo 'Usage: rolling-follower-failure.sh [coolify-rolling-web|cmp-release-poller]' >&2
    exit 2
    ;;
esac
printf 'To: dev@dtcdev.click\nFrom: DTC Alerts <alerts@dtcdev.click>\nSubject: %s\n\n%s\n' "$subject" "$body" \
  | ssh -o BatchMode=yes -o ConnectTimeout=10 contabo-a sudo msmtp -a alerts dev@dtcdev.click
