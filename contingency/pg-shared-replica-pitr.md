# pg-shared replica + PITR runbook

Primary: `pg-shared` (`ekm57uezdngrrscn0aqzidr8`, PG 16.15) on contabo-vps16-2 (.141).
Standby target: contabo-a (.163, 207 G free). Full plan + state:
`~/tmp/agent-reports/dr-p1-pg-shm-replica-t1037u-2026-10-22.md`.
Secrets: `~/tmp/secrets/` only (incl. `pg-shared-replicator.pw`), never git.
Hard: no RDS delete, no DNS/CF flip, no reckless restarts.

## Already applied (2026-10-22, reload-only, no restart)

- `wal_keep_size='1GB'` (`ALTER SYSTEM` + `pg_reload_conf`, verified).
- `replicator` role (`REPLICATION LOGIN`; HBA already `scram-sha-256` for host TCP).
- `log_checkpoints=on` (was already on). `archive_mode` still **off** (needs restart window).

## Build standby on .163 (no primary restart)

```bash
# 1) slot on primary (as pgadmin via docker exec on .141)
psql -U pgadmin -d postgres -c "SELECT pg_create_physical_replication_slot('standby_163')"
# 2) basebackup on .163 (~1.1 GB, seconds)
PGPASSWORD=$(cat ~/tmp/secrets/pg-shared-replicator.pw) pg_basebackup \
  -h 169.58.124.141 -U replicator -D /var/lib/pg-shared-standby \
  -Fp -Xs -P -R -S standby_163
# 3) start standby: docker run postgres:16.15 pinned, --restart unless-stopped,
#    no public port; verify: primary pg_stat_replication has 1 row,
#    standby SELECT pg_is_in_recovery() = t
```

## Failover (.141 declared dead; human + Alexey sign-off)

1. `pg_ctl promote` (or `SELECT pg_promote()`) on standby; verify `pg_is_in_recovery()=f`.
2. Flip each app's `DATABASE_URL` to .163 (Coolify env change, staggered) — no DNS/CF.
3. After .141 recovers: reverse `pg_basebackup` to make it the new standby.
Rollback before promote: standby takes no writes — just delete it.

## PITR (one short restart window, NOT yet done)

1. Window + Restart pg-shared via Coolify.
2. `archive_mode=on`, `archive_command='aws s3 cp %p s3://dtc-coolify-backups-387546586013/coolify/postgres/pg-shared/wal/%f'`, `archive_timeout='5min'`.
3. Weekly `pg_basebackup` → `coolify/postgres/pg-shared/base/` (keep 2); quarterly time-target restore drill on disposable host.

## Watch items

- Coolify 02:00 UTC schedule failed S3 upload on 2026-10-22 (`data/coolify/…` vs `coolify/*`
  IAM prefix); 05:43 manual + operator cron copies are in S3. Re-verify each 02:00 run via
  `GET /api/v1/databases/ekm57uezdngrrscn0aqzidr8/backups` until IAM/path fixed.
- Until PITR: RPO ≤24 h (dumps), RTO 24 s proven (`contingency/fast-pg-raise.sh` pattern).
  With standby: RPO seconds, RTO minutes.
