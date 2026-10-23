# AISHL scheduled-job and legacy-secret recovery

This procedure covers the self-paced batch query, terminal durable jobs and the
retained legacy Zoom webhook configuration. Use the authenticated application
APIs for production records. Keep request credentials and replacement secrets in
private files or process memory; publish only aggregate counts and boolean proof.

## Query repair

Application commit `d1c7a2ae03f9d4bc5ec3474687be17ee5540f97d` scopes
`select_for_update(of=('self',))` to project submission rows. The reverse-review
outer join still filters already assigned submissions, without asking PostgreSQL
to lock its nullable side. The original eligibility, ordering and transaction
remain in place. The commit includes a real PostgreSQL regression test.

The same commit makes missing Relay configuration a permanent
`relay_not_configured` error for the three contact handlers. Transient provider
failures retain bounded retries. This policy does not establish the cause of
historical generic `handler_error` records.

Both Coolify applications must use the same immutable image. Use the convergent
poller to deploy a published release; preserve its ownership of both image pins.
Do not repair this incident by disabling schedules, restoring the old queue,
rotating the shared Django key, or resetting dead jobs in bulk.

## Evidence and terminal-job policy

The staff worker history API provides the scheduled name, function, completion
time and success flag. Record a bounded safe function execution, followed by a
separate later naturally scheduled success. The schedule remains every 15 min.
Task payloads and result bodies are not necessary evidence.

The read-only dead-intent summary exposes grouped handler/error categories,
counts and creation-time ranges. Unknown stored labels collapse to safe labels;
totals include every dead row. Existing dead intents remain terminal and outside
normal claimable statuses. Retain obsolete or unclassified work dead. A future
single retry requires current relevance, repaired prerequisites and a check for
prior side effects. Do not replay expired verification messages or old contact
sync requests merely to reduce the dead count.

## Legacy Zoom secret

`ZOOM_WEBHOOK_SECRET_TOKEN` is retained legacy configuration; the application no
longer declares or consumes it. Its recovery must not restore that declaration
or enable a webhook consumer. The three current Zoom OAuth settings are separate.

The fixed-key recovery action accepts only the original replacement value and
requires the existing settings-write authority. It changes only the existing
legacy row using active-key encryption, writes a redacted audit entry, and
verifies the persisted round trip before committing. Its response contains only
`recovered` and `decryptable` booleans. Repeating the same replacement is a no-op.
No secret, ciphertext or key fingerprint belongs in evidence.

Use the authoritative private operator configuration as the replacement source.
If it is unavailable, the exact missing input is the original
`ZOOM_WEBHOOK_SECRET_TOKEN`, or the historical Django `SECRET_KEY` that encrypted
that row. Never replace the active shared key to recover one legacy value.

Current declared settings are checked through the site's safe settings adapter:
it decrypts stored secret rows but returns redacted values. Metadata-only
`configured=true` from a writer response is insufficient proof; require absence
of the reader's `invalid_stored_value` error.

## Live acceptance record

The sanitized finish report under the operator's `tmp/agent-reports` directory
owns timestamps, classification totals, deployment revisions and final outcome.

## Verified terminal-intent classification, 2026-10-23

Authenticated summary and follow-up read reconciled all 63 dead intents:

| Handler | Count | Disposition |
|---|---:|---|
| `cb_mail.deliver` | 1 | Retain dead; confirm current message relevance and prior provider acceptance before any single retry |
| `email_app.relay_sync.request_contact_verification` | 7 | Retain old verification requests; issue fresh verification only on a current request after prerequisites are repaired |
| `email_app.relay_sync.sync_contact` | 19 | Retain historical snapshots; reconcile current state and consent before any individually justified sync |
| `email_app.relay_sync.unsubscribe_contact` | 36 | Retain historical work; check current consent and provider state before an individual retry to avoid applying stale state |

All four groups carry generic `handler_error`. This category alone cannot prove
missing Relay configuration or whether a provider accepted an operation. The
summary spans creation dates from 2026-09-17 through 2026-10-22. No attempt count,
status, payload, consent state or schedule was reset by recovery. The follow-up
read still reported 63 terminal dead intents. The existing compiled producer
gates remain unchanged.
