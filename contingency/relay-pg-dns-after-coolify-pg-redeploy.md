# SOP: after Coolify pg-relay (or pg-shared) recreate/redeploy

**Why:** Coolify standalone Postgres keeps a stable *resourceName* label
(`pg-relay`) but the container **name** is a random uuid and the coolify-bridge
**IPv4/IPv6 change on recreate**. Long-lived Relay workers cache the old
address or retain a closed `django.db.connection` / crashed `StatReloader`
worker thread → `connection refused` / `server closed the connection unexpectedly`
while `coolify-healthcheck` still sees PG healthy + public `/health` OK → SES
SQS age/DLQ (t1205u / t1207u / t1218u).

**Evidence (2026-10-22/23, contabo-b):** PG uuid `mqimefrti7ratmaliirnikov`
moved to `10.0.1.15` (`fd12:8ac:8b43::f`); old `10.0.1.2` was later reused by
`client-callbacks` (non-PG → `:5432` refuse). Furthermore, a fresh `docker exec`
sibling TCP probe alone (`probe_from_container`) can pass (`ALL_OK`) because
Docker DNS `127.0.0.11` immediately resolves the new IP on a fresh lookup while
PID 1 inside the worker container remains stuck on the old socket/connection.

## Immediate (ops)

1. On **contabo-b**: confirm PG healthy
   `sudo docker ps --filter label=coolify.resourceName=pg-relay`
2. Verify or trigger the 1-minute watchdog (which now checks TCP + in-process
   socket peers + post-PG-recreate `StartedAt` + worker logs + SQL progress):
   ```bash
   sudo /usr/local/sbin/relay-pg-dns-watchdog.sh
   ```
   Or manually restart Relay background worker containers:
   ```bash
   for s in ses-ingress worker provider-events-worker scheduler \
            recipient-imports cmp-callbacks client-callbacks; do
     c=$(sudo docker ps -qf "name=${s}-fjnzwomg8n42lztloo34just")
     [ -n "$c" ] && sudo docker restart "$c"
   done
   ```
3. Verify recovery **beyond TCP**:
   - Watchdog log shows `progress=ok(...)`, `OK check=progress-scheduler-heartbeat`,
     `OK check=progress-task-queues`, and `ALL_OK`.
   - `ses-ingress` logs show `deleted=N failed=0` (and no `deleted=0 failed>0`
     since container `StartedAt`).
   - SQL check on `pg-relay`: `relay_scheduler_heartbeat.ticked_at` age < 60s
     and `django_tasks_database_dbtaskresult` has 0 stuck `READY` rows.
   - CloudWatch `relay-production-ses-webhooks-oldest-message` / DLQ back to OK.
4. If DLQ has depth, redrive DLQ → main (SQS start-message-move-task).

## Durable (`machine-management`, t1207u + t1218u)

- **`monitors/relay-pg-dns-watchdog.sh`** (cron every 1 min on contabo-b):
  1. Probes fresh DNS+TCP from *inside* dependents (`probe_from_container`).
  2. Verifies running-worker state (`probe_worker_progress`):
     - Active `:5432` TCP sockets in `/proc/1/net/tcp{,6}` match the live PG
       container's IPv4/IPv6 addresses.
     - Background workers (`! web-*`) have `StartedAt >= pg.StartedAt`
       (`RESTART_WORKERS_OLDER_THAN_PG=1`), so any PG recreate automatically
       triggers worker restarts on the next 1-minute tick even when fresh DNS
       already resolves the new IP.
     - `ses-ingress` latest batch has no `deleted=0 failed>0`.
     - Workers have no uncaught `OperationalError` / `InterfaceError` after
       their latest startup banner.
  3. Verifies SQL worker progress (`check_pg_worker_progress`):
     - `relay_scheduler_heartbeat.ticked_at` age <= `SCHEDULER_MAX_AGE_SEC` (180s).
     - `django_tasks_database_dbtaskresult` has no due `READY` tasks older than
       `TASK_QUEUE_MAX_READY_AGE_SEC` (180s).
  4. Auto-restarts affected workers (15-min cooldown per container), re-verifies
     both TCP and progress after restart, and alerts `alexey@` + `dev@`
     (`AUTOHEALED` / `FAIL` / `RECOVERED`).

## Policy & Residual Risk (t1210u / t1211u / t1218u)

- **No PG IP pin (rejected):** Do **not** pin `ipv4_address` on the `coolify`
  bridge network. Coolify overwrites standalone DB compose files when applying
  config changes, and Docker's default bridge IPAM has no reserved static range
  — if another container claims the pinned IP while PG is recreating (as
  `client-callbacks` claimed `10.0.1.2` in t1207u), Postgres fails to start
  (`Address already in use`), turning a recoverable worker reconnect into a hard
  database outage.
- **Residual risks, owners & mitigations:**
  1. *PG container UUID rename on full resource deletion/recreation*: container
     restart cannot update `DATABASE_URL`. **Mitigation:** watchdog detects
     `STALE-NAME`, skips restart, and pages `alexey@` + `dev@` to redeploy the
     app / update `DATABASE_URL` in Coolify. **Owner:** Coolify / Relay ops.
  2. *1–2 minute SQS retry window during PG recreate + worker restart*: in-flight
     SQS polls during the recreate minute return to queue until watchdog restart
     completes (~12s verify). **Mitigation:** SQS visibility timeout + redrive
     policy absorb single-minute retries without DLQ spill; CloudWatch
     `relay-production-ses-webhooks-oldest-message` + DLQ alarms provide
     external verification. **Owner:** DataOps (`machine-management`).
  3. *Host-local cron / MTA failure on contabo-b*: if `cron` or Docker daemon on
     `contabo-b` fails, host-local scripts cannot self-page. **Mitigation:**
     `contabo-a` (`169.58.119.163`) runs independent HTTP/content checks every
     5 minutes and VictoriaMetrics/Alertmanager scrapes cross-node exporters;
     AWS CloudWatch SES/SQS alarms page independently from AWS. **Owner:**
     DataOps (`machine-management`).

## Do not

- Do not pin `ipv4_address` on `pg-relay` or `pg-shared` in Coolify compose.
- Do not only restart PG (apps keep stale cache / closed connections).
- Do not equate a fresh `docker exec` TCP probe alone with worker recovery;
  always verify `probe_worker_progress` + SQL heartbeat/queue checks (`ALL_OK`).
- Do not paste `DATABASE_URL` secrets into tickets/reports/git.
