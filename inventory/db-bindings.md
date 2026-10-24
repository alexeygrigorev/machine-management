# Coolify DB bindings — dev vs prod isolation (t1143u dev-isolation, 2026-10-23)

Live matrix verified via Primary Coolify API + Traefik label inspect +
Host-header probes. **No secret values here** — users/hosts/DB names only.

Project `dtc-prod`, envs: `production`, `staging`.

## Serving-route separation (AC: no prod container serves a dev hostname)

| Hostname | DNS → | Before (23 Oct ~13:30 CEST) | After | Proof |
|---|---|---|---|---|
| `dev.courses.datatalks.club` | 169.58.119.163 | 200 from `cmp-staging` → prod `cmp` | **503 no-route** (Host rule removed from service, container redeployed with fresh labels) | `curl --resolve … /ping` → 503 + label inspect |
| `dev.aishippinglabs.com` | 169.58.124.141 | 200 from `aisl-staging` → prod `aisl` | **503 no-route** (Host rule removed, redeployed; web+worker healthy) | same |
| `dev.datatalks.club` | CloudFront → `origin.website` → .163 | 200 from `website-staging` → prod `website` | **200 isolated dev** (routes to `website-dev-web` backed by `website_dev` DB; dev guard retired; CF https-only) | direct unauth 403, auth/CF 200 |
| `dev.relay.datatalks.club` | CloudFront (not Contabo) | `relay-dev` → `relay_dev` (already isolated) | unchanged | out of scope, untouched |

Prod serving intact: `courses` 200, apex/`www`/`prod.aishippinglabs` 200,
`prod.datatalks.club` (via CF) 200. All Coolify statuses `running:healthy`.

## DATABASE_URL bindings (unchanged by this turn — still prod DBs by design)

| Object | User/host/db |
|---|---|
| `cmp-staging` svc | `cmp_app` @ `10.100.0.2` / `cmp` |
| `aisl-staging` svc | `aisl_app` @ pg-shared / `aisl` |
| `website-staging` app | `website_app` @ `10.100.0.2` / `website` |
| `website-dev-web` svc | `website_dev` @ `10.100.0.2` / `website_dev` |
| `relay-staging` svc | `relay_app` @ pg-relay / `relay` (least-privilege, t1037u) |
| `relay-dev` svc | `relay_dev` @ pg-relay / `relay_dev` |

CONNECT privilege matrix from t1037u still holds (per-role only, `PUBLIC`
revoked on all app DBs).

## `_dev` databases (migrated this turn, ready for future dev stacks)

| DB | Owner | Tables (23 Oct) | vs prod |
|---|---|---|---|
| `cmp_dev` | `cmp_dev` | 45 | = prod `cmp` (45) |
| `aisl_dev` | `aisl_dev` | 235 | = prod `aisl` (235) |
| `website_dev` | `website_dev` | 166 | = prod `website` (166) |

Migrated with one-shot containers (staging env minus prod secrets; passwords
percent-encoded). Not seeded (no prod data copied — PII). Backup scope still
excludes `_dev` DBs (documented follow-up for backup-copies worker when dev
stacks hold data).

## Known impacts / follow-ups (not blockers)

- CMP daily `e2e-smoke-dev` (06:00 UTC) and AISHL scheduled playwright-dev
  target the dev hostnames → they will fail (no route) until retargeted at
  future isolated dev stacks. This is the accepted cost of closing dev→prod
  writes (those suites currently exercise production databases).
- AISHL `f2d6550` per-request-host crawler handling stays valid (prod-host
  behavior unchanged); dev-host branch is now unreachable until dev stacks land.
- `website-staging` redeploys fail pre-existing (curl-less runtime image vs
  Coolify in-container healthcheck; also failed 00:12/01:16 today before this
  turn). Guard file removal condition: container labels for
  `wodajblzizrjunwme3ossav3` no longer list `dev.datatalks.club`.
- Test: `edge/tests/test-edge.sh` §7 (dev no-route + prod serves), runnable
  from the operator box.
