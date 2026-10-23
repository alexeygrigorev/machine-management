#!/usr/bin/env bash
# Direct tests for backups/coolify-pg-replay.sh --mode pitr WAL handling.
#
# Covers the t1143u P1 AC: gzipped S3 archive segments are consumed (never
# silently skipped), explicit recovery targets are validated, and
# missing/corrupt/gapped WAL fails loudly. Docker-dependent stages use stub
# binaries on PATH; no production, no network, no real Postgres.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/backups/coolify-pg-replay.sh"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# ---- T1: syntax ----
if bash -n "$SCRIPT"; then pass "T1 bash -n replay"; else fail "T1 bash -n replay"; fi

# ---- stub binaries ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
# chown helper: succeed; real `docker run -d`: announce then fail so tests
# observe everything up to container start without needing a daemon.
if [[ "${1:-}" == "run" && "$*" == *"/bin/chown"* ]]; then exit 0; fi
if [[ "${1:-}" == "run" ]]; then echo "STUB-RUN-REACHED" >&2; exit 1; fi
exit 0
EOF
for b in psql pg_restore pg_isready aws tar gzip; do
  # real tar/gzip stay on PATH (needed to build fixtures); stub only the rest
  case "$b" in tar|gzip) continue;; esac
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$b"
  chmod +x "$TMP/bin/$b"
done
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# ---- fixture: minimal base tar with backup_label (START seg ...026) + pg_wal tar ----
mkbase() { # $1=dir -> prints "base pgwal"
  local d="$1"
  local pd="$d/pgdata"
  mkdir -p "$pd/pg_wal"
  printf 'START WAL LOCATION: 0/26000028 (file 000000010000000000000026)\nCHECKPOINT LOCATION: 0/26000028\n' > "$pd/backup_label"
  printf 'V1' > "$pd/PG_VERSION"
  tar -czf "$d/base.tar.gz" -C "$pd" backup_label PG_VERSION
  (cd "$pd/pg_wal" && printf 'x%.0s' $(seq 1 100) > 000000010000000000000026 && tar -czf "$d/pgwal.tar.gz" 000000010000000000000026)
  printf '%s %s' "$d/base.tar.gz" "$d/pgwal.tar.gz"
}
mkwal() { # $1=waldir $2...=suffixes (last-8-hex) -> gzipped segments
  local wd="$1"; shift; mkdir -p "$wd"
  local s
  for s in "$@"; do
    printf 'wal-%s' "$s" | gzip -c > "$wd/0000000100000000$s.gz"
  done
}

run_replay() { # args... -> runs script, prints output, returns rc
  "$SCRIPT" --mode pitr --stack t --db-user pgadmin --db t "$@" 2>&1 || true
}

# ---- T2: bad recovery targets rejected ----
if run_replay --base /nope --recovery-target 'not-a-target' | grep -q 'must be'; then
  pass "T2a garbage target rejected"
else fail "T2a garbage target rejected"; fi
if run_replay --base /nope --recovery-target '2026-13-99 99:99' | grep -q 'not a parseable timestamp'; then
  pass "T2b impossible timestamp rejected"
else fail "T2b impossible timestamp rejected"; fi
if run_replay --base /nope --recovery-target-action explode | grep -q 'must be promote|pause|shutdown'; then
  pass "T2c bad action rejected"
else fail "T2c bad action rejected"; fi

# ---- T3: unknown / corrupt WAL files fail loudly ----
D3="$TMP/t3"; read -r BASE3 PGW3 <<< "$(mkbase "$D3")"
mkdir -p "$D3/wal"; mkwal "$D3/wal" 00000026 00000027
echo junk > "$D3/wal/notes.txt"
if run_replay --base "$BASE3" --base-wal "$PGW3" --wal-dir "$D3/wal" | grep -q 'unexpected name'; then
  pass "T3a unknown file fails loudly"
else fail "T3a unknown file fails loudly"; fi
rm "$D3/wal/notes.txt"
printf 'not-gzip-at-all' > "$D3/wal/000000010000000000000028.gz"
if run_replay --base "$BASE3" --base-wal "$PGW3" --wal-dir "$D3/wal" | grep -q 'CORRUPT'; then
  pass "T3b corrupt .gz fails loudly"
else fail "T3b corrupt .gz fails loudly"; fi

# ---- T4: gapped chain fails loudly; missing leading segment fails ----
D4="$TMP/t4"; read -r BASE4 PGW4 <<< "$(mkbase "$D4")"
mkdir -p "$D4/wal"; mkwal "$D4/wal" 00000026 00000028
if run_replay --base "$BASE4" --base-wal "$PGW4" --wal-dir "$D4/wal" | grep -q 'WAL GAP'; then
  pass "T4a gapped chain fails loudly"
else fail "T4a gapped chain fails loudly"; fi
D4b="$TMP/t4b"; read -r BASE4B PGW4B <<< "$(mkbase "$D4b")"
mkdir -p "$D4b/wal"; mkwal "$D4b/wal" 00000027 00000028
if run_replay --base "$BASE4B" --base-wal "$PGW4B" --wal-dir "$D4b/wal" | grep -q 'WAL GAP'; then
  pass "T4b missing leading segment fails loudly"
else fail "T4b missing leading segment fails loudly"; fi

# ---- T5: continuous .gz chain + time target stages, reaches container start ----
D5="$TMP/t5"; read -r BASE5 PGW5 <<< "$(mkbase "$D5")"
mkdir -p "$D5/wal"; mkwal "$D5/wal" 00000026 00000027 00000028
OUT="$(run_replay --base "$BASE5" --base-wal "$PGW5" --wal-dir "$D5/wal" \
  --recovery-target '2026-10-23 12:00:00+00' || true)"
if printf '%s' "$OUT" | grep -q 'recovery target: kind=time'; then
  pass "T5a time target accepted+validated"
else fail "T5a time target accepted+validated"; fi
if printf '%s' "$OUT" | grep -q 'WAL chain continuous: 000000010000000000000026 .. 000000010000000000000028'; then
  pass "T5b gz chain gunzipped+continuous"
else fail "T5b gz chain gunzipped+continuous"; fi
if printf '%s' "$OUT" | grep -q 'STUB-RUN-REACHED'; then
  pass "T5c staging complete, container start attempted"
else fail "T5c staging complete, container start attempted"; fi

# ---- T6: lsn/xid targets accepted; empty wal-dir fails ----
OUT6="$(run_replay --base "$BASE5" --base-wal "$PGW5" --wal-dir "$D5/wal" \
  --recovery-target '0/28000060' || true)"
if printf '%s' "$OUT6" | grep -q 'recovery target: kind=lsn'; then
  pass "T6a lsn target accepted"
else fail "T6a lsn target accepted"; fi
OUT6b="$(run_replay --base "$BASE5" --base-wal "$PGW5" --wal-dir "$D5/wal" \
  --recovery-target '12345678' || true)"
if printf '%s' "$OUT6b" | grep -q 'recovery target: kind=xid'; then
  pass "T6b xid target accepted"
else fail "T6b xid target accepted"; fi
mkdir -p "$D5/emptywal"
if run_replay --base "$BASE5" --base-wal "$PGW5" --wal-dir "$D5/emptywal" | grep -q 'zero usable WAL segments'; then
  pass "T6c empty wal-dir fails loudly"
else fail "T6c empty wal-dir fails loudly"; fi

# ---- T7: .backup label artifacts accepted, unknowns still rejected ----
D7="$TMP/t7"; read -r BASE7 PGW7 <<< "$(mkbase "$D7")"
mkdir -p "$D7/wal"; mkwal "$D7/wal" 00000026 00000027
printf 'label' | gzip -c > "$D7/wal/000000010000000000000026.backup.gz"
OUT7="$(run_replay --base "$BASE7" --base-wal "$PGW7" --wal-dir "$D7/wal" || true)"
if printf '%s' "$OUT7" | grep -q 'staged 3 WAL file(s)'; then
  pass "T7a .backup.gz staged, not skipped"
else fail "T7a .backup.gz staged, not skipped"; fi
if printf '%s' "$OUT7" | grep -q 'WAL chain continuous: 000000010000000000000026 .. 000000010000000000000027'; then
  pass "T7b chain check ignores .backup file"
else fail "T7b chain check ignores .backup file"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAILN"
[[ "$FAILN" -eq 0 ]]
