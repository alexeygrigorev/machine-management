#!/usr/bin/env bash
# Enable Traefik Prometheus metrics on an INTERNAL entrypoint (f5d8e22b AC1).
#
# What it does per host (contabo-a, contabo-b):
#   - PRESERVES coolify-proxy service-network attachments (2026-10-25
#     relay-dev/cmp-dev incident): before recreating the proxy it declares
#     every currently-attached non-coolify network in
#     /data/coolify/proxy/docker-compose.yml (external: true + service
#     attachment), so `docker compose up -d` no longer drops the ephemeral
#     `docker network connect` state Coolify relies on for compose-service
#     backends. After the recreate it re-runs the keeper (--apply) when
#     installed. See edge/ensure-coolify-proxy-networks.sh.
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
# Durability (2026-10-25): declare current proxy attachments BEFORE recreate.
# Prefer the versioned keeper when installed; fall back to an inline patch so
# this installer alone never drops service networks again.
if [[ -x /usr/local/sbin/ensure-coolify-proxy-networks.sh ]]; then
  /usr/local/sbin/ensure-coolify-proxy-networks.sh --patch-compose-only || true
else
  python3 - "$F" <<'PY' || true
import re, sys
path = sys.argv[1]
t = open(path).read()
orig = t
try:
  import json, subprocess
  cur = subprocess.run(["docker", "inspect", "coolify-proxy"],
                       capture_output=True, text=True).stdout
  nets = list((json.loads(cur)[0] if cur.strip().startswith("[") else json.loads(cur)).get("NetworkSettings", {}).get("Networks", {}).keys())
except Exception as e:
  print("WARN proxy-attachment preserve skipped:", e)
  nets = []
for net in nets:
  if net in ("coolify", "bridge", "host", "none", ""):
    continue
  # Exact-line matches only (never a prefix of another network name).
  if not re.search(rf"^  {re.escape(net)}:\s*$", t, re.M):
    if "\nnetworks:\n" in t:
      t = t.replace("\nnetworks:\n", f"\nnetworks:\n  {net}:\n    external: true\n", 1)
  if not re.search(rf"^      - {re.escape(net)}\s*$", t, re.M):
    m = re.search(r"^      - coolify\s*$", t, re.M)
    if m:
      t = t[:m.end()] + f"\n      - {net}" + t[m.end():]
if t != orig:
  open(path, "w").write(t)
  print("preserved proxy attachments:", ",".join(nets))
else:
  print("proxy attachments already declared")
PY
fi
cd /data/coolify/proxy && docker compose up -d traefik
# Re-attach anything compose still dropped (no-op when the patch held).
if [[ -x /usr/local/sbin/ensure-coolify-proxy-networks.sh ]]; then
  /usr/local/sbin/ensure-coolify-proxy-networks.sh --apply || true
fi
sleep 5
curl -sS --max-time 10 http://127.0.0.1:8082/metrics | head -n 5
echo "OK $HOSTNAME metrics live (internal only)"
REMOTE
done
echo "ALL_OK traefik metrics enabled (internal 8082, WG-scraped)"
