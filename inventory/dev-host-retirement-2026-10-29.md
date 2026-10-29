# Dev website retirement: live inventory, 2026-10-29

Intake `57e5c607-9b5d-4396-a6e3-39b6c638b852` remains **OPEN and incomplete**.
Session: `hub-05db147b-10cf-41b6-a4f2-c90e7315e10e`.
Decision: no dedicated dev website host; use [local testing or an authorized
isolated preview](../deployments/website-development.md). This report does not
change that decision or claim retirement complete.

## Acceptance and remaining work

- AC1: reuse the options/cost/risk and original question in the private report
  `~/tmp/agent-reports/dev-host-decision-2026-10-26.md`. The t1468u no-host
  decision supersedes that question. No new hosting cost is authorized.
- AC2: current production latency targets remain reachable with trusted TLS;
  neither historical website dev hostname is a latency target. No monitor
  code/config changes or duplicate implementation. Ownership remains intake
  `f5d8e22b-ce60-401d-8e4d-1a2091d63567`. See the checks below and the parent
  `~/tmp/agent-reports/latency-monitoring-2026-10-25.md`.
- AC3: local alternative passes; public dev remains live. Retirement cannot
  safely use the old single-container plan: the current dev web and worker
  are Coolify-managed, and that application's source UUID participates in the
  production rollout. Preserve them under the operator's container rule.
- AWS access blocker: this session has no configured AWS profile, credentials,
  web-identity token or container credential URI. No AWS API calls were made;
  no attempt to use `main-temp`, static keys, another application's credentials
  or another session's environment. Current operator rules restrict AWS to
  sandbox, while the earlier report places the dev distribution in MAIN.
  An operator must supply a permitted execution route and resource-specific
  retirement authorization; sandbox access alone would not prove access to
  this distribution. Public DNS does not establish current account ownership.
- S1: refreshed live commands/outputs below. S2: independent review recorded
  in the intake follow-up. S3: keep OPEN; append a progress/blocker note, never
  DONE while AC3 lacks retirement proof. Deploy run: none, documentation only.

No host configuration, database, container, DNS or edge distribution was
changed. No test containers or artificial load were created.

## Refreshed resource boundary

These are candidates for a future authorized plan, not deletion instructions.

| Resource | Current evidence and required boundary |
| --- | --- |
| `website-dev-web` on contabo-a | Still running, image `dtc-website:4d8f93ecc3b310c52b74c0e4efdb4c9bf5d987e7`, development settings, `website_dev`. Compose directory `/data/website-dev`, file `docker-compose.yaml`, restart `unless-stopped`, no mounts reported by inspect. Stopping it alone does not retire the public dev site. Check unique data and recovery material first. |
| Coolify `website-staging`, `wodajblzizrjunwme3ossav3` | Current `web-...-20261028T130108` and `worker-...-20261028T130108` are managed by Coolify and both use `website_dev` at `10.100.0.2`. Web carries `Host(dev.datatalks.club)`. Preserve both; any future control-plane change needs a reviewed deployment plan. |
| Production rollout dependency | `deployments/coolify-rolling-web.json` uses `wodajblzizrjunwme3ossav3` as the website `source_uuid`, with destination `nax9srpks6z7w1jgpebiuwuo`. Resolve that dependency and workflow triggers before proposing retirement of the source application. Production container currently uses `website`, not `website_dev`. |
| pg-shared `website_dev` database/role | At least three running container configurations reference the database. Do not drop it. Actual live sessions, unique data, verified backup and all consumers still need inventory before authorization. No role privileges or table contents audited in this session. Preserve `website`, production roles and backup systems. |
| `/data/coolify/proxy/dynamic/origin-enforce.yml` | Four `origin-websitedev-{allow,deny}-{http,tls}` routers target `http-0-wodajblzizrjunwme3ossav3-web-2567@docker`. `website-dev-backend` remains declared but is not these routers' target. Shared `origin-website-*` and `origin-websiteprod-*` target the production Docker service. Preserve production routes, enforcement credentials, ACME and shared origin hostname. |
| CloudFront `E33FS79KPFSAOM` and `dev.datatalks.club` records | Distribution ID/account attribution are historical evidence from 2026-10-26, not freshly verified through AWS. DNS still resolves and public readiness is 200. Need permitted inventory/export, exact hosted-zone/record sets, distribution aliases/origins and disable/wait/removal plan. Preserve production distribution `E1VNMGFFIXBOXX`, certificates and unrelated DNS. |
| Triggers and repo expectations | Inventory current website workflows, Coolify hooks, source dependencies and recovery configuration privately before any cutover. Refresh edge tests and live-state docs only after an authorized change. Preserve historical evidence and secrets. |

Required completion proof: production TLS/readiness stays green throughout;
the approved dev routes/resources stop serving and DNS/edge/container/DB
inventory agrees with the approved final state. Backup and rollback material
must be verified first. Do not treat an unexplained HTTP failure as retirement.

## Live DNS, TLS and readiness

Observed 2026-10-29 around 05:34–05:37 UTC from Hetzner. No `-k` used.

```text
$ dig +noall +comments +answer dev.datatalks.club
status: NOERROR, ANSWER: 4
dev.datatalks.club. 60 IN A 13.33.235.41
dev.datatalks.club. 60 IN A 13.33.235.111
dev.datatalks.club. 60 IN A 13.33.235.42
dev.datatalks.club. 60 IN A 13.33.235.117
$ dig +noall +comments +answer web.dtcdev.click
status: NXDOMAIN, ANSWER: 0
$ curl --fail-with-body --silent --show-error --max-time 20 --write-out '\nHTTP %{http_code}; TLS verify %{ssl_verify_result}\n' https://dev.datatalks.club/health/ready
{"status": "ready", "version": "20261028-125923-6dfc9ea", "source_sha": "6dfc9eae3bd14d2fa61ab109f77359e685e6e9cf", "image_digest": "sha256:a60ac57203076a821e54aab8c6733fc88eb924afc5377e6b7eed764c03d4f30a", "checks": {"configuration": {"status": "ok"}, "database": {"status": "ok"}, "migrations": {"status": "ok"}}}
HTTP 200; TLS verify 0
$ curl --fail-with-body --silent --show-error --max-time 20 --write-out '\nHTTP %{http_code}; TLS verify %{ssl_verify_result}\n' https://prod.datatalks.club/health/ready
{"status": "ready", "version": "20261028-125923-6dfc9ea", "source_sha": "6dfc9eae3bd14d2fa61ab109f77359e685e6e9cf", "image_digest": "sha256:a60ac57203076a821e54aab8c6733fc88eb924afc5377e6b7eed764c03d4f30a", "checks": {"configuration": {"status": "ok"}, "database": {"status": "ok"}, "migrations": {"status": "ok"}}}
HTTP 200; TLS verify 0
```

## Container and route inspection

Read-only `ssh -o BatchMode=yes -o ConnectTimeout=10 contabo-a` commands:

```text
$ sudo docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | grep -E 'website|pg-shared|coolify-proxy'
worker-wodajblzizrjunwme3ossav3-20261028T130108 dtc-website:6dfc9eae3bd14d2fa61ab109f77359e685e6e9cf Up 17 hours (healthy)
web-wodajblzizrjunwme3ossav3-20261028T130108 dtc-website:6dfc9eae3bd14d2fa61ab109f77359e685e6e9cf Up 17 hours (healthy)
coolify-proxy traefik:v3.7 Up 2 days (healthy)
website-dev-web 8f71747467b6 Up 4 days (healthy)
$ sudo docker exec website-dev-web python -c 'import urllib.request; r=urllib.request.urlopen("http://127.0.0.1:8000/health/ready",timeout=10); print("container readiness",r.status)'
container readiness 200
```

For each of those website containers and the `nax9...` production container,
`sudo docker inspect <name>` was consumed by Python without printing raw JSON.
Only image, ownership label allowlist, `Host(...)` matches, and the parsed
DATABASE_URL hostname/database were printed; credentials were withheld:

```text
worker-wodaj...: coolify.managed=true; coolify.resourceName=website-staging
DATABASE_URL host 10.100.0.2 database website_dev
web-wodaj...: coolify.managed=true; coolify.resourceName=website-staging
router http-0-wodajblzizrjunwme3ossav3-web-2567 hosts ['dev.datatalks.club']
DATABASE_URL host 10.100.0.2 database website_dev
website-dev-web: compose project website-dev; compose working_dir /data/website-dev
DATABASE_URL host 10.100.0.2 database website_dev
production container nax9srpks6z7w1jgpebiuwuo-20261028T130317
database host 10.100.0.2 name website
```

`sudo python3` read `origin-enforce.yml`, printing only key names, Host matches
and service references, withholding credential-bearing rules. All four
`origin-websitedev-*` references returned
`http-0-wodajblzizrjunwme3ossav3-web-2567@docker`; all eight production/shared
origin router references returned
`http-0-nax9srpks6z7w1jgpebiuwuov3-web-2567@docker`.

## Monitoring audit and live targets

Read `/etc/coolify-healthcheck.env` and the installed
`/usr/local/sbin/coolify-healthcheck.sh` on both nodes through SSH and Python,
printing only lines starting `LATENCY_PROBES=`, `CONTENT_CHECKS=` or `APP_URLS=`.
Relevant live latency overrides:

```text
contabo-a:
LATENCY_PROBES="aisl_home=https://aishippinglabs.com/::aisl aisl_content=https://aishippinglabs.com/blog/what-does-an-ai-engineer-do::aisl relay_health=https://relay.datatalks.club/health/::relay website_home=https://datatalks.club/::website website_events_past=https://datatalks.club/events/past::website"
contabo-b:
LATENCY_PROBES="cmp_course=https://courses.datatalks.club/ml-zoomcamp-2026/::cmp aisl_home=https://aishippinglabs.com/::aisl aisl_content=https://aishippinglabs.com/blog/what-does-an-ai-engineer-do::aisl relay_health=https://relay.datatalks.club/health/::relay website_home=https://datatalks.club/::website website_events_past=https://datatalks.club/events/past::website"
Hetzner /home/alexey/.contabo-deadman.env (read using Python, only LATENCY_PROBES printed):
LATENCY_PROBES="cmp_home=https://courses.datatalks.club/::cmp aisl_home=https://aishippinglabs.com/::aisl aisl_content=https://aishippinglabs.com/blog/what-does-an-ai-engineer-do::aisl relay_health=https://relay.datatalks.club/health/::relay website_home=https://datatalks.club/::website website_events_past=https://datatalks.club/events/past::website"
```

Both nodes' content/HTTP checks also exclude `web.dtcdev.click` and
`dev.datatalks.club`; `dev.relay.datatalks.club` is a different application,
outside this retirement. The installed deadman default matches the repo's
seven production targets. No running monitor was invoked or alert sent.
The parent session is exited; a coordination message was durably delivered to
its workspace (`01a1862c-6736-7723-aa0f-a53c5a87ede8`), with no monitor edit.

For each URL below, ran the following command (2026-10-29T05:34:33Z):

```bash
curl --silent --show-error --location --max-time 20 --output /dev/null \
  --write-out 'HTTP %{http_code}; TLS %{ssl_verify_result}; final %{url_effective}; TTFB %{time_starttransfer}; total %{time_total}' "$url"
```

| URL | Actual output (all curl exit 0) |
| --- | --- |
| `https://courses.datatalks.club/` | HTTP 200; TLS 0; final https://courses.datatalks.club/; TTFB 0.355995; total 0.391758 |
| `https://courses.datatalks.club/ml-zoomcamp-2026/` | HTTP 200; TLS 0; final https://courses.datatalks.club/ml-zoomcamp-2026/; TTFB 0.475319; total 0.510497 |
| `https://aishippinglabs.com/` | HTTP 200; TLS 0; final https://aishippinglabs.com/; TTFB 0.587999; total 0.690788 |
| `https://aishippinglabs.com/blog/what-does-an-ai-engineer-do` | HTTP 200; TLS 0; final https://aishippinglabs.com/blog/what-does-an-ai-engineer-do; TTFB 0.399474; total 0.523028 |
| `https://relay.datatalks.club/health/` | HTTP 200; TLS 0; final https://relay.datatalks.club/health/; TTFB 0.351938; total 0.352031 |
| `https://datatalks.club/` | HTTP 200; TLS 0; final https://datatalks.club/; TTFB 0.212332; total 0.212382 |
| `https://datatalks.club/events/past` | HTTP 404; TLS 0; final https://datatalks.club/events/past/; TTFB 0.215788; total 0.215883 |

The final 404 is the latency parent's known timing-only target, not application
health proof. Dev home was separately 200/TLS 0. Retired `web.dtcdev.click`
returned curl exit 6, HTTP 000, `Could not resolve host`; TLS was not attempted.

## Local workflow smoke test

Used a disposable `git archive HEAD` of `/home/alexey/git/dtc-website` at
`7152914de575d459e47cdbfdb5d0f73a65607ff1`. A Python TemporaryDirectory held
the checkout and new SQLite DB. Used its existing `.venv/bin/python` directly
without dependency installation or a deployed `.env`. Environment matched the
runbook's local variables; loopback port was 18795. The subprocess server
process group was terminated in `finally` and the directory/database removed.

```text
$ python manage.py migrate --noinput
exit 0; migrations applied successfully
$ python manage.py check
exit 0; System check identified 2 issues (0 silenced).
community_base.kernel.W005: nested main landmarks
content.W001: local public media root holds no projection objects
$ python manage.py runserver 127.0.0.1:18795 --noreload
GET /health/ready 200 {"status": "ready", "version": "local-development-build-version-not-configured", "source_sha": null, "image_digest": null, "checks": {"configuration": {"status": "ok"}, "database": {"status": "ok"}, "migrations": {"status": "ok"}}}
GET / 200 noindex=noindex, nofollow
GET /courses/ 200 noindex=noindex, nofollow
server, temporary checkout and database cleaned
```

GETs used Python urllib against the live server. Warning text above is
abbreviated; both are existing warnings, not test failures. This proves local
boot/routing on the specified source and existing environment, not a fresh
`uv sync`, populated catalogue, signup/email workflow or full regression suite.
No preview was provisioned or certified.

## Validation and independent review

`git diff --check` passed. A Python check confirmed all relative Markdown links
in the three changed documents resolve and fenced code blocks balance.

Independent reviewer: GPT-6-astra, selected explicitly by the parent review
tool call; implementer: Codex GPT-6. Reviewed the tracked diffs, this new report
and the rolling deployment configuration. Result: **no actionable findings**;
no exposed credentials found. Reviewer confirmed that the docs preserve
Coolify containers, identify the production rollout dependency, distinguish
historical AWS attribution from current evidence, and leave retirement
incomplete. Reviewer independently repeated whitespace and link checks, but did
not repeat live infrastructure or local smoke checks. Reviewer shared the
parent's workspace-coordination identity and preserved its edit declaration.

This reviewed change only corrects documentation and records evidence. No
deployment or teardown run is claimed. The commit ID and publication receipt
are recorded in the intake progress note after commit creation.
