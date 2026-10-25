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
  scp "${HERE}/coolify-proxy-networks.sh" "${H}:/tmp/coolify-proxy-networks.sh"
  "${SSH[@]}" "$H" sudo install -m 0755 /tmp/coolify-proxy-networks.sh /usr/local/sbin/coolify-proxy-networks.sh
  echo "== env file (placeholders only; never overwritten) =="
  scp "${HERE}/coolify-proxy-networks.env.example" "${H}:/tmp/coolify-proxy-networks.env.example"
  "${SSH[@]}" "$H" 'sudo bash -s' <<'EOF'
set -euo pipefail
if [[ ! -f /etc/coolify-proxy-networks.env ]]; then
  cp /tmp/coolify-proxy-networks.env.example /etc/coolify-proxy-networks.env
  chmod 600 /etc/coolify-proxy-networks.env
  echo "created /etc/coolify-proxy-networks.env (PLACEHOLDERS — dev@ only)"
else
  echo "keep existing /etc/coolify-proxy-networks.env (not overwritten)"
fi
mkdir -p /var/lib/coolify-healthcheck
command -v python3 >/dev/null || echo "WARN: python3 missing on node — install (apt install python3)"
command -v sendmail >/dev/null || command -v msmtp >/dev/null || echo "WARN: no MTA on node — alerts LOG-ONLY until msmtp is configured (see monitors/README.md)"
EOF
  echo "== cron entry (every 5 min Europe/Berlin) =="
  scp "${HERE}/coolify-proxy-networks.cron" "${H}:/tmp/coolify-proxy-networks.cron"
  "${SSH[@]}" "$H" sudo install -m 0644 /tmp/coolify-proxy-networks.cron /etc/cron.d/coolify-proxy-networks
  echo "== verify =="
  "${SSH[@]}" "$H" 'sudo bash -n /usr/local/sbin/coolify-proxy-networks.sh && echo SYNTAX_OK; cat /etc/cron.d/coolify-proxy-networks'
done
echo "ALL_OK proxy-networks pager installed (dev@ only, */5)"
echo "NEXT: force a check per host (read-only):"
echo "  ssh contabo-a 'sudo /usr/local/sbin/coolify-proxy-networks.sh; echo rc=\$?'"
echo "  ssh contabo-b 'sudo /usr/local/sbin/coolify-proxy-networks.sh; echo rc=\$?'"
