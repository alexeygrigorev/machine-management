#!/usr/bin/env bash
# Regression test: intake f5d8e22b AC2 requires page-level CMP TTFB/total
# measurements in both monitor scripts. Separate health checks still use
# /api/health/ and must keep their status/body verification.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HEALTHCHECK="$REPO/monitors/coolify-healthcheck.sh"
DEADMAN="$REPO/monitors/contabo-deadman.sh"
HEALTH_ENV_EXAMPLE="$REPO/monitors/coolify-healthcheck.env.example"
DEADMAN_ENV_EXAMPLE="$REPO/monitors/contabo-deadman.env.example"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

required_probes=(
  'cmp_home=https://courses.datatalks.club/::cmp'
  'cmp_course=https://courses.datatalks.club/ml-zoomcamp-2026/::cmp'
  'aisl_home=https://aishippinglabs.com/::aisl'
  'aisl_content=https://aishippinglabs.com/blog/what-does-an-ai-engineer-do::aisl'
  'relay_health=https://relay.datatalks.club/health/::relay'
  'website_home=https://datatalks.club/::website'
  'website_events_past=https://datatalks.club/events/past::website'
)

for f in "$HEALTHCHECK" "$DEADMAN"; do
  name="$(basename "$f")"
  defaults="$(grep -E '^LATENCY_PROBES=' "$f" || true)"
  for probe in "${required_probes[@]}"; do
    if [[ "$defaults" == *"$probe"* ]]; then
      pass "$name LATENCY_PROBES includes $probe"
    else
      fail "$name LATENCY_PROBES missing $probe"
    fi
  done
done

for f in "$HEALTH_ENV_EXAMPLE" "$DEADMAN_ENV_EXAMPLE"; do
  for probe in "${required_probes[@]}"; do
    if grep -qF "$probe" "$f"; then
      pass "$(basename "$f") documents $probe"
    else
      fail "$(basename "$f") missing $probe"
    fi
  done
done

# The CMP health check is separate from latency page probes.
if grep -qF 'courses_api=https://courses.datatalks.club/api/health/::"status":"ok"' "$HEALTH_ENV_EXAMPLE"; then
  pass "healthcheck env.example keeps the CMP health content check"
else
  fail "healthcheck env.example lost the CMP health content check"
fi
if grep -Eq '^APP_URLS=.*cmp=https://<cmp-host>/api/health/' "$HEALTH_ENV_EXAMPLE"; then
  pass "healthcheck env.example APP_URLS cmp target is /api/health/"
else
  fail "healthcheck env.example APP_URLS cmp target is not /api/health/"
fi

# Outage alerting preserved: the deadman still externally verifies the
# health endpoint with its body marker (marker itself is escaped in the
# script default, so match the URL part only).
if grep -qF 'courses_api=https://courses.datatalks.club/api/health/' "$DEADMAN"; then
  pass "deadman DEADMAN_URLS still verifies /api/health/ with body marker"
else
  fail "deadman DEADMAN_URLS lost the CMP health probe"
fi

if [[ "$FAILN" -eq 0 ]]; then
  echo "PASS: monitors include the AC2 page probes ($PASS checks)"
  exit 0
fi
echo "FAIL: $FAILN AC2 latency-probe check(s) failed ($PASS passed)"
exit 1
