# Weekly Contabo → alt-host fast PG raise (RTO drill) — t1119u

**Timezone:** Europe/Berlin  
**Schedule:** **Sundays 04:30** (`CRON_TZ=Europe/Berlin`) on the **Hetzner** operator box.  
**Why that slot:** after Contabo nightly logical dumps (02:30) and offset from weekly `pg_basebackup` (Sun 03:00); quiet before Monday.

## What it does

1. Takes **fresh** `pg_dump -Fc` from live Contabo Coolify Postgres (`pg-shared`: cmp/aisl/website, `pg-relay`: relay) via `sudo docker exec`.
2. SCPs dumps to Hetzner, stages as `~/tmp/pg-fast-raise-weekly/dumps/<db>.dump`.
3. Runs timed `contingency/fast-pg-raise.sh` on **loopback only** (`127.0.0.1:55439`, container `pg-fast-raise-weekly`, `Restart=no`).
4. Pushes metrics into Contabo **VictoriaMetrics** (`contabo-a:8428`) via SSH localhost import.
5. Tears down the throwaway container/volume (`TEARDOWN=1` default).

**Hard guards:** no CF/DNS flip, no Coolify prod restart, no RDS touch. Distinct port from one-shot drills (`:55437` t1037u, `:55438` t1118u).

## Scripts

| Path | Role |
|------|------|
| `contingency/fast-pg-raise.sh` | Core raise (pinned `postgres:16.15-alpine`) |
| `contingency/weekly-fast-pg-raise.sh` | Orchestrator (dump → raise → metrics → teardown) |
| `contingency/push-dr-raise-metrics.sh` | VM import helper |
| `contingency/weekly-fast-pg-raise.cron` | Hetzner `/etc/cron.d/` unit |
| `monitors/dr-raise-stale-check.sh` | 8-day dead-man → email |
| `monitors/dr-raise-stale-check.cron` | contabo-a daily 09:00 |

## Metrics (VictoriaMetrics)

| Metric | Meaning |
|--------|---------|
| `dr_fast_pg_raise_rto_seconds{host,result}` | Wall-clock RTO of last run |
| `dr_fast_pg_raise_last_success_unixtime{host}` | Unix time of last **pass** |
| `dr_fast_pg_raise_ok{host}` | 1 pass / 0 fail |
| `dr_fast_pg_raise_db_bytes{host,db}` | Restored DB size bytes |
| `dr_fast_pg_raise_last_run_unixtime{host,result}` | Last attempt (pass or fail) |

**vmui** (WireGuard): `http://10.100.0.1:8428/vmui/`

Example queries:

```
dr_fast_pg_raise_rto_seconds
dr_fast_pg_raise_last_success_unixtime
dr_fast_pg_raise_db_bytes
time() - max(max_over_time(dr_fast_pg_raise_last_success_unixtime[8d]))
```

Note: VM default `search.latencyOffset` ≈ 30s — wait briefly after push before instant queries.

## Alert

`monitors/dr-raise-stale-check.sh` on **contabo-a**:

- Fires if metric **missing** or age **> 691200 s (~8 days)**.
- Searches samples over `STALE_SECONDS` (`[691200s]`, equivalent to `[8d]` by
  default). Weekly push metrics disappear from instant-query lookback between
  runs; the range keeps successes visible throughout the existing stale window.
- Email **only** `dev@dtcdev.click` via existing msmtp → SES (`alerts@dtcdev.click`).
- Deduped to at most once per day while still failing; sends RECOVERED on clear.

Read-only proof on contabo-a (queries real VM; sends no mail and changes no state):

```bash
sudo DRY_RUN=1 /usr/local/sbin/dr-raise-stale-check.sh
```

Exit 0 means fresh; exit 1 still means missing/unreadable or stale. Regression
checks: `bash monitors/tests/test-dr-raise-stale-check.sh`.

## Install

```bash
# Hetzner (as root or with sudo)
install -m 0755 contingency/weekly-fast-pg-raise.sh /home/alexey/git/machine-management/contingency/
# (prefer git pull of machine-management main)
install -m 0644 contingency/weekly-fast-pg-raise.cron /etc/cron.d/weekly-fast-pg-raise
mkdir -p /home/alexey/.local/state/dr-fast-pg-raise
chown alexey:alexey /home/alexey/.local/state/dr-fast-pg-raise

# contabo-a
sudo install -m 0755 monitors/dr-raise-stale-check.sh /usr/local/sbin/dr-raise-stale-check.sh
sudo install -m 0644 monitors/dr-raise-stale-check.cron /etc/cron.d/dr-raise-stale-check
sudo mkdir -p /var/lib/dr-raise-stale-check /var/log
# optional: echo ALERT_TO=dev@dtcdev.click | sudo tee /etc/dr-raise-stale-check.env
```

Manual one-shot (does not conflict with t1118u ports):

```bash
TEARDOWN=1 bash ~/git/machine-management/contingency/weekly-fast-pg-raise.sh
```

## Locking (single owner — fixed 2026-10-27)

- **Owner:** `contingency/weekly-fast-pg-raise.sh` itself (`flock -n` on
  `$LOCK`, default `/tmp/weekly-fast-pg-raise.lock`, held for the whole run).
- **Cron** (`weekly-fast-pg-raise.cron`) calls the script directly with NO
  outer `flock`. The 2026-10-22→25 outage was a double lock: cron held the
  same file via `/usr/bin/flock -n`, so the script's inner `flock -n 9`
  always failed and every Sunday run logged `another weekly raise is
  running` and exited 0 without doing anything.
- **Contended run** (a second instance while one holds the lock): logs
  `SKIP: another weekly raise is running (lock contended on ...)` and exits
  **75** (`EX_TEMPFAIL`). It exits before the raise/push stages, so it never
  pushes metrics and `last_success.env` is untouched — a no-op is
  distinguishable from `done result=pass` (exit 0).

## Seed from t1118u (2026-10-22)

Real-data raise already proved **~26 s** RTO (cmp 393 MB / aisl 133 MB / relay 270 MB / website 18 MB). Metrics were seeded from that success so the dead-man does not false-alert before the first Sunday cron.
