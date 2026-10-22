# Observability (Contabo Coolify LGTM)

Canonical **design / SOP**: `DataTalksClub/dataops-knowledge` →
`content/10-engineering-and-automation/operate-production-systems/sops/coolify-prod-observability-lgtm.md`

## Phase rules

| Phase | Rule |
|-------|------|
| Migration / Tabo ~90 min cutover | **Healthchecks only**. **No** LGTM install. |
| After cutover | Full LGTM (self-host on Contabo `.163`). Alerts → `dev@datatalks.club`. |

## Installed (2026-10-22, t1005u)

Self-host on **contabo-a** `169.58.119.163` (Coolify service `lgtm`, uuid `5kwprwvtksvahhwerf5v2q8o`):

- Grafana + Loki + Prometheus + Alertmanager (Tempo **deferred** phase 2)
- Exporters on `.163` / `.141`: node_exporter, cAdvisor, Promtail; postgres_exporter on `.141` for pg-relay + pg-shared
- Configs live on hosts under `/data/lgtm/`; compose templates in [`lgtm/`](./lgtm/)

Grafana UI: `http://grafana.169.58.119.163.sslip.io` (admin password in Coolify env / operator secret store — **not** in git).

Prom/Loki/AM listen on WG `10.100.0.1` only.

## Hosts

See [`../inventory/hosts.md`](../inventory/hosts.md). Agents on Hetzner are **not** the primary telemetry backend.

No secrets. No purchases from this repo.
