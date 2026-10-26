# Coolify workers left in Created: 2026-10-26

Hub intake: `4912c277-519d-47a9-b846-9e2c8432469c` (leave open).

## Cause and evidence

Website staging (`wodajblzizrjunwme3ossav3`, Contabo A) uses this dependency:

```yaml
services:
  web:
    command: [web-migrate]
    restart: unless-stopped
  worker:
    command: [worker]
    restart: unless-stopped
    depends_on:
      web:
        condition: service_healthy
```

Compose creates both containers, starts web, then waits for web health before
starting worker. If web fails its startup gate, Compose exits with a dependency
error and worker remains Created. Its restart policy does not start a container
that has never started. Starting worker directly bypasses the migration gate;
the watchdog is a recovery measure, not a successful deployment.

GitHub Actions run `40278733897` on website commit `0569d765` first set the
staging database assertions correctly and queued successful deployment
`hhoea2up5v4liprgjocxvyrr`. Its later legacy "Point prod" and "Trigger Coolify
deploy" steps used a secret UUID that actually targeted `website-staging`.
The trigger response names that application. They overwrote staging assertions
with `website` / `website_app` and queued `arasrj4hjyccyxom2mmah3hw`.
Staging still connected to `website_dev` / `website_dev`, so web's database
preflight exited with code 20 instead of serving the wrong database.

Nonsecret deployment/container evidence, all UTC:

| Time | Evidence |
| --- | --- |
| 06:18:15 | Legacy prod workflow step queues `arasrj4hjyccyxom2mmah3hw` for website-staging |
| 06:19:18.033102 | Coolify log: worker Created |
| 06:19:18.327398 | Coolify log: web Started, then Waiting |
| 06:19:34.329722 | Coolify log: web Error, dependency web failed to start |
| 06:19:34.337728 | Coolify log: dependency failed to start; web is unhealthy |
| 06:22:01 | Watchdog HEALED worker `055b90491f3c`, age 163 seconds |

Docker inspect reports that worker's creation at `06:19:18.007566209Z` and
start at `06:22:01.777663780Z`. The web log identifies the expected and actual
database/role mismatch. No credentials are needed to establish this cause.
Historical Docker events for this container had already expired from the
daemon's bounded buffer; use live collection during reproduction/verification.

Earlier failed deployments `i6fkzpmavsbg5thir4eijmy0` (October 25, 02:50:32),
`2gywopiywole7ggy8u5pntkd` (October 26, 02:54:06), and
`anxvyylymg4yzquskgbamwvy` (03:52:09) show the same unhealthy-web dependency
failure. The earlier missing-migration startup trigger was addressed by
website commit `5133ed83`; that does not prevent the later workflow from
corrupting database assertions. There is no evidence here of a Docker
multi-container start race.

## Repair and boundaries

The website staging workflow independently disables its three legacy prod
steps. They remain in the file pending authorized cleanup. Production is owned
by the existing health-gated rolling follower described in
[coolify-rolling-web.md](coolify-rolling-web.md).
Website implementation commit: `3c7ec3c919c3e24b56c65794131625ac1ae74bb8`.

The staging trigger now waits for the exact returned deployment UUID to finish,
rejects failure/cancellation, bounds API request time, and fails on timeout.
Public readiness must return HTTP success and the expected SHA. An old backend
serving the same SHA cannot satisfy the deployment completion gate.
Staging's primary database/role assertions were restored to `website_dev`.
The migration dependency, `cmp-created-watchdog.sh`, its two-minute cron, and
the healthcheck monitor remain unchanged and enabled.

The current CMP source stack `avcfd5kwb7cj9r1tx4ygjs6v` contains only web.
AISHL source `mekt9kz74fvbixla6olinuma` has independent web and worker services,
without a web-health dependency. Neither uses this website workflow, so neither
needed a configuration change or verification redeploy. A similar historical
symptom alone does not establish the same current cause.

## Verification

GPT-5.6-sol High independently approved the final workflow diff with no blocking
findings. Its request-timeout and cancellation-status suggestions were applied.
Extracted-shell behavioral checks cover exact deployment success, failed and
cancelled deployments, wrong UUID, polling timeout, HTTP 503 with a matching
SHA, wrong SHA, and healthy matching SHA. All passed. `git diff --check` passed;
actionlint passed with only its intentional constant-false warnings excluded.

Three consecutive staging deployments on website commit
`c6f1dd2f37bb7b2ef5a88b4ab73e3ee52f2b7606` passed:

| Deployment UUID | Worker ID | Created UTC | Started UTC | Seconds |
| --- | --- | --- | --- | --- |
| `giaysmf8qtcdp5okgc3rmiz4` | `34b3b2565b44` | 06:35:06.209841483 | 06:35:29.528052688 | 23.318211 |
| `ix9ojahhsdw7evd6hyvduzzi` | `f35f1a461fb0` | 06:36:43.507634395 | 06:37:02.840552000 | 19.332918 |
| `e8xoq5g5tcj2ssdnkkociqhf` | `d60e1ebf3208` | 06:38:16.715481447 | 06:38:36.540576489 | 19.825095 |

These are worker creation-to-Running times, excluding checkout/build. Every
deployment finished, web was healthy, and public readiness returned HTTP 200
with the expected SHA. Live Docker events independently confirm the transitions:

```text
1792996506237160924 create worker-wodajblzizrjunwme3ossav3-20261026T063419 34b3b2565b44
1792996529798522263 start  worker-wodajblzizrjunwme3ossav3-20261026T063419 34b3b2565b44
1792996603530621581 create worker-wodajblzizrjunwme3ossav3-20261026T063557 f35f1a461fb0
1792996623125355504 start  worker-wodajblzizrjunwme3ossav3-20261026T063557 f35f1a461fb0
1792996696741878158 create worker-wodajblzizrjunwme3ossav3-20261026T063732 d60e1ebf3208
1792996716821908500 start  worker-wodajblzizrjunwme3ossav3-20261026T063732 d60e1ebf3208
```

The event timestamps are nanoseconds since epoch. Docker's creation and start
event emission follows the corresponding inspect state timestamps slightly.
The operator report retains the events with full container IDs.
The unchanged watchdog logged `OK checked=0 stuck=0` at 06:36:01 and 06:38:01,
with no intervention in the 06:34:04–06:38:48 proof window. Its grace period
remained 120 seconds, well after these workers started. Installed SHA256:

- `/usr/local/sbin/cmp-created-watchdog.sh`:
  `91b891d62576d4a1b3fe4f070afbe10a7a50dfd80d9a147acfe35d735658a43d`
- `/etc/cron.d/cmp-created-watchdog`:
  `91106b6fd2e7cc3b5452f64289426b88a1f0854f6a24f717b71dfa695623b6ee`

Live staging proof is collected in the operator report
`~/tmp/agent-reports/coolify-created-rootcause-2026-10-26.md`, including Docker
create/start events and watchdog log excerpts. If Hub storage rejects the
append, that report preserves the pending intake note. No explicit/manual
deletion command, production redeploy request, or file/branch deletion was
performed; staging used Coolify's normal managed replacement lifecycle.

For a future incident, collect only allowlisted Docker event fields, inspect
web startup errors and Compose dependencies, and correlate the exact Coolify
deployment with its workflow target. Do not dump runtime environments or raw
deployment commands, which can contain secrets. Preserve the health gate and
watchdog while correcting the failed prerequisite.
