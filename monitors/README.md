# Permanent continuous healthcheck (Postgres + services)

Frequent cron job that keeps watch over Coolify Contabo Postgres and apps
and emails **alexey@datatalks.club** and **dev@dtcdev.click** on failure — with dedupe so one outage
does not spam. This is the **continuous** monitor (every 5 min), unlike
[`backups/`](../backups/) which dumps daily.

## Schedule (Europe/Berlin)

| What | Value |
|------|-------|
| Cron | `*/5 * * * *` with `TZ=Europe/Berlin` (see `coolify-healthcheck.cron`) |
| Where | **contabo-b** runs both primary PG checks, public content, AISHL jobs, and dump/WAL freshness; **contabo-a** runs local CP/obs, disk and Created-container checks. Set `SKIP_BACKUP_CHECKS=1`, `SKIP_PG_*=1` and `SKIP_PUBLIC_HTTP_CHECKS=1` on a: primary PG/backups live on b, and b owns public-content paging to avoid duplicate mail. |
| Alternative | Coolify Scheduled Task on the node, same `*/5 * * * *` |
| Alert to | `alexey@datatalks.club,dev@dtcdev.click` (comma-separated) (repeat at most every `ALERT_REPEAT_MIN`, default 60 min, while still failing; recovery notice when an outage lasted at least `RECOVER_NOTIFY_MIN_SEC`, default 600 seconds) |

## What gets checked

| Check | How |
|-------|-----|
| **pg-shared** | `pg_isready` + `psql SELECT 1` via `PG_SHARED_CONTAINER` (`docker exec`), or TCP `PGHOST_SHARED:PGPORT_SHARED` when the container var is empty |
| **pg-relay** | same via `PG_RELAY_CONTAINER` / `PGHOST_RELAY:PGPORT_RELAY` (own instance, never shared) |
| **HTTP apps** | `curl` expects 2xx/3xx for each `name=url` pair in `APP_URLS`: Coolify UI, Relay, CMP, AISHL, website |
| **Content markers** | each `name=url::marker` triple in `CONTENT_CHECKS` must return 2xx/3xx **and** the body (lowercased, whitespace-stripped) must contain the marker verbatim — catches proxy-default-page / error-page-with-200 incidents that status-only checks miss |
| **AISHL jobs** | `CHECK_AISL_Q=1` on b checks recent failure count and age of the latest successful task with read-only, bounded SQL; real app failures remain red until repaired |
| **Host / containers** | root-disk usage and Created containers older than `CREATED_GRACE_SEC` on both nodes; node-exporter and cAdvisor scrape both hosts into VictoriaMetrics |
| **Backup freshness** | four DB dumps plus both stacks' WAL shipper success markers on b; these checks remain enabled there |

> Coolify `standalone-postgresql` uses `POSTGRES_USER=pgadmin` — there is no
> `postgres` role. Always use `PGUSER_*=pgadmin` (script default); `psql -U
> postgres` fails with `FATAL: role "postgres" does not exist` (incident
> 2026-10-22, pg-relay). When `PG_*_CONTAINER` is empty the script
> auto-resolves the container via the stable Coolify label
> (`coolify.resourceName=pg-shared|pg-relay`), so random uuid renames on
> redeploy do not break the check. Explicit names still win when set.

State (last status + last alert time per check) lives in `/var/lib/coolify-healthcheck/`
so alerts dedupe across runs. Exit `0` = all green, `1` = something failed
(cron output also lands in `/var/log/coolify-healthcheck.log`).

## Secrets (never in git)

Real values live **only** in:

1. Private Drive doc *Contabo Coolify VPS — credentials 2026-10-22*, and
2. `/etc/coolify-healthcheck.env` on the node (root-only `600`), plus operator
   hosts under `~/.secrets/` (`~/tmp/secrets` is a compat symlink).

This repo keeps **placeholders only** (`coolify-healthcheck.env.example`).

## Mail delivery

The script uses `sendmail` (or `msmtp`) on the node. Without an MTA it
**logs alerts only** and warns — so before relying on it:

1. `apt install msmtp-mta` (or equivalent) on the node.
2. Configure SMTP out-of-band (`/etc/msmtprc`, root-only `600`) with real
   relay credentials from the Drive secrets doc — never in git. The monitors use
   a dedicated msmtp account `alerts` sending `From: DTC Alerts <alerts@dtcdev.click>`
   and envelope sender `alerts@dtcdev.click` via sandbox SES SMTP `email-smtp.us-east-1.amazonaws.com`.
3. Force a failure (e.g. point one `APP_URLS` entry at a dead port) with
   isolated state and ops-only recipients, confirm transport acceptance,
   then restore the URL and healthy state.

## Enable (once targets exist on Contabo)

> Status today (2026-10-22): Postgres/apps may **not yet** be on Contabo —
> the migration cutover is owned by parallel agents. Ship this job now;
> enable it the day the nodes hold real targets. Do **not** invent green
> checks before then.

1. From an operator box (Hetzner RMTHZ):
   `./monitors/install-coolify-healthcheck.sh contabo-b`
   (repeat for `contabo-a` if you want the UI/app angle from the primary too).
2. On the node, fill `/etc/coolify-healthcheck.env` (real container names,
   DB names, public app URLs from the Drive doc); `chmod 600`.
3. Set up msmtp per above; test delivery with a forced failure + recovery.
4. Manual first run: `sudo /usr/local/sbin/coolify-healthcheck.sh` → log ends
   `ALL_OK`, state files appear under `/var/lib/coolify-healthcheck/`.
5. Confirm cron installed: `cat /etc/cron.d/coolify-healthcheck`; next hour
   check that `/var/log/coolify-healthcheck.log` shows regular `ALL_OK` lines
   (12 runs/hour at the default cadence).

Tuning: change `*/5` to `*/1`/`*/2` in the cron file for 1–2 min cadence
once SMTP + log volume look healthy.

## Files

| File | Purpose |
|------|---------|
| `coolify-healthcheck.sh` | the check (pg_isready + SELECT 1 + curl, deduped email alerts) |
| `coolify-healthcheck.cron` | `*/5 * * * *` Europe/Berlin entry |
| `coolify-healthcheck.env.example` | placeholders for `/etc/coolify-healthcheck.env` |
| `install-coolify-healthcheck.sh` | operator-box installer (backups + cron, migrates old shipped env defaults) |
| `coolify-proxy-networks.sh` | **proxy-attachment pager (2026-10-25)**: FAILs when `coolify-proxy` misses a service network a `traefik.enable=true` container routes; dev@ ONLY, same dedupe/recover |
| `coolify-proxy-networks.cron` | `*/5 * * * *` Europe/Berlin entry (pager; self-heal is the 2-min edge keeper) |
| `coolify-proxy-networks.env.example` | placeholders for `/etc/coolify-proxy-networks.env` (dev@ only) |
| `install-coolify-proxy-networks.sh` | operator-box installer (backups + cron, migrates old shipped env defaults) |
| `hetzner-disk-check.sh` | **Hetzner host-local disk pager (t1493u)**: every real mount (`/ /boot /data`; tmpfs/overlay/squashfs excluded; sshfs storagebox report-only, never paged) with free% (WARN <15 / CRIT <8), inode free% (WARN <10 / CRIT <5) and fills-within-24h linear trend (6h samples); prod `ALERT_TO`, drills `ALERT_OPS_TO` (dev@) only, 4h dedupe, one RECOVERED |
| `hetzner-disk-check.cron` | user-crontab `*/5 * * * *` entry pointing at the stable `/usr/local/sbin` copy |
| `hetzner-disk-check.env.example` | placeholders for `~/.hetzner-disk-check.env` (defaults are the prod values) |
| `install-hetzner-disk-check.sh` | Hetzner installer (stable path + user cron + live run; run on RMTHZ as your user) |
| `install-node-exporter.sh` | Hetzner node_exporter (apt, pinned to `127.0.0.1:9100` only, never public) |

## Proxy attachment pager (2026-10-25 relay-dev/cmp-dev incident)

`coolify-proxy` loses ephemeral `docker network connect` attachments on every
recreate (the proxy compose declares only `coolify`; Coolify service networks
like relay-dev `t9uu…` / cmp-dev `qjnp…` are attached out-of-band). The edge
keeper (`edge/ensure-coolify-proxy-networks.sh --apply`, `*/2` cron) heals and
declares them; this pager verifies independently and mails **dev@dtcdev.click
ONLY** (same 60-min repeat / RECOVERED rules as the main check) when the proxy
is still detached. It changes nothing and needs only docker + python3.

State lives in `/var/lib/coolify-proxy-networks/`, outside the main check's
pruned namespace. Old envs pointing at `/var/lib/coolify-healthcheck` are
safely redirected into its `proxy-networks/` subdirectory until reinstalled.
The installer migrates the old default state path and sender with backups,
preserves recipients, and keeps `/etc/cron.d/coolify-proxy-networks` separate
from the keeper's `/etc/cron.d/coolify-proxy-network-keep`.

Mail uses the working healthcheck transport: msmtp account `alerts`, explicit
envelope sender `alerts@dtcdev.click`, and `DTC Alerts` display name, with a
sendmail fallback. Failed sends retain state for retry, including recovery. As in the main check,
FAIL is immediate and RECOVERED is mailed for outages lasting at least 600 s
(`RECOVER_NOTIFY_MIN_SEC`); shorter recoveries update state silently.
Recipients are restricted to `dev@dtcdev.click`. An isolated drill can supply
`COOLIFY_PROXY_NETWORKS_ENV_FILE` with its own state/lock, a nonexistent
`PROXY_CONTAINER`, and `ALERT_SUBJECT_PREFIX='[DRILL coolify-proxy-networks]'`;
then set the drill container back to `coolify-proxy` to verify recovery.
This checks the real MTA without detaching an app or changing production state.

Install: `./monitors/install-coolify-proxy-networks.sh [contabo-a] [contabo-b]`
Test: `bash monitors/tests/test-coolify-proxy-networks.sh`


## Host roles (do not regress)

| Host | Role | Required env skips |
|------|------|--------------------|
| **contabo-b** `.141` | data node: Postgres, nightly `.dump.gz`, WAL shipper; sole on-node public HTTP/content pager | public checks **ON** (`SKIP_PUBLIC_HTTP_CHECKS=0`); `RECOVER_NOTIFY_MIN_SEC=600`; backup checks **ON** (`SKIP_BACKUP_CHECKS` unset/0); `WAL_STACKS="pg-shared pg-relay"` |
| **contabo-a** `.163` | Coolify CP + obs (VictoriaMetrics/Logs) | **`SKIP_PUBLIC_HTTP_CHECKS=1`** prevents duplicate public pages; `RECOVER_NOTIFY_MIN_SEC=600`. **`SKIP_BACKUP_CHECKS=1`** mandatory — dumps/WAL markers are not local (t1146u checks + t1209u false-FAIL storm). Prefer `SKIP_PG_SHARED=1` / `SKIP_PG_RELAY=1` when PG is docker-only on `.141`. |

`install-coolify-healthcheck.sh` never overwrites an existing `/etc/coolify-healthcheck.env`. After install on **contabo-a**, confirm `SKIP_BACKUP_CHECKS=1` is set before enabling mail alerts.

## Alert noise controls (t1273u/t1274u)

Real FAILs still email `ALERT_TO=alexey@datatalks.club,dev@dtcdev.click`
immediately. `RECOVER_NOTIFY_MIN_SEC=600` suppresses only RECOVERED mail
for outages shorter than ten minutes; the check returns to OK normally.
An outage lasting at least 600 seconds sends RECOVERED on the next green
run. Repeated FAILs retain the original outage start time.

Set `SKIP_PUBLIC_HTTP_CHECKS=1` on contabo-a and leave it `0` on contabo-b.
This covers both `APP_URLS` and `CONTENT_CHECKS`; loopback and WireGuard
probes continue on contabo-a. Database, disk and backup checks have their
own independent controls.

The off-Contabo deadman uses `ALERT_OPS_TO=dev@dtcdev.click` for both
FAIL and RECOVERED of `drill-forced` (`DEADMAN_FORCE_FAIL=1`). Real node
and external failures continue to use `ALERT_TO`. Keep `ALERT_OPS_TO` in
Hetzner's `/home/alexey/.contabo-deadman.env`; never put the force flag in
cron or the env file.

**Non-goal:** do not mute AISHL `http-aishl` or `content-aishl_home` FAILs,
or delay them with a FAIL streak. Deployment 503s belong to the
[aisl-zero-downtime intake](https://hub.dtcdev.click/#/intake/d9c11a67-c416-4c5c-84cc-92f0c3e2b543).

Offline verification (stubbed mail and network):
`bash monitors/tests/test-contabo-deadman.sh` (D7 verifies drill recipients)
and `bash monitors/tests/test-alert-noise.sh` (public dedupe, immediate
AISHL FAILs, recovery window).


## relay-pg-dns-watchdog (t1207u / t1218u)

Catches Coolify PG IP/DNS churn and stuck long-lived worker pools that leave
Relay workers with a stale resolve or broken DB session while PG itself is
healthy (t1205u → SQS age/DLQ). Runs **every 1 minute** on contabo-b;
auto-restarts dependents (cooldown-gated); alerts `alexey@datatalks.club,dev@dtcdev.click`.

### Three-layer verification (stronger than fresh TCP-only, t1218u)

Because a `docker exec` sibling TCP probe (`probe_from_container`) spawns a
new process that queries Docker DNS (`127.0.0.11`) afresh, `ALL_OK` on TCP
alone could previously coexist with a stuck long-lived PID 1 worker holding a
stale socket/pool or a crashed `db_worker` thread under `StatReloader`. The
watchdog now verifies all three layers before logging `ALL_OK`:

1. **Fresh DNS + TCP probe (`probe_from_container`)**: resolves `DATABASE_URL` /
   `POSTGRES_HOST` inside each dependent and opens a TCP connection to `:5432`.
2. **In-container running-worker progress probe (`probe_worker_progress`)**:
   - **Active socket peer match**: inspects `/proc/1/net/tcp{,6}` inside the
     container and verifies every `ESTABLISHED` / `SYN_SENT` `:5432` socket
     points to the live Postgres container's current IPv4/IPv6 addresses.
   - **Post-PG-recreate worker freshness**: ensures background workers
     (non-`web-*`) do not pre-date a Postgres container recreation
     (`dep.StartedAt < pg.StartedAt`).
   - **SES ingress batch progress**: checks `ses-ingress` current-lifecycle
     logs and fails if the latest `received=R deleted=D failed=F` batch had
     `deleted=0 failed>0`.
   - **DB exception classification** (hub intake 4140f58a): checks background
     workers (`db_worker`, `scheduler`, callbacks, imports) for DB exceptions
     after their latest `Starting ...` banner (catches `StatReloader` keeping
     PID 1 alive after the worker loop dies), ordered against the last
     successful unit of work (`state=SUCCESSFUL`, or an ingress batch with
     `deleted>=1`):
     - connection-class (`InterfaceError`, connection refused/closed, could
       not translate host name, server closed the connection, ...) **after**
       the last success -> restart;
     - handled per-task errors (`DeadlockDetected` / `SerializationFailure`)
       or an unrecognised `OperationalError` after the last success -> no
       immediate restart; deferred to `progress-task-queues` when that SQL
       check covers the worker's queue and database (and its query runs),
       else restart once `HANDLED_DB_ERROR_GRACE_SEC` (default `300`s) pass
       since the first such error without progress;
     - any DB error followed by a later success -> no restart.
     Each non-restart case logs `WARN check=dep-...` and sends one
     low-priority mail (`WARN handled DB error`, `X-Priority: 5`,
     `Importance: low`) per distinct error. App retry lines
     (`... hit a transient DB error ...; retrying ...`) are ignored.
3. **SQL task & heartbeat freshness (`check_pg_worker_progress`)**:
   - **`progress-scheduler-heartbeat`**: queries `relay_scheduler_heartbeat.ticked_at`
     (expected every 15s; fails and auto-restarts `scheduler-*` if age >
     `SCHEDULER_MAX_AGE_SEC`, default `180`s).
   - **`progress-task-queues`**: queries `django_tasks_database_dbtaskresult`
     for due `READY` tasks (`run_after <= NOW()`) and fails/auto-restarts the
     matching queue worker (`provider-events-worker-*` or `worker-*`) if
     `oldest_ready` exceeds `TASK_QUEUE_MAX_READY_AGE_SEC` (default `180`s).
     The restarted worker is the one whose `DATABASE_URL` uses the checked
     database (relay and relay_dev share one Postgres).

AUTOHEALED / FAIL mails carry `Pre-restart reason:` and `Post-restart result:`
as separate lines, so a heal shows why the restart happened.

### Multi-label coverage (t1143u)

`PG_LABELS` accepts several Coolify `resourceName` labels (e.g.
`PG_LABELS="pg-relay pg-shared"`). Each label resolves its own container and
dependent set. Because pg-shared has no `relay` database, the psql database
is resolved per label via `PG_DB_<label>` (`PG_DB_pg_shared=postgres`),
falling back to global `PG_DB`. Relay-only progress tables
(`relay_scheduler_heartbeat`, `django_tasks_database_dbtaskresult`) are
probed only where present (`to_regclass` guard), so the pg-shared branch
gets TCP + socket-peer + worker-freshness protection without false SQL
pages.

### Residual risk, owner & mitigation (no PG IP pin)

- **Policy**: Static `ipv4_address` pinning on the `coolify` Docker bridge is
  **rejected** (t1210u cancelled / t1211u synthesis): Coolify overwrites
  standalone PG compose on config changes, and unreserved bridge IPAM risks
  hard Postgres startup failure (`Address already in use`) if another container
  claims the IP during PG recreate.
- **Residual risks & mitigations**:
  1. *Idle workers with no active traffic or open socket* (e.g. `ses-ingress`
     between webhook bursts when no socket is open yet): mitigated by
     `RESTART_WORKERS_OLDER_THAN_PG=1` (proactively restarts background workers
     whenever `pg.StartedAt` is newer than `worker.StartedAt`) plus AWS
     CloudWatch alarms (`relay-production-ses-webhooks-oldest-message` and DLQ).
     **Owner**: DataOps / Relay ops (`machine-management`).
  2. *Coolify changes the PG container UUID hostname on full resource recreate*:
     restarts cannot rewrite `DATABASE_URL`; watchdog detects `STALE-NAME`,
     skips pointless restarts, and pages `alexey@` + `dev@` with the exact
     redeploy instruction. **Owner**: Relay / Coolify operator.
  3. *In-app Django DB connection management (`conn_max_age=600` without
     `close_old_connections()` in management command loops, and `db_worker`
     running without `--noreload`)*: ops watchdog auto-heals via container
     restart within ~1–2 min; app-level `close_old_connections()` / `--noreload`
     is tracked for the Relay repository as defense-in-depth. **Owner**: Relay
     app maintainer.

| File | Purpose |
|------|---------|
| `relay-pg-dns-watchdog.sh` | TCP + running-worker progress + SQL freshness probe; autoheal |
| `relay-pg-dns-watchdog.cron` | `* * * * *` Europe/Berlin |
| `relay-pg-dns-watchdog.env.example` | `/etc/relay-pg-dns-watchdog.env` |
| `install-relay-pg-dns-watchdog.sh` | scp + cron installer |
| `tests/test-relay-pg-dns-watchdog.sh` | regression test suite (TCP + stale pool + SQL progress) |
| `contabo-deadman.sh` | off-Contabo dead-man (Hetzner user cron): node reachability + check freshness + external markers |
| `contabo-deadman.cron` | `*/5 * * * *` user-crontab template (Hetzner, never Contabo) |
| `contabo-deadman.env.example` | `~/.contabo-deadman.env` (optional overrides) |
| `install-contabo-deadman.sh` | Hetzner-side installer (ssh/msmtp/cron checks, no secrets) |
| `tests/test-contabo-deadman.sh` | dead-man suite (unreachable/stale/marker/drill/recovery) |

SOP: `../contingency/relay-pg-dns-after-coolify-pg-redeploy.md`

Install: `./monitors/install-relay-pg-dns-watchdog.sh contabo-b`

## Independent off-Contabo dead-man

Hetzner user cron runs the stable `/usr/local/sbin/contabo-deadman.sh` copy
every five minutes. It checks both nodes over SSH plus public content from
outside Contabo. SSH has an overall deadline, including the remote command.
Freshness is the timestamp of the latest completed `ALL_OK` or `CHECKS_FAILED`
run, not the log's modification time: repeated lock-skip or partial output
must not hide a stuck monitor. A completed failing run is fresh; its actual
findings remain the on-node pager's responsibility. Unaccepted mail delivery
retains the previous state and retries on the next run, including recovery.

Install updates with `./monitors/install-contabo-deadman.sh` as the operator
user on Hetzner. SMTP configuration stays private. `DEADMAN_FORCE_FAIL=1`
proves the mail path with ops-only recipients; run normally afterward to
restore the drill state. To exercise freshness itself without stopping any
service or cron, use a temporary remote log containing an old terminal run,
an isolated local state/lock and env file, and **ops-only `ALERT_TO`**. Run
once, replace the fixture with a fresh terminal run, run again for recovery,
then remove the fixture and rerun the normal installed check. Never change
the production healthcheck log or leave a drill override in cron/env.

The weekly PG raise monitor uses an eight-day `max_over_time` query so recent
sparse push samples remain visible outside the instant lookback. Verify with
`DRY_RUN=1 /usr/local/sbin/dr-raise-stale-check.sh` on a; this leaves mail and
state untouched. Its query can only see samples retained by VictoriaMetrics
(currently two days of hot data); the window does not extend storage retention.

### DR stale-check alert transport

`dr-raise-stale-check.sh` sends through a chain: msmtp with the dedicated
`alerts` account (same proven SES path as `coolify-healthcheck`) first, then
`sendmail`, then the dedicated Contabo monitors Relay client (`sender`
`alerts`, `DTC Alerts <alerts@dtcdev.click>`) as a last resort. The first
working transport wins; a total failure exits non-zero, logs an explicit
error, and leaves dedupe state unchanged so the next run retries loudly.

Relay can only ever be the fallback here, never the primary: Relay sits
behind a CloudFront WAF whose managed body rules answer bare HTTP 403 to
request bodies containing `http(s)://` with an IP-literal host (reproduced
2026-10-27 with the exact cron bodies of 2026-10-25/26 — benign bodies are
accepted, `http://127.0.0.1:8428` and `http://93.184.216.34` are blocked).
Every real alert from this check contains the local vmui URL, so a
Relay-primary configuration fails silently on every firing. The Relay
fallback therefore sends a defanged body (`http://127.0.0.1:8428` becomes
`127.0.0.1:8428`); hostnames are untouched. Keep `/etc/relay-monitors.toml`
provisioned through Relay's admin/client API with `url` and `api_key`,
root-owned mode 0600. Never put the key in shell arguments, source control
or cron entries. `RELAY_MONITOR_CONFIG` and `DATAMAILER_BIN` can override
the paths for testing. Existing `ALERT_TO` recipients are preserved;
comma/space-separated recipients receive separate messages (one Relay
message each on the fallback leg).

`dr-raise-stale-check.sh --test-alert` sends a real source-specific proof only to
`dev@dtcdev.click` through the same chain, without querying VictoriaMetrics
or changing monitor state.
The Relay self-monitors (`relay-pg-dns-watchdog`, `coolify-healthcheck`, and
`contabo-deadman`) retain their independent direct SES SMTP transport.

## Hetzner host-local disk + node_exporter (t1493u)

Hetzner (RMTHZ) pages for its own disks from user cron (`*/5`, stable
`/usr/local/sbin/hetzner-disk-check.sh`, state under
`~/.local/state/hetzner-disk-check/`). Thresholds: free WARN <15% / CRIT <8%,
inode free WARN <10% / CRIT <5%, plus CRIT when the 6h linear trend fills the
disk within 24h. The first real WARN on `/` (~12% free) is expected and
correct — do not raise thresholds to hide it. Repeat at most every 4h, one
RECOVERED (flap-guarded). Prove the mail path with
`DISK_DRILL=1 /usr/local/sbin/hetzner-disk-check.sh` (dev@ only), then run
normally to clear. `install-node-exporter.sh` pins node_exporter to
`127.0.0.1:9100` for the follow-up vmalert intake; verify with
`curl -s 127.0.0.1:9100/metrics | grep node_filesystem_avail_bytes` and confirm
no non-loopback `:9100` listener (`ss -tln | grep :9100`).
