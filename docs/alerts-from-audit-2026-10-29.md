# Alert sender acceptance audit on 29 October 2026

Intake `55669c2f-d3a2-4d82-bf9b-36c815cc0f48` remains **OPEN**. The original
sender cutover is live, but current acceptance criteria are not all proven.
Other non-self-monitor SMTP sources still require Relay migration, the SMTP
user's IAM restriction is unverified, and individual Dapier notice paths still
lack their own receipt evidence. The DR routing gap was repaired and deployed
after the resumed criteria reasserted Relay delivery. No DONE note or legacy
sender removal is justified.

## Verified sender and delivery state

The [receipt evidence](alerts-from-receipts-2026-10-29.json) contains 17 records
read through the authenticated Dapier inbox and run APIs on 29 October. Each
record includes the full received Message-ID, full `dev-mailbox` run ID,
Authentication-Results, DKIM signing domains and Developer webhook status.
All 17 have From `DTC Alerts <alerts@dtcdev.click>`, SPF pass through
`mail.dtcdev.click`, DKIM pass with `d=dtcdev.click`, aligned DMARC pass, a
completed run and webhook HTTP 200. Original receipts are from 24 October;
seven additional records are from 29 October. Fifteen were existing messages;
the DR cutover generated one dev-only preflight and one real failure alert from
the installed monitor, described below.

Relay's `datamailer domains` API reports domain 1 enabled and routed to
`arn:aws:iam::817685572750:role/relay-sandbox-email-send`, region `us-east-1`,
with verified identity, DKIM SUCCESS and MAIL FROM `mail.dtcdev.click` SUCCESS.
That provider snapshot is dated 24 October. Refreshing it through
`datamailer domains --id 1 --verify` requires a Relay admin key unavailable to
this maintenance client; the attempt was refused before any provider change.
The 29 October receipts independently prove current authentication alignment.
No AWS API or stored static key was used by this continuation.

Both live Relay clients, `hetzner-maintenance` and `contabo-monitors`, expose
sender `alerts = DTC Alerts <alerts@dtcdev.click>` and default to `alerts`.
The old `backup-alerts` sender remains on the maintenance client.

## Source inventory

The target From for this inventory is `DTC Alerts <alerts@dtcdev.click>`.
Verified receipts and remaining source-specific evidence are listed below;
receipt keys refer to complete message/run evidence in the JSON companion.

| Source and repository file | Previous From | Current path | Deployment evidence | Receipt key |
| --- | --- | --- | --- | --- |
| machine-management `monitors/coolify-healthcheck.sh`, contabo-a | `noreply@datatalks.club` | Sandbox SES SMTP, account `alerts` | Live env sets address, display name and account; env backup exists | `healthcheck-a` |
| Same, contabo-b | `noreply@datatalks.club` | Sandbox SES SMTP, account `alerts` | Live script matches audited origin/main; env and backup present | `healthcheck-b` |
| machine-management `monitors/relay-pg-dns-watchdog.sh`, contabo-b | `noreply@datatalks.club` | Sandbox SES SMTP, account `alerts` | Live script matches audited origin/main; env and backup present | `pg-watchdog` |
| machine-management `monitors/contabo-deadman.sh`, Hetzner | `noreply@datatalks.club` | Sandbox SES SMTP, account `alerts` | Stable installed script matches audited origin/main; env and backup present | `deadman-fail`, `deadman-recovery` |
| machine-management `monitors/dr-raise-stale-check.sh`, contabo-a | `noreply@datatalks.club` | Relay sender `alerts`, every body sanitized before dispatch | Commit `78c87a7` installed by repo installer; hash and backups verified | `dr-stale-original-relay`, `dr-stale-relay-sanitized`, `dr-stale-relay-live` |
| course-management-platform `deploy/coolify/cmp-created-watchdog.sh` | Inherited `noreply@datatalks.club`, no explicit header | Relay sender `alerts` | Live script SHA256 matches current origin/main; backup present | `cmp-created` |
| course-management-platform `deploy/coolify/check-workers.sh`, installed as `cmp-check-workers` | Inherited `noreply@datatalks.club` | Relay sender `alerts` | Live script SHA256 matches current origin/main; backup present | `cmp-workers` |
| rds-export `notify_run.sh`, Hetzner | `Relay Backup Alerts <relay@datatalks.club>` via `backup-alerts` | Relay sender `alerts`, explicitly selected | Live wrapper contains `--from alerts`; origin/main `26deb55` | `rds-export-backup` |
| dapier `src/dapier/alarm_notify.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Sender deployment `3f2259e`; green deploy run below | `dapier-alarm-original`, `dapier-alarm-current` |
| dapier `src/dapier/engine/notify.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Alert sender present in current origin/main; real failure notice received on 29 October | `dapier-failure-notice-current` |
| dapier `src/dapier/error_digest.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Alert sender present in current origin/main | Individual received digest still required |
| dapier `src/dapier/connection_digest.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Alert sender present in current origin/main | Individual received digest still required |
| dapier `src/dapier/backup.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Alert sender present in current origin/main | Individual received backup notice still required; backup alarm is a different source |
| dapier `src/dapier/host_jobs.py` | `no-reply@dtcdev.click` default | Sandbox SES API, default `operator_sender()`; row overrides retained | Alert sender present in current origin/main | Individual received host-job notice still required |
| Host defaults: Contabo `/etc/msmtprc`, Hetzner `/home/alexey/.msmtprc` | Default account `ses`, `noreply@datatalks.club` | Default account `alerts`, sandbox SES SMTP | All three default aliases point to `alerts`; `.pre-alerts-from` backups present | Source-specific SMTP receipts above |

All three SMTP configurations select `email-smtp.us-east-1.amazonaws.com`
and `from alerts@dtcdev.click` for account `alerts`. Preserved, non-default
`ses` rollback accounts still contain the old eu-west-1 host and old From;
those lines are not active alert defaults. Contabo-a's msmtprc and Relay
config are root:root mode 0600. Hetzner's active msmtprc is **alexey:alexey
0600**, and `/etc/msmtprc` is absent: this does not satisfy literal
root-owned-only storage in AC3. A credential ownership/cron migration or
an explicit scope amendment remains necessary.

Audited repository revisions after fetch: machine-management `60e95cd`,
dapier `2d7bb668`, course-management-platform `a20aab14`, rds-export `26deb55`.
The Contabo-a healthcheck script differs from current origin/main; its
sender configuration is correct, but this audit does not claim a current
whole-script deployment on that host. The DR installer was subsequently
rerun for `78c87a7`, as detailed below.

## DR Relay cutover and remaining acceptance work

AC3 allows direct SMTP only for Relay self-monitors. The prior commit
`6a491bd6` from intake `f515a797-17e8-4b76-8934-17bd0dfc1cb1` explicitly
changed DR alerts to SMTP first after real Relay HTTP 403 failures on
IP-literal URLs. The local
27 October incident report documents the live bisection and SMTP proof.
Hub GET of that intake returns HTTP 403 to this session. The resumed task
reasserted the current Relay requirement. Commit `78c87a7` therefore routes
DR through Relay while retaining the incident's IP-literal URL sanitizer
before every send. This closes the DR routing gap without restoring raw
IP-URL request bodies.

### DR deployment and actual failure delivery

Independent review and all nine DR test groups passed. Isolated mutation
checks confirm the suite rejects unsanitized IP URLs, inherited API credential
overrides and a forbidden SMTP bypass. Tests also isolate the digest spool,
preserve custom recipients, check dev-only proof delivery, and protect personal
recipients during nonproduction-state manual runs regardless of MTA presence.

A temporary copy on Contabo-a sent a dev-only preflight through the production
Relay client at 06:55:48Z. The received body contains the readable vmui address
without its HTTP scheme; DKIM/SPF/DMARC and Developer webhook 200 are verified
under `dr-stale-relay-sanitized` in the JSON. Temporary staging was cleaned.

The repo installer then installed the same script bytes on Contabo-a:
SHA256 `f3ec7693440a5e3f3076bbda4e43f33f6073f7f7c8a1ae2f4741fe269be3d988`.
Operator env bytes, recipients and cron content were unchanged. Current
script, cron and env backups are retained with suffix
`.pre-alerts-from.20261029-83a46dc5`; the older `.pre-alerts-from` backups
were preserved too.

The post-install dry-run reported a real missing/unreadable weekly-raise
metric, exit 1. This is an existing health failure, not a passing DR check.
After confirming the configured destination was still dev@ only, one normal
installed-monitor run reported that observed condition at 06:59:49Z and sent
its actual failure body through Relay. It was received at 06:59:53Z with the
required From, aligned authentication, completed dev-mailbox run and webhook
HTTP 200 (`dr-stale-relay-live`). No outage or metric failure was forced, and
no threshold was changed. The state file was backed up before that normal run.
The missing weekly-raise metric remains an operational issue outside this
sender migration.

### Remaining routing and credential requirements

Newer direct-SMTP sources `coolify-proxy-networks.sh`,
`hetzner-disk-check.sh`, `storagebox-staleness-check.sh` and
`ops-daily-digest.sh` still need Relay migration under AC3. Healthcheck's
non-Relay checks also share its direct SMTP function and need separate
routing; AC3's independent-SMTP exception covers its Relay checks.
Current disk and storagebox receipt proofs are included in the companion JSON.

The SMTP IAM user's identity and `ses:FromAddress = alerts@dtcdev.click`
restriction remain unverified. The available local AWS profiles do not provide
an approved sandbox IAM inspection path. The prohibited `main-temp` profile
was not used. An approved sandbox role or operator-supplied current IAM policy
evidence is needed for this criterion.

AC5/10 require a real received alert and Developer webhook 2xx from each
Dapier notice source. Alarm and failure-notice receipts prove their respective
paths but cannot stand in for error digest, connection digest, backup notice
and host-job deliveries. Source-specific receipts or controlled source tests
are still required for those four paths. A bounded read-only search of 500
email events, spanning 23–29 October, found no new-sender candidates with
those sources' subject patterns. This is a search bound, not a claim that
they have never sent mail.

The newly verified failure notice arrived at dev@ on 29 October at 06:00:49Z,
with subject `[dapier] Run failed: orin-mailbox`. Its originating run
`orin-mailbox:37dbb03c-11e6-4204-91ce-7d73a2bd479f` is confirmed failed through
the run API. The notice's own `dev-mailbox` run completed and Developer
webhook returned HTTP 200. Full IDs and authentication evidence are in the
companion JSON. No inbox body, webhook URL, token or provider credential is
included in this report or the JSON evidence.

## Allowlists and recipients

Live Dapier dev, tofu and orin allowlists each still contain
`alerts@dtcdev.click`, `noreply@datatalks.club` and `no-reply@dtcdev.click`.
No allowlist entry was changed. Current Relay inbound mailbox policies have
not been re-audited by this continuation; the 24 October history reports
additive coverage, which must be checked again before any future inbound
cutover. No removal proposal is submitted until all current per-source
proof and transport criteria are met; removal still requires Alexey's OK.

No recipient settings were edited. Live healthcheck and deadman `ALERT_TO`
remain `alexey@datatalks.club,dev@dtcdev.click`; deadman `ALERT_OPS_TO` remains
`dev@dtcdev.click`; DR remains `dev@dtcdev.click`. Source tests verify custom
CMP recipients and the unchanged rds-export default recipient.
Dapier workflow `email_send` actions retain `DAPIER_EMAIL_SENDER`; alert
selection and refusal-loop suppression cover both configured senders.

## Tests and independent review

This continuation adds actual message/header/envelope assertions to the
healthcheck suite for msmtp and sendmail-only installations. It also repairs
latency fixtures after the digest policy added helper/config dependencies;
the extracted production functions now run with those dependencies and
isolated config/digest paths. Those header and fixture changes preserve their
monitor behavior; the separately reviewed DR transport change is described above.

- Healthcheck: 28 checks passed. Latency: 6 tests passed. Independent reviewer
  `/root/independent_review` reran both suites and reported no findings in the
  final diff.
- Other monitor suites passed: alert noise, backup host scope, callback
  healthcheck, deadman, proxy networks, Created attribution, DR stale-check,
  Hetzner disk, HTTP retries, ops digest, placeholder targets, storagebox,
  WAL freshness and WAL idle dry-run. The watchdog suite passed **59 checks**;
  its first attempt exceeded the audit runner's 150-second limit and was
  rerun to completion without that short limit.
- Dapier focused sender, alarm, digest, backup, refusal and host-worker suites:
  **107 passed** against an exported current origin/main snapshot, with dummy
  AWS test credentials and metadata disabled.
- CMP watchdog behavioral suites passed against exported origin/main,
  including fixed Relay sender, recipient preservation, delivery-failure
  retry and dev-only source proofs. rds-export notify wrapper: **3 passed**.

GitHub confirms the original sender [deployment 40098012299](https://github.com/DataTalksClub/dapier/actions/runs/40098012299)
succeeded at `3f2259e`, and receipt-header
[deployment 40102223331](https://github.com/DataTalksClub/dapier/actions/runs/40102223331)
succeeded at `1a4eaeb`. The historical report records 4,737 tests passing for
the sender change; this audit reran the focused suites, not that full count.

Independent acceptance review identified the transport conflict, missing
per-notice receipts, missing SMTP IAM restriction proof and missing healthcheck
From assertion. The assertion and DR routing gaps are fixed; the remaining
acceptance gaps above remain.
The reviewer also checked the final report and JSON for overclaims and secrets;
the report now explicitly distinguishes target senders from receipt proof.
Temporary test snapshots are cleaned automatically. No test containers or
host load generators were created. The DR deployment and one normal
monitor-state update are the production changes described above; no containers
were modified. The dedicated Hub worktree is retained while the intake is open.
