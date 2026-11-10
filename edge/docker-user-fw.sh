#!/usr/bin/env bash
# DOCKER-USER allowlist for Docker-published admin ports (t1037u edge harden).
#
# Why: Docker's DNAT happens before ufw, so ufw ALLOW rules for :9101 etc. do
# not matter and public :8000/:6001/:6002/:9101 are reachable from anywhere.
# DOCKER-USER is the supported hook to filter Docker-published ports without
# touching app routers, DNS, or CloudFront (no traffic flip).
#
# Run from OPERATOR box: ./edge/docker-user-fw.sh <contabo-a|contabo-b>
# Idempotent. Reversible: `sudo iptables -F DOCKER-USER && sudo ip6tables -F DOCKER-USER`.
# Persists across reboot via /etc/systemd/system/edge-docker-user-restore.service
# (restores the exact rule set after docker.service).
#
# Allows: loopback, WireGuard 10.100.0.0/24, docker nets, the Contabo peer,
# the operator box (Hetzner RMTHZ v4+v6, overridable via OPERATOR_V4/OPERATOR_V6).
# Public web ports 80/443 are allowed; every other new connection arriving on
# eth0 to a Docker-published port is dropped. Trusted operator/peer/WireGuard
# sources retain the existing allowlist access.
set -euo pipefail

HOST="${1:-}"
[[ -n "$HOST" ]] || { echo "usage: $0 <ssh-host>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPERATOR_V4="${OPERATOR_V4:-135.181.114.209}"
OPERATOR_V6="${OPERATOR_V6:-2a01:4f9:4b:1adc::2}"
# The other Contabo node (peer scrapes/monitors cross over the public IP too).
PEER_V4=""; [[ "$HOST" == "contabo-a" ]] && PEER_V4="169.58.124.141" || PEER_V4="169.58.119.163"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

echo "== [${HOST}] installing DOCKER-USER allowlist (admin ports only) =="
scp "${HERE}/docker-user-restore.sh" "${HOST}:/tmp/edge-docker-user-restore.sh"
scp "${HERE}/edge-docker-user-restore.service" "${HOST}:/tmp/edge-docker-user-restore.service"

"${SSH[@]}" "$HOST" HOST="$HOST" OPERATOR_V4="$OPERATOR_V4" OPERATOR_V6="$OPERATOR_V6" PEER_V4="$PEER_V4" sudo -E bash -s <<'EOF'
set -euo pipefail
trap 'rm -f -- /tmp/edge-docker-user-restore.sh /tmp/edge-docker-user-restore.service' EXIT
STAMP="$(date +%Y%m%dT%H%M%S%N)"
for path in /usr/local/sbin/edge-docker-user-restore.sh /etc/systemd/system/edge-docker-user-restore.service /etc/edge-docker-user-rules.v4 /etc/edge-docker-user-rules.v6; do
  [[ ! -e "$path" ]] || cp -a "$path" "${path}.bak-${STAMP}"
done
install -m 0755 /tmp/edge-docker-user-restore.sh /usr/local/sbin/edge-docker-user-restore.sh
install -m 0644 /tmp/edge-docker-user-restore.service /etc/systemd/system/edge-docker-user-restore.service
systemctl daemon-reload
systemctl enable edge-docker-user-restore.service
OPERATOR_V4="${OPERATOR_V4:?}" OPERATOR_V6="${OPERATOR_V6:?}" PEER_V4="${PEER_V4:?}" /usr/local/sbin/edge-docker-user-restore.sh apply

# Remove the exact stale public UFW allow rules. The DOCKER-USER rules are the
# actual Docker ingress filter; these UFW rules are misleading and ineffective
# for DNAT traffic. Snapshot UFW state first, then remove only Anywhere rules.
if command -v ufw >/dev/null 2>&1; then
  for path in /etc/ufw/user.rules /etc/ufw/user6.rules; do
    [[ ! -e "$path" ]] || cp -a "$path" "${path}.bak-${STAMP}"
  done
  remove_ufw_allow_rule() {
    local port="$1" source_text="$2" number
    while true; do
      number="$(ufw status numbered | awk -v port="$port/tcp" -v source="$source_text" '
        index($0, port) && index($0, "ALLOW") && index($0, source) { print; exit }
      ' | sed -nE 's/^\[[[:space:]]*([0-9]+)\].*/\1/p')"
      [[ -n "$number" ]] || break
      ufw --force delete "$number"
    done
  }
  for port in 8000 6001 6002; do remove_ufw_allow_rule "$port" 'Anywhere'; done
  if [[ "$HOST" == "contabo-a" ]]; then
    for port in 3100 9090 9093; do remove_ufw_allow_rule "$port" '10.100.0.0/24'; done
  fi
fi

echo "--- DOCKER-USER v4 ---"
iptables -L DOCKER-USER -n -v --line-numbers
echo "--- DOCKER-USER v6 ---"
ip6tables -L DOCKER-USER -n -v --line-numbers || true
EOF

echo
echo "VERIFY from operator box (do not skip):"
echo "  curl -sk -o /dev/null -w '8000:%{http_code}\n' -m 8 http://${HOST#contabo-}x/ 2>/dev/null || true"
echo "  curl -sk -o /dev/null -w '8000:%{http_code}\n' -m 8 http://169.58.119.163:8000/ http://169.58.124.141:8000/"
echo "  ssh ${HOST} 'sudo iptables -L DOCKER-USER -n -v | tail -3'   # DROP counters climb from background scans"
echo "ROLLBACK: restore timestamped /etc/ufw/user.rules* and DOCKER-USER rules/service/script backups; run ufw reload and systemctl daemon-reload"
