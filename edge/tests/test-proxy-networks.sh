#!/usr/bin/env bash
# Regression test: coolify-proxy network durability (2026-10-25 incident).
#
# Covers without touching prod and without docker daemon for most cases:
#   T1  bash -n on all new/patched scripts
#   T2  compose declarative patch: adds external + service nets, idempotent,
#       preserves metrics flags/ports, never removes coolify
#   T3  ensure --check with stub docker: detached -> FAIL/1, attached -> OK/0
#   T4  ensure --apply with stub docker: connects missing + patches compose
#   T5  metrics installer still patches metrics flags AND preserves nets
#   T6  monitor pager: detached -> FAIL/1 + dev@-only alert state; attached -> OK
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ENSURE="$REPO/edge/ensure-coolify-proxy-networks.sh"
METRICS="$REPO/edge/install-traefik-metrics.sh"
MONITOR="$REPO/monitors/coolify-proxy-networks.sh"

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# ---- T1: syntax ----
T1_OK=1
for f in "$ENSURE" "$METRICS" "$MONITOR" \
  "$REPO/edge/install-proxy-network-keep.sh" \
  "$REPO/monitors/install-coolify-proxy-networks.sh"; do
  bash -n "$f" || { T1_OK=0; echo "syntax fail: $f"; }
done
if [[ "$T1_OK" == "1" ]]; then pass "T1 bash -n (ensure+metrics+monitor+installers)"; else fail "T1 bash -n"; fi

# ---- fixture: minimal proxy compose like Contabo (metrics present, coolify only) ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
cat > "$TMP/docker-compose.yml" <<'YML'
name: coolify-proxy
networks:
  coolify:
    external: true
services:
  traefik:
    container_name: coolify-proxy
    image: 'traefik:v3.7'
    networks:
      - coolify
    ports:
      - '80:80'
      - '8080:8080'
      - '10.100.0.2:8082:8082'
      - '127.0.0.1:8082:8082'
    command:
      - '--metrics.prometheus=true'
      - '--entrypoints.metrics.address=:8082'
      - '--api.insecure=false'
      - '--providers.docker=true'
YML

# ---- T2: compose patch via python (same logic as ensure script) ----
cp "$TMP/docker-compose.yml" "$TMP/t2.yml"
python3 - "$TMP/t2.yml" qjnpmney8j8ehfuqcmzpjtzt t9uudl5ik40webxrzamrm8qy <<'PY'
import sys
path, nets = sys.argv[1], sys.argv[2:]
t = open(path).read()
orig = t
for net in nets:
  if f"\n  {net}:" not in t and not t.startswith(f"  {net}:"):
    if "\nnetworks:\n" in t:
      t = t.replace("\nnetworks:\n", f"\nnetworks:\n  {net}:\n    external: true\n", 1)
  if f"- {net}" not in t and "      - coolify" in t:
    t = t.replace("      - coolify", f"      - coolify\n      - {net}", 1)
open(path, "w").write(t)
print("patched" if t != orig else "noop")
PY
T2_OK=1
grep -q "qjnpmney8j8ehfuqcmzpjtzt:" "$TMP/t2.yml" || T2_OK=0
grep -q "t9uudl5ik40webxrzamrm8qy:" "$TMP/t2.yml" || T2_OK=0
grep -q "\- qjnpmney8j8ehfuqcmzpjtzt" "$TMP/t2.yml" || T2_OK=0
grep -q "\- t9uudl5ik40webxrzamrm8qy" "$TMP/t2.yml" || T2_OK=0
grep -q "metrics.prometheus=true" "$TMP/t2.yml" || T2_OK=0
grep -q "127.0.0.1:8082:8082" "$TMP/t2.yml" || T2_OK=0
grep -q "external: true" "$TMP/t2.yml" || T2_OK=0
# idempotent: second run changes nothing
sha1="$(sha256sum "$TMP/t2.yml" | cut -d' ' -f1)"
python3 - "$TMP/t2.yml" qjnpmney8j8ehfuqcmzpjtzt t9uudl5ik40webxrzamrm8qy <<'PY'
import sys
path, nets = sys.argv[1], sys.argv[2:]
t = open(path).read()
orig = t
for net in nets:
  if f"\n  {net}:" not in t and not t.startswith(f"  {net}:"):
    if "\nnetworks:\n" in t:
      t = t.replace("\nnetworks:\n", f"\nnetworks:\n  {net}:\n    external: true\n", 1)
  if f"- {net}" not in t and "      - coolify" in t:
    t = t.replace("      - coolify", f"      - coolify\n      - {net}", 1)
open(path, "w").write(t)
PY
sha2="$(sha256sum "$TMP/t2.yml" | cut -d' ' -f1)"
[[ "$sha1" == "$sha2" ]] || T2_OK=0
if [[ "$T2_OK" == "1" ]]; then pass "T2 compose patch adds + idempotent + preserves metrics"; else fail "T2 compose patch"; sed -n '1,60p' "$TMP/t2.yml"; fi

# ---- stub docker for T3/T4/T6 ----
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/docker" <<'EOF'
#!/usr/bin/env bash
# Stub docker for proxy-network tests. State via env:
#   STUB_PROXY_NETS="coolify netA netB"  (networks the proxy is on)
#   STUB_WANT_NET="qjnpmney8j8ehfuqcmzpjtzt" (service net the routed app needs)
#   STUB_LOG="$TMP/docker-calls.log" appended with "network connect <net> <ctr>"
set -euo pipefail
if [[ "${1:-}" == "ps" ]]; then
  echo "coolify-proxy"; echo "web-dev-stub"; exit 0
fi
if [[ "${1:-}" == "inspect" ]]; then
  # forms: docker inspect --format '...' <name>  |  docker inspect <name>
  fmt=""; name=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format) fmt="$2"; shift 2;;
      -f) fmt="$2"; shift 2;;
      *) name="$1"; shift;;
    esac
  done
  if [[ "$name" == "coolify-proxy" && -z "$fmt" ]]; then
    # full JSON for python parsing: build Networks object from STUB_PROXY_NETS
    python3 -c 'import json,os; nets=os.environ.get("STUB_PROXY_NETS","coolify").split(); print(json.dumps([{"NetworkSettings":{"Networks":{n:{} for n in nets}}}]))'
    exit 0
  fi
  case "$fmt" in
    *traefik.enable*) [[ "$name" == "web-dev-stub" ]] && { echo "true"; exit 0; }; echo "<no value>"; exit 0;;
    *traefik.docker.network*) [[ "$name" == "web-dev-stub" ]] && { echo "${STUB_WANT_NET:-qjnpmney8j8ehfuqcmzpjtzt}"; exit 0; }; echo "coolify"; exit 0;;
    *) echo "<no value>"; exit 0;;
  esac
fi
if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
  # any service net exists in the stub world
  exit 0
fi
if [[ "${1:-}" == "network" && "${2:-}" == "connect" ]]; then
  echo "network connect $3 $4" >> "${STUB_LOG:-/dev/null}"
  exit 0
fi
echo "stub docker: unsupported: $*" >&2; exit 99
EOF
chmod +x "$TMP/stubbin/docker"

# ---- T3: ensure --check detached vs attached ----
cp "$TMP/docker-compose.yml" "$TMP/t3.yml"
out=""; rc=0
set +e
STUB_PROXY_NETS="coolify" STUB_WANT_NET="qjnpmney8j8ehfuqcmzpjtzt" STUB_LOG="$TMP/t3.log" \
  PROXY_CONTAINER=coolify-proxy COMPOSE_FILE="$TMP/t3.yml" \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$ENSURE" --check > "$TMP/t3.out" 2>&1; rc=$?
set -e
out="$(cat "$TMP/t3.out")"
if [[ $rc -ne 0 && "$out" == *"MISSING"* && "$out" == *"qjnpmney8j8ehfuqcmzpjtzt"* ]]; then
  pass "T3a --check detached FAILs with MISSING (rc=$rc)"
else
  fail "T3a --check detached (rc=$rc) -- $out"
fi
set +e
STUB_PROXY_NETS="coolify qjnpmney8j8ehfuqcmzpjtzt" STUB_WANT_NET="qjnpmney8j8ehfuqcmzpjtzt" \
  PROXY_CONTAINER=coolify-proxy COMPOSE_FILE="$TMP/t3.yml" \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$ENSURE" --check > "$TMP/t3b.out" 2>&1; rc=$?
set -e
if [[ $rc -eq 0 && "$(cat "$TMP/t3b.out")" == *"CHECK_OK"* ]]; then
  pass "T3b --check attached passes"
else
  fail "T3b --check attached (rc=$rc) -- $(cat "$TMP/t3b.out")"
fi

# ---- T4: ensure --apply connects + patches compose ----
cp "$TMP/docker-compose.yml" "$TMP/t4.yml"
: > "$TMP/t4.log"
set +e
STUB_PROXY_NETS="coolify" STUB_WANT_NET="t9uudl5ik40webxrzamrm8qy" STUB_LOG="$TMP/t4.log" \
  PROXY_CONTAINER=coolify-proxy COMPOSE_FILE="$TMP/t4.yml" \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$ENSURE" --apply > "$TMP/t4.out" 2>&1; rc=$?
set -e
T4_OK=1
[[ $rc -eq 0 ]] || T4_OK=0
grep -q "network connect t9uudl5ik40webxrzamrm8qy coolify-proxy" "$TMP/t4.log" || T4_OK=0
grep -q "t9uudl5ik40webxrzamrm8qy:" "$TMP/t4.yml" || T4_OK=0
grep -q "\- t9uudl5ik40webxrzamrm8qy" "$TMP/t4.yml" || T4_OK=0
grep -q "metrics.prometheus=true" "$TMP/t4.yml" || T4_OK=0
if [[ "$T4_OK" == "1" ]]; then pass "T4 --apply connects missing + declares in compose"; else fail "T4 --apply"; cat "$TMP/t4.out"; cat "$TMP/t4.log"; fi

# ---- T5: metrics installer preserves nets (static check) ----
T5_OK=1
grep -q "PRESERVES coolify-proxy" "$METRICS" || T5_OK=0
grep -q "ensure-coolify-proxy-networks.sh --patch-compose-only" "$METRICS" || T5_OK=0
grep -q "ensure-coolify-proxy-networks.sh --apply" "$METRICS" || T5_OK=0
grep -q "metrics.prometheus" "$METRICS" || T5_OK=0
grep -q "127.0.0.1:8082" "$METRICS" || T5_OK=0
if [[ "$T5_OK" == "1" ]]; then pass "T5 metrics installer preserves proxy nets + keeps metrics"; else fail "T5 metrics installer"; fi

# ---- T6: monitor detached FAILs dev@-only, attached OK ----
mkdir -p "$TMP/mstate"
cat > "$TMP/stubbin/sendmail" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/stubbin/sendmail"
set +e
STUB_PROXY_NETS="coolify" STUB_WANT_NET="qjnpmney8j8ehfuqcmzpjtzt" \
  COOLIFY_PROXY_NETWORKS_ENV_FILE=/nonexistent STATE_DIR="$TMP/mstate" LOCK_FILE="$TMP/mlock" \
  ALERT_TO=dev@dtcdev.click ALERT_FROM=noreply@test \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$MONITOR" > "$TMP/m1.out" 2>&1; rc=$?
set -e
M1="$(cat "$TMP/m1.out"; echo; cat "$TMP/mstate"/proxy-networks.state 2>/dev/null || true)"
if [[ $rc -ne 0 && "$M1" == *"FAIL check=proxy-networks"* && "$M1" == *"STATUS=FAIL"* && "$M1" == *"to=dev@dtcdev.click"* ]]; then
  pass "T6a monitor detached FAILs, dev@-only state"
else
  fail "T6a monitor detached (rc=$rc) -- $M1"
fi
set +e
STUB_PROXY_NETS="coolify qjnpmney8j8ehfuqcmzpjtzt" STUB_WANT_NET="qjnpmney8j8ehfuqcmzpjtzt" \
  COOLIFY_PROXY_NETWORKS_ENV_FILE=/nonexistent STATE_DIR="$TMP/mstate" LOCK_FILE="$TMP/mlock" \
  ALERT_TO=dev@dtcdev.click ALERT_FROM=noreply@test \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$MONITOR" > "$TMP/m2.out" 2>&1; rc=$?
set -e
if [[ $rc -eq 0 && "$(cat "$TMP/m2.out")" == *"ALL_OK"* ]]; then
  pass "T6b monitor attached ALL_OK (+RECOVERED path)"
else
  fail "T6b monitor attached (rc=$rc) -- $(cat "$TMP/m2.out")"
fi

# ---- T7: prefix safety — sibling network "coolifylike" must survive ----
cp "$TMP/docker-compose.yml" "$TMP/t7.yml"
# add a prefix-colliding sibling (service + top-level) next to real coolify
python3 - "$TMP/t7.yml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("  coolify:\n    external: true\n",
              "  coolify:\n    external: true\n  coolifylike:\n    name: somecoolifynet\n", 1)
t = t.replace("      - coolify\n", "      - coolify\n      - coolifylike\n", 1)
open(p, "w").write(t)
PY
: > "$TMP/t7.log"
set +e
STUB_PROXY_NETS="coolify somecoolifynet" STUB_WANT_NET="t9uudl5ik40webxrzamrm8qy" STUB_LOG="$TMP/t7.log" \
  PROXY_CONTAINER=coolify-proxy COMPOSE_FILE="$TMP/t7.yml" \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$ENSURE" --apply > "$TMP/t7.out" 2>&1; rc=$?
set -e
T7_OK=1
[[ $rc -eq 0 ]] || T7_OK=0
grep -q "^      - coolify$" "$TMP/t7.yml" || T7_OK=0
grep -q "^      - coolifylike$" "$TMP/t7.yml" || T7_OK=0   # sibling untouched
grep -q "^      - t9uudl5ik40webxrzamrm8qy$" "$TMP/t7.yml" || T7_OK=0
if grep -q "t9uudl5ik40webxrzamrm8qylike" "$TMP/t7.yml"; then T7_OK=0; fi  # corruption guard
if grep -q "^      - coolifylike.*t9uudl" "$TMP/t7.yml"; then T7_OK=0; fi
if [[ "$T7_OK" == "1" ]]; then pass "T7 prefix-safe patch (coolifylike intact)"; else fail "T7 prefix safety"; cat "$TMP/t7.out"; cat "$TMP/t7.yml"; fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
