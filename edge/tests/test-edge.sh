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
P2="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: origin.relay.datatalks.club" "http://${B}/health/" || echo 000)"
P3="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: origin.website.datatalks.club" "http://${A}/" || echo 000)"
check "prod courses health" 200 "$P1"
check "prod origin.relay /health/" 200 "$P2"
[[ "$P3" =~ ^(200|301|302)$ ]] && echo "PASS: prod origin.website / (=$P3)" || { echo "FAIL: prod origin.website / (got $P3)"; fail=1; }

echo "== 6. WG scrape of cAdvisor on .141 intact =="
ssh -o BatchMode=yes contabo-b 'curl -sf -m 5 http://10.100.0.2:9101/containers/ -o /dev/null && echo "PASS: WG scrape"' || { echo "FAIL: WG scrape"; fail=1; }

[[ "$fail" == "0" ]] && echo "ALL EDGE CHECKS GREEN" || { echo "EDGE CHECKS FAILED" >&2; exit 1; }
