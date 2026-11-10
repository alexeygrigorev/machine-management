# False weekly DR alert, 2026-11-10

Hub intake: `60ff02f8-5610-4f97-8eb9-ff9c50391289`.

## Cause and owner

The 13:20:58Z `[dr-fast-pg-raise] FAIL ... no attempts recorded` message
came from an isolated delivery probe, not the production cron or vmalert.
The sending `alerts-to-dev` session confirmed its 13:20:57Z invocation in
Aplexer message `01a1c5a2-9908-7100-87d8-bbed4730757a`:

- Script: `/usr/local/sbin/dr-raise-stale-check.sh` on RMTHZ.
- Overrides: `DR_RAISE_STALE_ENV_FILE=/dev/null`,
  `VM_URL=http://127.0.0.1:1`, `STALE_SECONDS=0`,
  `ALERT_TO=dev@dtcdev.click`, and temporary `STATE_DIR` under `/tmp`.
- The sender removed the temporary directory, left production state untouched,
  and confirmed it would send no further DR probes.

Thus `:1` was an explicit test override for this message. Other mails may
redact addresses; the displayed address alone did not establish the cause.
The script swallowed curl failures and parsed every invalid response as
`MISSING`, fabricating a statement about absent metrics from a connection error.

Read-only inspection of `coolify-observability` found the historical
`alerts/rules.yaml` entry `A9_dr_fast_pg_raise_stale`:
`(time() - max(dr_fast_pg_raise_last_success_unixtime)) > 691200 or absent(dr_fast_pg_raise_last_success_unixtime)`.
Its comment says it is for vmui / future vmalert. The loaded-rule source
`configs/vmalert/rules-vm.yml` contains no DR rule; A2 rules concern disks.
The compose vmalert datasource is loopback `:8428`. That historical A9 entry
does not generate the script's exact subject/body. No Contabo host was accessed.

## Production query and live evidence

The production `/etc/dr-raise-stale-check.env` selects
`http://127.0.0.1:8428` on RMTHZ. `/etc/cron.d/dr-raise-stale-check`
runs the stable installed script at 09:00 Europe/Berlin. It queries
`/api/v1/query` with:

```promql
time() - max(max_over_time(dr_fast_pg_raise_last_success_unixtime[691200s]))
time() - max(max_over_time(dr_fast_pg_raise_last_run_unixtime[691200s]))
```

At 13:26:32Z both real queries returned successful instant vectors with ages
about 208486 seconds (57.9 hours), below 691200 seconds (eight days).
The patched script's read-only run logged
`OK last_success age=208486s (threshold 691200)`.
The production cron log recorded OK every day Nov 3–10; the latest scheduled
run was 08:00:01Z with age 188895 seconds.

`weekly.log` records the Nov 8 run passing at 03:31:16Z with `rto=31s rc=0`,
then `done result=pass rto=31s`. `last_success.env` contains
`LAST_SUCCESS=1794108677` and `LAST_RTO=31`. The hourly mirror log records
`series=8 remote=ok` through 13:17:02Z. Mirror evidence is the existing local
log, not a fresh connection to Contabo.

A read-only replay at 13:26:32Z used `DRY_RUN=1` and the sender's endpoint
and threshold overrides. The installed script logged `FAIL ... no attempts
recorded`; the patched script logged `UNKNOWN: VictoriaMetrics query
failed/unreadable` and exited 2. Neither replay sent mail or changed health state.

## Fix and validation

`monitors/dr-raise-stale-check.sh` now requires successful HTTP transport,
API status, vector structure, and finite numeric ages. Only a successful
empty vector proves a metric missing. Query errors log UNKNOWN, exit 2,
and preserve existing health/dedupe state without sending a raise FAIL or
RECOVERED message. A valid fresh success still proves health if the diagnostic
last-run probe fails. The endpoint, query window, and stale threshold stay
as configured. Use the existing explicit `--test-alert` path for authorized
transport tests; it labels the subject TEST and skips VM queries and state.

Targeted regression suites:

```bash
bash monitors/tests/test-dr-raise-stale-check.sh
bash monitors/tests/test-dr-raise-missing-vs-failed.sh
```

Both passed, including transport/HTTP/API/malformed/nonfinite errors with
existing OK and FAIL state, missing versus failed attempts, sparse weekly
samples through eight days, and Relay delivery/recovery/dedupe behavior.
All transport calls in these tests use stubs.

Host access remains read-only: the installed script was not replaced. The
identified one-off probe has ended, and current production checks are healthy.
A future absence of false alerts cannot be established by a finite observation;
after deploying this repository fix through an authorized host-update process,
repeat the read-only checks above and inspect the next scheduled cron result.
