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

cat > "$TMP/stubbin/msmtp" <<'EOF'
#!/usr/bin/env bash
mkdir -p "${STUB_STATE_DIR:-/tmp}/mail"
{
  echo "ARGS: $*"
  cat
  printf '\n---\n'
} >> "${STUB_STATE_DIR:-/tmp}/mail/sent.log"
EOF
chmod +x "$TMP/stubbin/msmtp"
cp "$TMP/stubbin/msmtp" "$TMP/stubbin/sendmail"

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
OLD="oascx5kjeimc0ivpttag9z3q-20261024T130608"
NEW="oascx5kjeimc0ivpttag9z3q-20261024T133508"
if [[ "$MODE" == retiring_* || "$MODE" == live_* || "$MODE" == removed_* || "$MODE" == restart_error ]]; then
  DEPS="$OLD"
  [[ "$MODE" == retiring_label || "$MODE" == retiring_compose || "$MODE" == live_other_service || "$MODE" == live_older_peer ]] && DEPS+=" $NEW"
fi

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
    if [[ "$*" == *"label=coolify.name="* ]]; then
      [[ "$MODE" == retiring_label || "$MODE" == live_older_peer ]] && printf '%s\n' "$OLD" "$NEW"
      exit 0
    fi
    if [[ "$*" == *"label=com.docker.compose.project="* ]]; then
      [[ "$MODE" == retiring_compose ]] && printf '%s\n' "$OLD" "$NEW"
      # Same project, different service must not retire a live dependent.
      [[ "$MODE" == live_other_service ]] && echo "$OLD"
      exit 0
    fi
    printf '%s\n' "$PG_NAME" $DEPS
    exit 0
    ;;
  restart)
    c="${2:-}"
    touch "${STUB_STATE_DIR}/restarted-${c}"
    if [[ "$MODE" == removed_restart ]]; then
      echo "Error response from daemon: No such container: $c" >&2
      touch "${STUB_STATE_DIR}/removed"
      exit 1
    fi
    if [[ "$MODE" == restart_error ]]; then
      echo "Error response from daemon: restart failed" >&2
      exit 1
    fi
    [[ "$MODE" == removed_after_restart ]] && touch "${STUB_STATE_DIR}/removed"
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
    if [[ "$target" == *"gone"* || "$target" == "nonexistent"* || ( "$target" == "$OLD" && -f "${STUB_STATE_DIR}/removed" ) ]]; then
      echo "error: no such object: $target" >&2
      exit 1
    fi
    case "$fmt" in
      '{{.State.Status}}|'*)
        status=running; running=true; networks=1
        created=2026-10-24T13:06:08.000000000Z
        coolify=""; project=""; service=""
        if [[ "$target" == "$OLD" ]]; then
          case "$MODE" in
            retiring_stopped) status=exited; running=false;;
            retiring_stopping) status=stopping;;
            retiring_no_networks) networks=0;;
            retiring_label|live_older_peer) coolify=relay;;
            retiring_compose|live_other_service) project=relay; service=web;;
          esac
        fi
        [[ "$target" == "$NEW" ]] && created=2026-10-24T13:35:15.677692498Z
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$status" "$running" "$networks" "$created" "$coolify" "$project" "$service"
        ;;
      '{{.Created}}|'*)
        if [[ "$MODE" == live_older_peer ]]; then
          echo '2026-10-24T12:00:00.000000000Z|true'
        else
          echo '2026-10-24T13:35:15.677692498Z|true'
        fi
        ;;
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
        if [[ "$MODE" == young* && "$target" != "$PG_NAME" ]]; then
          date -u -d '30 seconds ago' '+%Y-%m-%dT%H:%M:%SZ'
        elif [[ "$target" == "fake-shared-pg" ]]; then
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
      if [[ "$MODE" == "ses_fail" ]]; then
        printf '%s\n' \
          "Starting ses-webhooks ingress drain" \
          "received=2 deleted=2 failed=0" \
          "received=1 deleted=0 failed=1"
      elif [[ "$MODE" == "ses_db_err" ]] && ! was_restarted "$target"; then
        printf '%s\n' \
          "Starting ses-webhooks ingress drain" \
          "django.db.utils.OperationalError: could not translate host name"
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
    printf '%s\n' "$c" >> "${STUB_STATE_DIR}/execs"
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
      [[ "$c" == "$OLD" ]] && exit 1
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
        printf '%s\n' "$c" >> "${STUB_STATE_DIR}/probes"
        if [[ "$c" == "$OLD" && "$MODE" == removed_dns_wait ]]; then
          touch "${STUB_STATE_DIR}/removed"
          exit 2
        fi
        if [[ "$c" == "$OLD" && "$MODE" == live_dns ]]; then exit 2; fi
        if [[ "$MODE" == young* ]]; then exit 2; fi
        if [[ "$MODE" == dns_* && "$c" == ses-ingress-* ]] && ! was_restarted "$c"; then
          count=$(cat "${STUB_STATE_DIR}/dns-count" 2>/dev/null || echo 0)
          echo "$((count + 1))" > "${STUB_STATE_DIR}/dns-count"
          if [[ "$MODE" != dns_transient || "$count" == 0 ]]; then exit 2; fi
        fi
        exit 0
      fi
      if [[ "$py_code" == *"/proc/1/net/tcp"* ]]; then
        # Run the actual Python code from relay-pg-dns-watchdog against synthetic proc/net/tcp{,6} files!
        tcp4="${STUB_STATE_DIR}/tcp4-${c}"
        tcp6="${STUB_STATE_DIR}/tcp6-${c}"
        printf '  sl  local_address rem_address   st tx_queue rx_queue\n' > "$tcp4"
        printf '  sl  local_address                         remote_address                        st tx_queue rx_queue\n' > "$tcp6"
        if [[ "$c" == "$OLD" ]]; then
          # Incident fixture: v4=[]/v6=[], no established PG socket (peers=0).
          [[ "$MODE" == removed_progress ]] && touch "${STUB_STATE_DIR}/removed"
        elif [[ "$MODE" == "stale_peer" && "$c" == "ses-ingress-fjnzwomg" ]] && ! was_restarted "$c"; then
          # 10.0.1.2:5432 in little-endian hex = 0201000A:1538, state 01 (ESTABLISHED)
          printf '   0: 1001000A:9C40 0201000A:1538 01 00000000:00000000\n' >> "$tcp4"
        else
          # fd12:8ac:8b43::f:5432 in /proc/net/tcp6 hex (AC0812FD0000438B000000000F000000:1538), state 01 (ESTABLISHED)
          printf '   0: AC0812FD0000438B0000000010000000:9C40 AC0812FD0000438B000000000F000000:1538 01 00000000:00000000\n' >> "$tcp6"
        fi
        patched_py="${py_code//\/proc\/1\/net\/tcp6/$tcp6}"
        patched_py="${patched_py//\/proc\/1\/net\/tcp/$tcp4}"
        /usr/bin/python3 -c "$patched_py" "$3" "$4"
        py_rc=$?
        # The incident's docker exec failed with an empty peer summary; an
        # otherwise healthy idle worker with peers=0 remains valid.
        [[ "$c" == "$OLD" ]] && exit 1
        exit "$py_rc"
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
        if [[ "$MODE" == "hb_stale" || "$MODE" == "young_sql" ]] && ! was_restarted "scheduler-fjnzwomg"; then
          echo "420"
        else
          echo "8"
        fi
        exit 0
      fi
      if [[ "$sql" == *"GROUP BY queue_name"* ]]; then
        if [[ "$MODE" == "queue_stuck" || "$MODE" == "young_sql" ]] && ! was_restarted "provider-events-worker-fjnzwomg"; then
          echo "provider-events|4|360"
        fi
        exit 0
      fi
      if [[ "$sql" == *"AND queue_name ="* ]]; then
        if [[ "$MODE" == "queue_stuck" || "$MODE" == "young_sql" ]] && ! was_restarted "provider-events-worker-fjnzwomg"; then
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

# Never deliver real mail; record attempts, including unexpected recovery mail.
cat > "$TMP/stubbin/sendmail" <<'EOF'
#!/usr/bin/env bash
cat >> "$STUB_STATE_DIR/mail"
EOF
chmod +x "$TMP/stubbin/sendmail"

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

# ---- T3: Fresh TCP OK, ses-ingress per-message failure (deleted>0 recently or failed=1) -> NO restart, no FAIL mail, logged locally, ALL_OK ----
out=""; set +e; out="$(run_watchdog ses_fail)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *"ALL_OK"* && "$out" == *"ses_per_msg_fail=received=1,deleted=0,failed=1"* && "$out" != *"AUTOHEALED"* && "$out" != *"RESTART dep=ses-ingress"* ]]; then
  pass "T3 ses-ingress per-message failure (deleted=0 failed=1) recognized without container restart or false FAIL alert (t1342u)"
else
  fail "T3 ses-ingress per-message failure (rc=$rc) -- $out"
fi

# ---- T3b: Fresh TCP OK, ses-ingress DB OperationalError -> AUTOHEALED ----
out=""; set +e; out="$(run_watchdog ses_db_err)"; rc=$?; set -e
if [[ "$out" == *"worker_db_error_since_start"* && "$out" == *"HEALED check=dep-ses-ingress-fjnzwomg"* && "$out" == *"AUTOHEALED"* ]]; then
  pass "T3b ses-ingress real DB OperationalError caught and AUTOHEALED"
else
  fail "T3b ses-ingress real DB error (rc=$rc) -- $out"
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

# ---- T11: AUTOHEALED deduplication (at most 1 per cooldown window with count) ----
sdir_t11="$TMP/state-t11-$RANDOM"
mkdir -p "$sdir_t11/var"
printf '%s' "stale_peer" > "$sdir_t11/mode"
# Run 1: first autoheal -> should alert AUTOHEALED
out1=""; set +e
out1="$(STUB_STATE_DIR="$sdir_t11" RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir_t11/var" LOCK_FILE="$sdir_t11/lock" RESTART_VERIFY_WAIT=0 \
  ALERT_TO="test@example.com" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
set -e
# Clear the restarted flag and allow restart again by clearing stamp
rm -f "$sdir_t11/restarted-ses-ingress-fjnzwomg" "$sdir_t11/var/restart-ses-ingress-fjnzwomg.stamp"
# Run 2: second autoheal in same cooldown window -> alert should be suppressed
out2=""; set +e
out2="$(STUB_STATE_DIR="$sdir_t11" RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir_t11/var" LOCK_FILE="$sdir_t11/lock" RESTART_VERIFY_WAIT=0 \
  ALERT_TO="test@example.com" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
set -e
if [[ "$out1" == *"AUTOHEALED"* && "$out2" == *"AUTOHEALED check=dep-ses-ingress-fjnzwomg: alert suppressed"* ]]; then
  pass "T11 AUTOHEALED deduped: second autoheal within cooldown window suppressed"
else
  fail "T11 AUTOHEALED deduplication -- out1: $out1 -- out2: $out2"
fi

# ---- T12: RECOVER_NOTIFY_MIN_SEC suppresses rapid flap RECOVERED mail ----
sdir_t12="$TMP/state-t12-$RANDOM"
mkdir -p "$sdir_t12/var"
now_sec=$(date +%s)
# Simulate check that failed just 30s ago
printf 'STATUS=FAIL\nLAST_ALERT=%s\nFAIL_SINCE=%s\n' "$(( now_sec - 30 ))" "$(( now_sec - 30 ))" > "$sdir_t12/var/dep-ses-ingress-fjnzwomg.state"
printf '%s' "healthy" > "$sdir_t12/mode"
out_t12=""; set +e
out_t12="$(STUB_STATE_DIR="$sdir_t12" RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir_t12/var" LOCK_FILE="$sdir_t12/lock" RESTART_VERIFY_WAIT=0 \
  ALERT_TO="test@example.com" RECOVER_NOTIFY_MIN_SEC=600 PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
set -e
if [[ "$out_t12" == *"suppressing RECOVERED mail"* && "$out_t12" != *"ALERT check=dep-ses-ingress-fjnzwomg subject='[relay-pg-dns-watchdog] RECOVERED"* ]]; then
  pass "T12 RECOVER_NOTIFY_MIN_SEC suppresses RECOVERED mail for sub-window flap"
else
  fail "T12 RECOVER_NOTIFY_MIN_SEC -- $out_t12"
fi

# ---- T13: Stale state files for gone containers are pruned ----
sdir_t13="$TMP/state-t13-$RANDOM"
mkdir -p "$sdir_t13/var"
touch "$sdir_t13/var/dep-gonecontainer1.state"
touch "$sdir_t13/var/restart-gonecontainer1.stamp"
touch "$sdir_t13/var/dep-ses-ingress-fjnzwomg.state"
printf '%s' "healthy" > "$sdir_t13/mode"
out_t13=""; set +e
out_t13="$(STUB_STATE_DIR="$sdir_t13" RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir_t13/var" LOCK_FILE="$sdir_t13/lock" RESTART_VERIFY_WAIT=0 \
  ALERT_TO="test@example.com" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
set -e
if [[ ! -f "$sdir_t13/var/dep-gonecontainer1.state" && ! -f "$sdir_t13/var/restart-gonecontainer1.stamp" && -f "$sdir_t13/var/dep-ses-ingress-fjnzwomg.state" && "$out_t13" == *"PRUNE"* ]]; then
  pass "T13 stale state and stamp files for gone containers pruned automatically"
else
  fail "T13 stale state pruning -- remaining files: $(ls "$sdir_t13/var")"
fi

# Deploy grace, transient DNS, persistent DNS and retained restart cooldown.
for mode in young_dns young_sql dns_transient dns_persistent dns_cooldown; do
  sdir="$TMP/state-$mode"
  mkdir -p "$sdir/var"
  echo "$mode" > "$sdir/mode"
  if [[ "$mode" == young* ]]; then
    for check in dep-ses-ingress-fjnzwomg progress-scheduler-heartbeat progress-task-queues; do
      printf 'STATUS=FAIL\nFAIL_SINCE=1\nLAST_ALERT=1\n' > "$sdir/var/$check.state"
    done
  fi
  if [[ "$mode" == dns_cooldown ]]; then
    date +%s > "$sdir/var/restart-ses-ingress-fjnzwomg.stamp"
  fi
  set +e
  out="$(STUB_STATE_DIR="$sdir" RELAY_PG_DNS_WATCHDOG_ENV_FILE=/nonexistent \
    STATE_DIR="$sdir/var" LOCK_FILE="$sdir/lock" RESTART_VERIFY_WAIT=0 \
    DNS_RECHECK_WAIT_SEC=0 ALERT_TO=test@example.com \
    PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
  rc=$?
  set -e
  case "$mode" in
    young*)
      if [[ "$rc" == 0 && "$out" == *SKIP_YOUNG* && "$out" != *FAIL* && "$out" != *RESTART* && ! -f "$sdir/probes" && ! -f "$sdir/mail" ]]; then
        pass "$mode: no probe, failure, restart or mail during startup grace"
      else fail "$mode (rc=$rc): $out"; fi;;
    dns_transient)
      if [[ "$rc" == 0 && "$out" == *"DNS_RECHECK dep=ses-ingress-fjnzwomg rc=0"* && "$out" != *FAIL* && "$out" != *RESTART* && ! -f "$sdir/mail" && $(cat "$sdir/dns-count") == 2 ]]; then
        pass "$mode: confirmed recovery without restart or mail"
      else fail "$mode (rc=$rc): $out"; fi;;
    dns_persistent)
      if [[ "$rc" == 1 && "$out" == *"DNS_RECHECK dep=ses-ingress-fjnzwomg rc=2"* && -f "$sdir/restarted-ses-ingress-fjnzwomg" && "$out" == *AUTOHEALED* ]]; then
        pass "$mode: persistent failure restarts and verifies recovery"
      else fail "$mode (rc=$rc): $out"; fi;;
    dns_cooldown)
      if [[ "$rc" == 1 && "$out" == *"DNS_RECHECK dep=ses-ingress-fjnzwomg rc=2"* && "$out" == *"cooldown active"* && ! -f "$sdir/restarted-ses-ingress-fjnzwomg" ]]; then
        pass "$mode: persistent failure respects existing restart stamp"
      else fail "$mode (rc=$rc): $out"; fi;;
  esac
done

# ---- T14: Alert mail has From: DTC Alerts <alerts@dtcdev.click> and envelope alerts@dtcdev.click ----
sdir_t14="$TMP/state-t14-$RANDOM"
mkdir -p "$sdir_t14/var" "$sdir_t14/mail"
printf '%s' "older_than_pg" > "$sdir_t14/mode"
out_t14=""; set +e
out_t14="$(STUB_STATE_DIR="$sdir_t14" RELAY_PG_DNS_WATCHDOG_ENV_FILE="/nonexistent" \
  STATE_DIR="$sdir_t14/var" LOCK_FILE="$sdir_t14/lock" RESTART_VERIFY_WAIT=0 \
  ALERT_TO="dev@dtcdev.click" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
set -e
mail_log="$sdir_t14/mail/sent.log"
if [[ -f "$mail_log" ]] \
  && grep -q '^From: DTC Alerts <alerts@dtcdev.click>$' "$mail_log" \
  && grep -q -- '-a alerts' "$mail_log" \
  && grep -q -- '-f alerts@dtcdev.click' "$mail_log"; then
  pass "T14 alert mail From header and envelope sender match alerts@dtcdev.click"
else
  fail "T14 alert mail format -- log=$(cat "$mail_log" 2>/dev/null || echo missing)"
fi

# Rolling-deploy incident on 2026-10-24 at 13:36:12Z, plus lifecycle races.
for mode in retiring_label retiring_compose retiring_stopped retiring_stopping retiring_no_networks \
  removed_restart removed_after_restart removed_dns_wait removed_progress \
  live_peers_zero live_dns live_other_service live_older_peer restart_error; do
  sdir="$TMP/state-$mode"
  old=oascx5kjeimc0ivpttag9z3q-20261024T130608
  mkdir -p "$sdir/var"
  echo "$mode" > "$sdir/mode"
  printf 'STATUS=OK\n' > "$sdir/var/dep-$old.state"
  echo 1 > "$sdir/var/restart-$old.stamp"
  set +e
  out="$(STUB_STATE_DIR="$sdir" RELAY_PG_DNS_WATCHDOG_ENV_FILE=/nonexistent \
    STATE_DIR="$sdir/var" LOCK_FILE="$sdir/lock" RESTART_VERIFY_WAIT=0 \
    DNS_RECHECK_WAIT_SEC=0 ALERT_TO=test@example.com \
    PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
  rc=$?
  set -e
  case "$mode" in
    retiring_*)
      if [[ "$rc" == 0 && "$out" == *"SKIP_RETIRING dep=$old reason="* \
        && $(printf '%s\n' "$out" | grep -c "SKIP_RETIRING dep=$old ") == 1 \
        && "$out" != *FAIL* && "$out" != *RESTART* && "$out" == *ALL_OK* \
        && ! -f "$sdir/restarted-$old" && ! -e "$sdir/mail" ]] \
        && ! grep -qx "$old" "$sdir/execs"; then
        pass "$mode: retiring old deployment gets one skip, no probe/restart/failure/mail"
      else fail "$mode (rc=$rc): $out"; fi;;
    removed_*)
      if [[ "$rc" == 0 && "$out" == *"PRUNE dep=$old"* && "$out" == *ALL_OK* \
        && "$out" != *STILLFAIL* && "$out" != *ALERT* && ! -e "$sdir/mail" \
        && ! -f "$sdir/var/dep-$old.state" && ! -f "$sdir/var/restart-$old.stamp" ]]; then
        pass "$mode: mid-run removal prunes state/stamp without STILLFAIL or mail"
      else fail "$mode (rc=$rc): $out"; fi;;
    *)
      if [[ "$rc" == 1 && "$out" == *"FAIL check=dep-$old"* \
        && -f "$sdir/restarted-$old" && "$out" == *"ALERT check=dep-$old"* \
        && -s "$sdir/mail/sent.log" && "$out" != *SKIP_RETIRING* ]]; then
        pass "$mode: live failure past grace still fails, restarts and alerts"
      else fail "$mode (rc=$rc): $out"; fi;;
  esac
done

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
