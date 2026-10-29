#!/usr/bin/env bash
# Daily Ops Digest — aggregates DIGEST-class informational/warning/recovery
# events into a single daily email to dev@dtcdev.click ONLY (t1885u / 3bf25bda).
#
# Policy (Alexey t1885u):
#   - Every PAGE alert that fires to alexey@ must be a real must-fix-now problem.
#   - WARN, handled DB errors, 24h fill predictions, AUTOHEALED notices, and
#     RECOVERED notices are DIGEST items: they NEVER email alexey@.
#   - Quiet days (0 queued items) send nothing.
#
# Usage:
#   # Enqueue an item from any monitor script:
#   ops-daily-digest.sh --enqueue <source> <check> <level> <summary>
#
#   # Send the daily digest (cron at 08:00 Europe/Berlin) and rotate the queue:
#   ops-daily-digest.sh --send
#
#   # Render without sending or rotating:
#   ops-daily-digest.sh --dry-run
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  DEFAULT_STATE_DIR="/var/lib/ops-daily-digest"
else
  DEFAULT_STATE_DIR="${HOME}/.local/state/ops-daily-digest"
fi

DIGEST_STATE_DIR="${DIGEST_STATE_DIR:-$DEFAULT_STATE_DIR}"
DIGEST_QUEUE_FILE="${DIGEST_QUEUE_FILE:-${DIGEST_STATE_DIR}/queue.tsv}"
DIGEST_TO="${DIGEST_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
HOST_TAG="${HOST_TAG:-$(hostname -s 2>/dev/null || hostname)}"

# Hard safety guard (AC2 / AC4): DIGEST can NEVER reach alexey@ personal inboxes.
sanitize_digest_recipients() {
  local raw="${1// /,}" tok
  local -a kept=()
  IFS=',' read -r -a parts <<< "$raw"
  for tok in "${parts[@]}"; do
    [[ -n "$tok" ]] || continue
    case "${tok,,}" in
      alexey@*|*alexey.s.grigoriev@*) continue ;;
      *) kept+=("$tok") ;;
    esac
  done
  if [[ "${#kept[@]}" -eq 0 ]]; then
    echo "dev@dtcdev.click"
  else
    local IFS=','
    echo "${kept[*]}"
  fi
}

mkdir -p "$DIGEST_STATE_DIR"

MODE="${1:---send}"
case "$MODE" in
  --enqueue)
    shift
    src="${1:-monitor}"
    chk="${2:-check}"
    lvl="${3:-WARN}"
    msg="${4:-}"
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # One-line TSV: timestamp, host, source, check, level, summary
    clean_msg="$(printf '%s' "$msg" | tr '\t\r\n' '   ' | head -c 400)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$HOST_TAG" "$src" "$chk" "$lvl" "$clean_msg" >> "$DIGEST_QUEUE_FILE"
    exit 0
    ;;
  --dry-run|--send)
    ;;
  *)
    echo "usage: $0 [--enqueue <source> <check> <level> <summary> | --send | --dry-run]" >&2
    exit 2
    ;;
esac

if [[ ! -s "$DIGEST_QUEUE_FILE" ]]; then
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') OK ops-daily-digest: queue empty (0 items); nothing sent"
  exit 0
fi

SAFE_TO="$(sanitize_digest_recipients "$DIGEST_TO")"
TOTAL_LINES="$(wc -l < "$DIGEST_QUEUE_FILE" | tr -d ' ')"
SUBJECT="[ops-daily-digest] ${HOST_TAG}: ${TOTAL_LINES} informational/WARN/RECOVERED item(s) (24h)"

BODY="$(python3 - "$DIGEST_QUEUE_FILE" "$HOST_TAG" <<'PY'
import collections, pathlib, sys

qpath = pathlib.Path(sys.argv[1])
host = sys.argv[2]
rows = []
for raw in qpath.read_text(errors="replace").splitlines():
    if not raw.strip():
        continue
    parts = raw.split("\t", 5)
    while len(parts) < 6:
        parts.append("")
    rows.append(parts)

by_key = collections.OrderedDict()
for ts, h, src, chk, lvl, msg in rows:
    k = (src, chk, lvl)
    if k not in by_key:
        by_key[k] = {"count": 0, "first": ts, "last": ts, "sample": msg}
    by_key[k]["count"] += 1
    by_key[k]["last"] = ts
    by_key[k]["sample"] = msg

print(f"Daily ops digest for host {host} ({len(rows)} total event(s), {len(by_key)} distinct check/level pair(s)):")
print("Policy: WARN, handled DB errors, 24h fill predictions, AUTOHEALED, and RECOVERED events are")
print("aggregated here to dev@dtcdev.click only and never page alexey@.")
print("")
for (src, chk, lvl), info in by_key.items():
    print(f"- [{lvl}] {src} / {chk}: {info['count']}x (first={info['first']}, last={info['last']})")
    if info["sample"]:
        print(f"    last detail: {info['sample']}")
PY
)"

if [[ "$MODE" == "--dry-run" ]]; then
  echo "To: $SAFE_TO"
  echo "Subject: $SUBJECT"
  echo ""
  echo "$BODY"
  exit 0
fi

FROM_HEADER="${ALERT_FROM_NAME} <${ALERT_FROM}>"
IFS=',' read -r -a TO_ARGS <<< "$SAFE_TO"
SENT="no"

if command -v msmtp >/dev/null 2>&1; then
  if {
    echo "From: ${FROM_HEADER}"
    echo "To: ${SAFE_TO//,/, }"
    echo "Subject: ${SUBJECT}"
    echo ""
    printf '%s\n' "$BODY"
  } | msmtp -a "$ALERT_MSMTP_ACCOUNT" -f "$ALERT_FROM" -- "${TO_ARGS[@]}" 2>/dev/null; then
    SENT="msmtp"
  fi
elif command -v sendmail >/dev/null 2>&1; then
  if {
    echo "From: ${FROM_HEADER}"
    echo "To: ${SAFE_TO//,/, }"
    echo "Subject: ${SUBJECT}"
    echo ""
    printf '%s\n' "$BODY"
  } | sendmail -t -f "$ALERT_FROM" 2>/dev/null; then
    SENT="sendmail"
  fi
fi

if [[ "$SENT" == "no" ]]; then
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') WARN ops-daily-digest: delivery failed; retaining queue (${TOTAL_LINES} items)" >&2
  exit 1
fi

ARCHIVE_DIR="${DIGEST_STATE_DIR}/sent"
mkdir -p "$ARCHIVE_DIR"
mv "$DIGEST_QUEUE_FILE" "${ARCHIVE_DIR}/digest-$(date -u '+%Y%m%dT%H%M%SZ').tsv"
find "$ARCHIVE_DIR" -type f -name 'digest-*.tsv' -mtime +14 -delete 2>/dev/null || true
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') SENT ops-daily-digest via=${SENT} to=${SAFE_TO} items=${TOTAL_LINES}"
