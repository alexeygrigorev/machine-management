#!/usr/bin/env bash
# Harden the WG reboot race + manage pg-shared-wg-bridge via compose (t1035u).
#
# Run from an OPERATOR box (e.g. Hetzner RMTHZ) — never develop on Contabo
# prod boxes. Idempotent: safe to re-run.
#
# Usage:
#   ./wg-bridge/install-wg-bridge.sh contabo-b            # full: sysctl + docker order + bridge (on .141)
#   ./wg-bridge/install-wg-bridge.sh --sysctl-only contabo-a   # peer hardening only (on .163)
#
# Effects on target:
#   1) /etc/sysctl.d/99-wg-bind.conf (ip_nonlocal_bind=1), applied live.
#   2) /etc/systemd/system/docker.service.d/10-wg.conf (After/Wants wg-quick@wg0),
#      followed by `systemctl daemon-reload` (docker itself is NOT restarted).
#   3) Full mode only: /opt/pg-shared-wg-bridge/docker-compose.yml +
#      /etc/systemd/system/pg-shared-wg-bridge.service (enabled), then the
#      legacy ad-hoc `docker run` bridge is stopped+removed and re-created
#      via compose (same name/image/ports — seconds of SQL blip).
#
# No secrets in git: nothing copied contains credentials (socat target is a
# container NAME on the shared `coolify` network).
set -euo pipefail

SYSCTL_ONLY=0
if [[ "${1:-}" == "--sysctl-only" ]]; then
  SYSCTL_ONLY=1
  shift
fi

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  echo "usage: $0 [--sysctl-only] <ssh-host>   (e.g. contabo-b)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

echo "== [${HOST}] 1/3 sysctl ip_nonlocal_bind=1 (persisted + live) =="
scp "${HERE}/99-wg-bind.conf" "${HOST}:/tmp/99-wg-bind.conf"
"${SSH[@]}" "$HOST" sudo install -m 0644 /tmp/99-wg-bind.conf /etc/sysctl.d/99-wg-bind.conf
"${SSH[@]}" "$HOST" 'sudo sysctl --system >/dev/null && sysctl net.ipv4.ip_nonlocal_bind'

echo "== [${HOST}] 2/3 docker.service After/Wants wg-quick@wg0 =="
scp "${HERE}/docker-override.conf" "${HOST}:/tmp/docker-override.conf"
"${SSH[@]}" "$HOST" 'sudo mkdir -p /etc/systemd/system/docker.service.d && sudo install -m 0644 /tmp/docker-override.conf /etc/systemd/system/docker.service.d/10-wg.conf && sudo systemctl daemon-reload && systemctl show docker.service -p After | tr " " "\n" | grep -F wg-quick@wg0.service'

if [[ "$SYSCTL_ONLY" == "1" ]]; then
  echo "OK: ${HOST} hardened (sysctl-only mode, docker NOT restarted, no bridge changes)."
  exit 0
fi

echo "== [${HOST}] 3/3 compose-managed pg-shared-wg-bridge =="
scp "${HERE}/docker-compose.yml" "${HOST}:/tmp/wg-bridge-compose.yml"
scp "${HERE}/pg-shared-wg-bridge.service" "${HOST}:/tmp/pg-shared-wg-bridge.service"
"${SSH[@]}" "$HOST" 'sudo bash -s' <<'EOF'
set -euo pipefail
mkdir -p /opt/pg-shared-wg-bridge
sudo install -m 0644 /tmp/wg-bridge-compose.yml /opt/pg-shared-wg-bridge/docker-compose.yml
sudo install -m 0644 /tmp/pg-shared-wg-bridge.service /etc/systemd/system/pg-shared-wg-bridge.service
sudo systemctl daemon-reload
sudo systemctl enable pg-shared-wg-bridge.service
cd /opt/pg-shared-wg-bridge
if sudo docker ps -a --format "{{.Names}}" | grep -qx pg-shared-wg-bridge; then
  echo "-- adopting legacy ad-hoc bridge into compose management (stop+rm, seconds of blip) --"
  sudo docker stop pg-shared-wg-bridge
  sudo docker rm pg-shared-wg-bridge
fi
sudo docker compose up -d --remove-orphans
sleep 3
sudo docker ps --filter name=pg-shared-wg-bridge --format "bridge: {{.Names}} {{.Image}} {{.Status}} {{.Ports}}"
sudo ss -tlnp | grep -F "10.100.0.2:5432" || { echo "ERROR: 10.100.0.2:5432 not listening" >&2; exit 1; }
echo "OK: bridge compose-managed and listening on 10.100.0.2:5432"
EOF

echo
echo "NEXT (restart proof, maintenance-ok on ${HOST}):"
echo "  ssh ${HOST} 'sudo systemctl restart pg-shared-wg-bridge && sudo ss -tlnp | grep 10.100.0.2:5432'"
echo "  ssh contabo-a 'pg_isready -h 10.100.0.2 -p 5432'"
