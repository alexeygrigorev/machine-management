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
# Non-Relay checks send through the root-owned Relay client config. Checks of
# Relay itself retain the independent sandbox SES SMTP path.
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
scp "${HERE}/relay-alert-lib.sh" "${HOST}:/tmp/relay-alert-lib.sh"
scp "${HERE}/incident-gate.sh" "${HOST}:/tmp/incident-gate.sh"
scp "${HERE}/ops-daily-digest.sh" "${HOST}:/tmp/ops-daily-digest.sh"
scp "${HERE}/coolify-ops.logrotate" "${HOST}:/tmp/coolify-ops.logrotate"
"${SSH[@]}" "$HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
for path in /usr/local/sbin/coolify-healthcheck.sh /usr/local/sbin/ops-daily-digest.sh; do
  [[ ! -e "$path" || -e "${path}.pre-alerts-from" ]] || cp -a "$path" "${path}.pre-alerts-from"
done
if [[ -e /etc/logrotate.d/coolify-ops && ! -e /etc/logrotate.d/coolify-ops.pre-fable-fixes ]]; then
  cp -a /etc/logrotate.d/coolify-ops /etc/logrotate.d/coolify-ops.pre-fable-fixes
fi
install -m 0755 /tmp/coolify-healthcheck.sh /usr/local/sbin/coolify-healthcheck.sh
install -m 0755 /tmp/ops-daily-digest.sh /usr/local/sbin/ops-daily-digest.sh
install -m 0644 /tmp/relay-alert-lib.sh /usr/local/sbin/relay-alert-lib.sh
install -m 0644 /tmp/incident-gate.sh /usr/local/sbin/incident-gate.sh
rm -f /tmp/coolify-healthcheck.sh /tmp/ops-daily-digest.sh /tmp/relay-alert-lib.sh /tmp/incident-gate.sh
install -m 0644 /tmp/coolify-ops.logrotate /etc/logrotate.d/coolify-ops
rm -f /tmp/coolify-ops.logrotate
logrotate -d /etc/logrotate.d/coolify-ops
EOF

echo "== env file (placeholders only; never overwritten) =="
scp "${HERE}/coolify-healthcheck.env.example" "${HOST}:/tmp/coolify-healthcheck.env.example"
"${SSH[@]}" "$HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
if [[ ! -f /etc/coolify-healthcheck.env ]]; then
  cp /tmp/coolify-healthcheck.env.example /etc/coolify-healthcheck.env
  chmod 600 /etc/coolify-healthcheck.env
  echo "created /etc/coolify-healthcheck.env (PLACEHOLDERS — edit on node, chmod 600)"
else
  if grep -Eq '^ALERT_FROM=(noreply@datatalks\.club|no-reply@dtcdev\.click)$' /etc/coolify-healthcheck.env \
    || ! grep -q '^RELAY_MONITOR_CONFIG=' /etc/coolify-healthcheck.env; then
    [[ -e /etc/coolify-healthcheck.env.pre-alerts-from ]] || cp -a /etc/coolify-healthcheck.env /etc/coolify-healthcheck.env.pre-alerts-from
    python3 - <<'PYENV'
from pathlib import Path
import re
p = Path('/etc/coolify-healthcheck.env')
s = p.read_text()
s = re.sub(r'^ALERT_FROM=(noreply@datatalks\.club|no-reply@dtcdev\.click)$',
           'ALERT_FROM=alerts@dtcdev.click', s, flags=re.M)
for key, value in [('ALERT_FROM_NAME', '"DTC Alerts"'), ('ALERT_MSMTP_ACCOUNT', 'alerts'),
                   ('RELAY_MONITOR_CONFIG', '/etc/relay-monitors.toml')]:
    if not re.search(r'^' + key + '=', s, re.M):
        s += '\n' + key + '=' + value + '\n'
p.write_text(s)
PYENV
    chmod 600 /etc/coolify-healthcheck.env
    echo "migrated alert sender fields in /etc/coolify-healthcheck.env; recipients preserved"
  else
    echo "kept existing /etc/coolify-healthcheck.env (no sender migration needed)"
  fi
fi
mkdir -p /var/lib/coolify-healthcheck
command -v curl >/dev/null || echo "WARN: curl missing on node — install (apt install curl)"
command -v pg_isready >/dev/null || echo "WARN: pg_isready missing on node — install (apt install postgresql-client) or rely on docker exec"
command -v datamailer >/dev/null || [[ -x /usr/local/bin/datamailer ]] || echo "WARN: datamailer missing — non-Relay alerts cannot be sent"
[[ -r /etc/relay-monitors.toml ]] || echo "WARN: Relay monitor client config is not readable"
command -v sendmail >/dev/null || command -v msmtp >/dev/null || echo "WARN: no MTA (sendmail/msmtp) on node — Relay self-monitor alerts cannot be sent"
EOF

echo "== cron entry (every 5 min Europe/Berlin) =="
scp "${HERE}/coolify-healthcheck.cron" "${HOST}:/tmp/coolify-healthcheck.cron"
"${SSH[@]}" "$HOST" sudo install -m 0644 /tmp/coolify-healthcheck.cron /etc/cron.d/coolify-healthcheck

echo "== verify =="
"${SSH[@]}" "$HOST" 'sudo bash -n /usr/local/sbin/coolify-healthcheck.sh && echo SYNTAX_OK; cat /etc/cron.d/coolify-healthcheck'
echo
echo "NEXT: edit real values in /etc/coolify-healthcheck.env on ${HOST}, configure the Relay client"
echo "for delivery to dev@dtcdev.click only, then run:"
echo "  ssh ${HOST} 'sudo /usr/local/sbin/coolify-healthcheck.sh'"
echo "expect ALL_OK (or CHECKS_FAILED with entries) in /var/log/coolify-healthcheck.log."
echo "If HOST is contabo-a (CP): ensure SKIP_BACKUP_CHECKS=1 (and usually SKIP_PG_SHARED=1"
echo "SKIP_PG_RELAY=1) in /etc/coolify-healthcheck.env — dumps/WAL exist only on contabo-b (t1209u)."
echo "Set RECOVER_NOTIFY_MIN_SEC=600 on both hosts. Set SKIP_PUBLIC_HTTP_CHECKS=1 on"
echo "contabo-a and 0 on contabo-b, the sole on-node public HTTP/content pager (t1273u)."
echo "Keep ALERT_TO=dev@dtcdev.click for real FAILs, including AISHL."
