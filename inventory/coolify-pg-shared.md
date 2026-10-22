# pg-shared — Postgres 16 on contabo-vps16-2 (.141)

Shared Postgres for `cmp`, `aisl`, `website`. Created 2026-10-22 via primary
Coolify API (`http://169.58.119.163:8000`). **No secrets in this file** — values
live under `~/.secrets/` (chmod 600; `~/tmp/secrets` is a compat symlink) on the operator host.

## Coolify resource

| Field | Value |
|-------|-------|
| Name | `pg-shared` |
| Coolify uuid | `ekm57uezdngrrscn0aqzidr8` |
| Engine | `postgres:16` → 16.15 (Debian pgdg) |
| Project | `dtc-prod` (`jiayjv9m9koroe8wt4b4ykhx`), env `production` (`jywzt4x7qbikzummn04lq603`) |
| Server | `contabo-vps16-2` (`5dn3ejiqwkmvcwvf08drxarq` / 169.58.124.141) |
| Destination | `5daaeeunpkuxtyv6l8tw3yqs` (standalone, network `coolify`) |
| Public | no (internal-only, no public port) |
| Status at creation | `running:healthy` |
| Applied 2026-10-22 (t1143u) | `shm_size: 2g` via Coolify `custom_docker_run_options=--shm-size=2g` + API restart; `HostConfig.ShmSize=2147483648`, `shared_buffers=1GB`, `wal_keep_size=1GB`, still `running:healthy`. Full conf + evidence: `~/tmp/agent-reports/dr-p1-pg-shm-apply-t1143u-2026-10-22.md` |
| Superuser | `pgadmin` (pw: `~/.secrets/postgres-pg-shared-169.58.124.141.pw`) |

## Logical databases + owners (all unprivileged: NOSUPERUSER, NOCREATEDB, NOCREATEROLE)

| Database | Owner role | Owner pw file (`~/.secrets/`) |
|----------|------------|----------------------------------|
| `cmp` | `cmp_app` | `pg-shared-cmp-owner.pw` |
| `aisl` | `aisl_app` | `pg-shared-aisl-owner.pw` |
| `website` | `website_app` | `pg-shared-website-owner.pw` |

Each role owns its database (`CREATE DATABASE … OWNER …`); TCP password auth
verified for all three (`psql -h 127.0.0.1`).

## Backup

| Field | Value |
|-------|-------|
| Backup config uuid | `rtrym7uzkkbfxkpz84wst0ht` |
| Schedule | daily `0 2 * * *` (UTC), enabled |
| S3 | `save_s3=true` → storage `cwgvijajfjlcj6f5fh4ni0xb` (`dtc-coolify-backups-eu-west-1`, bucket `dtc-coolify-backups-387546586013`) |
| Scope | `dump_all=false`, `databases_to_backup=cmp,aisl,website` |
| Retention | 30 × S3, 7 × local |

## Explicitly NOT done (per brief)

- PG17 `dtc-postgres` (`glbxtdxkfhdwetll38lfb87r`) untouched — new DBs NOT placed there.
- `pg-relay` / Relay stack (owned by `coolify-relay-prep` session) — note: on 2026-10-22
  (t1143u) pg-relay got the same `shm_size=2g` + `shared_buffers=1GB` treatment as pg-shared
  (its staged 8 GB conf never ran and was scaled down to fit 2g shm); see
  `~/tmp/agent-reports/dr-p1-pg-shm-apply-t1143u-2026-10-22.md`. No other Relay changes.
- No DNS / CloudFront changes, no AWS RDS changes, no Coolify reinstall/session work.
