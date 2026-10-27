#!/usr/bin/env bash
# DR escrow restore drill: decrypt CP and acme bundles with context-bound
# DataOps team store values. Secret values travel through stdout redirection
# into owner-only ephemeral passphrase files and are never logged.
# Usage: dr-escrow-restore-drill.sh --cp-bundle <tar.gz.gpg> --acme-bundle <json.gpg>
#   [--region eu-west-1]
#   [--cp-secret dr-escrow.coolify-cp-backup-gpg-passphrase]
#   [--acme-secret dr-escrow.acme-backup-gpg-passphrase]
# Exit 0 + DRILL_OK only if both bundles decrypt and verify.
set -euo pipefail

# Private material: everything this script creates lands 600 regardless of umask.
umask 077

CP_BUNDLE=""; ACME_BUNDLE=""
REGION="${DR_ESCROW_REGION:-eu-west-1}"
CP_SECRET="${DR_ESCROW_CP_SECRET:-dr-escrow.coolify-cp-backup-gpg-passphrase}"
ACME_SECRET="${DR_ESCROW_ACME_SECRET:-dr-escrow.acme-backup-gpg-passphrase}"
PYTHON="${DR_ESCROW_PYTHON:-python3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cp-bundle) CP_BUNDLE="${2:-}"; [[ -n "$CP_BUNDLE" ]] || { echo "missing value for --cp-bundle" >&2; exit 2; }; shift 2;;
    --acme-bundle) ACME_BUNDLE="${2:-}"; [[ -n "$ACME_BUNDLE" ]] || { echo "missing value for --acme-bundle" >&2; exit 2; }; shift 2;;
    --region) REGION="${2:-}"; [[ -n "$REGION" ]] || { echo "missing value for --region" >&2; exit 2; }; shift 2;;
    --cp-secret) CP_SECRET="${2:-}"; [[ -n "$CP_SECRET" ]] || { echo "missing value for --cp-secret" >&2; exit 2; }; shift 2;;
    --acme-secret) ACME_SECRET="${2:-}"; [[ -n "$ACME_SECRET" ]] || { echo "missing value for --acme-secret" >&2; exit 2; }; shift 2;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2;;
  esac
done
[[ -n "$CP_BUNDLE" ]] || { echo "missing --cp-bundle" >&2; exit 2; }
[[ -n "$ACME_BUNDLE" ]] || { echo "missing --acme-bundle" >&2; exit 2; }
[[ -f "$CP_BUNDLE" ]] || { echo "CP bundle not found: $CP_BUNDLE" >&2; exit 2; }
[[ -f "$ACME_BUNDLE" ]] || { echo "acme bundle not found: $ACME_BUNDLE" >&2; exit 2; }

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
T0="$(date +%s)"

command -v gpg >/dev/null 2>&1 || fail "missing required binary: gpg"
command -v tar >/dev/null 2>&1 || fail "missing required binary: tar"
command -v "$PYTHON" >/dev/null 2>&1 || fail "missing required Python interpreter"

WORKDIR="$(mktemp -d /tmp/dr-escrow-drill-XXXXXX)"
chmod 700 "$WORKDIR"
cleanup() {
  find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || rm -rf "$WORKDIR"
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# Values never touch argv, logs, reports or persistent files.
resolve_pass() {
  local label="$1" name="$2" dest="$WORKDIR/$1.pass"
  "$PYTHON" "$SCRIPT_DIR/team-secret-value.py" "$name" --region "$REGION" \
    >"$dest" 2>"$WORKDIR/${label}.reader.err" || fail "$label: team store read failed"
  chmod 600 "$dest"
  [[ -s "$dest" ]] || fail "$label: team store returned an empty value"
  log "$label passphrase source: team-store:$name (region $REGION)" >&2
  printf '%s' "$dest"
}
CP_PASS="$(resolve_pass cp "$CP_SECRET")"
ACME_PASS="$(resolve_pass acme "$ACME_SECRET")"

# ---- CP bundle: decrypt + verify filenames only ----
log "cp decrypt start: $CP_BUNDLE"
if gpg --batch --yes --pinentry-mode loopback --passphrase-file "$CP_PASS" \
    -o "$WORKDIR/cp-bundle.tar.gz" -d "$CP_BUNDLE" 2>"$WORKDIR/cp-gpg.err"; then
  CP_SIZE="$(stat -c%s "$CP_BUNDLE" 2>/dev/null || stat -f%z "$CP_BUNDLE")"
  CP_LIST="$(tar tzf "$WORKDIR/cp-bundle.tar.gz" 2>"$WORKDIR/cp-tar.err")" \
    || fail "cp bundle tar list failed: $(tail -1 "$WORKDIR/cp-tar.err")"
  echo "$CP_LIST" | grep -q '^coolify\.env$' || fail "cp bundle missing: coolify.env"
  echo "$CP_LIST" | grep -q '^ssh-keys/' || fail "cp bundle missing: ssh-keys/"
  CP_ENTRIES="$(echo "$CP_LIST" | wc -l | tr -d ' ')"
  log "cp bundle ok: size=${CP_SIZE}B entries=${CP_ENTRIES} (coolify.env + ssh-keys/ present)"
else
  fail "cp bundle gpg decrypt failed: $(tail -1 "$WORKDIR/cp-gpg.err")"
fi

# ---- acme bundle: decrypt + verify JSON envelope (counts only) ----
log "acme decrypt start: $ACME_BUNDLE"
if gpg --batch --yes --pinentry-mode loopback --passphrase-file "$ACME_PASS" \
    -o "$WORKDIR/acme.json" -d "$ACME_BUNDLE" 2>"$WORKDIR/acme-gpg.err"; then
  ACME_SIZE="$(stat -c%s "$ACME_BUNDLE" 2>/dev/null || stat -f%z "$ACME_BUNDLE")"
  chmod 600 "$WORKDIR/acme.json"
  CERTS="$(python3 - "$WORKDIR/acme.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
le = d.get("letsencrypt")
if not isinstance(le, dict):
    raise SystemExit("missing letsencrypt block")
print(len(le.get("Certificates", [])))
PYEOF
)" || fail "acme bundle JSON verification failed (no letsencrypt block)"
  log "acme bundle ok: size=${ACME_SIZE}B certificates=${CERTS} (letsencrypt block present)"
else
  fail "acme bundle gpg decrypt failed: $(tail -1 "$WORKDIR/acme-gpg.err")"
fi

TOTAL="$(($(date +%s)-T0))"
log "DRILL_OK cp+acme total=${TOTAL}s"
