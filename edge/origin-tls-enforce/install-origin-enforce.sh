#!/usr/bin/env bash
# Phase 2: origin verification enforcement (file provider, reversible).
# Installs allow (header-gated, prio 200) + deny (prio 150) routers shadowing
# the Coolify docker routers (prio ~55). Then verifies the gate AND tests
# rollback (remove file -> old behavior -> reinstall).
#
# Header values come from process-memory env only (read-only CF reads):
#   contabo-a: V_WEB_PROD (E1VNMGFFIXBOXX) + V_WEB_DEV (E33FS79KPFSAOM)
#     V_WEB_PROD="$(aws ... get-distribution --id E1VNMGFFIXBOXX ...)" ./install-origin-enforce.sh contabo-a
#   contabo-b: V_RELAY_PROD (E3L9KUTE15WFJF) + V_RELAY_DEV (E35QPYDA1452SA)
#
# Values must match ^[A-Za-z0-9_=-]+$ or the script refuses (rule-injection guard).
set -euo pipefail

HOST="${1:-}"
[[ -n "$HOST" ]] || { echo "usage: V_*=... $0 <contabo-a|contabo-b>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

valid() { [[ "$1" =~ ^[A-Za-z0-9_=-]{16,128}$ ]]; }

# slug|hostname|service|value1|value2(empty ok)|health
# Hostnames include the VIEWER names CF forwards (allViewer Origin Request
# Policies): viewer Host+SNI reaches the origin, so TLS+enforcement must cover
# prod/dev.datatalks.club (.163) and relay/dev.relay.datatalks.club (.141).
if [[ "$HOST" == "contabo-a" ]]; then
  : "${V_WEB_PROD:?set V_WEB_PROD}"; : "${V_WEB_DEV:?set V_WEB_DEV}"
  valid "$V_WEB_PROD" || { echo "bad V_WEB_PROD charset" >&2; exit 2; }
  valid "$V_WEB_DEV" || { echo "bad V_WEB_DEV charset" >&2; exit 2; }
  ENTRIES=("website|origin.website.datatalks.club|http-0-wodajblzizrjunwme3ossav3@docker|$V_WEB_PROD|$V_WEB_DEV|/health/ready"
           "websiteprod|prod.datatalks.club|http-0-wodajblzizrjunwme3ossav3@docker|$V_WEB_PROD||/health/ready"
           "websitedev|dev.datatalks.club|http-0-wodajblzizrjunwme3ossav3@docker|$V_WEB_DEV||/health/ready")
  IP="169.58.119.163"
elif [[ "$HOST" == "contabo-b" ]]; then
  : "${V_RELAY_PROD:?set V_RELAY_PROD}"; : "${V_RELAY_DEV:?set V_RELAY_DEV}"
  valid "$V_RELAY_PROD" || { echo "bad V_RELAY_PROD charset" >&2; exit 2; }
  valid "$V_RELAY_DEV" || { echo "bad V_RELAY_DEV charset" >&2; exit 2; }
  ENTRIES=("relay|origin.relay.datatalks.club|http-0-fjnzwomg8n42lztloo34just-web-2567@docker|$V_RELAY_PROD||/health/"
           "relaypub|relay.datatalks.club|http-0-fjnzwomg8n42lztloo34just-web-2567@docker|$V_RELAY_PROD||/health/"
           "relaydev|origin.dev.relay.datatalks.club|http-0-t9uudl5ik40webxrzamrm8qy-web-2567@docker|$V_RELAY_DEV||/health/"
           "relaydevpub|dev.relay.datatalks.club|http-0-t9uudl5ik40webxrzamrm8qy-web-2567@docker|$V_RELAY_DEV||/health/")
  IP="169.58.124.141"
else
  echo "unknown host $HOST" >&2; exit 2
fi

# Header alternatives fragment for the allow rules.
headers_frag() { # $1=v1 $2=v2-or-empty -> "Header(`X-Origin-Verify`, `v1`)" [+ " || Header(...v2)"]
  local f="Header(\`X-Origin-Verify\`, \`$1\`)"
  [[ -n "${2:-}" ]] && f="$f || Header(\`X-Origin-Verify\`, \`$2\`)"
  printf '%s' "$f"
}

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
{
  echo "http:"
  echo "  middlewares:"
  for E in "${ENTRIES[@]}"; do
    IFS='|' read -r SLUG H SVC V1 V2 HP <<<"$E"
    echo "    origin-${SLUG}-deny:"
    echo "      ipAllowList:"
    echo "        sourceRange:"
    echo '          - "127.0.0.1/32"'
  done
  echo "  routers:"
  for E in "${ENTRIES[@]}"; do
    IFS='|' read -r SLUG H SVC V1 V2 HP <<<"$E"
    HF="$(headers_frag "$V1" "$V2")"
    cat <<Y
    origin-${SLUG}-allow-http:
      rule: "Host(\`${H}\`) && (${HF} || PathPrefix(\`/.well-known/acme-challenge/\`))"
      service: "${SVC}"
      entryPoints:
        - http
      priority: 200
    origin-${SLUG}-allow-tls:
      rule: "Host(\`${H}\`) && (${HF})"
      service: "${SVC}"
      entryPoints:
        - https
      priority: 200
      tls:
        certResolver: letsencrypt
    origin-${SLUG}-deny-http:
      rule: "Host(\`${H}\`)"
      service: "${SVC}"
      middlewares:
        - origin-${SLUG}-deny
      entryPoints:
        - http
      priority: 150
    origin-${SLUG}-deny-tls:
      rule: "Host(\`${H}\`)"
      service: "${SVC}"
      middlewares:
        - origin-${SLUG}-deny
      entryPoints:
        - https
      priority: 150
      tls:
        certResolver: letsencrypt
Y
  done
} > "$RENDERED"
python3 -c "import yaml; d=yaml.safe_load(open('$RENDERED')); print('yaml OK:', sorted(d['http']['routers']))"

install_file() {
  scp "$RENDERED" "${HOST}:/tmp/origin-enforce.yml"
  "${SSH[@]}" "$HOST" sudo bash -s <<'EOF'
set -euo pipefail
rm -f /data/coolify/proxy/dynamic/origin-tls-phase1.yml  # superseded by allow-tls
install -m 0600 -o root -g root /tmp/origin-enforce.yml /data/coolify/proxy/dynamic/origin-enforce.yml
rm -f /tmp/origin-enforce.yml
sleep 5
if docker logs coolify-proxy --since 60s 2>&1 | grep -iE "error.*origin-" | head -3; then
  echo "WARN: traefik errors above" >&2
fi
echo installed
EOF
}

gate_check() { # prints PASS/FAIL lines; returns 0 iff gate holds
  local fail=0
  for E in "${ENTRIES[@]}"; do
    IFS='|' read -r SLUG H SVC V1 V2 HP <<<"$E"
    local no_h no_h_s with_h with_h_s
    no_h="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: $H" "http://${IP}/")"
    no_h_s="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: $H" "https://${IP}/")"
    with_h="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: $H" -H "X-Origin-Verify: $V1" "http://${IP}${HP}")"
    with_h_s="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: $H" -H "X-Origin-Verify: $V1" "https://${IP}${HP}")"
    [[ "$no_h" == "403" ]] && echo "PASS: $H http no-header -> 403" || { echo "FAIL: $H http no-header -> $no_h"; fail=1; }
    [[ "$no_h_s" == "403" ]] && echo "PASS: $H https no-header -> 403" || { echo "FAIL: $H https no-header -> $no_h_s"; fail=1; }
    [[ "$with_h" =~ ^(200|301|302)$ ]] && echo "PASS: $H http+header -> $with_h" || { echo "FAIL: $H http+header -> $with_h"; fail=1; }
    [[ "$with_h_s" =~ ^(200|301|302)$ ]] && echo "PASS: $H https+header -> $with_h_s" || { echo "FAIL: $H https+header -> $with_h_s"; fail=1; }
  done
  return "$fail"
}

echo "== installing enforcement on ${HOST} =="
install_file
echo "== gate check =="
gate_check || { echo "GATE FAILED after install" >&2; exit 1; }

echo "== rollback test: remove file -> old behavior must return =="
"${SSH[@]}" "$HOST" sudo bash -s <<'EOF'
rm -f /data/coolify/proxy/dynamic/origin-enforce.yml && sleep 5 && echo removed
EOF
RB_FAIL=0
for E in "${ENTRIES[@]}"; do
  IFS='|' read -r SLUG H SVC V1 V2 HP <<<"$E"
  CODE="$(curl -sk -o /dev/null -w "%{http_code}" -m 8 -H "Host: $H" "http://${IP}/")"
  [[ "$CODE" =~ ^(200|301|302)$ ]] && echo "PASS: rollback $H http no-header -> $CODE (old behavior)" \
    || { echo "FAIL: rollback $H -> $CODE"; RB_FAIL=1; }
done
[[ "$RB_FAIL" == "0" ]] || { echo "ROLLBACK TEST FAILED" >&2; exit 1; }

echo "== reinstalling enforcement =="
install_file
gate_check || { echo "GATE FAILED after reinstall" >&2; exit 1; }
echo "PHASE2 GREEN on ${HOST} (gate verified + rollback tested)"
