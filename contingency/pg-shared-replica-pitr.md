# pg-shared replica + PITR runbook

Primary: `pg-shared` (`ekm57uezdngrrscn0aqzidr8`, PG 16.15) on contabo-vps16-2 (.141).
Standby target: contabo-a (.163). State + proofs:
`~/tmp/agent-reports/dr-p1-pg-shm-replica-t1037u-2026-10-22.md` (plan + safe tune),
`~/tmp/agent-reports/contabo-wal-pitr-t1114u-2026-10-22.md` (WAL→S3 live).
Secrets: `~/tmp/secrets/` only (incl. `pg-shared-replicator.pw`). Never git.
Hard: no RDS delete, no DNS/CF flip, no reckless restarts.

## Already applied (2026-10-22, reload-only, no restart)

- `wal_keep_size='1GB'` (`ALTER SYSTEM` + `pg_reload_conf`, verified).
- `replicator` role (`REPLICATION LOGIN`; HBA already `scram-sha-256` for host TCP).
- `log_checkpoints=on` (was already on).

## WAL archiving — LIVE since 2026-10-22 ~14:29 CEST (t1114u, one short restart)

Design constraint found during rollout: the `postgres:16` container has NO
`aws` binary and Coolify mounts no helpers into it, so `archive_command`
CANNOT upload to S3 directly. Live mechanism (two stages):

1. `archive_command='cp %p /var/lib/postgresql/data/wal_spool/.%f.tmp && mv …/%f.tmp …/%f'`
   spools each 16 MB segment into `PGDATA/wal_spool` (atomic publish via `mv`;
   dir is host-visible through the docker volume).
2. Host cron `coolify-wal-shipper.sh` (`/etc/cron.d/coolify-wal-shipper`,
   `* * * * *`, root) gzips + uploads spooled segments to
   `s3://dtc-coolify-backups-387546586013/coolify/postgres/pg-shared/wal/<YYYY>/<MM>/<DD>/<segment>.gz`,
   with S3 read-back before deleting the spool copy.

Config that took effect on restart (verified `SHOW` + `pg_stat_archiver`):

- `archive_mode=on`, `archive_command=<spool cmd above>`, `archive_timeout='300'`
- `wal_level=replica`, `max_wal_senders=10`, `wal_keep_size=1GB`

Proof (no creds, paths only): first forced `SELECT pg_switch_wal()` → segment
`000000010000000000000024` → per-minute cron shipped it to
`coolify/postgres/pg-shared/wal/2026/10/22/…024.gz` (~3.0 MB gz).
`archive_timeout=5min` bounds idle-gap segments, so S3 sees a new object at
least every ~6 min even with zero writes = continuity signal.

Monitoring: shipper writes `/var/lib/coolify-wal-shipper/last-success-pg-shared`
per verified upload and logs `ERROR` for spool files older than 15 min.
Follow-up: wire staleness into `monitors/coolify-healthcheck.sh` (alert dev@
if no S3 object for the current hour +15 min, or spool stale).

Rollback (if archiving misbehaves):

```sql
ALTER SYSTEM SET archive_mode = 'off';
-- optional: also clear archive_command
ALTER SYSTEM RESET archive_command;
```

then Coolify → pg-shared → Restart (same <1 min window), verify
`SHOW archive_mode;` → `off`. Spool dir can stay (ignored by Postgres).
Re-enable = reverse + restart. `archive_mode=off` takes effect only after restart.

## Base backups (weekly, no restart needed)

- Cron `/etc/cron.d/coolify-pg-basebackup` (Sun 03:00 Europe/Berlin) +
  `coolify-pg-basebackup.sh` → `s3://…/coolify/postgres/pg-shared/base/<date>/`
  (base `.tar.gz` + `pg_wal` window tarball, retain newest 2 locally).
- First base proven 2026-10-22 (manual run, t1114u): `pg-shared-base-*.tar.gz`
  (~174 MB) + `pg-shared-pg_wal-*.tar.gz` in S3 under `base/2026/10/22/`.
- PITR chain = latest base + all `wal/` segments after the base start.
  Drill: `backups/coolify-pg-replay.sh --mode pitr` on a disposable host
  (Hetzner throwaway, loopback bind), quarterly.

## Build standby on .163 (no primary restart)

```bash
# 1) slot on primary (as pgadmin via docker exec on .141)
psql -U pgadmin -d postgres -c "SELECT pg_create_physical_replication_slot('standby_163')"
# 2) basebackup on .163 (~1.1 GB, seconds)
PGPASSWORD=$(cat ~/tmp/secrets/pg-shared-replicator.pw) pg_basebackup \
  -h 169.58.124.141 -U replicator -D /var/lib/pg-shared-standby \
  -Fp -Xs -P -R -S standby_163
# 3) start standby: docker postgres:16.15 pinned, --restart unless-stopped,
#    no public port; verify: primary pg_stat_replication has 1 row,
#    standby SELECT pg_is_in_recovery() = t
```

## Failover (.141 declared dead; human + Alexey sign-off)

1. `pg_ctl promote` (or `SELECT pg_promote()`) on standby; verify `pg_is_in_recovery()=f`.
2. Flip each app's `DATABASE_URL` to .163 (Coolify env change, staggered) — no DNS/CF.
3. After .141 recovers: reverse `pg_basebackup` to make it the new standby.
Rollback before promote: standby takes no writes — just delete it.

## Watch items

- Coolify 02:00 UTC schedule failed S3 upload on 2026-10-22 (`data/coolify/…` vs `coolify/*`
  IAM prefix); 05:43 manual + operator cron copies are in S3. Re-verify each 02:00 run via
  `GET /api/v1/databases/ekm57uezdngrrscn0aqzidr8/backups` until IAM/path fixed.
- With WAL+S3 live: RPO ≤ ~6 min (timeout-bound), RTO from base+WAL replay drill (pending quarterly drill).
  With standby (not yet built): RPO seconds, RTO minutes.
