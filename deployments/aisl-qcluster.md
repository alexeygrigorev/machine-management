# AISHL qcluster on Contabo

AISHL's Coolify service `mekt9kz74fvbixla6olinuma` (`aisl-staging`, on
`contabo-b`) owns both `web` and `worker`. The worker uses the web image,
`BOOT_MODE=worker`, `RUN_MIGRATIONS=false`, two worker processes, the ORM
broker, and the existing service environment. No ports or Traefik routes
are exposed for the worker. Coolify persists the definition; this is not
a standalone `docker run` container that disappears on the next deployment.

The initial deployed image is
`ghcr.io/ai-shipping-labs/website:20261022-163449-f2d6550`.
Its entrypoint registers schedules and honors the compiled R1/R2 release
gates before starting qcluster. `catch_up=False` remains in effect.
Restoring a consumer does not enable the R2 producers or prove that every
integration/job is healthy.

## Deploy and verify

Run from an operator host with Python 3 + PyYAML, SSH access to `contabo-b`,
and the existing Coolify API token in
`~/.secrets/coolify-api-169.58.119.163.token`:

```sh
python3 deployments/aisl-qcluster.py             # read-only plan
python3 deployments/aisl-qcluster.py --apply     # save in Coolify, deploy
python3 deployments/verify-aisl-qcluster.py --min-uptime 0 > first.json
# After at least 15 minutes of unchanged worker uptime:
python3 deployments/verify-aisl-qcluster.py --baseline first.json
python3 -m unittest discover -s deployments/tests -v
```

The deploy helper leaves web's configuration and service secrets unchanged.
It refuses to overwrite a differing existing worker. An identical definition
is a no-op, including with `--apply`. It stores a private, exclusive rollback
snapshot under `~/tmp/aisl-qcluster-t1218u/` before changing Coolify. Inspect
that snapshot before a retry following an interrupted apply; do not overwrite
it blindly. A deploy rolls the service, including web; schedule accordingly.

The worker healthcheck runs the image's **virtual-environment Python** and
requires a recent django-q heartbeat from its own hostname, in Idle/Working
state. It does not report healthy merely because a Python process exists.
The verification script checks healthy web/worker, matching image and runtime
key/database, a DNS database hostname, restart policy, no published worker
ports, zero restarts, unchanged ID/StartedAt when a baseline is supplied,
minimum uptime, and successful tasks after startup and in the last five
minutes. Its output excludes credentials and task arguments/results.

`DATABASE_URL` continues to use the Coolify PostgreSQL container DNS name
`ekm57uezdngrrscn0aqzidr8`. No PG address, hosts entry, or `extra_hosts`
override was added. Existing DNS/watchdog ownership remains unchanged.

## Fernet / SECRET_KEY decision, 2026-10-23

**Retain the current shared service SECRET_KEY. Do not rotate it for this
worker deployment or rewrite stored ciphertext.** Both containers inherit
exactly the same nonempty key from Coolify. A read-only decryption check
found 12 encrypted `cb_config` settings: 11 decrypt successfully; one,
`ZOOM_WEBHOOK_SECRET_TOKEN`, does not. This is not evidence that all settings
need the historical AWS key. Replacing the current key would invalidate
working ciphertext and signatures, including sessions and new queue entries.

The Zoom setting needs a targeted follow-up using its authoritative secret
source and the current application configuration writer (which encrypts with
the current key), or a deliberate migration with all relevant old keys. This
deployment does not claim to repair Zoom webhook authentication. No secret
values or hashes are recorded here. No AWS credentials were used.

Before starting the consumer, the existing queue and schedules were backed
up on contabo-b to root-only
`/root/aisl-qcluster-t1218u/queue-schedules-before.dump` (mode 600). The first
worker processed four of the five queued entries; one failed django-q
signature verification and was rejected by the broker. Keep the backup for
investigation. Do not blindly restore all schedules/queue rows into a running
consumer, which could duplicate side effects. The rejected payload was not
re-signed or replayed.

The first drain also exposed a failed
`content.tasks.peer_reviews.form_self_paced_review_batches` task with
`NotSupportedError`. That application-level failure is separate from worker
availability; no task result payload is published. Successful recurring
`run_due_jobs`, `sweep_jobs`, and campaign recovery runs demonstrate that the
scheduler and consumer are active; successful task status alone does not
prove external delivery or execution behind release gates.

## Rollback and deployment ownership

To stop processing immediately, stop only
`worker-mekt9kz74fvbixla6olinuma` on contabo-b. Preserve the private queue
backup. For a durable rollback, remove the worker stanza from the **current**
Coolify raw compose and deploy; inspect intervening edits before using the
private pre-change snapshot. Verify web health afterward. No database schema
migration is part of this deployment.

The Hetzner AISHL five-minute auto-deploy cron remains commented out. Its
repair/reenablement belongs to Hub task `f45d00b0`; this task neither edits
nor enables it. The poller owner must update **both** web and worker image
references together before reenabling deployments: its old single-match
image substitution would update only web. Manual future image updates must
also keep both services aligned.
