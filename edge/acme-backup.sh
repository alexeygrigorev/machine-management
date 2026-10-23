#!/usr/bin/env bash
# Fetch + GPG-encrypt Traefik acme.json (LE private keys) from both Contabo
# hosts into off-host Storagebox (t1143u rewrite).
#
# Run from the OPERATOR box (Hetzner) — never on Contabo. Normally invoked by
# backups/storagebox-sync.sh (daily cron); safe to run manually.
#
# - Plaintext keys only ever exist as a short-lived 600 mktemp file during
#   verification (decrypt roundtrip checks the JSON envelope contains the
#   letsencrypt block — proves the copy is actually restorable), deleted
#   immediately after; the stored artifact is GPG only.
# - Output: $STORAGEBOX_ROOT/edge-tls/YYYY/MM/DD/acme-<host>-<STAMP>.json.gpg,
#   mode 600. GPG symmetric AES256; passphrase file $ACME_GPG_PASS_FILE
#   (default ~/.secrets/acme-backup-gpg.pass, must be 600 — fail closed if
#   missing; the operator creates it once with e.g.
#   `openssl rand -base64 48 | tr -d '\n' > ~/.secrets/acme-backup-gpg.pass`
#   and escrows it offline in the Drive credentials doc).
# - Each .gpg is verified by a decrypt roundtrip into a 600 temp file
#   (checks the JSON envelope contains the letsencrypt account block —
#   proves the copy is actually restorable, not just non-empty).
# - Pruning: backups/prune-storagebox.sh (edge-tls area, same 30d keep).
#
# No secrets in git: paths only, no passphrases or keys.
set -euo pipefail

# Private TLS keys: created files land 600 regardless of caller umask.
umask 077

STORAGEBOX_ROOT="${STORAGEBOX_ROOT:-$HOME/storagebox/backups}"
REMOTE_PATH="${REMOTE_PATH:-/data/coolify/proxy/acme.json}"
ACME_GPG_PASS_FILE="${ACME_GPG_PASS_FILE:-$HOME/.secrets/acme-backup-gpg.pass}"
STAMP="$(TZ=Europe/Berlin date '+%Y%m%dT%H%M%z')"
DAY_PATH="$(TZ=Europe/Berlin date '+%Y/%m/%d')"
HOSTS="${HOSTS:-contabo-a contabo-b}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

command -v gpg >/dev/null 2>&1 || fail "gpg missing on operator box (apt install gnupg)"
[[ -f "$ACME_GPG_PASS_FILE" ]] || fail "GPG passphrase file missing: $ACME_GPG_PASS_FILE (create once, 600, escrow offline — see header)"
[[ "$(stat -c%a "$ACME_GPG_PASS_FILE")" == "600" ]] || fail "refusing: $ACME_GPG_PASS_FILE is not mode 600"
[[ -d "$STORAGEBOX_ROOT" ]] || fail "missing Storagebox mount: $STORAGEBOX_ROOT"

OUTDIR="$STORAGEBOX_ROOT/edge-tls/$DAY_PATH"
mkdir -p "$OUTDIR"

FAILED=0
for H in $HOSTS; do
  OUT="$OUTDIR/acme-${H}-${STAMP}.json.gpg"
  log "fetch+encrypt ${H}:${REMOTE_PATH}"
  if ssh -o BatchMode=yes -o ConnectTimeout=15 "$H" "sudo cat $REMOTE_PATH" 2>/dev/null \
      | gpg --batch --yes --pinentry-mode loopback \
            --passphrase-file "$ACME_GPG_PASS_FILE" \
            --symmetric --cipher-algo AES256 -o "$OUT"; then
    chmod 600 "$OUT"
    size="$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")"
    if [[ "$size" -gt 1024 ]]; then
      CHECK_TMP="$(mktemp /tmp/acme-verify-XXXXXX)"
      if gpg --batch --yes --pinentry-mode loopback \
          --passphrase-file "$ACME_GPG_PASS_FILE" -o "$CHECK_TMP" -d "$OUT" 2>/dev/null \
          && grep -q '"letsencrypt"' "$CHECK_TMP"; then
        log "acme ok host=${H} size=${size}B out=${OUT}"
        rm -f "$CHECK_TMP"
      else
        log "ERROR: acme verification failed host=${H} (size=${size}B)"
        rm -f "$CHECK_TMP" "$OUT"
        FAILED=1
      fi
    else
      log "ERROR: acme verification failed host=${H} (size=${size}B)"
      rm -f "$OUT"
      FAILED=1
    fi
  else
    log "ERROR: fetch or encrypt failed host=${H}"
    rm -f "$OUT"
    FAILED=1
  fi
done

chmod 700 "$STORAGEBOX_ROOT/edge-tls" 2>/dev/null || true

[[ "$FAILED" -eq 0 ]] || fail "one or more hosts failed"
log "ALL_DONE edge-tls"
