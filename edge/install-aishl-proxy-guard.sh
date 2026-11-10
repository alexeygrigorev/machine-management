#!/usr/bin/env bash
# Install the AISHL Traefik rate limiter and guard the dev router.
# Run after the change is merged; only contabo-b is in scope.
set -euo pipefail

HOST="${1:-contabo-b}"
[[ "$HOST" == "contabo-b" ]] || { echo "usage: $0 [contabo-b]" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
REMOTE_TMP="/tmp/aishl-proxy-guard-${STAMP}-$$"

cleanup() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "rm -rf -- '$REMOTE_TMP'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "mkdir -m 0700 -- '$REMOTE_TMP'"
scp -q "$HERE/traefik/aishl-ratelimit.yml" "$HERE/traefik/patch-aisl-dev-route.py" "$HOST:$REMOTE_TMP/"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" sudo bash -s -- "$REMOTE_TMP" "$STAMP" <<'REMOTE'
set -euo pipefail
tmp="$1"
stamp="$2"
directory=/data/coolify/proxy/dynamic
route="$directory/aisl-dev-route.yml"
[[ -f "$route" ]] || { echo "ERROR: expected live AISHL dev route is missing: $route" >&2; exit 1; }
install -d -o root -g root -m 0755 "$directory"
for destination in "$directory/aishl-ratelimit.yml" "$route"; do
  if [[ -f "$destination" ]]; then
    cp -a -- "$destination" "$destination.bak-$stamp"
  fi
done
# Load the middleware definition first, then atomically add references to the
# existing dev router while preserving its Coolify-owned backend service URL.
install -o root -g root -m 0644 -- "$tmp/aishl-ratelimit.yml" "$directory/aishl-ratelimit.yml"
python3 "$tmp/patch-aisl-dev-route.py" "$route"
sha256sum "$directory/aishl-ratelimit.yml" "$route"
REMOTE

echo "AISHL proxy guard installed on $HOST. The file provider reloads these files without a proxy restart."
echo "Next: allow the one-at-a-time rolling follower to update the AISHL production router labels, then verify one IP receives 429 and an independent /ping remains 200."
