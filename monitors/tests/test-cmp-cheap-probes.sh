#!/usr/bin/env bash
# Regression test: intake 6e626719 (CMP baseline waste) AC1/AC5.
#
# The every-5-min monitors used to render the CMP homepage and a real
# course page on every cycle (coolify-healthcheck LATENCY_PROBES
# cmp_home/cmp_course + CONTENT_CHECKS courses_home, same latency probes
# in the Hetzner deadman) — ~4 homepage + ~3 course renders per cycle of
# wasted baseline load. They must probe the cheap /api/health/ endpoint
# instead, while keeping outage alerting intact (health URL still checked
# for status AND body marker; deadman DEADMAN_URLS unchanged).
#
# Static check on repo defaults: the deployed nodes override these keys
# via /etc/coolify-healthcheck.env, which this test cannot see — node env
# updates are verified live, not here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HEALTHCHECK="$REPO/monitors/coolify-healthcheck.sh"
DEADMAN="$REPO/monitors/contabo-deadman.sh"
ENV_EXAMPLE="$REPO/monitors/coolify-healthcheck.env.example"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# CMP probe entries must target /api/health/ only — never the homepage or
# a course page render.
cheap_probe='cmp_health=https://courses.datatalks.club/api/health/::cmp'
page_probes='cmp_home=https://courses.datatalks.club/|cmp_course=https://courses.datatalks.club/ml-zoomcamp-2026/'

for f in "$HEALTHCHECK" "$DEADMAN"; do
  name="$(basename "$f")"
  defaults="$(grep -E '^LATENCY_PROBES=' "$f" || true)"
  if [[ -n "$defaults" && "$defaults" == *"$cheap_probe"* ]]; then
    pass "$name LATENCY_PROBES default probes /api/health/"
  else
    fail "$name LATENCY_PROBES default missing $cheap_probe"
  fi
  if [[ "$defaults" != *$(echo "$page_probes" | cut -d'|' -f1)* && "$defaults" != *$(echo "$page_probes" | cut -d'|' -f2)* ]]; then
    pass "$name LATENCY_PROBES default has no CMP homepage/course page probes"
  else
    fail "$name LATENCY_PROBES default still renders CMP pages"
  fi
done

# env.example: the courses_home content check (homepage render + marker)
# is gone; the health content check and the APP_URLS health target stay.
if grep -qF 'courses_home=https://courses.datatalks.club/::activecourses' "$ENV_EXAMPLE"; then
  fail "env.example CONTENT_CHECKS still renders the homepage (courses_home)"
else
  pass "env.example CONTENT_CHECKS has no courses_home page render"
fi
if grep -qF 'courses_api=https://courses.datatalks.club/api/health/::"status":"ok"' "$ENV_EXAMPLE"; then
  pass "env.example keeps the courses_api health content check"
else
  fail "env.example lost the courses_api health content check"
fi
if grep -Eq '^APP_URLS=.*cmp=https://<cmp-host>/api/health/' "$ENV_EXAMPLE"; then
  pass "env.example APP_URLS cmp target is /api/health/"
else
  fail "env.example APP_URLS cmp target is not /api/health/"
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
  echo "PASS: CMP monitors probe /api/health/ only ($PASS checks)"
  exit 0
fi
echo "FAIL: $FAILN CMP cheap-probe check(s) failed ($PASS passed)"
exit 1
