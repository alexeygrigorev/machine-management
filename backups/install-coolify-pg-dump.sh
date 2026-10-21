#!/usr/bin/env bash
# Install the daily pg_dump -> S3 job on the Coolify data node (contabo-b).
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never install coding agents
# on Contabo prod boxes. Copies this repo's backups/coolify-pg-dump.sh to the
# node, creates /etc/coolify-pg-dump.env from the example if missing (you fill
# real values on the node afterwards), and installs the cron entry.
#
# Usage:
#   ./backups/install-coolify-pg-dump.sh contabo-b
#   # then on the node (once): sudo nano /etc/coolify-pg-dump.env
#   # verify: /usr/local/sbin/coolify-pg-dump.sh   (manual dry run, then check S3)
#
# No secrets in git: this script never writes credentials; the env file on the
# node starts as placeholders and must be edited out-of-band (Drive doc).
set -euo pipefail

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  echo "usage: $0 <ssh-host>   (e.g. contabo-b)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

echo "== copy dump script to ${HOST} =="
scp "${HERE}/coolify-pg-dump.sh" "${HOST}:/tmp/coolify-pg-dump.sh"
"${SSH[@]}" "$HOST" sudo install -m 0755 /tmp/coolify-pg-dump.sh /usr/local/sbin/coolify-pg-dump.sh

echo "== env file (placeholders only; never overwritten) =="
scp "${HERE}/coolify-pg-dump.env.example" "${HOST}:/tmp/coolify-pg-dump.env.example"
"${SSH[@]}" "$HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
if [[ ! -f /etc/coolify-pg-dump.env ]]; then
  sudo install -m 0600 /tmp/coolify-pg-dump.env.example /etc/coolify-pg-dump.env 2>/dev/null \
    || { cp /tmp/coolify-pg-dump.env.example /etc/coolify-pg-dump.env; chmod 600 /etc/coolify-pg-dump.env; }
  echo "created /etc/coolify-pg-dump.env (PLACEHOLDERS — edit on node, chmod 600)"
else
  echo "keep existing /etc/coolify-pg-dump.env (not overwritten)"
fi
mkdir -p /var/backups/coolify-postgres
command -v aws >/dev/null || echo "WARN: aws cli missing on node — install (apt install awscli)"
command -v pg_dump >/dev/null || echo "WARN: pg_dump missing on node — install (apt install postgresql-client)"
EOF

echo "== cron entry (02:30 Europe/Berlin daily) =="
scp "${HERE}/coolify-pg-dump.cron" "${HOST}:/tmp/coolify-pg-dump.cron"
"${SSH[@]}" "$HOST" sudo install -m 0644 /tmp/coolify-pg-dump.cron /etc/cron.d/coolify-pg-dump

echo "== verify =="
"${SSH[@]}" "$HOST" 'sudo bash -n /usr/local/sbin/coolify-pg-dump.sh && echo SYNTAX_OK; cat /etc/cron.d/coolify-pg-dump'
echo
echo "NEXT: edit real values in /etc/coolify-pg-dump.env on ${HOST}, then run:"
echo "  ssh ${HOST} 'sudo /usr/local/sbin/coolify-pg-dump.sh'"
echo "and confirm the S3 object appears under s3://<bucket>/coolify/postgres/."
