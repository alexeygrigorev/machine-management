#!/usr/bin/env bash
# Mirror the latest DR fast-pg-raise series from the Hetzner loopback VM
# (400d, the source of truth) into contabo-a's VictoriaMetrics (the obs
# vmui Alexey uses, t1119u/68147e6c AC5).
#
# contabo-a hot VM keeps only ~2d, so the weekly push there expires five
# days before the next run: RTO vanished from the obs vmui and the legacy
# contabo-a stale-check copy paged "missing" (2026-10-29/30). Re-pushing the
# newest sample of each series hourly keeps them queryable there.
#
# Values are copied verbatim (last_success/last_run are the real run
# timestamps, not the mirror time), so any reader computing
# time() - last_success still sees the true age. If the source has no DR
# series, nothing is pushed and contabo-a correctly goes missing.
#
# Usage (Hetzner user cron, see dr-raise-metrics-mirror.cron):
#   ./contingency/mirror-dr-raise-metrics.sh
# Optional env:
#   VM_URL (source, default http://127.0.0.1:8428), VM_SSH (target; "" = print
#   only, no Contabo contact), SSH_ID, MIRROR_HOSTS (host label regex,
#   default hetzner), WINDOW (default 30d)
set -euo pipefail

VM_URL="${VM_URL:-http://127.0.0.1:8428}"
# Empty VM_SSH ("") prints the payload and skips the remote leg.
VM_SSH="${VM_SSH-alexey@169.58.119.163}"
SSH_ID="${SSH_ID:-$HOME/.ssh/id_contabo}"
MIRROR_HOSTS="${MIRROR_HOSTS:-hetzner}"
WINDOW="${WINDOW:-30d}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

QUERY="last_over_time({__name__=~\"dr_fast_pg_raise_(rto_seconds|last_success_unixtime|ok|last_run_unixtime|db_bytes)\",host=~\"${MIRROR_HOSTS}\"}[${WINDOW}])"
if ! json="$(curl -sS -m 10 --fail --get "${VM_URL}/api/v1/query" --data-urlencode "query=${QUERY}")"; then
  log "ERROR: source VM query failed (url=${VM_URL})"
  exit 1
fi

# Prometheus text exposition, one line per series; label values escaped.
metrics="$(python3 -c '
import json, re, sys
d = json.loads(sys.argv[1])
if d.get("status") != "success":
    sys.exit("source VM status " + str(d.get("status")))
def esc(v):
    return v.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
for r in d["data"]["result"]:
    m = dict(r["metric"])
    name = m.pop("__name__")
    if not re.fullmatch(r"dr_fast_pg_raise_[a-z_]+", name):
        continue
    labels = ",".join("%s=\"%s\"" % (k, esc(v)) for k, v in sorted(m.items()))
    print("%s{%s} %s" % (name, labels, r["value"][1]))
' "$json")" || { log "ERROR: unparseable source VM response"; exit 1; }

if [[ -z "$metrics" ]]; then
  log "nothing to mirror: no dr_fast_pg_raise series in ${VM_URL} (last ${WINDOW})"
  exit 0
fi
count="$(printf '%s\n' "$metrics" | wc -l)"

if [[ -z "$VM_SSH" ]]; then
  printf '%s\n' "$metrics"
  log "mirror series=${count} remote=skipped"
  exit 0
fi

code="$(printf '%s\n' "$metrics" | ssh -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new -i "$SSH_ID" "$VM_SSH" \
  'curl -sS -m 15 -o /dev/null -w "%{http_code}" -H "Content-Type: text/plain" --data-binary @- http://127.0.0.1:8428/api/v1/import/prometheus')" || code="ssh_failed"
if [[ "$code" != "204" ]]; then
  log "ERROR: remote VM import HTTP ${code} via ${VM_SSH}"
  exit 1
fi
log "mirror series=${count} remote=ok"
