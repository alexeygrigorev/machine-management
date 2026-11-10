#!/usr/bin/env bash
# Offline regression test for chain-only DOCKER-USER persistence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/edge/docker-user-restore.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
export STUB_LOG="$TMP/calls.log"
export STUB_RULES="$TMP/full-rules.v4"
cat > "$STUB_RULES" <<'RULES'
*raw
:PREROUTING ACCEPT [0:0]
COMMIT
*filter
:INPUT ACCEPT [0:0]
:DOCKER-USER - [0:0]
:FORWARD ACCEPT [0:0]
-A INPUT -j ACCEPT
-A DOCKER-USER -s 10.100.0.0/24 -j RETURN
-A DOCKER-USER -i eth0 -j DROP
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
COMMIT
RULES
export STUB_RULES

cat > "$TMP/bin/iptables" <<'STUB'
#!/usr/bin/env bash
printf 'iptables %s\n' "$*" >> "$STUB_LOG"
STUB
cat > "$TMP/bin/ip6tables" <<'STUB'
#!/usr/bin/env bash
printf 'ip6tables %s\n' "$*" >> "$STUB_LOG"
STUB
cat > "$TMP/bin/iptables-save" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_RULES"
STUB
cat > "$TMP/bin/ip6tables-save" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_RULES"
STUB
cat > "$TMP/bin/iptables-restore" <<'STUB'
#!/usr/bin/env bash
printf 'iptables-restore %s\n' "$*" >> "$STUB_LOG"
cat >> "$STUB_LOG"
STUB
cat > "$TMP/bin/ip6tables-restore" <<'STUB'
#!/usr/bin/env bash
printf 'ip6tables-restore %s\n' "$*" >> "$STUB_LOG"
cat >> "$STUB_LOG"
STUB
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/"*

PATH="$TMP/bin:$PATH" EDGE_DOCKER_USER_STATE_DIR="$TMP/state" \
  OPERATOR_V4=192.0.2.1 OPERATOR_V6=2001:db8::1 PEER_V4=198.51.100.1 \
  bash "$SCRIPT" apply > "$TMP/apply.out"
RULES="$TMP/state/edge-docker-user-rules.v4"
[[ -s "$RULES" ]]
[[ "$(grep -c '^\*nat' "$RULES" || true)" == 0 ]]
grep -q '^\*filter$' "$RULES"
grep -q '^:DOCKER-USER ' "$RULES"
[[ "$(grep -c '^-A DOCKER-USER ' "$RULES")" == 2 ]]
[[ "$(stat -c '%a' "$RULES")" == 600 ]]
grep -q -- '-A DOCKER-USER -i eth0 -j DROP' "$STUB_LOG" || {
  # The stub logs iptables commands; the fixture remains the saved source.
  echo 'expected public-interface default drop in apply commands' >&2
  exit 1
}
grep -q -- 'iptables -A DOCKER-USER ! -i eth0 -s 10.0.0.0/8 -j RETURN' "$STUB_LOG" || {
  echo 'expected private-source exception to exclude the public interface' >&2
  exit 1
}

: > "$STUB_LOG"
PATH="$TMP/bin:$PATH" EDGE_DOCKER_USER_STATE_DIR="$TMP/state" \
  bash "$SCRIPT" restore > "$TMP/restore.out"
grep -q '^iptables -F DOCKER-USER$' "$STUB_LOG"
grep -q '^iptables-restore --noflush$' "$STUB_LOG"
grep -q '^\*filter$' "$STUB_LOG"
! grep -q '^\*nat$' "$STUB_LOG"
echo 'PASS: apply persists only DOCKER-USER and restore uses --noflush'
