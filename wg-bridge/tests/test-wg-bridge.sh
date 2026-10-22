#!/usr/bin/env bash
# Regression test for the WG bridge reboot-race hardening (t1035u).
# Repo-side only: no SSH, no nodes, no secrets needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WGBRIDGE="$REPO/wg-bridge"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

check_grep() { # $1=file $2=fixed-string $3=label
  if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3 (missing: $2 in $1)"; fi
}

# ---- T1: syntax ----
if bash -n "$WGBRIDGE/install-wg-bridge.sh"; then pass "T1 bash -n install-wg-bridge.sh"; else fail "T1 bash -n install-wg-bridge.sh"; fi

# ---- T2: sysctl persisted ----
check_grep "$WGBRIDGE/99-wg-bind.conf" 'net.ipv4.ip_nonlocal_bind = 1' "T2 sysctl persists ip_nonlocal_bind=1"

# ---- T3: docker ordering drop-in ----
check_grep "$WGBRIDGE/docker-override.conf" 'After=wg-quick@wg0.service' "T3a docker drop-in After wg-quick@wg0"
check_grep "$WGBRIDGE/docker-override.conf" 'Wants=wg-quick@wg0.service' "T3b docker drop-in Wants wg-quick@wg0"
if grep -q '\[Unit\]' "$WGBRIDGE/docker-override.conf"; then pass "T3c docker drop-in has [Unit] section"; else fail "T3c docker drop-in [Unit] section"; fi

# ---- T4: compose-managed bridge ----
check_grep "$WGBRIDGE/docker-compose.yml" 'container_name: pg-shared-wg-bridge' "T4a compose keeps bridge container name"
check_grep "$WGBRIDGE/docker-compose.yml" '10.100.0.2:5432:5432' "T4b compose binds WG IP 10.100.0.2:5432"
check_grep "$WGBRIDGE/docker-compose.yml" 'TCP:ekm57uezdngrrscn0aqzidr8:5432' "T4c compose socat target is pg-shared container name"
if grep -qE 'image:[[:space:]]*[^[:space:]]+:latest' "$WGBRIDGE/docker-compose.yml"; then fail "T4d no :latest image"; else pass "T4d no :latest image"; fi
check_grep "$WGBRIDGE/docker-compose.yml" 'alpine/socat:1.8.0.1' "T4e bridge image pinned (1.8.0.1)"
# The image ENTRYPOINT is already `socat`: command must be exactly the 2
# addresses (a duplicated `socat` arg crash-loops — seen live on 2026-10-22).
if grep -q '"socat"' "$WGBRIDGE/docker-compose.yml"; then fail "T4g command has no duplicated socat binary"; else pass "T4g command has no duplicated socat binary"; fi
if grep -q 'external: true' "$WGBRIDGE/docker-compose.yml"; then pass "T4f compose reuses external coolify network"; else fail "T4f external coolify network"; fi

# ---- T5: systemd unit ordering ----
check_grep "$WGBRIDGE/pg-shared-wg-bridge.service" 'After=wg-quick@wg0.service docker.service' "T5a unit After wg0 + docker"
check_grep "$WGBRIDGE/pg-shared-wg-bridge.service" 'WantedBy=multi-user.target' "T5b unit enabled at boot"
check_grep "$WGBRIDGE/pg-shared-wg-bridge.service" 'docker compose up -d' "T5c unit starts bridge via compose"

# ---- T6: installer behavior ----
check_grep "$WGBRIDGE/install-wg-bridge.sh" 'sysctl --system' "T6a installer applies sysctl live"
check_grep "$WGBRIDGE/install-wg-bridge.sh" 'docker.service.d/10-wg.conf' "T6b installer installs docker drop-in"
check_grep "$WGBRIDGE/install-wg-bridge.sh" 'systemctl daemon-reload' "T6c installer daemon-reloads"
check_grep "$WGBRIDGE/install-wg-bridge.sh" 'systemctl enable pg-shared-wg-bridge' "T6d installer enables bridge unit"
check_grep "$WGBRIDGE/install-wg-bridge.sh" '--sysctl-only' "T6e installer supports peer-only mode"

# ---- T7: compose config validates (needs docker; skipped without it) ----
if command -v docker >/dev/null 2>&1; then
  if (cd "$WGBRIDGE" && docker compose config >/dev/null 2>&1); then
    pass "T7 docker compose config validates"
  else
    fail "T7 docker compose config validates"
  fi
else
  echo "SKIP: T7 docker compose config (no docker on operator box)"
fi

# ---- T8: no credential values in deployed artifacts ----
# (policy prose in README/test is fine — scan only what lands on nodes)
if grep -rniE 'PASSWORD\s*=|PASSWD\s*=|BEGIN .*PRIVATE KEY|APP_KEY\s*=|[A-Za-z0-9]{32,}' "$WGBRIDGE/docker-compose.yml" "$WGBRIDGE/pg-shared-wg-bridge.service" "$WGBRIDGE/99-wg-bind.conf" "$WGBRIDGE/docker-override.conf" >/dev/null; then
  fail "T8 no credential values in deployed artifacts (match found)"
else
  pass "T8 no credential values in deployed artifacts"
fi

echo
echo "wg-bridge tests: $PASS passed, $FAILN failed"
[[ "$FAILN" == "0" ]]
