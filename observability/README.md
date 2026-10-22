# Observability (Contabo Coolify)

**Live stack (2026-10-22):** VictoriaMetrics + VictoriaLogs + Vector — canonical repo
[`alexeygrigorev/coolify-observability`](https://github.com/alexeygrigorev/coolify-observability).

| Piece | Host | Notes |
|-------|------|-------|
| VictoriaMetrics `:8428` + VictoriaLogs `:9428` | contabo-a `.163` | vmui; **no Grafana** |
| Vector | `.163` + `.141` | Docker logs → VL; host_metrics → VM |
| Exporters | `.141` | node + postgres×2 (+ cadvisor) |
| coolify-healthcheck | both | [`../monitors/`](../monitors/) → `dev@dtcdev.click` |

## Retention + S3 (t1031u)

| Tier | Policy |
|------|--------|
| Hot local | VM/VL **`-retentionPeriod=2d`** on Contabo disk |
| Daily archive | day-before-yesterday → `s3://dtc-coolify-backups-387546586013/coolify/obs/{metrics,logs}/YYYY/MM/DD/` |
| S3 | **14 days** lifecycle on prefix `coolify/obs/` |

Job + docs live in **coolify-observability** (`scripts/obs-day-archive.sh`, `docs/retention-s3.md`).  
Bucket/IAM shared with Postgres dumps (`coolify-s3-backup-writer`, prefix `coolify/*`).  
Lifecycle example (postgres 30d + obs 14d): [`../backups/s3-lifecycle.example.json`](../backups/s3-lifecycle.example.json).

## Legacy LGTM

LGTM compose under [`lgtm/`](./lgtm/) is **historical** (torn down). Do not reinstall as primary.

## Hosts

See [`../inventory/hosts.md`](../inventory/hosts.md). No secrets in this repo.
