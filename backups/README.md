# Daily Coolify `pg_dump` → S3 (keeps the "every day like now" cadence)

Cheaper DR path per the contingency SOP: **one cron run per day** dumps every
Coolify Postgres database to S3-compatible storage. This replaces the
SnapshotExport / Hetzner ~90GB daily dumps after cutover — **not** Contabo
panel Auto-Backup (out of scope for DR).

## Schedule (Europe/Berlin)

| What | Value |
|------|-------|
| Cron | `30 2 * * *` with `TZ=Europe/Berlin` (see `coolify-pg-dump.cron`) |
| Where | data node **contabo-b** (`169.58.124.141`) via `/etc/cron.d/coolify-pg-dump` |
| Alternative | Coolify Scheduled Task on the data node, same `30 2 * * *` |
| RPO | ≤ 24 h |

## What gets dumped (separately, per SOP)

| Stack | Databases | Container / port |
|-------|-----------|------------------|
| **pg-shared** | `cmp`, `aishl`, `website` (one instance, separate DB names) | `PG_SHARED_CONTAINER` (or TCP `PGHOST_SHARED:PGPORT_SHARED`) |
| **pg-relay** | `relay` (own instance, never shared) | `PG_RELAY_CONTAINER` (or TCP `PGHOST_RELAY:PGPORT_RELAY`) |

Exact DB/container names are set in `/etc/coolify-pg-dump.env` on the node —
this repo keeps **placeholders only**.

## S3 layout (canonical pattern)

```
s3://<BACKUP_BUCKET>/coolify/postgres/<pg-shared|pg-relay>/<dbname>/YYYY/MM/DD/<dbname>-<stack>-<STAMP>.dump.gz
```

Example: `s3://<BACKUP_BUCKET>/coolify/postgres/pg-shared/cmp/2026/10/23/cmp-pg-shared-20261023T0230+0200.dump.gz`

## Retention

| Location | Policy |
|----------|--------|
| S3 `coolify/postgres/` | **30 days** via bucket lifecycle (`s3-lifecycle.example.json`) |
| S3 `coolify/obs/` | **14 days** (VM/VL day archives — see coolify-observability `docs/retention-s3.md`) |
| Local node (pg dumps) | newest **7 days** (`LOCAL_KEEP_DAYS`), pruned by the script |
| In-script S3 prune | backstop only, default **OFF** (`S3_PRUNE_ENABLED=0`) |


## IAM / bucket (MAIN, 2026-10-22)

| Item | Value |
|------|-------|
| Bucket | `dtc-coolify-backups-387546586013` (`eu-west-1`) |
| IAM user | `coolify-s3-backup-writer` (prefix `coolify/*` only) |
| Keys | `~/tmp/secrets/coolify-s3-backup-writer-2026-10-22.env` on Tabo + Hetzner; Coolify storage `dtc-coolify-backups` |
| Terraform | `DataTalksClub/aws-infra` → `main/coolify-backups/` (no access keys in TF) |
| Coolify UI storage | name `dtc-coolify-backups`, uuid `f8qhiqm4oe0p70yrnld5up17` (validated) |

## Secrets (never in git)

Real values live **only** in:

1. Private Drive doc *Contabo Coolify VPS — credentials 2026-10-22*, and
2. `/etc/coolify-pg-dump.env` on contabo-b (root-only `600`), plus operator
   hosts under `~/tmp/secrets/`.

## Enable (once Postgres exists on Contabo)

> Status today (2026-10-22): Postgres is **not yet** on Contabo — the
> migration cutover is owned by parallel agents. Ship this job now; enable it
> the day the data node has real databases. Do **not** invent running dumps.

1. From an operator box (Hetzner RMTHZ):
   `./backups/install-coolify-pg-dump.sh contabo-b`
2. On contabo-b, fill `/etc/coolify-pg-dump.env` (real container names, DB
   names, bucket, endpoint, keys) from the Drive doc; `chmod 600`.
3. Apply the lifecycle rule from `s3-lifecycle.example.json` to the bucket.
4. Manual first run: `sudo /usr/local/sbin/coolify-pg-dump.sh` → log ends
   `ALL_DONE`, one S3 object per database.
5. Confirm cron installed: `cat /etc/cron.d/coolify-pg-dump`; next-day check
   that fresh `YYYY/MM/DD` objects exist for **every** database.
6. Run a restore drill (disposable DB) before DNS cutover — see below.

## Restore pointers

Full procedure: contingency SOP § DB restore (DataTalksClub/dataops-knowledge →
`coolify-prod-contingency-and-db-backups.md`). Quick pattern from any host
that can reach the object and the target Postgres:

```bash
aws s3 cp s3://<BACKUP_BUCKET>/coolify/postgres/pg-shared/cmp/<date>/cmp-pg-shared-<STAMP>.dump.gz /tmp/restore.dump.gz \
  --endpoint-url <endpoint>   # omit --endpoint-url for real AWS S3
gunzip -c /tmp/restore.dump.gz > /tmp/restore.dump
pg_restore --no-owner --no-acl -d "$DATABASE_URL" -v /tmp/restore.dump
```

Prefer restoring into a **new** DB name, switching the app `DATABASE_URL`,
then dropping the old DB after verification. Always `Back up now` after a
production restore so the next dump matches the restored state.

## Files

| File | Purpose |
|------|---------|
| `coolify-pg-dump.sh` | the daily job (dump → gzip → S3 → prune) |
| `coolify-pg-dump.cron` | `30 2 * * *` Europe/Berlin entry |
| `coolify-pg-dump.env.example` | placeholders for `/etc/coolify-pg-dump.env` |
| `install-coolify-pg-dump.sh` | operator-box installer (scp + cron, never overwrites env) |
| `s3-lifecycle.example.json` | 30-day S3 retention rule for the `coolify/postgres/` prefix |
