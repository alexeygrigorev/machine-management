#!/usr/bin/env bash
# Regression test: 2026-10-22 pg-relay healthcheck FAIL
#   SELECT 1 failed for relay via container mqimefrti7ratmaliirnikov (rc=2):
#   psql: FATAL: role "postgres" does not exist
#
# Root cause: Coolify standalone-postgresql creates only POSTGRES_USER
# (pgadmin) — no `postgres` role. The script used to default to
# PGUSER_*=postgres / PG_RELAY_DB=postgres, so any run without the fixed
# env failed exactly like the alert.
#
# Runs the real script with stub docker/curl on PATH (no DB needed).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/coolify-healthcheck.sh"
DUMP="$REPO/backups/coolify-pg-dump.sh"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# ---- T1: syntax ----
if bash -n "$SCRIPT" && bash -n "$DUMP"; then pass "T1 bash -n (healthcheck + pg-dump)"; else fail "T1 bash -n"; fi

# ---- T2: safe defaults in repo ----
check_grep() { # $1=file $2=pattern $3=label
  if grep -qF "$2" "$1"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}
check_grep "$SCRIPT" 'PGUSER_RELAY="${PGUSER_RELAY:-pgadmin}"' "T2a relay user default is pgadmin"
check_grep "$SCRIPT" 'PGUSER_SHARED="${PGUSER_SHARED:-pgadmin}"' "T2b shared user default is pgadmin"
check_grep "$SCRIPT" 'PG_RELAY_DB="${PG_RELAY_DB:-relay}"' "T2c relay db default is relay"
check_grep "$SCRIPT" 'coolify.resourceName' "T2d container auto-discovery via Coolify label"
check_grep "$SCRIPT" 'does not exist' "T2e role-missing hint present"
check_grep "$DUMP" 'PGUSER_RELAY="${PGUSER_RELAY:-pgadmin}"' "T2f pg-dump relay user default is pgadmin"

# ---- stub binaries ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin" "$TMP/state"
cat > "$TMP/stubbin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: pg_isready always accepting (mirrors incident: pg_isready was
# green, SELECT 1 red); psql succeeds only for -U pgadmin, else the exact
# 2026-10-22 error with rc=2.
if [[ "${1:-}" == "ps" ]]; then
  for a in "$@"; do
    case "$a" in
      *pg-relay*) echo "fake-relay-uuid"; exit 0;;
      *pg-shared*) echo "fake-shared-uuid"; exit 0;;
    esac
  done
  exit 0
fi
[[ "${1:-}" == "exec" ]] || { echo "stub docker: unsupported: $*" >&2; exit 99; }
shift; _container="$1"; shift; _cmd="$1"; shift
_user=""; _db=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -U) _user="$2"; shift 2;;
    -d) _db="$2"; shift 2;;
    *) shift;;
  esac
done
if [[ "$_cmd" == "pg_isready" ]]; then
  echo "${_container}:5432 - accepting connections"
  exit 0
fi
if [[ "$_cmd" == "psql" ]]; then
  if [[ "$_user" != "pgadmin" ]]; then
    echo "psql: error: connection to server on socket \"/var/run/postgresql/.s.PGSQL.5432\" failed: FATAL:  role \"${_user}\" does not exist" >&2
    exit 2
  fi
  echo "1"
  exit 0
fi
echo "stub docker: unsupported cmd: $_cmd" >&2; exit 99
EOF
cat > "$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
echo "200"; exit 0
EOF
chmod +x "$TMP/stubbin/docker" "$TMP/stubbin/curl"

run_check() { # $1=envfile -> prints output, returns script rc
  local envf="$1" statedir
  statedir="$(mktemp -d -p "$TMP")"
  COOLIFY_HEALTHCHECK_ENV_FILE="$envf" \
  STATE_DIR="$statedir" \
  LOCK_FILE="$TMP/lock-$RANDOM" \
  APP_URLS="" \
  LATENCY_PROBES="" \
  LATENCY_PUSH_ENABLED=0 \
  SKIP_DISK_CHECK=1 \
  SKIP_BACKUP_CHECKS=1 \
  SKIP_CREATED_CHECK=1 \
  CHECK_CMP_CALLBACKS=0 \
  PATH="$TMP/stubbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}

# ---- T3: incident repro — stale PGUSER_RELAY=postgres must FAIL like the alert ----
printf '%s\n' 'SKIP_PG_SHARED=1' 'PG_RELAY_CONTAINER=fake-relay-uuid' \
  'PGUSER_RELAY=postgres' 'PG_RELAY_DB=postgres' 'ALERT_TO=test@example.com' > "$TMP/env-stale"
out=""; set +e; out="$(run_check "$TMP/env-stale")"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'role "postgres" does not exist'* && "$out" == *'HINT'* ]]; then
  pass "T3 stale postgres user FAILs with alert error + hint (rc=$rc)"
else
  fail "T3 incident repro (rc=$rc) -- $out"
fi

# ---- T4: fixed defaults + label auto-discovery — empty env must go green ----
: > "$TMP/env-empty"
out=""; set +e; out="$(run_check "$TMP/env-empty")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'ALL_OK'* && "$out" == *'OK check=pg-relay'* ]]; then
  pass "T4 empty env green via pgadmin defaults + auto-discovery"
else
  fail "T4 empty env (rc=$rc) -- $out"
fi

# ---- T5: explicit contabo-b-style env stays green ----
printf '%s\n' 'PG_SHARED_CONTAINER=fake-shared-uuid' 'PGUSER_SHARED=pgadmin' 'PG_SHARED_DB=postgres' \
  'PG_RELAY_CONTAINER=fake-relay-uuid' 'PGUSER_RELAY=pgadmin' 'PG_RELAY_DB=relay' > "$TMP/env-good"
out=""; set +e; out="$(run_check "$TMP/env-good")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'ALL_OK'* ]]; then
  pass "T5 explicit pgadmin/relay env green"
else
  fail "T5 explicit env (rc=$rc) -- $out"
fi

# ---- T6-T9: content-marker checks (t1037u: not status-only) ----
mkdir -p "$TMP/cbin"
cat > "$TMP/cbin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl for content checks: honors -o <file> and always prints the
# canned HTTP code on stdout. Body selected by URL substring:
#   *good*  -> 200 + body containing the marker (mixed case + whitespace)
#   *wrong* -> 200 + proxy-default body WITHOUT the marker
#   *empty* -> 200 + empty body
#   *fivehundred* -> 500
#   *down*  -> curl rc=7 (connect failed)
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -w) shift 2;;
    --connect-timeout|--max-time) shift 2;;
    -*) shift;;
    *) url="$1"; shift;;
  esac
done
case "$url" in
  *good*) printf '  { "STATUS": "OK" }  ' > "$out"; echo "200"; exit 0;;
  *wrong*) printf '<html>proxy default backend page</html>' > "$out"; echo "200"; exit 0;;
  *empty*) : > "$out"; echo "200"; exit 0;;
  *fivehundred*) printf 'error' > "$out"; echo "500"; exit 0;;
  *down*) echo "curl: (7) Failed to connect" >&2; echo ""; exit 7;;
  *) echo "stub curl: unknown url $url" >&2; exit 99;;
esac
EOF
chmod +x "$TMP/cbin/curl"
cat > "$TMP/cbin/docker" <<'EOF'
#!/usr/bin/env bash
# No-op docker for content tests: no containers anywhere (Created check green).
exit 0
EOF
chmod +x "$TMP/cbin/docker"

run_content() { # $1=CONTENT_CHECKS value -> prints output, returns script rc
  local statedir
  statedir="$(mktemp -d -p "$TMP")"
  printf '%s\n' 'SKIP_PG_SHARED=1' 'SKIP_PG_RELAY=1' 'ALERT_TO=test@example.com' > "$TMP/env-content-base"
  COOLIFY_HEALTHCHECK_ENV_FILE="$TMP/env-content-base" \
  STATE_DIR="$statedir" \
  LOCK_FILE="$TMP/clock-$RANDOM" \
  APP_URLS="" \
  CONTENT_CHECKS="$1" \
  LATENCY_PROBES="" \
  LATENCY_PUSH_ENABLED=0 \
  SKIP_DISK_CHECK=1 SKIP_BACKUP_CHECKS=1 CHECK_CMP_CALLBACKS=0 SKIP_CREATED_CHECK=1 \
  PATH="$TMP/cbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}

# T6: marker present (case/whitespace-insensitive) -> green
out=""; set +e; out="$(run_content 'svc=https://127.0.0.1/good::"status":"ok"')"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'OK check=content-svc'* ]]; then
  pass "T6 content marker match green (rc=$rc)"
else
  fail "T6 content match (rc=$rc) -- $out"
fi

# T7: HTTP 200 but marker absent (proxy default page) -> FAIL
out=""; set +e; out="$(run_content 'svc=https://127.0.0.1/wrong::"status":"ok"')"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *"marker"*"absent"* ]]; then
  pass "T7 wrong-content 200 FAILs on missing marker (rc=$rc)"
else
  fail "T7 wrong-content (rc=$rc) -- $out"
fi

# T8: empty 200 body -> FAIL (catches empty-backend incidents)
out=""; set +e; out="$(run_content 'svc=https://127.0.0.1/empty::"status":"ok"')"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=content-svc'* ]]; then
  pass "T8 empty-body 200 FAILs (rc=$rc)"
else
  fail "T8 empty body (rc=$rc) -- $out"
fi

# T9: connect failure + HTTP 500 -> FAIL (marker stage never masks transport)
out=""; set +e; out="$(run_content 'svc=https://127.0.0.1/down::"status":"ok"')"; rc=$?; set -e
t9a=1; [[ $rc -ne 0 && "$out" == *'FAIL check=content-svc'* ]] || t9a=0
out=""; set +e; out="$(run_content 'svc=https://127.0.0.1/fivehundred::"status":"ok"')"; rc=$?; set -e
if [[ $t9a -eq 1 && $rc -ne 0 && "$out" == *'returned HTTP 500'* ]]; then
  pass "T9 transport/500 FAILs before marker match"
else
  fail "T9 transport/500 -- $out"
fi

# T10: malformed CONTENT_CHECKS entry is skipped with WARN, others still run
out=""; set +e; out="$(run_content 'bogus-no-delimiter svc=https://127.0.0.1/good::"status":"ok"')"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'skipping malformed CONTENT_CHECKS entry'* && "$out" == *'OK check=content-svc'* ]]; then
  pass "T10 malformed entry skipped, good entry green"
else
  fail "T10 malformed entry (rc=$rc) -- $out"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]] && : # gate re-checked after ops tests below

# ---- T11-T17: Created-container detection + AISHL django_q (t1143u) ----
mkdir -p "$TMP/dbin"
cat > "$TMP/dbin/docker" <<'EOF'
#!/usr/bin/env bash
# Stub docker for ops tests: state via $STUB2_* env.
#   STUB2_NOPG=1          -> pg-shared label lookup returns empty
#   STUB2_CREATED_IDS     -> ids for `ps -a --filter status=created`
#   STUB2_CREATED_TS      -> Created timestamp for `inspect` (default: 2026-10-22 old)
#   STUB2_AISL_FAIL       -> django_q 24h failure count (default 3)
#   STUB2_AISL_PROG       -> seconds since last success (default 120)
set -uo pipefail
case "${1:-}" in
  ps)
    if [[ "$*" == *"status=created"* ]]; then
      # shellcheck disable=SC2086
      echo ${STUB2_CREATED_IDS:-}
      exit 0
    fi
    if [[ "${STUB2_NOPG:-0}" == "1" ]]; then exit 0; fi
    echo "fake-shared-uuid"; exit 0;;
  inspect)
    echo "${STUB2_CREATED_TS:-2026-10-22T15:36:18+02:00}"; exit 0;;
  exec)
    shift
    while [[ $# -gt 0 && "$1" == -* ]]; do
      case "$1" in -e) shift 2;; *) shift;; esac
    done
    _container="${1:-}"; shift || true
    _cmd="${1:-}"; shift || true
    if [[ "$_cmd" == "pg_isready" ]]; then echo "accepting connections"; exit 0; fi
    if [[ "$_cmd" == "psql" ]]; then
      if [[ "$*" == *"success=false"* ]]; then echo "${STUB2_AISL_FAIL:-3}"; exit 0; fi
      if [[ "$*" == *"max(stopped)"* ]]; then echo "${STUB2_AISL_PROG:-120}"; exit 0; fi
      echo "1"; exit 0
    fi
    echo "stub docker: unsupported cmd: $_cmd" >&2; exit 99;;
esac
echo "stub docker: unsupported: $*" >&2; exit 99
EOF
chmod +x "$TMP/dbin/docker"

run_ops() { # uses $STUB2_* env; $1=CHECK_AISL_Q value
  local statedir envf="$TMP/env-ops"
  statedir="$(mktemp -d -p "$TMP")"
  printf '%s\n' 'SKIP_PG_SHARED=1' 'SKIP_PG_RELAY=1' 'SKIP_DISK_CHECK=1' \
    'SKIP_BACKUP_CHECKS=1' 'ALERT_TO=test@example.com' "CHECK_AISL_Q=$1" > "$envf"
  COOLIFY_HEALTHCHECK_ENV_FILE="$envf" \
  STATE_DIR="$statedir" \
  LOCK_FILE="$TMP/olock-$RANDOM" \
  APP_URLS="" CONTENT_CHECKS="" LATENCY_PROBES="" LATENCY_PUSH_ENABLED=0 \
  PATH="$TMP/dbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}

# T11: no Created containers -> OK docker-created
out=""; set +e; out="$(STUB2_CREATED_IDS="" run_ops 0)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'OK check=docker-created'* ]]; then
  pass "T11 no Created containers green"
else
  fail "T11 created-empty (rc=$rc) -- $out"
fi

# T12: stale Created container -> FAIL with id
out=""; set +e; out="$(STUB2_CREATED_IDS="edf37bcf137b" run_ops 0)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=docker-created'* && "$out" == *'edf37bcf137b'* ]]; then
  pass "T12 stale Created FAILs with id (rc=$rc)"
else
  fail "T12 stale created (rc=$rc) -- $out"
fi

# T13: fresh Created container (within grace) -> OK, no flap on deploys
out=""; set +e; out="$(STUB2_CREATED_IDS="abc123" STUB2_CREATED_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" run_ops 0)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'OK check=docker-created'* ]]; then
  pass "T13 fresh Created within grace green"
else
  fail "T13 fresh created (rc=$rc) -- $out"
fi

# T14: aisl-q green (failures under threshold, progress fresh)
out=""; set +e; out="$(STUB2_CREATED_IDS="" STUB2_AISL_FAIL=3 STUB2_AISL_PROG=120 run_ops 1)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'OK check=aisl-q: failed_last_24h=3 success_age=120s'* ]]; then
  pass "T14 aisl-q green with counts"
else
  fail "T14 aisl-q green (rc=$rc) -- $out"
fi

# T15: aisl-q red on recurring failures (live: 41/24h vs threshold 10)
out=""; set +e; out="$(STUB2_CREATED_IDS="" STUB2_AISL_FAIL=41 STUB2_AISL_PROG=60 run_ops 1)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=aisl-q'* && "$out" == *'failed_last_24h=41'* ]]; then
  pass "T15 aisl-q recurring failures FAIL (rc=$rc)"
else
  fail "T15 aisl-q failures (rc=$rc) -- $out"
fi

# T16: aisl-q red on stale progress (no success > 3600s)
out=""; set +e; out="$(STUB2_CREATED_IDS="" STUB2_AISL_FAIL=0 STUB2_AISL_PROG=9999 run_ops 1)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=aisl-q'* && "$out" == *'9999s'* ]]; then
  pass "T16 aisl-q stale progress FAILs (rc=$rc)"
else
  fail "T16 aisl-q progress (rc=$rc) -- $out"
fi

# T17: CHECK_AISL_Q=1 without local pg-shared -> loud misconfig FAIL
out=""; set +e; out="$(STUB2_CREATED_IDS="" STUB2_NOPG=1 run_ops 1)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=aisl-q'* && "$out" == *'no local pg-shared'* ]]; then
  pass "T17 aisl-q without container FAILs loud"
else
  fail "T17 aisl-q misconfig (rc=$rc) -- $out"
fi

# ---- T18-T20: latency probes (f5d8e22b: TTFB/total + slowness hysteresis) ----
mkdir -p "$TMP/lbin"
cat > "$TMP/lbin/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl for latency: honors -w format, prints "code ttfb total".
# Slow when URL contains "slow", fail when URL contains "down".
url="${@: -1}"
if [[ "$url" == *down* ]]; then echo "curl: (7) failed" >&2; exit 7; fi
if [[ "$url" == *slow* ]]; then echo "200 5.00 5.20"; exit 0; fi
echo "200 0.20 0.30"; exit 0
EOF
chmod +x "$TMP/lbin/curl"
cat > "$TMP/lbin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/lbin/docker"
cat > "$TMP/lbin/msmtp" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; exit 0
EOF
chmod +x "$TMP/lbin/msmtp"
cat > "$TMP/lbin/sendmail" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; exit 0
EOF
chmod +x "$TMP/lbin/sendmail"
run_latency() { # $1=LATENCY_PROBES $2=extra env assignments
  local statedir envf="$TMP/env-lat" rc out
  statedir="$(mktemp -d -p "$TMP")"
  printf '%s\n' 'SKIP_PG_SHARED=1' 'SKIP_PG_RELAY=1' 'SKIP_DISK_CHECK=1' \
    'SKIP_BACKUP_CHECKS=1' 'ALERT_TO=test@example.com' > "$envf"
  # shellcheck disable=SC2086
  out="$(env COOLIFY_HEALTHCHECK_ENV_FILE="$envf" \
  STATE_DIR="$statedir" \
  LOCK_FILE="$TMP/llock-$RANDOM" \
  APP_URLS="" CONTENT_CHECKS="" LATENCY_PROBES="$1" LATENCY_PUSH_ENABLED=0 \
  $2 \
  PATH="$TMP/lbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  echo "STATE_DIR=$statedir"
  return "$rc"
}
# T18: fast probes record TTFB/total, no slowness page
out=""; set +e; out="$(run_latency 'p1=https://127.0.0.1/fast::cmp' 'LATENCY_SUSTAIN_SEC=600')"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'latency probe=p1'* && "$out" == *'ttfb=0.20'* ]]; then
  pass "T18 fast latency records TTFB/total, no page"
else
  fail "T18 fast latency (rc=$rc) -- $out"
fi
# T19: slow probe below sustain -> WARN only, no FAIL page yet
out=""; set +e; out="$(run_latency 'p1=https://127.0.0.1/slow::cmp' 'LATENCY_SUSTAIN_SEC=600')"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'above threshold'* && "$out" != *'FAIL latency probe=p1'* ]]; then
  pass "T19 slow below sustain WARNs without paging"
else
  fail "T19 slow sustain (rc=$rc) -- $out"
fi
# T20: slow probe with sustain=0 -> FAIL pages immediately (drill path)
out=""; set +e; out="$(run_latency 'p1=https://127.0.0.1/slow::cmp' 'LATENCY_SUSTAIN_SEC=0')"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL latency probe=p1'* ]]; then
  pass "T20 slow with sustain=0 FAILs (drill)"
else
  fail "T20 slow immediate (rc=$rc) -- $out"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
