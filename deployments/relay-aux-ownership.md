# Relay production inbound-mail and pruning ownership

Verified 2026-10-23 at 12:41–12:47 UTC for t1143u. This is the operations
record for the production Relay service on contabo-b. The application policy
and implementation live in the Relay repository, in
`docs/production-aux-ownership.md`, `jobs/services.py`, and
`jobs/management/commands/run_relay_scheduler.py`.

| Path | Current policy and execution owner |
| --- | --- |
| Production inbound mail | **Intended disabled.** No consumer, no configured inbound queue, no provisioned addresses or messages. Relay ops owns this policy. Existing AWS storage/queues alone do not authorize consumption. |
| Finished database task results | **One production scheduler on contabo-b**, `run_relay_scheduler`, calls `prune_finished_task_results`. Successful and failed results older than 14 days, all queues, once per UTC day per scheduler process. Restarting can repeat an idempotent sweep. |
| Business and delivery history | **Intended retention; no recurring pruner.** The task-result sweep does not delete provider events, recipients, suppression state, callback outboxes, contacts, or jobs. Changing their retention requires a separate policy decision. |

The recurring task-result implementation already landed in Relay commits
`dd4ff79` and `d8cba22` and is present in deployed revision `b292684`.
No additional cron, container, Coolify scheduled task, or AWS schedule is
required. The existing scheduler heartbeat monitors the execution loop;
heartbeat freshness alone does not prove a successful prune. Check the sweep
log and dry-run result too. A prune failure is logged and retried the next
UTC day.

## Current verification

| Check | Fresh evidence |
| --- | --- |
| Deployed production service | Nine running containers, web healthy; exactly one production scheduler. The separate development service has its own scheduler and database. |
| Inbound policy | Zero addresses and messages; inbound queue setting absent. `get_ingress_config("inbound-email")` raises `ImproperlyConfigured`; patched AWS client factory received zero calls. No inbound consumer in live compose or either Contabo host. |
| AWS receipt routing | The sole active receipt rule routes to the existing AISHL bucket and Lambda, not Relay inbound storage. Do not disable that independent receiving path. |
| AWS ownership | Legacy production prune EventBridge rule is **DISABLED**. No EC2 instances or ECS clusters returned in the production account's eu-west-1 region. No second AWS execution owner. |
| Contabo ownership | No prune/inbound cron or systemd unit on either node; no root crontab entry on contabo-b; zero Coolify scheduled tasks on production Relay. |
| Pruning | Scheduler log records `task_results_pruned=True`; explicit 14-day, all-queue dry run: **Would delete 0 task result(s)**. No destructive command invoked by this verification. |
| Scheduler and database queue | Heartbeat age **3.3 seconds**; no READY/RUNNING task rows. Default queue: 23,328 successful, 75 retained failed results; provider-events queue: 98 successful results. These are retained receipts, not queued work. |
| SQS | Production inbound, inbound DLQ, SES webhooks, and webhook DLQ each **0 visible / 0 in-flight / 0 delayed**, observed twice. All six Relay production CloudWatch alarms OK. |
| Callback flow | 16,756 CMP callbacks delivered; zero pending older than 30 minutes and zero failures in the last 24 hours. Five historical failed callbacks retained. Client outbox empty. Latest delivery 12:22:48 UTC. |
| Provider and send evidence | Last 24 hours: 3 sent, 2 delivered, 79 open, 16 click, 1 bounce, 1 complaint events. Latest provider event 12:22:45 UTC. Existing outbound backend is console; this verification does not establish a new live-send path. No test send initiated. |

Counts are observations, not configuration or permanent health assertions.
The AWS and application checks were read-only. No queue receive, delete,
redrive, mail replay, provider event injection, or production restart was used.

## Safe verification path

Discover the current production web container on contabo-b; do not select
the development web container. Run the following management command there:

```sh
python manage.py prune_db_task_results --queue-name '*' --min-age-days 14 --failed-min-age-days 14 --dry-run
```

For database evidence, run these queries in one read-only transaction against
the production Relay database. They return aggregate operational data only:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '15s';
SELECT extract(epoch FROM now() - max(ticked_at)) AS heartbeat_age_seconds
FROM relay_scheduler_heartbeat;
SELECT (SELECT count(*) FROM inbound_addresses) AS inbound_addresses,
       (SELECT count(*) FROM inbound_messages) AS inbound_messages;
SELECT queue_name, status, count(*)
FROM django_tasks_database_dbtaskresult
GROUP BY queue_name, status ORDER BY queue_name, status;
SELECT count(*) FILTER (
         WHERE status = 'pending' AND created_at < now() - interval '30 minutes'
       ) AS pending_older_30m,
       count(*) FILTER (
         WHERE status = 'failed' AND updated_at >= now() - interval '24 hours'
       ) AS failed_last_24h,
       max(delivered_at) AS latest_delivery
FROM cmp_callbacks;
COMMIT;
```

For AWS evidence, use `GetQueueAttributes` on the four queues above, inspect
the production prune rule state, and enumerate EC2/ECS in eu-west-1. Do not
print credentials, queue addresses, message bodies, or callback destinations.
Check Coolify scheduled tasks and the running container commands as well.
`drain_sqs_ingress --once` can consume real mail; it is not a read-only probe.
Do not run the scheduler with `--once` as a test: it dispatches due work.

## Re-enable and rollback boundaries

Inbound remains disabled until Relay ops deliberately provisions receiving
routes and addresses, configures the queue, and designates exactly one
Contabo inbound consumer. Verify that no AWS consumer is enabled before that
change. Use one newly generated synthetic message to a permitted address;
never replay historical mail or redrive an old queue as a test.

Keep the legacy AWS prune rule disabled, including after any Terraform apply.
Do not add a second pruner in Coolify or host cron. The development scheduler
must retain its separate database and must not receive production ingress
queue configuration. If reverting the application pruning change, document
the resulting retention gap rather than activating the retired AWS path.
