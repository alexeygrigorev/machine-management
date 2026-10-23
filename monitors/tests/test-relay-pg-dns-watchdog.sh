#!/usr/bin/env bash
# Regression test suite for monitors/relay-pg-dns-watchdog.sh (t1207u + t1218u).
#
# Specifically verifies that the watchdog catches stale/stuck long-lived workers
# BEYOND a fresh sibling `docker exec` DNS+TCP probe (`probe_from_container`):
#   T1: bash -n syntax check (watchdog + installer)
#   T2: Healthy baseline -> ALL_OK (TCP + worker progress + SQL heartbeat & queues)
#   T3: Fresh TCP OK, but ses-ingress latest batch has `deleted=0 failed=1` ->
#       detected (ses_ingress_batch_failed), auto-restarted, verified AUTOHEALED
#   T4: Fresh TCP OK, but worker has active :5432 socket to stale IP 10.0.1.2
#       (while live PG is 10.0.1.15) -> detected (stale_socket_peer), AUTOHEALED
#   T5: Fresh TCP OK, but background worker StartedAt pre-dates PG StartedAt
#       (worker_older_than_pg) -> detected, auto-restarted, verified AUTOHEALED
#   T6: Fresh TCP OK, but db_worker logged OperationalError after 'Starting worker'
#       (StatReloader thread death) -> detected (worker_db_error_since_start), AUTOHEALED
#   T7: Fresh TCP OK, but SQL relay_scheduler_heartbeat.ticked_at is stale ->
#       detected (progress-scheduler-heartbeat), restarts scheduler-*, AUTOHEALED
#   T8: Fresh TCP OK, but SQL django_tasks_database_dbtaskresult has due READY
#       task stuck > TASK_QUEUE_MAX_READY_AGE_SEC -> detected (progress-task-queues),
#       restarts provider-events-worker-*, AUTOHEALED
#   T9: Postgres self-check fails -> stands down (PG_STANDDOWN, rc=2), 0 restarts
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/relay-pg-dns-watchdog.sh"
INSTALLER="$REPO/monitors/install-relay-pg-dns-watchdog.sh"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# ---- T1: syntax ----
if bash -n "$SCRIPT" && bash -n "$INSTALLER"; then
  pass "T1 bash -n (relay-pg-dns-watchdog.sh + installer)"
else
  fail "T1 bash -n"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin"

cat > "$TMP/stubbin/docker" <<'EOF'
#!/usr/bin/env bash
# Stub docker for relay-pg-dns-watchdog tests.
# State controlled by files in $STUB_STATE_DIR:
#   mode: healthy | ses_fail | stale_peer | older_than_pg | db_worker_err | hb_stale | queue_stuck | pg_down
#   restarted-<container>: created when `docker restart <container>` runs
set -uo pipefail
MODE="$(cat "${STUB_STATE_DIR}/mode" 2>/dev/null || echo healthy)"
PG_NAME="mqimefrti7ratmaliirnikov"
DEPS="ses-ingress-fjnzwomg worker-fjnzwomg provider-events-worker-fjnzwomg scheduler-fjnzwomg web-fjnzwomg"

was_restarted() { [[ -f "${STUB_STATE_DIR}/restarted-$1" ]]; }

case "${1:-}" in
  ps)
    if [[ "$*" == *"label=coolify.resourceName=pg-relay"* ]]; then
      echo "$PG_NAME"
      exit 0
    fi
    if [[ "$*" == *"label=coolify.resourceName=pg-shared"* ]]; then
      echo "fake-shared-pg"
      exit 0
    fi
    printf '%s\n' "$PG_NAME" $DEPS
    exit 0
    ;;
  restart)
    c="${2:-}"
    touch "${STUB_STATE_DIR}/restarted-${c}"
    exit 0
    ;;
  inspect)
    fmt=""; target=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--format) fmt="$2"; shift 2;;
        *) target="$1"; shift;;
      esac
    done
    case "$fmt" in
      *'NetworkSettings.Networks'*'IPAddress'*)
        # All PG targets resolve to the live relay IPs in these tests, so
        # synthetic healthy socket peers match for every label branch.
        echo "10.0.1.15 fd12:8ac:8b43::f"
        ;;
      *'NetworkSettings.Networks'*)
        echo "coolify "
        ;;
      *'.Name'*)
        echo "/${target}"
        ;;
      *'.State.Running'*)
        echo "true"
        ;;
      *'.State.Health'*)
        echo "healthy"
        ;;
      *'.State.StartedAt'*)
        if [[ "$target" == "fake-shared-pg" ]]; then
          echo "2026-10-20T10:00:00Z"
        elif [[ "$target" == "$PG_NAME" ]]; then
          echo "2026-10-22T15:13:26Z"
        elif [[ "$MODE" == "older_than_pg" && "$target" == "ses-ingress-fjnzwomg" ]] && ! was_restarted "$target"; then
          echo "2026-10-22T13:36:21Z"
        elif [[ "$target" == web-* ]]; then
          echo "2026-10-22T13:36:19Z"
        else
          echo "2026-10-22T23:59:12Z"
        fi
        ;;
      *'.Config.Env'*)
        if [[ "$target" != "$PG_NAME" ]]; then
          echo "DATABASE_URL=postgres://relay_app:redacted@${PG_NAME}:5432/relay"
        fi
        ;;
      *'.Config.Cmd'*)
        case "$target" in
          web-*) echo "gunicorn --bind 0.0.0.0:8000 relay.wsgi:application";;
          worker-*|provider-events-worker-*) echo "python manage.py db_worker";;
          scheduler-*) echo "python manage.py run_relay_scheduler";;
          ses-ingress-*) echo "python manage.py drain_sqs_ingress ses-webhooks";;
        esac
        ;;
    esac
    exit 0
    ;;
  logs)
    target="${!#}"
    if [[ "$target" == "ses-ingress-fjnzwomg" ]]; then
      if [[ "$MODE" == "ses_fail" ]] && ! was_restarted "$target"; then
        printf '%s\n' \
          "Starting ses-webhooks ingress drain" \
          "received=2 deleted=2 failed=0" \
          "received=1 deleted=0 failed=1"
      else
        printf '%s\n' \
          "Starting ses-webhooks ingress drain" \
          "received=3 deleted=3 failed=0"
      fi
      exit 0
    fi
    if [[ "$target" == "worker-fjnzwomg" ]]; then
      if [[ "$MODE" == "db_worker_err" ]] && ! was_restarted "$target"; then
        printf '%s\n' \
          "Watching for file changes with StatReloader" \
          "Starting worker worker_id=abc queues=default" \
          "django.db.utils.OperationalError: could not translate host name"
      else
        printf '%s\n' \
          "Watching for file changes with StatReloader" \
          "Starting worker worker_id=def queues=default"
      fi
      exit 0
    fi
    echo "Starting worker"
    exit 0
    ;;
  exec)
    shift
    c="$1"; shift
    cmd="$1"; shift
    # Record the psql/pg_isready database per container for T10 mapping proof.
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "-d" ]]; then
        printf '%s %s\n' "$c" "$a" >> "${STUB_STATE_DIR}/seen-dbs"
      fi
      prev="$a"
    done
    if [[ "$cmd" == "pg_isready" ]]; then
      [[ "$MODE" == "pg_down" ]] && { echo "no response"; exit 2; }
      echo "accepting connections"
      exit 0
    fi
    if [[ "$cmd" == "getent" ]]; then
      printf '10.0.1.15 STREAM mqimefrti7ratmaliirnikov\nfd12:8ac:8b43::f STREAM mqimefrti7ratmaliirnikov\n'
      exit 0
    fi
    if [[ "$cmd" == "sh" ]]; then
      # command -v python3 check
      exit 0
    fi
    if [[ "$cmd" == "python3" ]]; then
      # Distinguish probe_from_container vs check_active_socket_peers by script content
      py_code="$2"
      if [[ "$py_code" == *"socket.getaddrinfo"* ]]; then
        # Fresh sibling TCP probe ALWAYS succeeds in these tests!
        exit 0
      fi
      if [[ "$py_code" == *"/proc/1/net/tcp"* ]]; then
        # Run the actual Python code from relay-pg-dns-watchdog against synthetic proc/net/tcp{,6} files!
        tcp4="${STUB_STATE_DIR}/tcp4-${c}"
        tcp6="${STUB_STATE_DIR}/tcp6-${c}"
        printf '  sl  local_address rem_address   st tx_queue rx_queue\n' > "$tcp4"
        printf '  sl  local_address                         remote_address                        st tx_queue rx_queue\n' > "$tcp6"
        if [[ "$MODE" == "stale_peer" && "$c" == "ses-ingress-fjnzwomg" ]] && ! was_restarted "$c"; then
          # 10.0.1.2:5432 in little-endian hex = 0201000A:1538, state 01 (ESTABLISHED)
          printf '   0: 1001000A:9C40 0201000A:1538 01 00000000:00000000\n' >> "$tcp4"
        else
          # fd12:8ac:8b43::f:5432 in /proc/net/tcp6 hex (AC0812FD0000438B000000000F000000:1538), state 01 (ESTABLISHED)
          printf '   0: AC0812FD0000438B0000000010000000:9C40 AC0812FD0000438B000000000F000000:1538 01 00000000:00000000\n' >> "$tcp6"
        fi
        patched_py="${py_code//\/proc\/1\/net\/tcp6/$tcp6}"
        patched_py="${patched_py//\/proc\/1\/net\/tcp/$tcp4}"
        /usr/bin/python3 -c "$patched_py" "$3" "$4"
        exit $?
      fi
      exit 0
    fi
    if [[ "$cmd" == "psql" ]]; then
      sql="${!#}"
      if [[ "$sql" == *"SELECT 1"* ]]; then
        echo "1"; exit 0
      fi
      if [[ "$sql" == *"to_regclass"* ]]; then
        # pg-shared has no relay progress tables -> probes must skip, not fail
        if [[ "$c" == "fake-shared-pg" ]]; then echo ""; exit 0; fi
        echo "t"; exit 0
      fi
      if [[ "$sql" == *"FROM relay_scheduler_heartbeat"* ]]; then
        if [[ "$MODE" == "hb_stale" ]] && ! was_restarted "scheduler-fjnzwomg"; then
          echo "420"
        else
          echo "8"
        fi
        exit 0
      fi
      if [[ "$sql" == *"GROUP BY queue_name"* ]]; then
        if [[ "$MODE" == "queue_stuck" ]] && ! was_restarted "provider-events-worker-fjnzwomg"; then
          echo "provider-events|4|360"
        fi
        exit 0
      fi
      if [[ "$sql" == *"AND queue_name ="* ]]; then
        if [[ "$MODE" == "queue_stuck" ]] && ! was_restarted "provider-events-worker-fjnzwomg"; then
          echo "360"
        else
          echo "0"
        fi
        exit 0
      fi
      if [[ "$sql" == *"MAX(finished_at)"* ]]; then
        echo "2026-10-23T01:40:03Z"
        exit 0
      fi
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TMP/stubbin/docker"

run_watchdog() {
  # $1=mode
  local mode="$1"
  local sdir="$TMP/state-$mode-$RANDOM"
  mkdir -p "$sdir"
  printf '%s' "$mode" > "$sdir/mode"
  STUB_STATE_DIR="$sdir" \
  RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir/var" \
  LOCK_FILE="$sdir/lock" \
  RESTART_VERIFY_WAIT=0 \
  ALERT_TO="test@example.com" \
  PATH="$TMP/stubbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}

# ---- T2: Healthy state -> ALL_OK ----
out=""; set +e; out="$(run_watchdog healthy)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *"ALL_OK"* && "$out" == *"OK check=progress-scheduler-heartbeat"* && "$out" == *"OK check=progress-task-queues"* ]]; then
  pass "T2 healthy baseline ALL_OK (TCP + worker progress + SQL heartbeat & queues)"
else
  fail "T2 healthy baseline (rc=$rc) -- $out"
fi

# ---- T3: Fresh TCP OK, ses-ingress batch failed -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog ses_fail)"; rc=$?; set -e
if [[ "$out" == *"ses_ingress_batch_failed"* && "$out" == *"HEALED check=dep-ses-ingress-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T3 ses-ingress deleted=0 failed=1 caught despite TCP OK and AUTOHEALED"
else
  fail "T3 ses-ingress batch failure (rc=$rc) -- $out"
fi

# ---- T4: Fresh TCP OK, stale active socket peer -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog stale_peer)"; rc=$?; set -e
if [[ "$out" == *"stale_socket_peer=10.0.1.2"* && "$out" == *"HEALED check=dep-ses-ingress-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T4 stale active :5432 socket peer (10.0.1.2) caught despite fresh TCP OK and AUTOHEALED"
else
  fail "T4 stale socket peer (rc=$rc) -- $out"
fi

# ---- T5: Fresh TCP OK, worker older than recreated PG -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog older_than_pg)"; rc=$?; set -e
if [[ "$out" == *"worker_older_than_pg"* && "$out" == *"HEALED check=dep-ses-ingress-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T5 worker pre-dating PG recreate caught despite fresh TCP OK and AUTOHEALED"
else
  fail "T5 worker older than PG (rc=$rc) -- $out"
fi

# ---- T6: Fresh TCP OK, db_worker OperationalError under StatReloader -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog db_worker_err)"; rc=$?; set -e
if [[ "$out" == *"worker_db_error_since_start"* && "$out" == *"HEALED check=dep-worker-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T6 db_worker OperationalError caught despite fresh TCP OK and AUTOHEALED"
else
  fail "T6 db_worker OperationalError (rc=$rc) -- $out"
fi

# ---- T7: Fresh TCP OK, stale relay_scheduler_heartbeat -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog hb_stale)"; rc=$?; set -e
if [[ "$out" == *"FAIL check=progress-scheduler-heartbeat"* && "$out" == *"HEALED check=progress-scheduler-heartbeat scheduler=scheduler-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T7 stale SQL relay_scheduler_heartbeat caught and scheduler-* AUTOHEALED"
else
  fail "T7 stale scheduler heartbeat (rc=$rc) -- $out"
fi

# ---- T8: Fresh TCP OK, stuck READY task in django_tasks_database_dbtaskresult -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog queue_stuck)"; rc=$?; set -e
if [[ "$out" == *"FAIL check=progress-task-queues"* && "$out" == *"HEALED check=progress-task-queues queue=provider-events worker=provider-events-worker-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T8 stuck READY task in provider-events queue caught and provider-events-worker-* AUTOHEALED"
else
  fail "T8 stuck task queue (rc=$rc) -- $out"
fi

# ---- T9: PG down -> STANDDOWN (rc=2), no restarts ----
out=""; set +e; out="$(run_watchdog pg_down)"; rc=$?; set -e
if [[ $rc -eq 2 && "$out" == *"PG_STANDDOWN"* && "$out" != *"RESTART"* ]]; then
  pass "T9 PG self-check failure stands down cleanly (rc=2, 0 restarts)"
else
  fail "T9 PG standdown (rc=$rc) -- $out"
fi

# ---- T10: multi-label pg-relay+pg-shared uses per-label DB, no STANDDOWN ----
run_watchdog_multi() {
  local sdir="$TMP/state-multi-$RANDOM"
  mkdir -p "$sdir"
  printf '%s' "healthy" > "$sdir/mode"
  STUB_STATE_DIR="$sdir" \
  RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir/var" \
  LOCK_FILE="$sdir/lock" \
  RESTART_VERIFY_WAIT=0 \
  ALERT_TO="test@example.com" \
  PG_LABELS="pg-relay pg-shared" \
  PG_DB_pg_shared="postgres" \
  PATH="$TMP/stubbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
  printf 'SEEN-DBS:\n'; cat "$sdir/seen-dbs" 2>/dev/null
}
out=""; set +e; out="$(run_watchdog_multi)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *"ALL_OK"* \
  && "$out" == *"OK pg=pg-relay container="* \
  && "$out" == *"OK pg=pg-shared container=fake-shared-pg"* \
  && "$out" != *"STANDDOWN"* \
  && "$out" == *"fake-shared-pg postgres"* \
  && "$out" == *"mqimefrti7ratmaliirnikov relay"* ]]; then
  pass "T10 pg-shared branch uses PG_DB_pg_shared=postgres, relay keeps PG_DB, ALL_OK"
else
  fail "T10 multi-label per-label DB (rc=$rc) -- $out"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
