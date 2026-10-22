#!/usr/bin/env bash
# Back up Traefik acme.json (LE cert state) off-host (t1037u).
# Losing acme.json + hitting LE rate limits (5 dup certs/week) would block a
# rebuild of the edge on new hardware. Run from OPERATOR box.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HOME/storagebox/backups/edge-tls/2026/10/22}"
mkdir -p "$OUT"
for H in contabo-a contabo-b; do
  echo "== ${H} =="
  TS="$(date +%Y%m%dT%H%M)"
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$H" \
    "sudo cp -a /data/coolify/proxy/acme.json /root/acme.json.bak-t1037u-${TS} && sudo ls -la /root/acme.json.bak-t1037u-${TS}"
  chmod 600 "/tmp/acme-${H}.json"
  python3 -c "import json; d=json.load(open('/tmp/acme-${H}.json')); print('certs:', len(d.get('letsencrypt',{}).get('Certificates',[])))"
  cp -a "/tmp/acme-${H}.json" "${OUT}/acme-${H}-20261022.json"
  chmod 600 "${OUT}/acme-${H}-20261022.json"
  rm -f "/tmp/acme-${H}.json"
done
ls -la "$OUT"
echo "OK: acme.json backups off-host (local /root copy + storagebox)"
