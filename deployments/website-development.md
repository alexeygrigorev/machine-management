# Website development without a dedicated host

Decision, 2026-10-26 (Alexey t1468u; intake
`57e5c607-9b5d-4396-a6e3-39b6c638b852`): use local testing or an isolated,
temporary Coolify preview. Do not provision a dedicated website development
host. Local testing is the available default; preview availability must be
verified for the particular application and release.

`web.dtcdev.click` was retired on 2026-09-02. Do not rebuild that AWS stack.
`dev.datatalks.club` is a different, existing deployment: `website-dev-web` on
contabo-a, isolated on the `website_dev` database. The decision does not mean
it has already been removed. Its retirement is **prep-only** in this intake;
preserve its container, database, credentials, DNS and CloudFront distribution.
See the [current bindings](../inventory/db-bindings.md) and
[origin TLS enforcement](../edge/origin-tls-enforce/README.md).

## Local workflow

Use a clean [dtc-website checkout](https://github.com/DataTalksClub/website),
Python 3.13 and `uv`. Run these commands from that checkout, in a shell without
deployed credentials or a deployed `.env` file:

```bash
uv sync --locked
export DTC_ENVIRONMENT=local
export DJANGO_SETTINGS_MODULE=website.settings.local
export DTC_SQLITE_PATH=.tmp/local.sqlite3
export DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1
export DJANGO_CSRF_TRUSTED_ORIGINS=http://localhost:8000
uv run --frozen python manage.py migrate --noinput
uv run --frozen python manage.py check
uv run --frozen python manage.py runserver 127.0.0.1:8000 --noreload
```

In another terminal:

```bash
curl --fail-with-body --show-error http://localhost:8000/health/ready
curl --fail-with-body --show-error --output /dev/null http://localhost:8000/
curl --fail-with-body --show-error --output /dev/null http://localhost:8000/courses/
```

Readiness must return HTTP 200 with `status: ready`. The pages can have an empty
catalogue on a fresh database; this verifies boot and routing, not populated
content or registration behavior. Local settings use SQLite and memory mail;
no AWS access or production database is required. Loopback HTTP is intentional;
this development server is not a public TLS endpoint. Stop it with Ctrl-C.

For application regression checks, follow the website's own CI entry points:

```bash
uv run --frozen python scripts/ci.py test-core
uv run --frozen playwright install chromium
uv run --frozen python scripts/ci.py test-playwright-core
```

Use synthetic accounts and data for writes. `make data` / `seed_local_data.py`
also checks an external reviewed course projection. In a clean checkout on
2026-10-26 it fails with `public-projection-unavailable` when that input is
absent; it is not a prerequisite for the boot checks above. Do not fetch a
production database or invent the missing projection to bypass that check.
Use the website's maintained local-data instructions for populated scenarios.
Missing public image files produce a separate hydration warning; the website's
[media runbook](https://github.com/DataTalksClub/website/blob/main/_docs/runbooks/public-media-objects.md)
describes hydration from public content checkouts without AWS credentials.

## Testing an authorized Coolify preview

Coolify documents separate preview domains and variables in its
[preview guide](https://coolify.io/docs/applications/deployments/preview-deployments)
and [environment-variable guide](https://coolify.io/docs/applications/configuration/environment-variables).
Those features alone do not prove this website has a usable preview.

1. Open the website application in Coolify and inspect Preview Deployments.
   Use a preview already authorized for this test and confirm its image/source
   commit and successful deployment. If none exists, use the local workflow.
   This runbook does not require opening a PR or enabling public PR deploys.
2. Confirm its database, role, storage and external services are isolated from
   production, with synthetic data and no production email/webhook delivery.
   Configure values in the **preview** variable group; do not copy production
   credentials. Do not use the production-backed `website-staging` release
   application as a writable preview despite its name.
3. Check the image's hostname contract before deploying: the currently reviewed
   `website.settings.development` accepts only the selected hostname in
   `deploy/development_target.py`, whose allowlist contains `web.dtcdev.click`
   and `dev.datatalks.club`. An arbitrary generated preview hostname will fail
   that contract. It needs a separately reviewed application change before use;
   do not work around it with production settings or `ALLOWED_HOSTS=*`.
4. Use the exact HTTPS URL shown for that preview, with working DNS, a trusted
   certificate, exact allowed host/CSRF origin, and `noindex, nofollow`. Do not
   repoint either historical dev hostname. Check readiness through the public
   route, then test the changed behavior with synthetic users.

```bash
# Set this to the authorized HTTPS preview origin, with no trailing slash.
# The placeholder is deliberately not a provisioned domain.
PREVIEW_ORIGIN=https://preview.example.invalid
curl --fail-with-body --show-error --max-time 20 \
  --write-out '\nHTTP %{http_code}; TLS verify %{ssl_verify_result}\n' \
  "$PREVIEW_ORIGIN/health/ready"
curl --fail-with-body --show-error --max-time 20 \
  --dump-header - --output /dev/null "$PREVIEW_ORIGIN/"
```

Require readiness 200, TLS verification 0 (never `-k`), and the noindex header.
Record source SHA, deployment ID, checks and behavior results without secrets.
A successful container health check alone does not prove the public route.
No website preview was provisioned or certified by this documentation change.
Any subsequent preview creation must include its own authorized cleanup plan;
this intake authorizes no resource deletion.

## Monitoring ownership

Latency monitoring remains owned by intake
`f5d8e22b-ce60-401d-8e4d-1a2091d63567` and the
[monitor scripts](../monitors/README.md). Keep its production probes; no retired
hostname or temporary preview belongs in permanent latency paging. No new probe
implementation or retargeting is required for this decision. The existing
`website_events_past` latency probe follows a redirect to a 404; that measures
timing and is not an application-health proof (see the parent intake report).

## Existing dev stack: retirement preparation only

Before a separately authorized retirement, refresh this exact inventory and
capture backups and rollback material privately. This is a plan, not a teardown
command sequence:

| Object | Proposed future change and boundary |
| --- | --- |
| contabo-a `website-dev-web`, `/data/website-dev/docker-compose.yaml` | Stop the dedicated dev web only after checking current ownership, mounts and unique data; retain recovery material. Preserve production web, workers and Coolify applications. |
| pg-shared `website_dev` database and `website_dev` role | Verify no consumers or unique data, create and verify a backup, then seek authorization for those two objects only. Preserve `website` and `website_app`. |
| Traefik dev routes and `website-dev-backend` in dynamic configuration | Inventory current keys and references before changing them; do not replay historical installer output. Preserve production routes, shared `origin.website.datatalks.club`, origin verification and ACME renewal. Remove only dev credential alternatives from shared rules after reviewing the rendered diff privately. |
| CloudFront `E33FS79KPFSAOM`, viewer `dev.datatalks.club` | Prepare disable/wait/record-removal order and exact DNS record set. No AWS calls are needed for this documentation change. AWS work must use separately available authorized credentials, never `main-temp`. Preserve production distribution `E1VNMGFFIXBOXX`. |
| Website deployment triggers and development environment references | Inventory the website repository's current workflows, Coolify hooks and consumers before disabling a dev target. Do not delete credentials, state, historical evidence or unrelated configuration. |
| This repo's inventory and edge expectations | Update live-state claims only after an authorized cutover, with independent review. Keep historical TLS/isolation evidence identifiable as history. |

Before and after any future authorized change, verify production website,
courses, AISHL and Relay TLS and health, and refresh the latency-parent evidence.
Use verified backups and saved routing/configuration for rollback. Do not declare
retirement complete until live DNS/edge/container/DB inventory agrees with the
approved resource list. Under this intake's prep-only rule all listed resources
remain untouched.
