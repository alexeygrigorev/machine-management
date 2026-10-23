#!/usr/bin/env bash
# Idempotent install of relay-pg-dns-watchdog onto a Contabo node via SSH.
# Usage: ./monitors/install-relay-pg-dns-watchdog.sh contabo-b
set -euo pipefail
HOST="${1:?usage: $0 <ssh-host>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/relay-pg-dns-watchdog.sh"
CRON="$HERE/relay-pg-dns-watchdog.cron"
ENV_EX="$HERE/relay-pg-dns-watchdog.env.example"
[[ -f "$SCRIPT" && -f "$CRON" && -f "$ENV_EX" ]] || { echo "missing script/cron/env.example next to installer" >&2; exit 2; }

ssh -o BatchMode=yes "$HOST" 'sudo mkdir -p /var/lib/relay-pg-dns-watchdog /var/log'
scp -o BatchMode=yes "$SCRIPT" "${HOST}:/tmp/relay-pg-dns-watchdog.sh"
scp -o BatchMode=yes "$CRON" "${HOST}:/tmp/relay-pg-dns-watchdog.cron"
scp -o BatchMode=yes "$ENV_EX" "${HOST}:/tmp/relay-pg-dns-watchdog.env.example"
ssh -o BatchMode=yes "$HOST" "sudo install -m 0755 /tmp/relay-pg-dns-watchdog.sh /usr/local/sbin/relay-pg-dns-watchdog.sh &&   sudo install -m 0644 /tmp/relay-pg-dns-watchdog.cron /etc/cron.d/relay-pg-dns-watchdog &&   if [ ! -f /etc/relay-pg-dns-watchdog.env ]; then sudo install -m 0600 /tmp/relay-pg-dns-watchdog.env.example /etc/relay-pg-dns-watchdog.env; echo Created env from example; else echo Kept existing env; fi &&   rm -f /tmp/relay-pg-dns-watchdog.sh /tmp/relay-pg-dns-watchdog.cron /tmp/relay-pg-dns-watchdog.env.example &&   sudo DRY_RUN=1 /usr/local/sbin/relay-pg-dns-watchdog.sh | tail -30 &&   echo Installed. Cron: /etc/cron.d/relay-pg-dns-watchdog"
