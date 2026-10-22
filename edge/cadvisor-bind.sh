#!/usr/bin/env bash
# Rebind lgtm cAdvisor from 0.0.0.0:9101 to WireGuard + loopback (t1037u).
# Safe: Prometheus scrapes cadvisor via 10.100.0.2:9101 (see
# /data/lgtm/prometheus/prometheus.yml job `cadvisor`), which keeps working.
# Only recreates the `cadvisor` container — no app, DB, or proxy restarts.
#
# Run from OPERATOR box: ./edge/cadvisor-bind.sh contabo-b
set -euo pipefail

HOST="${1:-}"
[[ -n "$HOST" ]] || { echo "usage: $0 <ssh-host>" >&2; exit 2; }
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

"${SSH[@]}" "$HOST" sudo bash -s <<'EOF'
set -euo pipefail
F=/data/lgtm/exporters/docker-compose.node.yml
[[ -f "$F" ]] || { echo "no exporters compose on this host, nothing to do"; exit 0; }
cp -a "$F" "$F.bak-t1037u-$(date +%Y%m%dT%H%M)"
if grep -q "10.100.0.2:9101:8080" "$F" && ! grep -q "0.0.0.0:9101" "$F"; then
  echo "already WG-bound, nothing to change"
else
  # '9101:8080' -> WG + loopback binds (proper YAML list items).
  python3 - "$F" <<'PYEOF'
import sys
f = sys.argv[1]
s = open(f).read()
s = s.replace("'9101:8080', '127.0.0.1:9101:8080'", "'10.100.0.2:9101:8080'\n      - '127.0.0.1:9101:8080'")
s = s.replace("- '9101:8080'", "- '10.100.0.2:9101:8080'\n      - '127.0.0.1:9101:8080'")
open(f, "w").write(s)
PYEOF
  grep -n "9101" "$F"
  docker compose -f docker-compose.node.yml config >/dev/null || { echo "ERROR: compose invalid after edit" >&2; exit 1; }
fi
cd /data/lgtm/exporters
# NOTE: project name is pinned (-p lgtm-exporters); bare `docker compose`
# would derive `exporters` and collide on the port instead of recreating.
docker compose -p lgtm-exporters -f docker-compose.node.yml up -d cadvisor
sleep 5
docker ps --filter name=cadvisor --format "cadvisor: {{.Names}} {{.Image}} {{.Status}} {{.Ports}}"
echo "--- host listeners ---"
ss -tlnp | grep -E ":9101" || { echo "ERROR: :9101 not listening at all" >&2; exit 1; }
if ss -tln | grep -q "0.0.0.0:9101"; then
  echo "ERROR: :9101 still on 0.0.0.0" >&2; exit 1
fi
echo "OK: :9101 no longer on 0.0.0.0"
# Prometheus scrape path must stay green (WG).
curl -sf -m 5 http://10.100.0.2:9101/containers/ -o /dev/null \
  && echo "OK: WG scrape http://10.100.0.2:9101/containers/ reachable" \
  || { echo "ERROR: WG scrape broken" >&2; exit 1; }
EOF

echo "--- external probe (expect 000/timeout for :9101) ---"
IP=""; [[ "$HOST" == "contabo-a" ]] && IP="169.58.119.163" || IP="169.58.124.141"
curl -sk -o /dev/null -w ":9101 -> %{http_code}\n" -m 8 "http://${IP}:9101/containers/" || echo ":9101 -> unreachable (good)"
