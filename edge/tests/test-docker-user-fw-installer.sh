#!/usr/bin/env bash
# Ensure the operator installer passes its host selector and removes only the
# audited UFW allow rules without executing any remote commands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/edge/docker-user-fw.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/scp" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGS'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$STUB_LOG"
cat > "$STUB_REMOTE"
STUB
chmod +x "$TMP/bin/"*

PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/a.log" STUB_REMOTE="$TMP/a.remote" \
  bash "$SCRIPT" contabo-a >/dev/null
grep -q '<HOST=contabo-a>' "$TMP/a.log"
grep -Fq "'10\.100\.0\.0/24'" "$TMP/a.remote"
grep -q 'for port in 3100 9090 9093' "$TMP/a.remote"

PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/b.log" STUB_REMOTE="$TMP/b.remote" \
  bash "$SCRIPT" contabo-b >/dev/null
grep -q '<HOST=contabo-b>' "$TMP/b.log"
! grep -q 'for port in 3100 9090 9093' "$TMP/b.remote"

echo 'PASS: installer passes host and targets only audited UFW rules'
