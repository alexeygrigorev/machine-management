#!/usr/bin/env bash
# Direct tests for backups/coolify-pg-replay.sh --mode pitr WAL handling.
#
# Covers the t1143u P1 AC: gzipped S3 archive segments are consumed (never
# silently skipped), explicit recovery targets are validated, and
# missing/corrupt/gapped WAL fails loudly — within one PostgreSQL log and
# across a log boundary. Docker-dependent stages use stub binaries on PATH
# (the stub `docker` answers the script's read-only `pg_controldata` probe
# with the PG default 16MB segment size); no production, no network, no real
# Postgres.
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
# Read-only pg_controldata probe (WAL segment size for the chain check):
# answer like a real PG16 cluster, or fail on demand. chown helper: succeed.
# Real `docker run -d`: announce then fail so tests observe everything up to
# container start without needing a daemon. Any other `run` is unhandled —
# fail loudly rather than masquerade as a container start.
if [[ "${1:-}" == "run" && "$*" == *"pg_controldata"* ]]; then
  [[ -z "${STUB_PG_CONTROLDATA_FAIL:-}" ]] || exit 1
  printf 'pg_control version number:            1300\n'
  printf 'Bytes per WAL segment:                16777216\n'
  exit 0
fi
if [[ "${1:-}" == "run" && "$*" == *"/bin/chown"* ]]; then exit 0; fi
if [[ "${1:-}" == "run" && " $* " == *" -d "* ]]; then echo "STUB-RUN-REACHED" >&2; exit 1; fi
if [[ "${1:-}" == "run" ]]; then echo "STUB-DOCKER-UNHANDLED" >&2; exit 1; fi
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
mkbase() { # $1=dir [$2=START segment, default ...026] -> prints "base pgwal"
  local d="$1" start="${2:-000000010000000000000026}"
  local pd="$d/pgdata"
  mkdir -p "$pd/pg_wal"
  printf 'START WAL LOCATION: 0/26000028 (file %s)\nCHECKPOINT LOCATION: 0/26000028\n' "$start" > "$pd/backup_label"
  printf 'V1' > "$pd/PG_VERSION"
  tar -czf "$d/base.tar.gz" -C "$pd" backup_label PG_VERSION
  (cd "$pd/pg_wal" && printf 'x%.0s' $(seq 1 100) > "$start" && tar -czf "$d/pgwal.tar.gz" "$start")
  printf '%s %s' "$d/base.tar.gz" "$d/pgwal.tar.gz"
}
mkwal() { # $1=waldir $2...=suffixes (last-8-hex) -> gzipped segments
  local wd="$1"; shift; mkdir -p "$wd"
  local s
  for s in "$@"; do
    printf 'wal-%s' "$s" | gzip -c > "$wd/0000000100000000$s.gz"
  done
}
mkfull() { # $1=waldir $2...=full 24-hex segment names -> gzipped segments
  local wd="$1"; shift; mkdir -p "$wd"
  local s
  for s in "$@"; do
    printf 'wal-%s' "$s" | gzip -c > "$wd/$s.gz"
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
printf 'label' | gzip -c > "$D7/wal/000000010000000000000026.00000028.backup.gz"
printf 'label' > "$D7/wal/000000010000000000000027.00000028.backup"
OUT7="$(run_replay --base "$BASE7" --base-wal "$PGW7" --wal-dir "$D7/wal" || true)"
if printf '%s' "$OUT7" | grep -q 'staged 4 WAL file(s)'; then
  pass "T7a .backup.gz staged, not skipped"
else fail "T7a .backup.gz staged, not skipped"; fi
if printf '%s' "$OUT7" | grep -q 'WAL chain continuous: 000000010000000000000026 .. 000000010000000000000027'; then
  pass "T7b chain check ignores .backup file"
else fail "T7b chain check ignores .backup file"; fi

# ---- T8: pre-base segments tolerated, missing START still fails ----
D8="$TMP/t8"; read -r BASE8 PGW8 <<< "$(mkbase "$D8")"
mkdir -p "$D8/wal"; mkwal "$D8/wal" 00000024 00000025 00000026 00000027
OUT8="$(run_replay --base "$BASE8" --base-wal "$PGW8" --wal-dir "$D8/wal" || true)"
if printf '%s' "$OUT8" | grep -q 'WAL chain continuous: 000000010000000000000026 .. 000000010000000000000027'; then
  pass "T8a older leading segments skipped, chain verified from START"
else fail "T8a older leading segments skipped, chain verified from START"; fi
D8b="$TMP/t8b"; read -r BASE8B PGW8B <<< "$(mkbase "$D8b")"
mkdir -p "$D8b/wal"; mkwal "$D8b/wal" 00000024 00000025
if run_replay --base "$BASE8B" --base-wal "$PGW8B" --wal-dir "$D8b/wal" | grep -q 'START segment .* not present'; then
  pass "T8b START nowhere in chain fails loudly"
else fail "T8b START nowhere in chain fails loudly"; fi

# ---- T9: the same guarantees across a PostgreSQL log boundary ----
# The script derives segments-per-log from pg_control (stub: 16MB => 256 per
# log), so log 0001 index FF is followed by log 0002 index 00 — not "FF+1".
B9="$TMP/t9"; read -r BASE9 PGW9 <<< "$(mkbase "$B9" 0000000100000001000000FF)"
D9="$TMP/t9a"; mkfull "$D9" 0000000100000001000000FF 000000010000000200000000 000000010000000200000001
if run_replay --base "$BASE9" --base-wal "$PGW9" --wal-dir "$D9" | grep -q 'WAL chain continuous: 0000000100000001000000FF .. 000000010000000200000001'; then
  pass "T9a gz chain continuous across log boundary"
else fail "T9a gz chain continuous across log boundary"; fi
D9b="$TMP/t9b"; mkfull "$D9b" 0000000100000001000000FF 000000010000000200000001
if run_replay --base "$BASE9" --base-wal "$PGW9" --wal-dir "$D9b" | grep -q 'WAL GAP: after 0000000100000001000000FF expected 000000010000000200000000 but chain has 000000010000000200000001'; then
  pass "T9b gap across log boundary fails loudly"
else fail "T9b gap across log boundary fails loudly"; fi
D9c="$TMP/t9c"; mkfull "$D9c" 000000010000000200000000 000000010000000200000001
if run_replay --base "$BASE9" --base-wal "$PGW9" --wal-dir "$D9c" | grep -q 'WAL GAP: staged chain starts at 000000010000000200000000 but base needs 0000000100000001000000FF'; then
  pass "T9c START (last of previous log) missing fails loudly"
else fail "T9c START (last of previous log) missing fails loudly"; fi
D9d="$TMP/t9d"; mkfull "$D9d" 0000000100000001000000FE 0000000100000001000000FF 000000010000000200000000
printf 'label' | gzip -c > "$D9d/0000000100000001000000FF.00000002.backup.gz"
OUT9="$(run_replay --base "$BASE9" --base-wal "$PGW9" --wal-dir "$D9d" || true)"
if printf '%s' "$OUT9" | grep -q 'staged 4 WAL file(s)' && \
   printf '%s' "$OUT9" | grep -q 'WAL chain continuous: 0000000100000001000000FF .. 000000010000000200000000'; then
  pass "T9d older leading segment + .backup skipped across log boundary"
else fail "T9d older leading segment + .backup skipped across log boundary"; fi

# ---- T10: unreadable pg_control must not skip the chain check ----
# The segment size is what makes the boundary arithmetic exact; without it
# even a continuous chain (D9) is refused before any container start.
OUT10="$(STUB_PG_CONTROLDATA_FAIL=1 run_replay --base "$BASE9" --base-wal "$PGW9" --wal-dir "$D9" || true)"
if printf '%s' "$OUT10" | grep -q 'cannot read WAL segment size from pg_control' && \
   ! printf '%s' "$OUT10" | grep -q -e 'WAL chain continuous' -e 'STUB-RUN-REACHED'; then
  pass "T10 unreadable pg_control fails loudly before chain check/container start"
else fail "T10 unreadable pg_control fails loudly before chain check/container start"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAILN"
[[ "$FAILN" -eq 0 ]]
