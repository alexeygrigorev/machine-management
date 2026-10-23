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
| **pg-shared** | `cmp`, `aisl`, `website` (one instance, separate DB names) | `PG_SHARED_CONTAINER` (or TCP `PGHOST_SHARED:PGPORT_SHARED`) |
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
| S3 `coolify/postgres/` | **14 days** via bucket lifecycle (`s3-lifecycle.example.json`, obs-aligned t1146u) |
| S3 `coolify/obs/` | **14 days** (VM/VL day archives — see coolify-observability `docs/retention-s3.md`) |
| Local node (pg dumps) | newest **1–2 days** (`LOCAL_KEEP_DAYS=2` + `LOCAL_KEEP_COUNT`), pruned by the script |
| Storagebox off-host copies | newest **14–30 days** (mirror of S3) via `prune-storagebox.sh` (dry-run default; `--apply` deletes) |
| In-script S3 prune | backstop only, default **OFF** (`S3_PRUNE_ENABLED=0`) |


## IAM / bucket (MAIN, 2026-10-22)

| Item | Value |
|------|-------|
| Bucket | `dtc-coolify-backups-387546586013` (`eu-west-1`) |
| IAM user | `coolify-s3-backup-writer` (prefix `coolify/*` only) |
| Keys | `~/.secrets/coolify-s3-backup-writer-2026-10-22.env` on Tabo + Hetzner; Coolify storage `dtc-coolify-backups` |
| Terraform | `DataTalksClub/aws-infra` → `main/coolify-backups/` (no access keys in TF) |
| Coolify UI storage | name `dtc-coolify-backups`, uuid `f8qhiqm4oe0p70yrnld5up17` (validated) |

## Secrets (never in git)

Real values live **only** in:

1. Private Drive doc *Contabo Coolify VPS — credentials 2026-10-22*, and
2. `/etc/coolify-pg-dump.env` on contabo-b (root-only `600`), plus operator
   hosts under `~/.secrets/` (`~/tmp/secrets` is a compat symlink).

## Enable

> Status 2026-10-22 (t1037u): Postgres **is** on Contabo (cutover done-ish):
> `pg-shared` (`ekm57…`, PG16, DBs `cmp`/`aisl`/`website`) and `pg-relay`
> (`mqime…`, PG16, DB `relay`) on contabo-b. Coolify scheduled dumps run
> ~06:00 Berlin. Enable the cron-script path below so the canonical S3
> layout is covered even if Coolify schedules change; enable basebackup + WAL
> per the CDC section.

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
| `prune-storagebox.sh` | 30d retention for Storagebox off-host copies (dry-run default, `--apply` deletes) |
| `coolify-pg-dump.cron` | `30 2 * * *` Europe/Berlin entry |
| `coolify-pg-dump.env.example` | placeholders for `/etc/coolify-pg-dump.env` |
| `install-coolify-pg-dump.sh` | operator-box installer (scp + cron, never overwrites env) |
| `coolify-cp-backup.sh` | **control-plane** job: `coolify-db` dump + encrypted `.env`/SSH-keys bundle → S3 |
| `coolify-cp-backup.cron` | `30 3 * * *` Europe/Berlin entry (one hour after app-DB dumps) |
| `coolify-cp-backup.env.example` | placeholders for `/etc/coolify-cp-backup.env` (+ `/etc/coolify-cp-backup.pass`) |
| `install-coolify-cp-backup.sh` | operator-box installer for the CP job (per CP host, never overwrites env) |
| `s3-lifecycle.example.json` | 30-day S3 retention rules for `coolify/postgres/`, `coolify/obs/` (14d), `coolify/control-plane/` |
| `coolify-pg-basebackup.sh` | weekly `pg_basebackup -Ft -z -X stream` → S3 `…/<stack>/base/…` (no restart needed) |
| `coolify-pg-basebackup.cron` | `0 3 * * 0` Europe/Berlin entry (same env file as dumps) |
| `coolify-wal-shipper.sh` | per-minute host cron: spool → gzip → S3 `…/<stack>/wal/…` with read-back |
| `coolify-wal-shipper.cron` | `* * * * *` Europe/Berlin entry for the shipper |
| `coolify-wal-archive.sh` | SUPERSEDED by the shipper (kept for reference): direct-upload helper that cannot run inside the Coolify PG container (no aws binary, no mounts) |
| `coolify-wal-enable.sh` | stages `archive_mode=on` etc. via ALTER SYSTEM; NEVER restarts (operator window) |
| `coolify-pg-replay.sh` | throwaway-DB replay drill: dump→restore or base+WAL PITR, census + timing |

## Control-plane backups (Coolify CP itself — live since 2026-10-22)

Each CP host (`contabo-a` .163, `contabo-b` .141) runs
`/usr/local/sbin/coolify-cp-backup.sh` nightly at `30 3 * * *`
Europe/Berlin (`/etc/cron.d/coolify-cp-backup`):

```
s3://<BACKUP_BUCKET>/coolify/control-plane/<contabo-a-163|contabo-b-141>/YYYY/MM/DD/coolify-db-<host>-<STAMP>.dump.gz
s3://<BACKUP_BUCKET>/coolify/control-plane/<host>/YYYY/MM/DD/coolify-deploy-inputs-<host>-<STAMP>.json   (sanitized, plaintext)
s3://<BACKUP_BUCKET>/coolify/control-plane/<host>/YYYY/MM/DD/coolify-cp-bundle-<host>-<STAMP>.tar.gz.gpg  (gpg-AES256)
```

The **manifest** (`coolify-deploy-inputs.sh`, sanitized — fingerprints, never
secret values) records Coolify resource metadata (apps/services/postgres/
servers + counts), git pins, running-image tag→digest pairs (e.g. website =
exact `dtc-website` commit SHA + `sha256:` digest, not floating `main`),
compose fingerprints, and a per-host config checklist. It is plaintext so
rebuild planning never needs the passphrase.

The **encrypted bundle** holds `coolify.env` + `.env.production`,
`ssh-keys/`, `deploy-inputs.json` copy, and the host-reconstruction inputs:
`host/wg/` (wg0.conf + keys), `host/bridge-compose.yml` (or `.ABSENT`
marker — data node only), `host/firewall-{ufw,iptables-v4,iptables-v6}.txt`
(live rulesets), `host/docker-10-wg.conf`, `host/sysctl-99-wg-bind.conf`,
`host/docker-daemon.json`, `host/systemd-units.txt`,
`host/proxy-compose.yml` + `host/proxy-dynamic/` + `host/acme.json`
(reconstruction copy; recurring plaintext TLS copies stay with the
backup-copies sibling schedule — no duplicate schedule here).

The passphrase lives only in `/etc/coolify-cp-backup.pass` (600) on the
nodes and the operator box (`~/tmp/secrets/` + `~/.secrets/`); human-held
second escrow (Drive doc / password manager) is an explicit open item for
Alexey. S3 retention: 30 d lifecycle (`coolify-control-plane-30d`); local
copies 7 d.

Isolated restore drill (operator box only, never on a CP host —
`contingency/coolify-cp-restore.sh` refuses live `coolify-db` / `/data/coolify`,
loopback-only throwaway Postgres, destroys container+volume+workdir after):

```bash
./contingency/coolify-cp-restore.sh --host-id contabo-a-163 [--date 2026/10/23] [--port 55439]
# → downloads 3 objects, verifies TOC + bundle checklist, restores into
#   throwaway postgres:15-alpine (pinned digest), cross-checks metadata
#   counts vs manifest, prints measured phases + RECOVERY_OK
```

Proven 2026-10-23: `contabo-a-163` RECOVERY_OK in 14 s (1 app, 4 services,
3 PG, 2 servers, auto_update=f, manifest MATCH); `contabo-b-141`
RECOVERY_OK in 13 s (empty CP + bridge=present, MATCH).

Coolify auto-update is **OFF** on both CP hosts
(`instance_settings.is_auto_update_enabled=false`); upgrades are manual.

## CDC: backup base + replay (t1037u, post-cutover)
Alexey's ask: if the database dies, take a backup and **replay everything**
onto a fresh DB. Mechanism chosen (2026-10-22):

| Option | Verdict | Reason |
|--------|---------|--------|
| Physical WAL shipping + weekly base + daily dump | **ADOPTED** | RPO minutes with zero app changes; DBs < 1 GB total; no new fleet |
| Debezium / Kafka / logical-decoding pipeline | Rejected | No stream consumers exist; new stateful fleet on 250 GB NVMe boxes for <500 MB DBs |
| RDS → Contabo logical replication | Rejected as forward path | Wrong direction post-cutover (Contabo is primary); was a pre-cutover dual-run tool only |
| Dump-only (daily `pg_dump`) | Kept as tier-1 (RPO ≤ 24 h) | Already running via Coolify ~06:00 Berlin; table-level restore; replay script proves it |

Resulting tiers:

| Tier | RPO | Path |
|------|-----|------|
| Dump restore | ≤ 24 h | daily dump (`coolify-pg-dump.sh` or Coolify schedule) → `coolify-pg-replay.sh --mode dump` |
| PITR to tip | minutes | weekly base (`coolify-pg-basebackup.sh`) + WAL spool/shipper (`coolify-wal-shipper.sh`) → `coolify-pg-replay.sh --mode pitr` |

WAL rollout order (each step is a Hub task; restart = operator window):

1. Install shipper + env on contabo-b (`coolify-wal-shipper.sh` →
   `/usr/local/sbin/`, `/etc/coolify-wal-archive.env` root 600, `coolify-wal-shipper.cron` →
   `/etc/cron.d/`). Rationale: the `postgres:16` container has no `aws` binary
   and Coolify mounts no helpers into it, so `archive_command` spools to
   `PGDATA/wal_spool` and the host shipper uploads to S3.
2. Run `coolify-wal-enable.sh --stack pg-shared --container <name>` (stages
   config, prints restart command). Same for `pg-relay`.
3. Maintenance window: `docker restart` per instance, verify `SHOW
   archive_mode;` = `on`, `SELECT pg_switch_wal();`, confirm WAL objects land
   in S3, then weekly basebackup cron.
4. PITR drill on Hetzner throwaway via `coolify-pg-replay.sh --mode pitr`
   before relying on it.

Status 2026-10-22 (t1143u): BOTH stacks live — `pg-shared` (`ekm57…`) and
`pg-relay` (`mqime…`) spool via the same `archive_command`
(`PGDATA/wal_spool`), and the per-minute shipper
(`WAL_STACKS="pg-shared pg-relay"` in `/etc/coolify-wal-archive.env`)
uploads to `s3://<bucket>/coolify/postgres/<stack>/wal/…` with S3
read-back (`/var/lib/coolify-wal-shipper/last-success-<stack>`; healthcheck
`WAL_STACKS` covers both). `pg-relay` was restarted once to activate
`archive_mode=on` (+ `wal_keep_size='1GB'` backstop, same as pg-shared);
`pg-shared` untouched. `coolify-wal-shipper.sh` now defaults to both
stacks (skips stacks with no spool dir yet).

CloudWatch dual-run: keep AWS CloudWatch while RDS still lives (default
there, no action); LGTM on Contabo is authoritative for Contabo Postgres.
Revisit at RDS decommission (human decision, separate Hub task).

## Backup freshness metrics (t1146u–t1153u)

Nightly Contabo path is **`pg_dump` `.dump.gz` → S3** (not parquet/SQLite).

| Piece | Role |
|-------|------|
| `monitors/coolify-backup-metrics.sh` | Every 5m on contabo-b: per-DB dump **export size bytes** + age, WAL last-success age, disk % → VictoriaMetrics `/api/v1/import/prometheus` |
| `monitors/coolify-healthcheck.sh` | Alerts `dev@dtcdev.click` on missing/stale dump, stale WAL, or `/` disk ≥ `DISK_WARN_PERCENT` |

Metric names: `coolify_backup_dump_size_bytes{db=…}`, `coolify_backup_dump_age_seconds`, `coolify_backup_wal_age_seconds`, `coolify_backup_disk_used_percent`.
