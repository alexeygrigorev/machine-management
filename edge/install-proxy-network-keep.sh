#!/usr/bin/env bash
# Install the coolify-proxy network keeper on Contabo node(s).
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never develop on Contabo.
# Copies edge/ensure-coolify-proxy-networks.sh to the node(s), installs the
# every-2-min self-heal cron (connect + declarative compose patch; no
# recreation, no app restarts), and runs one --check to show current state.
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
  scp "${HERE}/ensure-coolify-proxy-networks.sh" "${H}:/tmp/ensure-coolify-proxy-networks.sh"
  scp "${HERE}/proxy-network-keep.cron" "${H}:/tmp/proxy-network-keep.cron"
  "${SSH[@]}" "$H" 'sudo bash -s' <<'EOF'
set -euo pipefail
install -m 0755 /tmp/ensure-coolify-proxy-networks.sh /usr/local/sbin/ensure-coolify-proxy-networks.sh
install -m 0644 /tmp/proxy-network-keep.cron /etc/cron.d/coolify-proxy-networks
bash -n /usr/local/sbin/ensure-coolify-proxy-networks.sh && echo SYNTAX_OK
mkdir -p /var/lib/coolify-healthcheck
touch /var/log/coolify-proxy-networks.log
echo "--- current attachment state (check-only, changes nothing) ---"
/usr/local/sbin/ensure-coolify-proxy-networks.sh --check || echo "(missing networks above will be healed by the 2-min cron or by running --apply)"
cat /etc/cron.d/coolify-proxy-networks
EOF
done
echo "ALL_OK proxy network keeper installed (self-heal */2; pager is monitors/coolify-proxy-networks)"
echo "NEXT (safe, no recreation): run the healer once per host to reattach + declare:"
echo "  ssh contabo-a 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --apply'"
echo "  ssh contabo-b 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --apply'"
echo "Do NOT 'docker compose up -d traefik' on a live proxy outside Alexey's maintenance window."
