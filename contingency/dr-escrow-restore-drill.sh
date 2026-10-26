#!/usr/bin/env bash
# DR escrow restore drill: decrypt one Coolify CP bundle + one acme bundle
# using the passphrase from the SANDBOX SSM escrow copy (t1468u decision).
#
# Default passphrase source is AWS SSM Parameter Store (SANDBOX account
# 817685572750, eu-west-1):
#   /dr-escrow/coolify-cp-backup-gpg-passphrase  (SecureString)
#   /dr-escrow/acme-backup-gpg-passphrase        (SecureString)
# fetched with --with-decryption into a 600 temp file that is shredded
# after use. The Hetzner operator file is NOT read unless the caller
# passes --cp-pass-file / --acme-pass-file explicitly (Hetzner-copy test).
#
# Verifies only (never prints secrets — names, counts, sizes, timings):
#   CP bundle:   gpg decrypt -> tar tz lists coolify.env + ssh-keys/
#   acme bundle: gpg decrypt -> JSON contains the letsencrypt block
#
# Usage:
#   dr-escrow-restore-drill.sh --cp-bundle <file.tar.gz.gpg> --acme-bundle <file.json.gpg>
#     [--region eu-west-1]
#     [--cp-param /dr-escrow/coolify-cp-backup-gpg-passphrase]
#     [--acme-param /dr-escrow/acme-backup-gpg-passphrase]
#     [--cp-pass-file ~/tmp/secrets/coolify-cp-backup.pass]       # Hetzner-copy test only
#     [--acme-pass-file ~/.secrets/acme-backup-gpg.pass]          # Hetzner-copy test only
#
# Exit 0 + DRILL_OK only if BOTH bundles decrypt and verify.
set -euo pipefail

# Private material: everything this script creates lands 600 regardless of umask.
umask 077

CP_BUNDLE=""; ACME_BUNDLE=""
REGION="${DR_ESCROW_REGION:-eu-west-1}"
CP_PARAM="${DR_ESCROW_CP_PARAM:-/dr-escrow/coolify-cp-backup-gpg-passphrase}"
ACME_PARAM="${DR_ESCROW_ACME_PARAM:-/dr-escrow/acme-backup-gpg-passphrase}"
CP_PASS_FILE=""; ACME_PASS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cp-bundle) CP_BUNDLE="${2:-}"; [[ -n "$CP_BUNDLE" ]] || { echo "missing value for --cp-bundle" >&2; exit 2; }; shift 2;;
    --acme-bundle) ACME_BUNDLE="${2:-}"; [[ -n "$ACME_BUNDLE" ]] || { echo "missing value for --acme-bundle" >&2; exit 2; }; shift 2;;
    --region) REGION="${2:-}"; [[ -n "$REGION" ]] || { echo "missing value for --region" >&2; exit 2; }; shift 2;;
    --cp-param) CP_PARAM="${2:-}"; [[ -n "$CP_PARAM" ]] || { echo "missing value for --cp-param" >&2; exit 2; }; shift 2;;
    --acme-param) ACME_PARAM="${2:-}"; [[ -n "$ACME_PARAM" ]] || { echo "missing value for --acme-param" >&2; exit 2; }; shift 2;;
    --cp-pass-file) CP_PASS_FILE="${2:-}"; [[ -n "$CP_PASS_FILE" ]] || { echo "missing value for --cp-pass-file" >&2; exit 2; }; shift 2;;
    --acme-pass-file) ACME_PASS_FILE="${2:-}"; [[ -n "$ACME_PASS_FILE" ]] || { echo "missing value for --acme-pass-file" >&2; exit 2; }; shift 2;;
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
command -v python3 >/dev/null 2>&1 || fail "missing required binary: python3"
if [[ -z "$CP_PASS_FILE" || -z "$ACME_PASS_FILE" ]]; then
  command -v aws >/dev/null 2>&1 || fail "missing required binary: aws (SSM escrow mode)"
fi

WORKDIR="$(mktemp -d /tmp/dr-escrow-drill-XXXXXX)"
chmod 700 "$WORKDIR"
cleanup() {
  find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || rm -rf "$WORKDIR"
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# Resolve a passphrase to a 600 file: explicit file (Hetzner test) or SSM escrow.
# Prints the path; the VALUE never touches argv, logs or reports.
resolve_pass() { # $1 = label, $2 = file-override, $3 = ssm-param-name
  local label="$1" file="$2" param="$3"
  local dest="$WORKDIR/${label}.pass"
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || fail "$label: pass file missing: $file"
    cp -a "$file" "$dest"; chmod 600 "$dest"
    log "$label passphrase source: file (Hetzner-copy test)" >&2
  else
    aws ssm get-parameter --name "$param" --with-decryption \
      --region "$REGION" --query "Parameter.Value" --output text >"$dest" 2>"$WORKDIR/${label}.ssm.err" \
      || fail "$label: SSM fetch failed ($param): $(tail -1 "$WORKDIR/${label}.ssm.err")"
    chmod 600 "$dest"
    [[ -s "$dest" ]] || fail "$label: SSM returned empty value ($param)"
    log "$label passphrase source: ssm:$param (region $REGION)" >&2
  fi
  printf '%s' "$dest"
}

CP_PASS="$(resolve_pass cp "$CP_PASS_FILE" "$CP_PARAM")"
ACME_PASS="$(resolve_pass acme "$ACME_PASS_FILE" "$ACME_PARAM")"

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
