#!/usr/bin/env bash
# Guarded CloudFront origin transport switch for ONE in-scope (dist, origin).
# Changes ONLY CustomOriginConfig.OriginProtocolPolicy of the named origin;
# every other field is passed back byte-identical with a fresh ETag.
#
# Refuses to switch TO https-only unless origin readiness is live-verified:
#   https + correct header -> 2xx/3xx AND https no-header -> 403
# (prevents blackholing CF traffic). Always prints the exact rollback command.
#
# Usage (operator box):
#   ./edge/origin-tls-enforce/cf-origin-flip.sh E35QPYDA1452SA relay-dev-shared-alb https-only
#   ./edge/origin-tls-enforce/cf-origin-flip.sh E35QPYDA1452SA relay-dev-shared-alb http-only   # rollback
set -euo pipefail

DIST="${1:-}"; ORIGIN_ID="${2:-}"; WANT="${3:-}"
[[ -n "$DIST" && -n "$ORIGIN_ID" && "$WANT" =~ ^(https-only|http-only)$ ]] \
  || { echo "usage: $0 <dist-id> <origin-id> <https-only|http-only>" >&2; exit 2; }
[[ "$DIST" =~ ^(E1VNMGFFIXBOXX|E33FS79KPFSAOM|E3L9KUTE15WFJF|E35QPYDA1452SA)$ ]] \
  || { echo "refusing: $DIST is not an in-scope t1143u distribution" >&2; exit 2; }

AWS=(aws --profile main-temp --region eu-west-1)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ETAG="$("${AWS[@]}" cloudfront get-distribution --id "$DIST" --query ETag --output text)"
"${AWS[@]}" cloudfront get-distribution --id "$DIST" --query Distribution.DistributionConfig > "$TMP/cfg.json"
DOMAIN="$("${AWS[@]}" cloudfront get-distribution --id "$DIST" \
  --query "Distribution.DistributionConfig.Origins.Items[?Id=='$ORIGIN_ID'].DomainName | [0]" --output text)"
CUR="$("${AWS[@]}" cloudfront get-distribution --id "$DIST" \
  --query "Distribution.DistributionConfig.Origins.Items[?Id=='$ORIGIN_ID'].CustomOriginConfig.OriginProtocolPolicy | [0]" --output text)"
HDR="$("${AWS[@]}" cloudfront get-distribution --id "$DIST" \
  --query "Distribution.DistributionConfig.Origins.Items[?Id=='$ORIGIN_ID'].CustomHeaders.Items[?HeaderName=='X-Origin-Verify'].HeaderValue | [0]" --output text)"
[[ "$DOMAIN" != "None" && -n "$DOMAIN" ]] || { echo "refusing: origin $ORIGIN_ID not found on $DIST" >&2; exit 2; }
echo "dist=$DIST origin=$ORIGIN_ID domain=$DOMAIN current=$CUR want=$WANT (header configured: $([[ -n "$HDR" && "$HDR" != "None" ]] && echo yes || echo NO)"
[[ "$CUR" == "$WANT" ]] && { echo "already $WANT, nothing to do"; exit 0; }

if [[ "$WANT" == "https-only" ]]; then
  [[ -n "$HDR" && "$HDR" != "None" ]] || { echo "refusing: CF would not send X-Origin-Verify" >&2; exit 2; }
  [[ "$HDR" =~ ^[A-Za-z0-9_=-]{16,128}$ ]] || { echo "refusing: unexpected header charset" >&2; exit 2; }
  # Readiness: origin must serve valid TLS + enforce the header, live, now.
  OK_HTTPS="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: $DOMAIN" -H "X-Origin-Verify: $HDR" "https://$DOMAIN/health/" || true)"
  # website answers /health/ready; accept either path probe
  if [[ ! "$OK_HTTPS" =~ ^(200|301|302)$ ]]; then
    OK_HTTPS="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: $DOMAIN" -H "X-Origin-Verify: $HDR" "https://$DOMAIN/health/ready" || true)"
  fi
  DENY_HTTPS="$(curl -sk -o /dev/null -w "%{http_code}" -m 10 -H "Host: $DOMAIN" "https://$DOMAIN/" || true)"
  SUBJ="$(echo | timeout 8 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
  echo "readiness: https+header=$OK_HTTPS https-no-header=$DENY_HTTPS cert=[$SUBJ]"
  [[ "$OK_HTTPS" =~ ^(200|301|302)$ ]] || { echo "refusing: origin https+header not healthy" >&2; exit 2; }
  [[ "$DENY_HTTPS" == "403" ]] || { echo "refusing: origin https enforcement not active" >&2; exit 2; }
  echo "$SUBJ" | grep -q "CN *= *$DOMAIN" || { echo "refusing: cert CN mismatch" >&2; exit 2; }
  echo "$SUBJ" | grep -qi "TRAEFIK DEFAULT" && { echo "refusing: default cert" >&2; exit 2; } || true
fi

python3 - "$TMP/cfg.json" "$ORIGIN_ID" "$WANT" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
oid, want = sys.argv[2], sys.argv[3]
hit = [o for o in cfg["Origins"]["Items"] if o["Id"] == oid]
assert len(hit) == 1, "origin id not unique"
hit[0]["CustomOriginConfig"]["OriginProtocolPolicy"] = want
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
print(f"patched {oid} -> {want}, everything else identical")
EOF

echo "ROLLBACK (run if CF-served health fails): $0 $DIST $ORIGIN_ID http-only"
read -r -p "Apply $DIST $ORIGIN_ID -> $WANT ? [type YES] " ANS
[[ "$ANS" == "YES" ]] || { echo "aborted"; exit 3; }

ETAG2="$("${AWS[@]}" cloudfront get-distribution --id "$DIST" --query ETag --output text)"
[[ "$ETAG2" == "$ETAG" ]] || { echo "refusing: distribution changed under us (ETag moved)" >&2; exit 2; }
"${AWS[@]}" cloudfront update-distribution --id "$DIST" --if-match "$ETAG" \
  --distribution-config "file://$TMP/cfg.json" --output json > "$TMP/upd.json"
python3 -c "import json; u=json.load(open('$TMP/upd.json')); print('update:', u['Distribution']['Status'], u['Distribution']['DistributionConfig']['Origins']['Items'][0]['CustomOriginConfig']['OriginProtocolPolicy'])"

echo "waiting for Status=Deployed (poll 30s, up to 15 min)..."
for i in $(seq 1 30); do
  ST="$("${AWS[@]}" cloudfront get-distribution --id "$DIST" --query Distribution.Status --output text)"
  echo "  [$i] $ST"
  [[ "$ST" == "Deployed" ]] && break
  sleep 30
done
[[ "$ST" == "Deployed" ]] && echo "FLIP DONE: $DIST $ORIGIN_ID -> $WANT" || { echo "STILL DEPLOYING (verify before proceeding)" >&2; exit 1; }
