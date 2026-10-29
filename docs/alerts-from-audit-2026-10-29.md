# Alert sender acceptance audit on 29 October 2026

Intake `55669c2f-d3a2-4d82-bf9b-36c815cc0f48` remains **OPEN**. The original
sender cutover is live, but current acceptance criteria are not all proven.
In particular, AC3 conflicts with the later DR delivery fix, the SMTP user's
IAM restriction is unverified, and individual Dapier notice paths still lack
their own receipt evidence. No DONE note or legacy sender removal is justified.

## Verified sender and delivery state

The [receipt evidence](alerts-from-receipts-2026-10-29.json) contains 14 records
read through the authenticated Dapier inbox and run APIs on 29 October. Each
record includes the full received Message-ID, full `dev-mailbox` run ID,
Authentication-Results, DKIM signing domains and Developer webhook status.
All 14 have From `DTC Alerts <alerts@dtcdev.click>`, SPF pass through
`mail.dtcdev.click`, DKIM pass with `d=dtcdev.click`, aligned DMARC pass, a
completed run and webhook HTTP 200. Original receipts are from 24 October;
four additional records are from 29 October. These were existing messages;
this continuation generated no mail.

Relay's `datamailer domains` API reports domain 1 enabled and routed to
`arn:aws:iam::817685572750:role/relay-sandbox-email-send`, region `us-east-1`,
with verified identity, DKIM SUCCESS and MAIL FROM `mail.dtcdev.click` SUCCESS.
That provider snapshot is dated 24 October. Refreshing it through
`datamailer domains --id 1 --verify` requires a Relay admin key unavailable to
this maintenance client; the attempt was refused before any provider change.
The 29 October receipts independently prove current authentication alignment.
No AWS API, profile or static key was used by this continuation.

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
| machine-management `monitors/dr-raise-stale-check.sh`, contabo-a | `noreply@datatalks.club` | SMTP first, sendmail second, sanitized Relay fallback | Installed script matches audited origin/main; `.pre-alerts-from` backup present | `dr-stale-original-relay`, `dr-stale-current` |
| course-management-platform `deploy/coolify/cmp-created-watchdog.sh` | Inherited `noreply@datatalks.club`, no explicit header | Relay sender `alerts` | Live script SHA256 matches current origin/main; backup present | `cmp-created` |
| course-management-platform `deploy/coolify/check-workers.sh`, installed as `cmp-check-workers` | Inherited `noreply@datatalks.club` | Relay sender `alerts` | Live script SHA256 matches current origin/main; backup present | `cmp-workers` |
| rds-export `notify_run.sh`, Hetzner | `Relay Backup Alerts <relay@datatalks.club>` via `backup-alerts` | Relay sender `alerts`, explicitly selected | Live wrapper contains `--from alerts`; origin/main `26deb55` | `rds-export-backup` |
| dapier `src/dapier/alarm_notify.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Sender deployment `3f2259e`; green deploy run below | `dapier-alarm-original`, `dapier-alarm-current` |
| dapier `src/dapier/engine/notify.py` | `no-reply@dtcdev.click` | Sandbox SES API through `operator_sender()` | Alert sender present in current origin/main | Individual received notice still required |
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
whole-script deployment on that host. No installer was rerun in this
continuation because the changes made here are tests and evidence only.

## Transport conflict and remaining acceptance work

AC3 allows direct SMTP only for Relay self-monitors. The later commit
`6a491bd6` from intake `f515a797-17e8-4b76-8934-17bd0dfc1cb1` explicitly
changed DR alerts to SMTP first after real Relay HTTP 403 failures on
IP-literal URLs. Current README and tests require that chain. The local
27 October incident report documents the live bisection and SMTP proof.
Hub GET of that intake returns HTTP 403 to this session, so its full current
scope decisions could not be read. The newer working transport was preserved
pending reconciliation with this intake; it must not be reported as Relay-only.

Newer direct-SMTP sources `coolify-proxy-networks.sh`,
`hetzner-disk-check.sh`, `storagebox-staleness-check.sh` and
`ops-daily-digest.sh` also need an explicit AC3 routing decision or migration.
Current disk and storagebox receipt proofs are included in the companion JSON.

The SMTP IAM user's identity and `ses:FromAddress = alerts@dtcdev.click`
restriction remain unverified. The available local AWS profiles do not provide
an approved sandbox IAM inspection path. The prohibited `main-temp` profile
was not used. An approved sandbox role or operator-supplied current IAM policy
evidence is needed for this criterion.

AC5/10 require a real received alert and Developer webhook 2xx from each
Dapier notice source. Alarm receipts prove the shared sender works but cannot
stand in for notify, error digest, connection digest, backup notice and
host-job deliveries. Source-specific receipts or controlled source tests are
still required. No inbox body, webhook URL, token or provider credential is
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
isolated config/digest paths. Runtime transport behavior is unchanged.

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
From assertion. The assertion gap is fixed; the acceptance gaps above remain.
The reviewer also checked the final report and JSON for overclaims and secrets;
the report now explicitly distinguishes target senders from receipt proof.
Temporary test snapshots are cleaned automatically. No test containers or
host load generators were created. Production files and containers were not
modified. The dedicated Hub worktree is retained while the intake is open.
