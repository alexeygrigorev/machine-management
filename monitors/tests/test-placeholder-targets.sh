#!/usr/bin/env bash
# Reject reserved test targets before probes, state changes or alert delivery.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
for binary in curl docker msmtp sendmail; do
  printf '#!/usr/bin/env bash\necho invoked >> "$SIDE_EFFECTS"\nexit 99\n' > "$TMP/bin/$binary"
  chmod +x "$TMP/bin/$binary"
done
export SIDE_EFFECTS="$TMP/side-effects"
for setting in APP_URLS CONTENT_CHECKS; do
  for target in 'https://relay.example.test/health/' 'https://EXAMPLE.TEST.:443/health/' 'https://user:password@nested.relay.example.test/health/'; do
    printf '%s=%q\n' "$setting" "relay=$target::ok" > "$TMP/env"
    set +e
    output="$(PATH="$TMP/bin:$PATH" COOLIFY_HEALTHCHECK_ENV_FILE="$TMP/env" \
      APP_URLS= CONTENT_CHECKS= SKIP_PUBLIC_HTTP_CHECKS=1 \
      STATE_DIR="$TMP/state" bash "$HERE/../coolify-healthcheck.sh" 2>&1)"
    rc=$?
    set -e
    [[ "$rc" == 2 && "$output" == *'ERROR: reserved example.test host'* ]]
    [[ "$output" != *password* && ! -e "$SIDE_EFFECTS" && ! -d "$TMP/state" ]]
  done
done
echo 'PASS: APP_URLS and CONTENT_CHECKS reject example.test hosts before side effects, including skipped public checks'
