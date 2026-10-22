# Permanent continuous healthcheck (Postgres + services)

Frequent cron job that keeps watch over Coolify Contabo Postgres and apps
and emails **dev@dtcdev.click** on failure — with dedupe so one outage
does not spam. This is the **continuous** monitor (every 5 min), unlike
[`backups/`](../backups/) which dumps daily.

## Schedule (Europe/Berlin)

| What | Value |
|------|-------|
| Cron | `*/5 * * * *` with `TZ=Europe/Berlin` (see `coolify-healthcheck.cron`) |
| Where | data node **contabo-b** (`169.58.124.141`); optionally also primary **contabo-a** for the Coolify-UI/app angle |
| Alternative | Coolify Scheduled Task on the node, same `*/5 * * * *` |
| Alert to | `dev@dtcdev.click` (comma-separated OK if ever multi) (repeat at most every `ALERT_REPEAT_MIN`, default 60 min, while still failing; recovery notice on green again) |

## What gets checked

| Check | How |
|-------|-----|
| **pg-shared** | `pg_isready` + `psql SELECT 1` via `PG_SHARED_CONTAINER` (`docker exec`), or TCP `PGHOST_SHARED:PGPORT_SHARED` when the container var is empty |
| **pg-relay** | same via `PG_RELAY_CONTAINER` / `PGHOST_RELAY:PGPORT_RELAY` (own instance, never shared) |
| **HTTP apps** | `curl` expects 2xx/3xx for each `name=url` pair in `APP_URLS`: Coolify UI, Relay, CMP, AISHL, website |
| **Content markers** | each `name=url::marker` triple in `CONTENT_CHECKS` must return 2xx/3xx **and** the body (lowercased, whitespace-stripped) must contain the marker verbatim — catches proxy-default-page / error-page-with-200 incidents that status-only checks miss |

> Coolify `standalone-postgresql` uses `POSTGRES_USER=pgadmin` — there is no
> `postgres` role. Always use `PGUSER_*=pgadmin` (script default); `psql -U
> postgres` fails with `FATAL: role "postgres" does not exist` (incident
> 2026-10-22, pg-relay). When `PG_*_CONTAINER` is empty the script
> auto-resolves the container via the stable Coolify label
> (`coolify.resourceName=pg-shared|pg-relay`), so random uuid renames on
> redeploy do not break the check. Explicit names still win when set.

State (last status + last alert time per check) lives in `/var/lib/coolify-healthcheck/`
so alerts dedupe across runs. Exit `0` = all green, `1` = something failed
(cron output also lands in `/var/log/coolify-healthcheck.log`).

## Secrets (never in git)

Real values live **only** in:

1. Private Drive doc *Contabo Coolify VPS — credentials 2026-10-22*, and
2. `/etc/coolify-healthcheck.env` on the node (root-only `600`), plus operator
   hosts under `~/.secrets/` (`~/tmp/secrets` is a compat symlink).

This repo keeps **placeholders only** (`coolify-healthcheck.env.example`).

## Mail delivery

The script uses `sendmail` (or `msmtp`) on the node. Without an MTA it
**logs alerts only** and warns — so before relying on it:

1. `apt install msmtp-mta` (or equivalent) on the node.
2. Configure SMTP out-of-band (`/etc/msmtprc`, root-only `600`) with real
   relay credentials from the Drive secrets doc — never in git.
3. Force a failure (e.g. point one `APP_URLS` entry at a dead port), run the
   script by hand, confirm mail arrives at dev@, then fix the URL back.

## Enable (once targets exist on Contabo)

> Status today (2026-10-22): Postgres/apps may **not yet** be on Contabo —
> the migration cutover is owned by parallel agents. Ship this job now;
> enable it the day the nodes hold real targets. Do **not** invent green
> checks before then.

1. From an operator box (Hetzner RMTHZ):
   `./monitors/install-coolify-healthcheck.sh contabo-b`
   (repeat for `contabo-a` if you want the UI/app angle from the primary too).
2. On the node, fill `/etc/coolify-healthcheck.env` (real container names,
   DB names, public app URLs from the Drive doc); `chmod 600`.
3. Set up msmtp per above; test delivery with a forced failure + recovery.
4. Manual first run: `sudo /usr/local/sbin/coolify-healthcheck.sh` → log ends
   `ALL_OK`, state files appear under `/var/lib/coolify-healthcheck/`.
5. Confirm cron installed: `cat /etc/cron.d/coolify-healthcheck`; next hour
   check that `/var/log/coolify-healthcheck.log` shows regular `ALL_OK` lines
   (12 runs/hour at the default cadence).

Tuning: change `*/5` to `*/1`/`*/2` in the cron file for 1–2 min cadence
once SMTP + log volume look healthy.

## Files

| File | Purpose |
|------|---------|
| `coolify-healthcheck.sh` | the check (pg_isready + SELECT 1 + curl, deduped email alerts) |
| `coolify-healthcheck.cron` | `*/5 * * * *` Europe/Berlin entry |
| `coolify-healthcheck.env.example` | placeholders for `/etc/coolify-healthcheck.env` |
| `install-coolify-healthcheck.sh` | operator-box installer (scp + cron, never overwrites env) |
