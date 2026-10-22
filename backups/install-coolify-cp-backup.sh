#!/usr/bin/env bash
# Install the nightly Coolify CP backup job on a CP host (contabo-a / contabo-b).
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never install coding agents
# on Contabo prod boxes. Copies this repo's backups/coolify-cp-backup.sh to the
# node, creates /etc/coolify-cp-backup.env from the example if missing (you fill
# real values on the node afterwards), and installs the cron entry.
#
# Usage:
#   ./backups/install-coolify-cp-backup.sh contabo-a   # then contabo-b
#   # then on each node (once): sudo nano /etc/coolify-cp-backup.env
#   #   + place /etc/coolify-cp-backup.pass (600) from operator secrets
#   # verify: ssh <host> 'sudo /usr/local/sbin/coolify-cp-backup.sh'
#
# No secrets in git: this script never writes credentials; the env file on the
# node starts as placeholders and must be edited out-of-band (Drive doc).
# The GPG passphrase must be copied separately (see README section).
set -euo pipefail

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  echo "usage: $0 <ssh-host>   (e.g. contabo-a)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

echo "== copy CP backup script to ${HOST} =="
scp "${HERE}/coolify-cp-backup.sh" "${HOST}:/tmp/coolify-cp-backup.sh"
"${SSH[@]}" "$HOST" sudo install -m 0755 /tmp/coolify-cp-backup.sh /usr/local/sbin/coolify-cp-backup.sh

echo "== env file (placeholders only; never overwritten) =="
scp "${HERE}/coolify-cp-backup.env.example" "${HOST}:/tmp/coolify-cp-backup.env.example"
"${SSH[@]}" "$HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
if [[ ! -f /etc/coolify-cp-backup.env ]]; then
  sudo install -m 0600 /tmp/coolify-cp-backup.env.example /etc/coolify-cp-backup.env 2>/dev/null \
    || { cp /tmp/coolify-cp-backup.env.example /etc/coolify-cp-backup.env; chmod 600 /etc/coolify-cp-backup.env; }
  echo "created /etc/coolify-cp-backup.env (PLACEHOLDERS — edit on node, chmod 600)"
else
  echo "keep existing /etc/coolify-cp-backup.env (not overwritten)"
fi
mkdir -p /var/backups/coolify-cp
for bin in aws gpg pg_dump docker; do
  command -v "$bin" >/dev/null || echo "WARN: $bin missing on node"
done
EOF

echo "== cron entry (03:30 Europe/Berlin daily) =="
scp "${HERE}/coolify-cp-backup.cron" "${HOST}:/tmp/coolify-cp-backup.cron"
"${SSH[@]}" "$HOST" sudo install -m 0644 /tmp/coolify-cp-backup.cron /etc/cron.d/coolify-cp-backup

echo "== verify =="
"${SSH[@]}" "$HOST" 'sudo bash -n /usr/local/sbin/coolify-cp-backup.sh && echo SYNTAX_OK; cat /etc/cron.d/coolify-cp-backup'
echo
echo "NEXT on ${HOST}:"
echo "  1. sudo nano /etc/coolify-cp-backup.env  (CP_HOST_ID + S3 keys, chmod 600)"
echo "  2. place /etc/coolify-cp-backup.pass     (GPG passphrase, chmod 600, from operator ~/tmp/secrets/coolify-cp-backup.pass)"
echo "  3. ssh ${HOST} 'sudo /usr/local/sbin/coolify-cp-backup.sh'  (manual first run)"
echo "  4. confirm S3 objects under s3://<bucket>/coolify/control-plane/"
