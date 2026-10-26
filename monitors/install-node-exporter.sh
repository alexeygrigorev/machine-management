#!/usr/bin/env bash
# Install node_exporter on Hetzner bound to 127.0.0.1 only (t1493u AC4).
#
# Run on HETZNER (RMTHZ) as your normal user (sudo is used for apt/systemd):
#   ./monitors/install-node-exporter.sh
#
# What it does (idempotent):
#   1. Installs prometheus-node-exporter from Ubuntu archive (no AWS, no
#      third-party binaries).
#   2. Pins the listener to 127.0.0.1:9100 (never a public unauthenticated
#      port) so the follow-up vmalert intake can scrape or push filesystem
#      metrics locally.
#   3. Enables + starts the systemd unit and verifies
#      `curl -s 127.0.0.1:9100/metrics | grep node_filesystem_avail_bytes`.
set -euo pipefail

echo "== apt install prometheus-node-exporter =="
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-node-exporter

echo "== pin listener to 127.0.0.1:9100 =="
# Ubuntu unit reads ARGS from /etc/default/prometheus-node-exporter.
if [[ -f /etc/default/prometheus-node-exporter ]]; then
  echo "current /etc/default/prometheus-node-exporter:"
  cat /etc/default/prometheus-node-exporter || true
fi
sudo bash -c 'cat > /etc/default/prometheus-node-exporter <<EOF
# Hetzner loopback-only (t1493u AC4): never expose an unauthenticated port.
ARGS="--web.listen-address=127.0.0.1:9100 --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|run|snap)($|/)"
EOF'
cat /etc/default/prometheus-node-exporter

echo "== enable + restart =="
sudo systemctl daemon-reload
sudo systemctl enable prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter
sleep 2
sudo systemctl is-active prometheus-node-exporter
ss -tlnp 2>/dev/null | grep -E ':9100' || sudo ss -tlnp | grep -E ':9100' || true

echo "== verify metrics =="
curl -s -m 10 127.0.0.1:9100/metrics | grep -E '^node_exporter_build_info|node_filesystem_avail_bytes' | head -n 10
echo "== public-bind guard (must be empty) =="
if ss -tln 2>/dev/null | awk '$4 ~ /:9100$/ {print $4}' | grep -qv '127.0.0.1:9100'; then
  echo "FAIL: node_exporter listens on a non-loopback address:"
  ss -tln | grep ':9100' || true
  exit 1
else
  echo "OK: only 127.0.0.1:9100 (or nothing else) listens on :9100"
  ss -tln 2>/dev/null | grep ':9100' || true
fi
