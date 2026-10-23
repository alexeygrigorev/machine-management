#!/usr/bin/env bash
# Phase 1: origin TLS routers (NO enforcement yet) via Traefik file provider.
# Adds https + LE certResolver routers for the origin hostnames on one host.
# No Coolify saves, no restarts, no traffic impact: http behavior unchanged.
#
# Run from OPERATOR box: ./edge/origin-tls-enforce/install-origin-tls.sh contabo-a
#                        ./edge/origin-tls-enforce/install-origin-tls.sh contabo-b
# Then waits for LE issuance and verifies each hostname serves a real cert.
set -euo pipefail

HOST="${1:-}"
[[ -n "$HOST" ]] || { echo "usage: $0 <contabo-a|contabo-b>" >&2; exit 2; }
[[ "$HOST" =~ ^contabo-[ab]$ ]] || { echo "unknown host" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

# Bootstrap only: rolling deployment owns the current backend references and
# retry middleware. Replaying this historical renderer would undo that mapping.
"${SSH[@]}" "$HOST" 'sudo test ! -f /data/coolify/proxy/dynamic/origin-enforce.yml' \
  || { echo "refusing: enforcement already installed; preserve current rolling backends (see README.md)" >&2; exit 2; }

# slug|hostname|docker-service per host (services are uuid-derived, stable).
# Includes the VIEWER hostnames: CF allViewer policies forward viewer Host+SNI
# to the origin, so origin TLS must cover them (verified live 23 Oct: CF sent
# SNI=dev.relay.datatalks.club and got default-cert close/503 without it).
if [[ "$HOST" == "contabo-a" ]]; then
  ENTRIES=("website|origin.website.datatalks.club|http-0-wodajblzizrjunwme3ossav3@docker"
           "websiteprod|prod.datatalks.club|http-0-wodajblzizrjunwme3ossav3@docker"
           "websitedev|dev.datatalks.club|http-0-wodajblzizrjunwme3ossav3@docker")
  IP="169.58.119.163"
elif [[ "$HOST" == "contabo-b" ]]; then
  ENTRIES=("relay|origin.relay.datatalks.club|http-0-fjnzwomg8n42lztloo34just-web-2567@docker"
           "relaypub|relay.datatalks.club|http-0-fjnzwomg8n42lztloo34just-web-2567@docker"
           "relaydev|origin.dev.relay.datatalks.club|http-0-t9uudl5ik40webxrzamrm8qy-web-2567@docker"
           "relaydevpub|dev.relay.datatalks.club|http-0-t9uudl5ik40webxrzamrm8qy-web-2567@docker")
  IP="169.58.124.141"
else
  echo "unknown host $HOST" >&2; exit 2
fi

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
{
  echo "http:"
  echo "  routers:"
  for E in "${ENTRIES[@]}"; do
    IFS='|' read -r SLUG H SVC <<<"$E"
    cat <<Y
    origin-${SLUG}-tls:
      rule: "Host(\`${H}\`)"
      service: "${SVC}"
      entryPoints:
        - https
      priority: 190
      tls:
        certResolver: letsencrypt
Y
  done
} > "$RENDERED"
python3 -c "import yaml,sys; yaml.safe_load(open('$RENDERED'))" && echo "yaml OK"

scp "$RENDERED" "${HOST}:/tmp/origin-tls-phase1.yml"
"${SSH[@]}" "$HOST" sudo bash -s <<'EOF'
set -euo pipefail
install -m 0644 -o root -g root /tmp/origin-tls-phase1.yml /data/coolify/proxy/dynamic/origin-tls-phase1.yml
rm -f /tmp/origin-tls-phase1.yml
sleep 5   # file provider watch
echo "installed; checking traefik for parse errors:"
if docker logs coolify-proxy --since 60s 2>&1 | grep -iE "error.*origin-.*tls|failed.*origin-.*tls" | head -3; then
  echo "WARN: traefik errors above" >&2
else
  echo "no traefik errors"
fi
EOF

echo "--- waiting for LE issuance (up to 5 min per hostname) ---"
FAIL=0
for E in "${ENTRIES[@]}"; do
  IFS='|' read -r SLUG H SVC <<<"$E"
  OK=0
  for i in $(seq 1 30); do
    if curl --silent --noproxy '*' --max-time 8 --output /dev/null \
        --resolve "${H}:443:${IP}" "https://${H}/"; then
      echo "OK: $H certificate trust, validity and hostname verified"
      OK=1; break
    fi
    sleep 10
  done
  [[ "$OK" == "1" ]] || { echo "FAIL: no valid trusted cert for $H yet" >&2; FAIL=1; }
done
[[ "$FAIL" == "0" ]] && echo "PHASE1 GREEN on ${HOST}" || { echo "PHASE1 INCOMPLETE on ${HOST}" >&2; exit 1; }
