#!/usr/bin/env bash
# Install the permanent continuous healthcheck on a Coolify node.
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never install coding agents
# on Contabo prod boxes. Copies monitors/coolify-healthcheck.sh to the node,
# creates /etc/coolify-healthcheck.env from the example if missing (you fill
# real values on the node afterwards), and installs the every-5-min cron entry.
#
# Usage:
#   ./monitors/install-coolify-healthcheck.sh contabo-b
#   # then on the node (once): sudo nano /etc/coolify-healthcheck.env
#   # verify: sudo /usr/local/sbin/coolify-healthcheck.sh; echo $?; tail /var/log/coolify-healthcheck.log
#
# No secrets in git: this script never writes credentials; the env file on the
# node starts as placeholders and must be edited out-of-band (Drive doc).
# SMTP: the node needs sendmail or msmtp to actually deliver to dev@ — without
# an MTA, failures are logged only (script warns). Configure msmtp out-of-band.
set -euo pipefail

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  echo "usage: $0 <ssh-host>   (e.g. contabo-b)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

echo "== copy healthcheck script to ${HOST} =="
scp "${HERE}/coolify-healthcheck.sh" "${HOST}:/tmp/coolify-healthcheck.sh"
"${SSH[@]}" "$HOST" sudo install -m 0755 /tmp/coolify-healthcheck.sh /usr/local/sbin/coolify-healthcheck.sh

echo "== env file (placeholders only; never overwritten) =="
scp "${HERE}/coolify-healthcheck.env.example" "${HOST}:/tmp/coolify-healthcheck.env.example"
"${SSH[@]}" "$HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
if [[ ! -f /etc/coolify-healthcheck.env ]]; then
  cp /tmp/coolify-healthcheck.env.example /etc/coolify-healthcheck.env
  chmod 600 /etc/coolify-healthcheck.env
  echo "created /etc/coolify-healthcheck.env (PLACEHOLDERS — edit on node, chmod 600)"
else
  echo "keep existing /etc/coolify-healthcheck.env (not overwritten)"
fi
mkdir -p /var/lib/coolify-healthcheck
command -v curl >/dev/null || echo "WARN: curl missing on node — install (apt install curl)"
command -v pg_isready >/dev/null || echo "WARN: pg_isready missing on node — install (apt install postgresql-client) or rely on docker exec"
command -v sendmail >/dev/null || command -v msmtp >/dev/null || echo "WARN: no MTA (sendmail/msmtp) on node — alerts will be LOG-ONLY until msmtp is configured (see monitors/README.md)"
EOF

echo "== cron entry (every 5 min Europe/Berlin) =="
scp "${HERE}/coolify-healthcheck.cron" "${HOST}:/tmp/coolify-healthcheck.cron"
"${SSH[@]}" "$HOST" sudo install -m 0644 /tmp/coolify-healthcheck.cron /etc/cron.d/coolify-healthcheck

echo "== verify =="
"${SSH[@]}" "$HOST" 'sudo bash -n /usr/local/sbin/coolify-healthcheck.sh && echo SYNTAX_OK; cat /etc/cron.d/coolify-healthcheck'
echo
echo "NEXT: edit real values in /etc/coolify-healthcheck.env on ${HOST}, configure msmtp"
echo "for delivery to alexey@datatalks.club and dev@dtcdev.click, then run:"
echo "  ssh ${HOST} 'sudo /usr/local/sbin/coolify-healthcheck.sh'"
echo "expect ALL_OK (or CHECKS_FAILED with entries) in /var/log/coolify-healthcheck.log."
