#!/usr/bin/env bash
# Install the coolify-proxy network keeper on Contabo node(s).
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never develop on Contabo.
# Copies edge/ensure-coolify-proxy-networks.sh to the node(s), installs the
# every-2-min self-heal cron (connect + declarative compose patch; no
# recreation, no app restarts), and runs --apply once to verify the keeper and start its log.
#
# Usage:
#   ./edge/install-proxy-network-keep.sh [contabo-a] [contabo-b]
#
# No secrets in git: this installer writes no credentials; the script needs
# only local docker access on the node.
set -euo pipefail

HOSTS="${*:-contabo-a contabo-b}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

for H in $HOSTS; do
  case "$H" in contabo-a|contabo-b) ;; *) echo "unknown host $H (want contabo-a|contabo-b)" >&2; exit 1 ;; esac
  echo "== ${H}: install proxy network keeper =="
  STAGING="$("${SSH[@]}" "$H" 'mktemp -d /tmp/proxy-network-keep.XXXXXXXX')"
  scp "${HERE}/ensure-coolify-proxy-networks.sh" "${H}:${STAGING}/ensure.sh"
  scp "${HERE}/proxy-network-keep.cron" "${H}:${STAGING}/keeper.cron"
  "${SSH[@]}" "$H" "sudo bash -s -- '$STAGING'" <<'EOF'
set -euo pipefail
staging="$1"
backup="$(date -u +%Y%m%dT%H%M%S)-$$"
for path in /usr/local/sbin/ensure-coolify-proxy-networks.sh /etc/cron.d/coolify-proxy-network-keep; do
  [[ ! -e "$path" ]] || cp -a "$path" "${path}.bak-${backup}"
done
bash -n "$staging/ensure.sh"
install -m 0755 "$staging/ensure.sh" /usr/local/sbin/ensure-coolify-proxy-networks.sh
# This MUST differ from the pager's /etc/cron.d/coolify-proxy-networks.
install -m 0644 "$staging/keeper.cron" /etc/cron.d/coolify-proxy-network-keep
touch /var/log/coolify-proxy-networks.log
/usr/local/sbin/ensure-coolify-proxy-networks.sh --apply >> /var/log/coolify-proxy-networks.log 2>&1
/usr/local/sbin/ensure-coolify-proxy-networks.sh --check
cat /etc/cron.d/coolify-proxy-network-keep
echo "BACKUP_SUFFIX=$backup (staging retained; no deletions)"
EOF
done
echo "ALL_OK proxy network keeper installed (self-heal */2; pager is monitors/coolify-proxy-networks)"
echo "Do NOT 'docker compose up -d traefik' on a live proxy outside Alexey's maintenance window."
