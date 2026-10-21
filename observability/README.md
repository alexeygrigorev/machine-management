# Observability (pointer)

Canonical **design / SOP** for Coolify Contabo logs, metrics, and traces lives in
private knowledge:

`DataTalksClub/dataops-knowledge` →
`content/10-engineering-and-automation/operate-production-systems/sops/coolify-prod-observability-lgtm.md`

## Phase rules (do not invert)

| Phase | Rule |
|-------|------|
| Migration / Tabo ~90 min cutover | **Healthchecks only** (Coolify DB + services, external HTTPS, disk). **No** LGTM install. |
| After cutover | Full LGTM (self-host on Contabo `.163` preferred long-term; Grafana Cloud Free OK as bootstrap). Alerts → `dev@datatalks.club`. |

## Hosts (inventory only)

See [`../inventory/hosts.md`](../inventory/hosts.md):

- `169.58.119.163` — contabo-a (apps / Coolify UI) — preferred place for Grafana/Loki/Prom
- `169.58.124.141` — contabo-b (Postgres) — exporters only; scrapes from `.163`

Agents on Hetzner are **not** the primary telemetry backend.

No secrets. No purchases from this repo.
