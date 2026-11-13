# A10_service_p95_slow flaps, 2026-11-13 (Hub intake cba107e3)

Verdict: one service, Relay web (`http-0-oascx5kjeimc0ivpttag9z3qv3-web-2567@docker`,
image `relay:20261113-124134-3f5d3c8`). Cause is an internal batch endpoint,
`POST /api/recipient-lists/{list_key}/members/reconcile`. No end-user impact.
Recommendation: tune the rule, do not mute it. The tune is **not yet applied**
because the rule lives in another repo (see "Where the change goes").

## Which alerting instance

Not `hetzner-aplexer :8428` (no rule groups). The A10 rule is evaluated by
`vmalert-vm` on contabo-a, group `obs-a10-slowness`
(`coolify-observability: configs/vmalert/rules-vm.yml`), against the contabo-a
VictoriaMetrics `127.0.0.1:8428` (2d retention), routed by alertmanager
`class="A10"` to the dev-only `slowness-dev` receiver. This repo has no rule
definitions (`monitors/` holds only the script-side A11 probe leg).
All numbers below were read-only queries (VM `:8428`/`:8429`, VictoriaLogs
`:9428`) over SSH to loopback; no containers touched.

## AC1: service, windows, p95

`ALERTS{alertname="A10_service_p95_slow"}` has a single `service` value in the
span, the Relay web service. Pending 12:27-12:36 and 12:42-12:51Z; firing
12:37-12:38 and 12:52Z. It resolved between them because p95 fell to 1.91s at
12:39, below the 2.0s hysteresis.

| Firing | p95 (5m) | Rate (10m) | 5xx/s | Codes |
|--------|----------|------------|-------|-------|
| 12:37:11Z | 3.04s | 0.205 req/s | 0 | 200/202/204/409 |
| 12:52:11Z | 3.62s | 0.302 req/s | 0 | 200/202/204/409 |

p95 swung 0.1s-4.5s from 12:06 to 12:54 and was back to 0.26s at 12:57.

## AC2: impact

Relay access logs (VictoriaLogs, 12:00-13:05Z, 4296 requests):

- 72% of requests are `/health/ready` and `/health/` probes (p95 5ms/17ms).
  They count toward the 0.05 req/s traffic floor.
- All slow requests are `POST .../members/reconcile` (19 x 200, 6 x 409) and
  one `bulk-upsert` at 2.3s. Reconcile p50 2.6s, max 22.1s. Fires in a loop
  (about every 55s) 12:09-12:50 with overlapping calls answered 409 by the
  concurrency guard; 25 reconcile calls in the last 24h, **all in hour 12Z**.
  It is a server-to-server sync, not a browser endpoint.
- User-facing paths were fast: tracking pixel p95 0.25s (max 1.45s), subscribe
  p95 0.41s, unsubscribe 0.12s, contacts upsert p95 0.15s.
- Relay probe TTFB (`probe_ttfb_seconds{service="relay"}`, A11 leg): max 0.29s.
- 0 x 5xx. 499s: 0.
- Over the 47h retention p95 > 2.5s only 34 min, all in this burst; max 4.55s;
  99th percentile of the minute-by-minute p95 is 3.36s, 90th is 0.28s.

Impact verdict: none for end users. The cost is a slow internal batch API; the
caller sees 2-22s and some 409s, which are not failures. Oncall probes seeing
fast front pages is consistent.

## AC3: decision

No backend defect to hotfix from this session: reconcile is O(list size) and
the 12:09-12:25 outliers (19-22s) are the same endpoint under a loop of
overlapping runs. Relay code is outside this repo and prod is read-only here.
Hence the flaps are impactless and the proposal is:

1. **Rule tune** (precise): add a per-service override for the Relay web service
   (`service=~"http-0-oascx5kjeimc0ivpttag9z3qv3-web-.*@docker"`) with p95
   threshold 6s, recovery 4s, `for: 10m`, rate floor excluding nothing else.
   6s sits above the 47h max (4.55s) yet still catches a real regression;
   A11 `relay_health` TTFB > 3s stays the user-facing guard. Do **not** exclude
   the service: Traefik exposes no path label, so a service exclusion would
   also mute `/health`, subscribe, tracking and API outages. Keep the global
   2.5s/10m/2.0s rule unchanged for every other service.
2. **Backend/structure fix (preferred, follow-up)**: give
   `/api/recipient-lists/*/members/{reconcile,bulk-upsert}` their own Traefik
   router+service (or make reconcile async, 202 + status poll) so batch
   latency stops sharing the user-facing p95, then alert that service at a
   batch-appropriate threshold (30s). Needs a Relay/Coolify change plus owner
   review and a deploy, none of which this read-only session may do.
3. Optional hygiene: the traffic floor counts health probes (72% of requests
   here), so a 0.05 req/s floor means little for Relay. Revisit after (2).

## Where the change goes

`coolify-observability`: `configs/vmalert/rules-vm.yml` (group
`obs-a10-slowness`), `alerts/rules.yaml` (A10 entries) and
`tests/test_latency.py`. Regression cover there should assert the override
rule exists, the generic rule still has `service!~` Relay-override exclusion
and 2.5s/2.0s thresholds, and that no other service gains an exclusion. Deploy
only after reviewer APPROVE on the exact SHA.
