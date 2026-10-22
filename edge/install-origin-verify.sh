#!/usr/bin/env bash
# Install the X-Origin-Verify canary on one Contabo Traefik (t1037u).
# Prod routers untouched; no DNS/CF changes. Proves the Headers() gate +
# fallback-deny pattern for the future https-only maintenance window.
#
# Run from OPERATOR box:
#   X_ORIGIN_VERIFY="<from CF CustomHeaders, read-only>" ./edge/install-origin-verify.sh contabo-b [canary-service]
# Defaults: contabo-b -> relay service, contabo-a -> website service.
set -euo pipefail

HOST="${1:-}"
[[ -n "$HOST" ]] || { echo "usage: X_ORIGIN_VERIFY=... $0 <ssh-host> [canary-service@docker]" >&2; exit 2; }
: "${X_ORIGIN_VERIFY:?set X_ORIGIN_VERIFY from the CloudFront CustomHeaders value (read-only AWS call)}"
CANARY_SERVICE="${2:-}"
if [[ -z "$CANARY_SERVICE" ]]; then
  [[ "$HOST" == "contabo-a" ]] \
    && CANARY_SERVICE="http-0-wodajblzizrjunwme3ossav3@docker" \
    || CANARY_SERVICE="http-0-fjnzwomg8n42lztloo34just-web-2567@docker"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
IP=""; [[ "$HOST" == "contabo-a" ]] && IP="169.58.119.163" || IP="169.58.124.141"

# Render locally (secret never leaves this box except into the host file 0600).
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
ESCAPED="$(printf '%s' "$X_ORIGIN_VERIFY" | sed -e 's/[&|\\]/\\&/g')"
sed -e "s|__X_ORIGIN_VERIFY__|${ESCAPED}|g" -e "s|__CANARY_SERVICE__|${CANARY_SERVICE}|g" \
  "${HERE}/origin-verify.yml.example" > "$RENDERED"
grep -q "__X_ORIGIN_VERIFY__\|__CANARY_SERVICE__" "$RENDERED" && { echo "template render failed" >&2; exit 1; }

set +x
scp "$RENDERED" "${HOST}:/tmp/origin-verify-canary.yml"
"${SSH[@]}" "$HOST" sudo bash -s <<'EOF'
set -euo pipefail
install -m 0600 -o root -g root /tmp/origin-verify-canary.yml /data/coolify/proxy/dynamic/origin-verify-canary.yml
rm -f /tmp/origin-verify-canary.yml
sleep 4   # file provider watch picks it up
if docker logs coolify-proxy --since 30s 2>&1 | grep -iE "error.*origin-verify|failed.*origin-verify" | head -3; then
  echo "WARN: traefik logged errors about the canary file (see above)" >&2
fi
echo "canary installed"
EOF

echo "--- canary tests (prod untouched) ---"
# NOTE: the canary hostname is intentionally unknown to the apps, so the
# allow-path may return the app's own 4xx for a bad Host. What proves the
# gate is the BODY difference: Traefik-level deny is exactly "Forbidden",
# while the allow-path reaches the backend (any other body).
NO_BODY="$(curl -sk -m 8 -H "Host: edge-verify-canary.invalid" "http://${IP}/")"
echo "no header    -> body: $(printf '%s' "$NO_BODY" | head -c 60)"
WITH_BODY="$(curl -sk -m 8 -H "Host: edge-verify-canary.invalid" -H "X-Origin-Verify: ${X_ORIGIN_VERIFY}" "http://${IP}/")"
echo "with header  -> body: $(printf '%s' "$WITH_BODY" | head -c 60)"
[[ "$NO_BODY" == "Forbidden" ]] || { echo "FAIL: canary deny is not Traefik-403" >&2; exit 1; }
[[ "$WITH_BODY" != "Forbidden" ]] || { echo "FAIL: allow-path did not reach backend" >&2; exit 1; }
echo "OK: canary Header() gate proven on ${HOST} (deny=Traefik 403, allow=reaches backend)"
