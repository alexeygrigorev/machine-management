# Coolify DB bindings — dev vs prod isolation (t1037u, 2026-10-22)

Live matrix verified via Primary Coolify API (`http://169.58.119.163:8000/api/v1`)
+ `psql` privilege probes. **No secret values here** — users/hosts/DB names only.

Project `dtc-prod`, envs: `production` (only `website-staging` app sits here —
see findings), `staging` (all four services).

## DATABASE_URL bindings (user/host/db — passwords in Coolify env store only)

| Coolify object | Env | User | Host | DB | DB owner | Role |
|---|---|---|---|---|---|---|
| `cmp-staging` (svc `avcfd5kw…`) | staging | `cmp_app` | `10.100.0.2` (WG bridge → pg-shared) | `cmp` (393 MB prod-data) | `cmp_app` | staging on prod DB (by design until cutover) |
| `aisl-staging` (svc `mekt9kz7…`) | staging | `aisl_app` | `ekm57uez…` (pg-shared, same-host net) | `aisl` (132 MB prod-data) | `aisl_app` | staging on prod DB (by design until cutover) |
| `website-staging` (app `wodajblz…`) | **production** ⚠️ | `website_app` | `10.100.0.2` → pg-shared | `website` (18 MB) | `website_app` | staging app in prod env (doc-only; move at cutover) |
| `relay-staging` (svc `fjnzwomg…`) | staging | `relay_app` (t1037u; was `pgadmin`) | `mqimefrt…` (pg-relay) | `relay` (269 MB prod-data) | `pgadmin` | least-privilege app role, DDL+DML verified |
| `relay-dev` (svc `t9uudl5i…`) | staging | `relay_dev` | `mqimefrt…` (pg-relay) | `relay_dev` (14 MB) | `relay_dev` | ✅ isolated dev binding (reference pattern) |

## CONNECT privilege matrix (t = allowed, enforced 2026-10-22)

pg-shared (`ekm57uez…`): each prod DB allows **only its owner app role**;
each `*_dev` DB allows **only its dev role**. `PUBLIC` revoked on all app DBs.
`postgres` maintenance DB intentionally left default.

| DB | `cmp_app` | `cmp_dev` | `aisl_app` | `aisl_dev` | `website_app` | `website_dev` |
|---|---|---|---|---|---|---|
| `cmp` / `cmp_seed_empty_*` | t | f | f | f | f | f |
| `aisl` / `aisl_seed_empty_*` | f | f | t | f | f | f |
| `website` | f | f | f | f | t | f |
| `cmp_dev` / `aisl_dev` / `website_dev` (empty, t1037u) | f | t¹ | f | t¹ | f | t¹ |

¹ each dev role only on its own dev DB.

pg-relay (`mqimefrt…`): `relay` → `relay_app` only (+`pgadmin` bypass);
`relay_dev` → `relay_dev` only. `PUBLIC` revoked on both.

## Dev targets created (t1037u, empty — for future `*-dev` services)

`cmp_dev` / `aisl_dev` / `website_dev` (owners `cmp_dev` / `aisl_dev` /
`website_dev`, passwords under `~/tmp/secrets/pg-dev-*.pw`, 600).
Pattern matches existing `relay` / `relay_dev` split.
Backup scope NOT yet extended (Coolify: pg-shared `cmp,aisl,website`, pg-relay
`relay`; mm cron same) — extend when dev DBs hold data worth keeping.

## Known latent overlaps (documented, NOT changed — DNS still AWS-side)

- Staging FQDNs claim prod hostnames (`courses.datatalks.club`,
  `aishippinglabs.com` + `www`/`prod`, `prod.datatalks.club`,
  `relay.datatalks.club`) and dev hostnames (`dev.*`) route to staging apps
  that write prod DBs. Zero live impact today (dev/prod DNS → AWS RDS/ALB).
  At cutover: move `dev.*` to `*-dev` services on `*_dev` DBs; keep prod
  hostnames only on prod services.
- `website-staging` lives in the `production` env (env_id 1) — move to
  `staging` env (or graduate to prod) at cutover.
- `postgres-exporter-relay` DSN points at `10.100.0.2:5432/relay` (pg-shared
  bridge has no `relay` DB) — observability sibling to repoint at pg-relay.

## Safety invariants (from task brief)

- No RDS delete, no DNS/CF flip — neither touched (only Coolify env PATCH +
  `restart` on `relay-staging`, staging-only).
- Rollback for relay-staging: PATCH `DATABASE_URL` back to `pgadmin` form +
  `POST …/restart`. Old superuser path remains available via `pgadmin`.
