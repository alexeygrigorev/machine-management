#!/usr/bin/env bash
# Full AC matrix for t1143u origin-security. Read-only + external probes.
# No secrets. Exit non-zero on any failure.
set -euo pipefail
A=169.58.119.163
B=169.58.124.141
fail=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS: $1 (=$3)"; else echo "FAIL: $1 (want $2, got $3)"; fail=1; fi
}

echo "== 1. origin TLS: valid LE cert per hostname (no default cert) =="
for H in origin.website.datatalks.club; do
  S="$(echo | timeout 8 openssl s_client -connect "$A:443" -servername "$H" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo NONE)"
  echo "$S" | grep -q "CN *= *$H" && echo "PASS: $H cert CN" || { echo "FAIL: $H cert [$S]"; fail=1; }
  echo "$S" | grep -qi "TRAEFIK DEFAULT" && { echo "FAIL: $H default cert"; fail=1; } || echo "PASS: $H not default cert"
done
for H in origin.relay.datatalks.club origin.dev.relay.datatalks.club; do
  S="$(echo | timeout 8 openssl s_client -connect "$B:443" -servername "$H" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo NONE)"
  echo "$S" | grep -q "CN *= *$H" && echo "PASS: $H cert CN" || { echo "FAIL: $H cert [$S]"; fail=1; }
  echo "$S" | grep -qi "TRAEFIK DEFAULT" && { echo "FAIL: $H default cert"; fail=1; } || echo "PASS: $H not default cert"
done

echo "== 2. direct-origin bypass rejected (no header -> 403, http+https) =="
for T in "$A|origin.website.datatalks.club" "$B|origin.relay.datatalks.club" "$B|origin.dev.relay.datatalks.club"; do
  IP="${T%%|*}"; H="${T##*|}"
  for SCH in http https; do
    C="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: $H" "${SCH}://${IP}/" || echo 000)"
    check "deny $H $SCH" 403 "$C"
  done
done

echo "== 3. CF transport state (read-only; flips recorded in report) =="
for D in E1VNMGFFIXBOXX E33FS79KPFSAOM E3L9KUTE15WFJF E35QPYDA1452SA; do
  P="$(AWS_PROFILE=main-temp aws cloudfront get-distribution --id "$D" \
    --query 'Distribution.DistributionConfig.Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy' --output text 2>/dev/null)"
  echo "INFO: $D origin proto = $P"
done

echo "== 4. public traffic healthy via CF =="
for U in "https://prod.datatalks.club/health/ready" "https://dev.datatalks.club/health/ready" "https://relay.datatalks.club/health/" "https://dev.relay.datatalks.club/health/"; do
  C="$(curl -sk -o /dev/null -w "%{http_code}" -m 12 "$U" || echo 000)"
  check "public $U" 200 "$C"
done

echo "== 5. admin-port firewall still effective =="
C9101="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 "http://${B}:9101/containers/" 2>/dev/null || true)"
check "ext .141:9101" 000 "$C9101"
for H in contabo-a contabo-b; do
  N="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$H" 'sudo iptables -S DOCKER-USER | grep -c ctorigdstport || echo 0')"
  check "${H} DOCKER-USER rules" 8 "$N"
done

echo "== 6. prod docker routers intact (rollback path present) =="
for H in contabo-a contabo-b; do
  F="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$H" 'ls /data/coolify/proxy/dynamic/origin-enforce.yml /data/coolify/proxy/dynamic/origin-verify-canary.yml 2>/dev/null | wc -l')"
  check "${H} file-provider configs" 2 "$F"
done

[[ "$fail" == "0" ]] && echo "ALL ORIGIN CHECKS GREEN" || { echo "ORIGIN CHECKS FAILED" >&2; exit 1; }
