# SOP: after Coolify pg-relay (or pg-shared) recreate/redeploy

**Why:** Coolify standalone Postgres keeps a stable *resourceName* label
(`pg-relay`) but the container **name** is a random uuid and the coolify-bridge
**IPv4/IPv6 change on recreate**. Long-lived Relay workers cache the old
address → `connection refused` while `coolify-healthcheck` still sees PG
healthy + public `/health` OK → SES SQS age/DLQ (t1205u / t1207u).

**Evidence (2026-10-22/23, contabo-b):** PG uuid `mqimefrti7ratmaliirnikov`
moved to `10.0.1.15`; old `10.0.1.2` was later reused by `client-callbacks`
(non-PG → :5432 refuse).

## Immediate (ops)

1. On **contabo-b**: confirm PG healthy
   `sudo docker ps --filter label=coolify.resourceName=pg-relay`
2. Restart Relay app containers (clears stale resolve):
   ```bash
   for s in ses-ingress worker provider-events-worker scheduler \
            recipient-imports cmp-callbacks client-callbacks; do
     c=$(sudo docker ps -qf "name=${s}-fjnzwomg8n42lztloo34just")
     [ -n "$c" ] && sudo docker restart "$c"
   done
   ```
3. Watch `ses-ingress` logs for `deleted=N failed=0`; CloudWatch
   `relay-production-ses-webhooks-oldest-message` / DLQ back to OK.
4. If DLQ has depth, redrive DLQ → main (SQS start-message-move-task).

## Durable (machine-management)

- **`monitors/relay-pg-dns-watchdog.sh`** (cron every 1 min on contabo-b):
  probes app→PG from *inside* dependents; auto-restarts on stale resolve
  when PG itself is healthy; alerts alexey@ + dev@.
- Prefer pinning `ipv4_address` for pg-relay on the `coolify` network in
  Coolify compose (Coolify UI redeploy may overwrite disk compose — re-apply
  or set via Coolify custom compose if available).

## Do not

- Do not only restart PG (apps keep stale cache).
- Do not paste `DATABASE_URL` secrets into tickets/reports/git.
