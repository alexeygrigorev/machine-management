#!/usr/bin/env bash
# Post-apply verification for t1037u edge harden. Read-only + external probes.
# No secrets. Exit non-zero on any failure.
set -euo pipefail

A=169.58.119.163
B=169.58.124.141
fail=0
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "PASS: $1 (=$3)"; else echo "FAIL: $1 (want $2, got $3)"; fail=1; fi
}

echo "== 1. cAdvisor :9101 closed to the world (.141 was 200 before) =="
C9101="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 "http://${B}:9101/containers/" 2>/dev/null || true)"
check "ext .141:9101" 000 "$C9101"

echo "== 2. operator still reaches Coolify UI (allowlisted) =="
UA="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 "http://${A}:8000/" || echo 000)"
UB="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 "http://${B}:8000/" || echo 000)"
check "operator .163:8000" 302 "$UA"
check "operator .141:8000" 302 "$UB"

echo "== 3. DOCKER-USER rules present on both hosts =="
for H in contabo-a contabo-b; do
  N="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$H" 'sudo iptables -S DOCKER-USER | grep -c "ctorigdstport" || echo 0')"
  check "${H} v4 ctorigdstport rules" 8 "$N"
done

echo "== 4. canary Header() gate (prod routers untouched) =="
for IP in "$A" "$B"; do
  DENY="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: edge-verify-canary.invalid" "http://${IP}/" || echo 000)"
  check "canary deny ${IP}" 403 "$DENY"
done

echo "== 5. prod edge still serves (no traffic impact) =="
P1="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 https://courses.datatalks.club/api/health/ || echo 000)"
P2="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 https://relay.datatalks.club/health/ || echo 000)"
[[ "$P1" == "200" ]] && echo "PASS: prod courses health (=200)" || { echo "FAIL: prod courses health (got $P1)"; fail=1; }
[[ "$P2" =~ ^(200|301|302)$ ]] && echo "PASS: prod relay /health/ (=$P2)" || { echo "FAIL: prod relay /health/ (got $P2)"; fail=1; }
echo "NOTE: direct-Host origin probes now expect 403 (t1143u origin-security enforcement denies unauthenticated direct-origin bypass by design)"
O1="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: origin.relay.datatalks.club" "http://${B}/health/" || echo 000)"
check "direct origin.relay denied" 403 "$O1"
O2="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: origin.website.datatalks.club" "http://${A}/health/ready" || echo 000)"
check "direct origin.website denied" 403 "$O2"

echo "== 6. WG scrape of cAdvisor on .141 intact =="
ssh -o BatchMode=yes contabo-b 'curl -sf -m 5 http://10.100.0.2:9101/containers/ -o /dev/null && echo "PASS: WG scrape"' || { echo "FAIL: WG scrape"; fail=1; }

echo "== 7. dev hostnames do not reach production containers (t1143u dev-isolation) =="
D1="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 --resolve dev.courses.datatalks.club:443:${A} https://dev.courses.datatalks.club/ping || echo 000)"
check "dev.courses no-route" 503 "$D1"
D2="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 --resolve dev.aishippinglabs.com:443:${B} https://dev.aishippinglabs.com/ping || echo 000)"
check "dev.aishippinglabs no-route" 503 "$D2"
D3="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: dev.datatalks.club" "http://${A}/health/ready" || echo 000)"
check "dev.datatalks no-route" 503 "$D3"
P4="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 --resolve courses.datatalks.club:443:${A} https://courses.datatalks.club/ping || echo 000)"
check "prod courses still serves" 200 "$P4"
P5="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 --resolve aishippinglabs.com:443:${B} https://aishippinglabs.com/ping || echo 000)"
check "prod aisl still serves" 200 "$P5"
P6="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 https://prod.datatalks.club/health/ready || echo 000)"
check "prod website still serves (via CF)" 200 "$P6"

[[ "$fail" == "0" ]] && echo "ALL EDGE CHECKS GREEN" || { echo "EDGE CHECKS FAILED" >&2; exit 1; }
