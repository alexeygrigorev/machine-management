#!/usr/bin/env bash
# Enable Traefik Prometheus metrics on an INTERNAL entrypoint (f5d8e22b AC1).
#
# What it does per host (contabo-a, contabo-b):
#   - patches /data/coolify/proxy/docker-compose.yml (root-owned, Coolify-managed):
#     adds --metrics.prometheus=true + --entrypoints.metrics.address=:8082
#     + --metrics.prometheus.entrypoint=metrics, publishes 8082 bound ONLY to
#     127.0.0.1 + 10.100.0.x (WireGuard) — NEVER 0.0.0.0, never public.
#   - restarts only the coolify-proxy service (no app restarts).
#   - verifies http://127.0.0.1:8082/metrics on the host.
#
# VictoriaMetrics scrapes over WireGuard:
#   contabo-a -> 10.100.0.1:8082, contabo-b -> 10.100.0.2:8082
# (see coolify-observability configs/vm/prometheus.yml traefik jobs).
#
# Usage: ./edge/install-traefik-metrics.sh [contabo-a] [contabo-b]
set -euo pipefail

HOSTS="${*:-contabo-a contabo-b}"

for H in $HOSTS; do
  echo "=== $H: enable traefik metrics (internal 8082) ==="
  # WG IP per host for the bind (internal only).
  case "$H" in
    contabo-a) WG_IP="10.100.0.1" ;;
    contabo-b) WG_IP="10.100.0.2" ;;
    *) echo "unknown host $H (want contabo-a|contabo-b)"; exit 1 ;;
  esac
  # shellcheck disable=SC2086
  ssh -o BatchMode=yes -o ConnectTimeout=10 $H sudo bash -s "$WG_IP" <<'REMOTE'
set -euo pipefail
WG_IP="$1"
F=/data/coolify/proxy/docker-compose.yml
cp -a "$F" "$F.bak-pre-metrics-$(date +%Y%m%dT%H%M%S)" 2>/dev/null || true
python3 - "$F" "$WG_IP" <<'PY'
import sys
path, wg = sys.argv[1], sys.argv[2]
t = open(path).read()
# Idempotent: add metrics flags if missing.
flags = [
  "--metrics.prometheus=true",
  "--entrypoints.metrics.address=:8082",
  "--metrics.prometheus.entrypoint=metrics",
  "--metrics.prometheus.addEntryPointsLabels=true",
  "--metrics.prometheus.addServicesLabels=true",
  "--metrics.prometheus.addRoutersLabels=true",
]
for f in flags:
  if f not in t:
    # insert before the api.insecure=false line (stable anchor), else append
    anchor = "'--api.insecure=false'"
    if anchor in t:
      t = t.replace(anchor, f"'{f}'\n      - {anchor}", 1)
    else:
      t = t.replace("labels:", f"      - '{f}'\n    labels:", 1)
# Publish 8082 bound to loopback + WG only (never public).
for bind in (f"127.0.0.1:8082:8082", f"{wg}:8082:8082"):
  needle = f"'{bind}'"
  if needle not in t:
    # add after the 8080 publish line
    anchor = "'8080:8080'"
    if anchor in t:
      t = t.replace(anchor, f"{anchor}\n      - {needle}", 1)
    else:
      raise SystemExit("anchor 8080:8080 not found")
open(path, "w").write(t)
print("patched", path)
PY
cd /data/coolify/proxy && docker compose up -d traefik
sleep 5
curl -sS --max-time 10 http://127.0.0.1:8082/metrics | head -n 5
echo "OK $HOSTNAME metrics live (internal only)"
REMOTE
done
echo "ALL_OK traefik metrics enabled (internal 8082, WG-scraped)"
