#!/usr/bin/env bash
# Regression test for t1143u cp-rebuild: extended CP bundle + manifest + restore helper.
# Repo-side only: no SSH, no nodes, no secrets needed (shimmed docker/psql).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BU="$REPO/backups"
CONT="$REPO/contingency"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# ---- T1: syntax ----
for f in "$BU/coolify-cp-backup.sh" "$BU/coolify-deploy-inputs.sh" "$BU/install-coolify-cp-backup.sh" "$CONT/coolify-cp-restore.sh"; do
  if bash -n "$f"; then pass "T1 bash -n $(basename "$f")"; else fail "T1 bash -n $(basename "$f")"; fi
done

# ---- T2: shellcheck (skip when absent) ----
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$BU/coolify-deploy-inputs.sh" "$CONT/coolify-cp-restore.sh" 2>&1 | head -5; then
    pass "T2 shellcheck clean (warning+)"
  else
    fail "T2 shellcheck warnings"
  fi
else
  echo "SKIP: T2 shellcheck not installed"; PASS=$((PASS+1))
fi

# ---- T3: manifest never selects secret-bearing columns/values ----
# (comment lines excluded — the policy note names the forbidden columns)
DENY='SELECT \*|postgres_password|smtp_password|resend_api_key|git_full_url|manual_webhook|secret_access|access_token'
if grep -vE '^\s*#' "$BU/coolify-deploy-inputs.sh" | grep -niE "$DENY" >/dev/null 2>&1; then
  fail "T3 manifest denylist hit"; grep -vE '^\s*#' "$BU/coolify-deploy-inputs.sh" | grep -niE "$DENY" | head -5
else
  pass "T3 manifest selects no secret columns"
fi
# environment_variables may appear ONLY inside a count(*) expression (or comments)
if grep -vE '^\s*#' "$BU/coolify-deploy-inputs.sh" | grep -n 'environment_variables' | grep -v 'count(\*) FROM environment_variables' >/dev/null 2>&1; then
  fail "T3b environment_variables used beyond count"; else pass "T3b environment_variables count-only"; fi

# ---- T4: manifest shim run produces sanitized JSON ----
SHIM="$(mktemp -d)"; trap 'rm -rf "$SHIM"' EXIT
cat >"$SHIM/psql-stub" <<'EOF'
#!/usr/bin/env bash
# stub: print canned TSV for the -c argument's table
sql=""
prev=""
for a in "$@"; do [[ "$prev" == "-c" ]] && sql="$a"; prev="$a"; done
case "$sql" in
  *count\(\*\)*FROM*applications*) echo "applications=1 services=1 postgresqls=1 dockers=0 servers=1 projects=1 envs=1 private_keys=1 s3_storages=1 env_vars=5";;
  *instance_settings*) echo "false|0 0 * * *|0 * * * *";;
  *SELECT\ uuid\ FROM\ services*) echo "svc-1";;
  *docker_compose_raw\ FROM\ services*) echo "fake-compose-body";;
  *FROM\ applications\ ORDER*) echo "uuid-1|website-staging|http://x|DataTalksClub/website|main|abc123|dockerfile|||8000||/||/health/ready|running:healthy|App_Models_StandaloneDocker";;
  *FROM\ services\ ORDER*) echo "svc-1|cmp-staging|compose|type|hash1|100";;
  *FROM\ standalone_postgresqls*) echo "pg-1|pg-shared|postgres:16|running:healthy|false||pgadmin|postgres|";;
  *FROM\ standalone_dockers*) echo "";;
  *FROM\ servers\ ORDER*) echo "srv-1|contabo-vps16-2|169.58.124.141|22|root";;
  *application_deployment_queues\ ORDER*) echo "website-staging|abc123|finished|2026-10-23 00:00:00";;
  *) echo "";;
esac
EOF
chmod +x "$SHIM/psql-stub"
cat >"$SHIM/docker-stub" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ps" ]] && exit 0
[[ "$1" == "inspect" ]] && { echo "sha256:deadbeef"; exit 0; }
exit 0
EOF
chmod +x "$SHIM/docker-stub"
export CP_PSQL_CMD="$SHIM/psql-stub"
# manifest script calls `docker` via CP_DOCKER_CMD and systemctl/ufw/iptables directly;
# run with empty PATH additions so host probes degrade gracefully (host dir absent on CI box).
if CP_HOST_ID=shim-host STAMP=shim-stamp CP_DOCKER_CMD="$SHIM/docker-stub" \
    WG_DIR="$SHIM/no-wg" BRIDGE_COMPOSE="$SHIM/no-bridge" PROXY_DIR="$SHIM/no-proxy" \
    bash "$BU/coolify-deploy-inputs.sh" "$SHIM/manifest.json" >/dev/null 2>&1; then
  if python3 -c "import json; d=json.load(open('$SHIM/manifest.json')); assert d['host_id']=='shim-host', d; assert len(d['applications'])==1; assert len(d['services'])==1; assert d['services'][0]['compose_sha256'] and len(d['services'][0]['compose_sha256'])==64; assert any('wg0_conf:absent' in l for l in d['host_config'])" 2>&1; then
    pass "T4 shim manifest valid + sanitized"
  else
    fail "T4 shim manifest content"
  fi
else
  fail "T4 shim manifest run"
fi
# shim manifest must not contain stub secrets (none defined, but assert no forbidden keys)
if grep -niE 'password|secret|token|BEGIN.*PRIVATE' "$SHIM/manifest.json" >/dev/null 2>&1; then
  fail "T4b shim manifest leak"; else pass "T4b shim manifest leak-free"; fi

# ---- T5: restore helper guards ----
if bash "$CONT/coolify-cp-restore.sh" --help >/dev/null 2>&1; then pass "T5a restore --help"; else fail "T5a restore --help"; fi
mkdir -p "$SHIM/guardbin"
cat >"$SHIM/guardbin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ps" ]] && { echo "coolify-db"; exit 0; }
exit 0
EOF
chmod +x "$SHIM/guardbin/docker"
# NB: the helper correctly exits 1 on guard refusal; capture output first so
# pipefail does not turn the expected refusal into a failed condition.
GUARD_OUT="$(PATH="$SHIM/guardbin:$PATH" bash "$CONT/coolify-cp-restore.sh" --host-id x 2>&1 || true)"
if echo "$GUARD_OUT" | grep -q 'live coolify-db'; then
  pass "T5b restore refuses live coolify-db"
else
  fail "T5b restore refuses live coolify-db"
fi

# ---- T6: backup script wires new inputs ----
for needle in 'coolify-deploy-inputs-' 'host/wg/' 'host/acme.json' 'firewall-iptables-v4' 'bridge-compose.ABSENT' 'CP_MANIFEST_GEN'; do
  if grep -qF -- "$needle" "$BU/coolify-cp-backup.sh"; then pass "T6 wires $needle"; else fail "T6 wires $needle"; fi
done
if grep -q 'coolify-deploy-inputs.sh' "$BU/install-coolify-cp-backup.sh"; then
  pass "T6 installer ships manifest generator"
else
  fail "T6 installer ships manifest generator"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
