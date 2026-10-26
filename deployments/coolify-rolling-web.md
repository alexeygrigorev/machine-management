# Contabo production web: health-gated rolling replacement

Coolify 4.4.7 Compose Services run `docker compose up --force-recreate`.
There is no Compose Service setting that turns this into a rolling update.
`deploy.update_config.order: start-first` applies to Swarm, not standalone
Compose. Adding a second replica or a Traefik health check to a single
force-recreated Compose stack does not fix kill-before-start replacement.

Public production web now runs as native Coolify Applications. These start a
new container beside the current one, wait for health, and retain the current
container when the replacement fails. Docker health filtering and Traefik
active health checks gate traffic. An explicit pre-stop drain withdraws the
old backend before Docker terminates it. Retry and a short connection timeout
are additional protection; live tests demonstrated that they are insufficient
without draining.

## Resource ownership

| App | Public native Application | Private release/worker Compose Service | Node |
| --- | --- | --- | --- |
| AISHL | `w3mxfr6wzjnpg3hqaw3y0obq` | `mekt9kz74fvbixla6olinuma` | contabo-b |
| Relay production | `oascx5kjeimc0ivpttag9z3q` | `fjnzwomg8n42lztloo34just` | contabo-b |
| CMP production | `9gqubsq4lxubaxm27v1mtq9u` | `avcfd5kwb7cj9r1tx4ygjs6v` | contabo-a |
| DTC website | `nax9srpks6z7w1jgpebiuwuo` (Dockerfile Application) | `wodajblzizrjunwme3ossav3` (Compose Application, web + worker) | contabo-a |

The three private Services keep their existing `web` component name for
release validation, migrations, CMP scheduled `docker exec` tasks, and
compatibility with current CI/promotion pollers. They keep every worker,
environment variable, volume, image policy, network and scheduling rule.
Their web component has no domain in Coolify and explicitly disables Traefik:

```yaml
services:
  web:
    # Keep the existing image, command, environment, healthcheck and networks.
    labels:
      traefik.enable: "false"
```

This is an overlay, not a replacement Compose file. Component domain metadata
was cleared directly in Coolify's metadata model, avoiding managed-DNS cleanup
requests. No DNS or CloudFront configuration was changed. Saved/generated
Compose and actual recreated containers must all show `traefik.enable=false`.
Do not put production domains back on these private components.

The private release web remains an intentional extra container. This avoids
changing three independent CI pipelines or dropping workers/scheduled tasks
while moving public traffic onto native rolling replacement. The source
Service's Recreate/Restart actions can now replace its private containers
without stopping public web.

The website source is a Compose Application rather than a Compose Service.
A concurrent worker rollout converted its original Application to Compose,
which would have removed native rolling support. Its new worker is preserved
in that original resource, and public web has a separate native Application.
The source Application's top-level and per-service domains are unset in
Coolify metadata. Its checked-in Compose has no explicit proxy labels,
so future source deployments have no public web router. Do not put production
domains back on the release/worker resource.

## Release follower on Hetzner

[`coolify-rolling-web.json`](coolify-rolling-web.json) records the non-secret
production mapping and native settings. [`coolify-rolling-web.py`](coolify-rolling-web.py)
follows the healthy, actually running private web image, not the newest image
in a registry. Existing AISHL/CMP pollers and Relay's manual production
promotion remain the release authority. Relay dev is outside this mapping.

Each minute the follower:

1. Inspects the source container over SSH. If it is absent/unhealthy, public
   web stays on its current release.
2. Requires an immutable dated tag in the first three apps' expected image
   repository. For the website, require the healthy source's `dtc-website`
   image tag to be a full Git commit and pin the native Dockerfile build to it.
3. Verifies the control-plane drain-hook checksum and refuses native settings
   that prevent health-gated rolling replacement.
4. Skips queued/running deployments and makes no writes when already in sync.
5. Copies runtime environment changes as literal values through the Coolify
   API, without printing them or deleting any secret.
6. Updates the native image and requests one normal native deployment.

AISHL overrides `BOOT_MODE=web` and `RUN_MIGRATIONS=false` on public replicas.
Its private release container still migrates before becoming healthy, so a
new native image is not promoted before that release has booted successfully.
The public replica never accidentally starts qcluster through the legacy
`RUN_MIGRATIONS=false` dispatch. Existing worker ownership remains unchanged.
CMP's image also migrates on boot; this happens beside the old public replica
before health passes. All releases must use backward-compatible migrations.

The follower preserves native-only variables; source variable removal does
not delete credentials. Explicit credential retirement is a separate task.
Failures produce only a name and exception class, never API bodies or values.

The website's `destination_environment` also protects its production database
URL, transactional dry-run policy, Relay configuration, settings module, and
media reader credentials when the same keys exist on the development source.
These values are managed on the native
production Application through Coolify's normal encrypted environment path.
Each required value must already be nonempty and runtime-enabled there;
otherwise reconciliation fails before any environment/image write or deployment. Source values never
fill missing destination credentials. Keep Website development dry-run enabled
and production dry-run disabled under the approved policy, without copying
the development database URL.
`destination_environment_optional` prevents source values from filling or
overwriting optional production identity settings and AWS session tokens.
In particular, a source session token must never be paired with the destination's
permanent media reader key. Optional values may be absent at the destination.

## Native Application settings

The first three Applications use `Docker Image`, with the source container's
immutable image and runtime environment. The launch helper preserves the
source container's actual entrypoint/CMD in `ROLLING_ORIGINAL_ENTRYPOINT` and
`ROLLING_ORIGINAL_COMMAND`. The website uses a separate Dockerfile Application
with the same Git source and `./entrypoint.sh web` startup. Its automatic Git
deployment is disabled: the follower promotes only the commit already running
healthy in the original private web/worker Application. Build-secret flags are
preserved when mirroring changed environment values.

| Setting | Value |
| --- | --- |
| Published host ports | empty |
| Consistent/custom container name | disabled/empty |
| Fixed `--ip` / `--ip6` | absent |
| Health check | enabled, command type |
| Health command | `python /opt/coolify-healthcheck.py http://127.0.0.1:8099/ready` |
| Docker Run Options | `--entrypoint "python /opt/rolling-launch.py"` |
| Interval / timeout / retries | 2 seconds / 3 seconds / 60 |
| Start period | 45 seconds |
| Stop grace period | 45 seconds |
| Container network | existing external `coolify`, attached at creation |
| Container labels | manual mode; preserve the saved custom labels |

Coolify's deployment health polling waits through the start period; Docker
can report healthy earlier, allowing proxy discovery while the old instance
remains alive. The one-time routing migration used 180 seconds for this
coexistence window, then restored 45 seconds.

Create three Coolify file storages: `/opt/coolify-healthcheck.py` from
[`rolling-healthcheck.py`](rolling-healthcheck.py), `/opt/rolling-readiness.py`
from [`rolling-readiness.py`](rolling-readiness.py), and `/opt/rolling-launch.py`
from [`rolling-launch.py`](rolling-launch.py). Coolify persists and mounts them
for every replacement. All four images have Python;
do not depend on `curl`/`wget` existing in every image. Docker Run Options do
not support volume mounting in this Coolify version; use file storage.

Install their contents with the versioned asset installer:

```sh
python3 deployments/install-coolify-web-assets.py
python3 deployments/install-coolify-web-assets.py --apply
```

Each binding uses an exact host-file path under
`/data/coolify/rolling-assets/<application>/<sha256>/<filename>` and mounts it
at the corresponding `/opt` path. The installer preserves private rollback
metadata and does not restart containers. Update the manifest hashes when
changing helper code, install it, then deploy each native Application normally.
Verify the replacement's mount sources and in-container checksums before
acceptance. Coolify can retain an existing generated content file even after
its database content changes; updating content metadata alone did not install
the backlog fix in the running replicas. The follower checks host checksums
and exact storage bindings before promotion.

| App | Internal port | Health path |
| --- | --- | --- |
| AISHL | 8000 | `/ping` |
| Relay | 8000 | `/health/ready` |
| CMP | 80 | `/api/health/` |
| Website | 8000 | `/health/ready` |

AISHL `/ping` is a serving-process check, not a database readiness assertion.
Its entrypoint finishes Django initialization before binding Gunicorn; the
private release container completes migrations before promotion.

`ROLLING_APP_URL` points to the loopback application URL in the table. The
launch helper starts a small HTTP readiness process on internal port 8099,
then executes the original startup. A background probe checks that application
URL once per second with a two-second timeout. Startup requires a successful
probe; after startup, three consecutive failures withdraw readiness. This
avoids routing flaps from a single slow probe and prevents multiple Traefik
routers from issuing a burst of nested application checks. `/ready` reads
this cached state immediately; a drain marker overrides it immediately.
The HTTP readiness listener uses backlog 128. The stdlib default of five was
too small for AISHL's seven synchronized Traefik service checks plus Docker
health. Live diagnostics showed Traefik marking the backend DOWN while both
direct readiness and application probes returned 200; AISHL had 42 TCP listen
queue overflows, versus zero on the other three apps. The burst regression
test reproduces the default-backlog timeout and passes with backlog 128.
Neither the
application port nor the readiness port is published on the host. There is
no HTTP drain operation: the actuator runs only through local Docker exec.

Website public web also sets `GUNICORN_CMD_ARGS=--threads 4`. Its two worker
processes therefore use Gunicorn's threaded worker with eight request slots.
The follower's website environment override preserves this setting even if
the private source still uses synchronous workers. Slow page requests must
leave capacity for application health requests; overlap at deployment alone
does not prevent the sole steady-state backend from withdrawing when both
synchronous workers are occupied. See
[Gunicorn thread settings](https://gunicorn.org/reference/settings/#threads).
Do not increase readiness timeouts or suppress monitoring to hide saturation.

## Explicit pre-stop drain

Native Coolify waits for the replacement's health before stopping the old
container, but does not withdraw the old backend from Traefik first. This
left measured termination races even with retries. The tested 4.4.7
`ApplicationDeploymentJob` now invokes [`coolify-web-drain.py`](coolify-web-drain.py)
on the application host before stopping an old managed web replica.

The hook runs only after the replacement is healthy, and only for applications
using the readiness agent. The host actuator requires another healthy
container with the same `dtc.rolling-web.application` label. It waits three
seconds for replacement discovery, creates the old replica's local drain
marker, then waits six seconds (three active-health intervals). The old
application keeps serving in-flight requests during this period. Traefik
removes that backend after `/ready` returns 503. Only afterward does Coolify
send TERM and apply the 45-second stop grace. If the prerequisite fails, the
old container is retained.

[`patch-coolify-drain.py`](patch-coolify-drain.py) checks the complete original
job checksum and refuses an unreviewed source version. Install from Hetzner:

```sh
python3 deployments/install-coolify-drain.py
python3 deployments/install-coolify-drain.py --apply
```

The installer lints in the current PHP runtime, saves private rollback copies,
installs the actuator on both Contabo hosts and pins the control-plane image
to the tested 4.4.7 release. It mounts
`/data/coolify/custom/rolling/ApplicationDeploymentJob.php` read-only over
`/var/www/html/app/Jobs/ApplicationDeploymentJob.php` through the persistent
control-plane Compose override. It recreates only the control-plane container;
public web, databases and Traefik remain running. Automatic Coolify updates
were already disabled and remain disabled. Review/rebase the hook and rerun
the tests before a control-plane upgrade; never silently drop this mount.
The follower refuses deployments if the installed hook checksum changes.

## Traefik configuration

Install [`rolling-web-transport.yml`](rolling-web-transport.yml) on both
nodes as `/data/coolify/proxy/dynamic/rolling-web.yml`. The existing file
provider reloads this without restarting Traefik. It defines
`rolling-web@file` with a one-second dial timeout, so packets to an old
Docker address cannot consume the default long connection timeout.

Saved native Docker labels use the following settings for every numbered
HTTP/HTTPS load-balancer service. `<service>` is that native app's identifier,
not the retired Compose component's identifier:

```text
traefik.docker.network=coolify
traefik.enable=true
dtc.rolling-web.application=<native-application-uuid>
traefik.http.services.<service>.loadbalancer.server.port=<port>
traefik.http.services.<service>.loadbalancer.healthcheck.path=/ready
traefik.http.services.<service>.loadbalancer.healthcheck.port=8099
traefik.http.services.<service>.loadbalancer.healthcheck.hostname=localhost
traefik.http.services.<service>.loadbalancer.healthcheck.interval=2s
traefik.http.services.<service>.loadbalancer.healthcheck.timeout=1s
traefik.http.services.<service>.loadbalancer.serverstransport=rolling-web@file
traefik.http.middlewares.rolling-retry.retry.attempts=3
traefik.http.middlewares.rolling-retry.retry.initialinterval=100ms
```

Use `localhost` for the probe Host header: CMP rejects arbitrary backend IPs
through Django's host validation. HTTP health checks must succeed from the
proxy as well as from inside the container.

Native public routers have priority 110 and retain the existing domains,
entrypoints, TLS and gzip settings. Serving routers add `rolling-retry` to
their middleware list; HTTPS redirects keep their existing behavior.

The secret-bearing `origin-enforce.yml` file remains private. Its allow
routers keep priority 200 and their exact verification rules; deny routers
keep priority 150 and their middleware. Backend service references were
switched to the new native identifiers after those backends were healthy.
Every allowed-origin router also appends `rolling-retry@docker` to its
middleware list. This is required: these higher-priority routes bypass the
middleware on the normal Docker routers. Without it, an origin request can
still fail against a stale address at old-container removal. Verification
rules, deny rules and TLS settings are unchanged. Direct origin access
remains denied. Never commit the origin file.
The existing private `origin-verify-canary.yml` routes also reference the new
Relay backend; their verification and deny rules remain unchanged.

The current label namespace is `<native-application-uuid>v3`. When changing
load-balancer settings, give the new configuration a new label namespace for
the transition. Two containers advertising the same service name with
different load-balancer configuration can make Traefik reject the service.
Switch private origin-file references only once the new namespace is healthy,
before Coolify retires the old container. Subsequent image-only rolling
deployments reuse the stable namespace and identical service configuration.
For a future namespace migration, hold traffic on the old namespace until
the new load balancer has passed its first active health check through
Traefik, using a loopback-restricted temporary canary route. Docker health
alone is insufficient for that one-time cutover: a new higher-priority router
can otherwise become selectable before its first active check succeeds.
Readiness-agent adoption included brief AISHL 503 samples while the previous
synchronous probe was still serving. The final cached-readiness and draining
deployments were measured separately.

## Install the follower

On Hetzner, preserve existing cron entries and private credential files:

```sh
install -m 755 deployments/coolify-rolling-web.py /home/alexey/tmp/bin/coolify-rolling-web.py
install -m 600 deployments/coolify-rolling-web.json /home/alexey/.config/coolify-rolling-web.json
python3 /home/alexey/tmp/bin/coolify-rolling-web.py --config /home/alexey/.config/coolify-rolling-web.json
```

Require all four entries to say `in-sync` before adding the single line in
[`coolify-rolling-web.cron`](coolify-rolling-web.cron). Keep its `flock` lock.
The token and SSH key are read from the referenced private files; the script
does not contain credentials. Preserve the existing source/promotion pollers.

## Verification and rollback

Run the focused behavior tests:

```sh
python3 -m unittest discover -s deployments/tests -p 'test_*rolling*.py' -v
```

For a controlled native redeploy, collect public probes and Docker lifecycle
events. Verify replacement start, then healthy, then old readiness withdrawal,
the propagation wait, and old-container stop. The deployment must log
`Draining old web backend before termination.` For a live actuator check,
observe old `/ready` fail while its application endpoint still succeeds.
Verify the Coolify deployment messages `Rolling update started`,
`New container is healthy`, and `Rolling update completed`. Also recreate the
private source Service and verify public traffic remains on the native web.
Check the normal `http-aishl` monitor result, not just container health.

Use the checked-in acceptance runner for a fresh website replacement:

```sh
flock -n /home/alexey/.local/state/coolify-rolling-web.lock \
  python3 deployments/verify-coolify-rolling.py --app website \
  --url https://prod.datatalks.club/health/ready \
  --output /home/alexey/tmp/rolling-acceptance-UNIQUE --deploy
```

Coordinate the live deployment slot with other operators first. The existing
follower lock above serializes its cron with the measurement; it does not lock
Coolify's UI or other operators. The output directory must be new. The runner checks the installed hook,
versioned host assets, native eligibility, storage bindings and running helper
hashes before requesting a normal native deployment. It refuses an active
deployment or an unhealthy baseline. It samples public readiness approximately
every 300 milliseconds, including ten seconds before deployment and sixty
seconds after completion. It requires a different healthy replacement, Docker
events proving start then healthy then old drain then old termination, and at
least six seconds between drain and termination. Any non-200 response, timeout
or missing lifecycle proof fails acceptance. Sanitized probes, events and a
summary remain in the output directory even when the post-deploy check fails.
Lifecycle events stream from before deployment: querying Docker history only
after observation can lose early events to its bounded history buffer.
It does not automatically roll back a completed deployment after a failed
measurement. For CMP use `--app cmp --url
https://courses.datatalks.club/api/health/`; for AISHL use `--app aishl --url
https://aishippinglabs.com/ping`. Keep Relay on its slower measurement cadence.

On 2026-10-23 the replacement intake `131c6dea` found the original rolling fix
already landed at `6efd197`, with its final four-app acceptance at
15:16–15:24 UTC, after the reported 14:40/14:55 UTC website gaps. The concurrent
r3 recovery also found later readiness starvation from slow website pages and
landed the threaded serving override described above at `e82fe3e`. Missing old
Hub intakes or a stopped session are not evidence that the deployed fix is
absent. Check actual application ownership, installed helper checksums and raw
acceptance artifacts before reapplying configuration. The private dated
`coolify-rolling-0dt-orch1802` report records the independent follow-up.

Use cache-busting public probes for AISHL, CMP and the website origin. Relay
has a request-rate WAF rule: use a public probe every five seconds to avoid
turning the measurement into an intentional rate-limit block. High-frequency
origin probes, if needed, must keep origin credentials private.

Rollback a public release by pinning a previously healthy immutable tag in
the native Application and using a normal native deployment. Pause only the
new follower cron while doing so, otherwise it follows the promoted source
again. Preserve the old healthy public container until rollback is healthy.
Restore routing only from private pre-change snapshots after checking backend
readiness; enabling the original source domains reintroduces the Compose
recreate outage. Do not remove credentials, volumes, DNS records or ALBs.

## Incident reference

On 2026-10-23, Coolify activity 218 started at 14:02:02 Europe/Berlin and
errored at 14:02:15. Activities 219 and 220 started at 14:02:14 and 14:02:16,
finishing at 14:02:29 and 14:08:00. The production AISHL hostname was on the
single `web` component of the misleadingly named `aisl-staging` Compose
Service. Overlapping force-recreate operations removed the only web backend;
Traefik had no active load-balancer health gate. The public monitor observed
a real 503. `RUN_MIGRATIONS=true` and the long boot period extended the gap.
The separate creation-time network repair is preserved and is not this fix.

Website monitoring separately recorded readiness 503 responses at 14:40,
14:55 and 15:35 UTC, including one after the earlier rolling acceptance window.
At 15:35 the same native container was still running. Its access log shows
two synchronous workers handling slow event pages, including past-event
requests taking 6.08 and 6.40 seconds, while health completions paused.
Application health completions around the incident were 200. This supports
request starvation and readiness withdrawal, rather than a Compose replacement
gap, as the explanation for that later incident. Threaded serving capacity
addresses that additional failure mode. Preserve failed diagnostic samples
and record a separate post-change controlled replacement window.

Evidence, implementation test failures and final acceptance results are in
the private dated `coolify-rolling-0dt-t1287u` report under
`/home/alexey/tmp/agent-reports/`. They are not stored in knowledge.

References: [Coolify rolling updates](https://coolify.io/docs/applications/deployments/rolling-updates),
[Traefik load-balancer services](https://doc.traefik.io/traefik/reference/routing-configuration/http/load-balancing/service/),
[Traefik retry middleware](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/retry/).
