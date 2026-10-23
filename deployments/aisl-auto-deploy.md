# AISHL pinned-image poller and five-minute recreate incident

The Hetzner user cron polls immutable GHCR release tags every five minutes.
`aisl-auto-deploy.py` is the canonical implementation; the installed wrapper
is `~/tmp/bin/coolify-aisl-auto-deploy.sh`. Credentials stay in private files.
Only the AISHL Coolify service is managed by this poller.

## Root cause, 2026-10-22

The old shell poller compared the first Coolify application's image,
`ghcr.io/ai-shipping-labs/website:20261022-163449-f2d6550`, with
`ai-shipping-labs/website:20261022-163449-f2d6550`. The missing registry prefix
made the equality check false on every run. It patched the unchanged tag and
called the deployment API every five minutes. The old log records that exact
pair followed by a deploy at 16:45, 16:50, 16:55, 17:00, 17:05 and 17:10 UTC.
Coolify activity rows 204–209 match those times to within seconds.

This is specific to the AISHL poller. CMP uses a separate rollout script;
Relay has separate deployment paths. Their compose files also contain
`pull_policy: always` without this loop, demonstrating that policy alone
was not the initiating trigger.

Coolify 4.4.7's `DeployController::deploy_resource`, service branch, calls
`StartService::run`. `StartService::handle` saves compose, records the
configuration hash and invokes compose `up` with `--force-recreate`.
Even an unchanged service deployment therefore replaces containers.
RestartCount alone cannot identify such replacements.

`pull_policy: always` adds unnecessary registry pulls for immutable images;
it does not schedule deployments. Use `missing` for pinned AISHL images.
`Service::isConfigurationChanged` hashes images, domains, storage metadata
and environment values. Clearing `config_hash` makes the next check report
changed and repopulate it; it does not cancel API-triggered deployments.
A normal nonempty hash is expected after configuration is saved.

The built-in five-minute `horizon:snapshot` job collects queue metrics.
`ServerManagerJob` runs every minute. Sentinel pushes container status through
`PushServerUpdateJob`; its restart tracking is not this deployment trigger.
No Coolify scheduler, Horizon or Sentinel job was disabled or patched.
The old external cron was disabled as containment, then replaced and
reenabled on 2026-10-23 after the new executable returned a live no-op.

## Durable behavior

- Compare canonical GHCR references across all selected applications; API
  application order and an optional registry prefix cannot cause a deploy.
- Pin web and worker together. Preserve environment, healthchecks, networks
  and unrelated services. Refuse conflicting worker image ownership.
- Persist `pull_policy: missing` whenever pinning images. Policy-only drift
  is saved without requesting a container replacement.
- Refuse concurrent compose edits; verify persistence before requesting one
  deployment. A second run with that release must make no writes.
- Read-only by default; the installed cron wrapper explicitly uses `--apply`.
- Store rollback snapshots with mode 600 outside the repository; print no
  compose payloads, credentials, API responses or exception messages.

`aisl-pinned.override.yml` is the operator template for the immutable image
and pull policies. Merge it into the existing compose with a full immutable
release reference supplied as `AISL_IMAGE`; it is not a standalone stack.
Preserve the current web/worker environment and healthchecks. The older
application-repository staging template uses `always`; use this maintained
operator template and poller for Contabo rather than restoring that policy.
Do not replace the whole live stack with the overlay.

## Install or update

Requires Python 3, PyYAML, curl for operator verification, and flock.
On Hetzner, the existing private credential files are
`~/tmp/secrets/coolify-ghcr-read.pat` and
`~/tmp/secrets/coolify-api-169.58.119.163.token`.
`GH_PAT_FILE`, `COOLIFY_TOKEN_FILE` and `COOLIFY_URL` override these defaults.

1. Save the installed wrapper, Python file and user crontab privately.
2. Copy `aisl-auto-deploy.py` to `~/tmp/bin/aisl-auto-deploy.py` and
   `aisl-auto-deploy.sh` to `~/tmp/bin/coolify-aisl-auto-deploy.sh` on Hetzner;
   make both executable.
3. Run `python3 ~/tmp/bin/aisl-auto-deploy.py` for a read-only plan.
   If the release is current, require the `In sync` no-op message.
4. Keep exactly one AISHL line from `aisl-auto-deploy.cron` in the user
   crontab. Preserve CMP, Relay, backups and every other entry.
5. Verify at least three scheduled boundaries over 15 minutes: unchanged
   container ID and StartedAt, no new AISHL activity rows, healthy public ping.

If containment is needed, comment only the AISHL cron line. Restore a previous
executable only with that cron disabled; the old comparison is unsafe.
Rollback compose snapshots can contain secrets; inspect privately and preserve
intervening web/worker edits before applying any restore.

## Verification

Run `python3 -m unittest discover -s deployments/tests -p 'test_aisl_auto_deploy.py' -v`.
The tests enforce a no-write/no-deploy same-tag poll, an optional registry
prefix, reversed application order, one deployment for a new release across
both applications, unrelated-service preservation, missing pull policy,
mutable-tag/conflicting-worker refusal and concurrent-edit refusal.

Activity rows have null `subject_type`/`subject_id` for these inline runs.
Filter `properties->>'type_uuid'` by the service UUID, with a description
fallback. Filtering only by subject would falsely report zero historical
and new deployments. Compare a baseline count and max ID as well as StartedAt.

The incident report is maintained privately at
`~/tmp/agent-reports/aisl-5m-redeploy-loop-t1908u-2026-10-22.md`.
