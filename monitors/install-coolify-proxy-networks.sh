#!/usr/bin/env bash
# Install the coolify-proxy network regression pager on Contabo node(s).
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never develop on Contabo.
# Copies monitors/coolify-proxy-networks.sh to the node(s), creates
# /etc/coolify-proxy-networks.env from the example if missing (placeholders
# only; real values stay out-of-band), and installs the every-5-min cron.
# Alerts go to dev@ ONLY (same dedupe/recover rules as the main healthcheck).
#
# Usage:
#   ./monitors/install-coolify-proxy-networks.sh [contabo-a] [contabo-b]
set -euo pipefail

HOSTS="${*:-contabo-a contabo-b}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

for H in $HOSTS; do
  case "$H" in contabo-a|contabo-b) ;; *) echo "unknown host $H (want contabo-a|contabo-b)" >&2; exit 1 ;; esac
  echo "== copy proxy-networks pager to ${H} =="
  STAGING="$("${SSH[@]}" "$H" 'mktemp -d /tmp/proxy-network-monitor.XXXXXXXX')"
  scp "${HERE}/coolify-proxy-networks.sh" "${H}:${STAGING}/monitor.sh"
  scp "${HERE}/relay-alert-lib.sh" "${H}:${STAGING}/relay-alert-lib.sh"
  scp "${HERE}/ops-daily-digest.sh" "${H}:${STAGING}/ops-daily-digest.sh"
  scp "${HERE}/coolify-proxy-networks.env.example" "${H}:${STAGING}/monitor.env"
  scp "${HERE}/coolify-proxy-networks.cron" "${H}:${STAGING}/monitor.cron"
  "${SSH[@]}" "$H" "sudo bash -s -- '$STAGING'" <<'EOF'
set -euo pipefail
staging="$1"
backup="$(date -u +%Y%m%dT%H%M%S)-$$"
for path in /usr/local/sbin/coolify-proxy-networks.sh /usr/local/sbin/ops-daily-digest.sh /etc/cron.d/coolify-proxy-networks /etc/coolify-proxy-networks.env; do
  [[ ! -e "$path" ]] || cp -a "$path" "${path}.bak-${backup}"
done
for path in /usr/local/sbin/coolify-proxy-networks.sh /usr/local/sbin/ops-daily-digest.sh /etc/coolify-proxy-networks.env; do
  [[ ! -e "$path" || -e "${path}.pre-alerts-from" ]] || cp -a "$path" "${path}.pre-alerts-from"
done
bash -n "$staging/monitor.sh"
install -m 0755 "$staging/monitor.sh" /usr/local/sbin/coolify-proxy-networks.sh
install -m 0755 "$staging/ops-daily-digest.sh" /usr/local/sbin/ops-daily-digest.sh
install -m 0644 "$staging/relay-alert-lib.sh" /usr/local/sbin/relay-alert-lib.sh
if [[ ! -f /etc/coolify-proxy-networks.env ]]; then
  install -m 0600 "$staging/monitor.env" /etc/coolify-proxy-networks.env
else
  # Migrate only the old shipped defaults; never load the main env (which
  # includes different recipients). Keep custom configuration and old state.
  python3 - <<'PYENV'
from pathlib import Path
import re
p = Path('/etc/coolify-proxy-networks.env')
s = p.read_text()
s = re.sub(r'^STATE_DIR=/var/lib/coolify-healthcheck/?$',
           'STATE_DIR=/var/lib/coolify-proxy-networks', s, flags=re.M)
s = re.sub(r'^ALERT_FROM=.*$', '', s, flags=re.M)
s = re.sub(r'^ALERT_FROM_NAME=.*$', '', s, flags=re.M)
s = re.sub(r'^ALERT_MSMTP_ACCOUNT=.*$', '', s, flags=re.M)
if not re.search(r'^RELAY_MONITOR_CONFIG=', s, re.M):
    s += '\nRELAY_MONITOR_CONFIG=/etc/relay-monitors.toml\n'
p.write_text(s)
PYENV
fi
mkdir -p /var/lib/coolify-proxy-networks
# Distinct from the keeper's /etc/cron.d/coolify-proxy-network-keep.
install -m 0644 "$staging/monitor.cron" /etc/cron.d/coolify-proxy-networks
command -v python3 >/dev/null
command -v datamailer >/dev/null || [[ -x /usr/local/bin/datamailer ]] || echo "WARN: datamailer missing on node"
[[ -r /etc/relay-monitors.toml ]] || echo "WARN: Relay monitor client config is not readable"
cat /etc/cron.d/coolify-proxy-networks
echo "BACKUP_SUFFIX=$backup (staging retained; no deletions)"
EOF
done
echo "ALL_OK proxy-networks pager installed (dev@ only, */5)"
echo "NEXT: force a check per host (read-only):"
echo "  ssh contabo-a 'sudo /usr/local/sbin/coolify-proxy-networks.sh; echo rc=\$?'"
echo "  ssh contabo-b 'sudo /usr/local/sbin/coolify-proxy-networks.sh; echo rc=\$?'"
