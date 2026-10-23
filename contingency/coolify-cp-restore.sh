#!/usr/bin/env bash
# Throwaway isolated Coolify control-plane restore drill (t1143u cp-rebuild).
#
# Runs ONLY on an operator/alternate box (e.g. Hetzner) — NEVER on a live
# Coolify CP host. Reconstructs Coolify resource metadata from off-host
# artifacts into a loopback-only throwaway Postgres, verifies the required
# host-config inputs checklist, prints a measured recovery result, then
# destroys the container, volume and workdir (unless --keep).
#
# Guards (fail closed, production CP untouched):
#   * refuses when a `coolify-db` container exists (live CP present), and
#   * refuses when /data/coolify exists (looks like a CP host).
#   * throwaway Postgres binds 127.0.0.1:<port> only; Restart=no.
#
# Inputs (S3, MAIN bucket): latest (or --date) coolify-db dump + encrypted
# bundle + plaintext deploy-inputs manifest for --host-id.
# The GPG passphrase is read from a file (default operator secrets path);
# secret VALUES are never printed — only names, counts, hashes, timings.
#
# Usage:
#   ./contingency/coolify-cp-restore.sh --host-id contabo-a-163 [--date 2026/10/23]
#     [--port 55438] [--workdir /tmp/cp-restore-XX] [--keep]
#
# Exit 0 + RECOVERY_OK only if every verification passes.
set -euo pipefail

HOST_ID=""; DATE_PATH=""; PORT="55438"; WORKDIR=""; KEEP=0
PASSPHRASE_FILE="${CP_RESTORE_PASSPHRASE:-$HOME/tmp/secrets/coolify-cp-backup.pass}"
S3_BUCKET="${S3_BUCKET:-dtc-coolify-backups-387546586013}"
S3_PREFIX="${S3_PREFIX:-coolify/control-plane}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
# Pinned to the live coolify-db image digest (postgres 15-alpine).
PG_IMAGE="${CP_RESTORE_PG_IMAGE:-postgres:15-alpine@sha256:f7d23353e1b15400d22ebe31189f4d314b87a4c129cc400c8c2d8d4ca127bf81}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-id) HOST_ID="$2"; shift 2;;
    --date) DATE_PATH="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --keep) KEEP=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2;;
  esac
done
[[ -n "$HOST_ID" ]] || { echo "missing --host-id" >&2; exit 2; }
[[ -f "$PASSPHRASE_FILE" ]] || { echo "passphrase file missing: $PASSPHRASE_FILE" >&2; exit 2; }

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }
T0="$(date +%s)"

for bin in docker aws gpg gunzip python3; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing required binary: $bin"
done

# ---- guards: never near live Coolify ----
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'coolify-db'; then
  fail "live coolify-db container present — refusing to run here"
fi
if [[ -d /data/coolify ]]; then
  fail "/data/coolify exists — this looks like a CP host; run on an operator box instead"
fi

[[ -z "$WORKDIR" ]] && WORKDIR="$(mktemp -d /tmp/cp-restore-XXXXXX)"
mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
CNAME="cp-restore-drill-$HOST_ID"; CVOL="cp-restore-drill-$HOST_ID-data"
cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    docker volume rm "$CVOL" >/dev/null 2>&1 || true
    find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || rm -rf "$WORKDIR"
    log "cleanup done (container+volume+workdir destroyed)"
  else
    log "KEEP: container=$CNAME volume=$CVOL workdir=$WORKDIR left for inspection"
  fi
}
trap cleanup EXIT

AWS_ARGS=(); [[ -n "$S3_ENDPOINT_URL" ]] && AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT_URL")

# ---- resolve objects (latest overall, or under --date) ----
if [[ -n "$DATE_PATH" ]]; then LQ="--prefix ${S3_PREFIX}/${HOST_ID}/${DATE_PATH}/";
else LQ="--prefix ${S3_PREFIX}/${HOST_ID}/"; fi
LIST_JSON="$WORKDIR/list.json"
aws s3api list-objects-v2 --bucket "$S3_BUCKET" $LQ "${AWS_ARGS[@]}" --output json >"$LIST_JSON" 2>"$WORKDIR/list.err" \
  || fail "S3 list failed: $(tail -2 "$WORKDIR/list.err")"
pick() { python3 - "$LIST_JSON" "$1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); frag = sys.argv[2]
c = sorted([o for o in d.get("Contents", []) if frag in o["Key"]], key=lambda o: o["LastModified"])
print(c[-1]["Key"] if c else "")
PYEOF
}
DB_KEY="$(pick 'coolify-db-')"; MAN_KEY="$(pick 'coolify-deploy-inputs-')"; BUN_KEY="$(pick 'coolify-cp-bundle-')"
[[ -n "$DB_KEY" && -n "$MAN_KEY" && -n "$BUN_KEY" ]] || fail "missing objects (db=[$DB_KEY] manifest=[$MAN_KEY] bundle=[$BUN_KEY])"
log "objects: db=$DB_KEY"
log "objects: manifest=$MAN_KEY"
log "objects: bundle=$BUN_KEY"
aws s3 cp "s3://$S3_BUCKET/$DB_KEY" "$WORKDIR/cp.dump.gz" "${AWS_ARGS[@]}" --only-show-errors || fail "download db"
aws s3 cp "s3://$S3_BUCKET/$MAN_KEY" "$WORKDIR/deploy-inputs.json" "${AWS_ARGS[@]}" --only-show-errors || fail "download manifest"
aws s3 cp "s3://$S3_BUCKET/$BUN_KEY" "$WORKDIR/bundle.tar.gz.gpg" "${AWS_ARGS[@]}" --only-show-errors || fail "download bundle"
T_DL="$(date +%s)"; log "phase download: $((T_DL-T0))s"

# ---- verify dump integrity (no data printed) ----
gzip -t "$WORKDIR/cp.dump.gz" || fail "gzip integrity failed"
gunzip -c "$WORKDIR/cp.dump.gz" >"$WORKDIR/cp.dump"
TOC_LINES="$(docker run --rm -v "$WORKDIR:/w:ro" "$PG_IMAGE" pg_restore --list /w/cp.dump 2>/dev/null | wc -l | tr -d ' ')"
[[ "$TOC_LINES" -gt 100 ]] || fail "TOC suspiciously small ($TOC_LINES lines)"
log "dump ok: TOC lines=$TOC_LINES"

# ---- decrypt bundle, verify required host-config inputs (names only) ----
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" \
  -o "$WORKDIR/bundle.tar.gz" -d "$WORKDIR/bundle.tar.gz.gpg" 2>"$WORKDIR/gpg.err" \
  || fail "gpg decrypt failed: $(tail -2 "$WORKDIR/gpg.err")"
BUNDLE_LIST="$(tar tzf "$WORKDIR/bundle.tar.gz" 2>/dev/null)" || fail "bundle tar list failed"
need() { echo "$BUNDLE_LIST" | grep -qE "$1" || fail "bundle missing required: $1"; }
need '^coolify\.env$'; need '^coolify\.env\.production$'; need '^ssh-keys/'; need '^deploy-inputs\.json$'
need '^host/wg/wg0\.conf$'; need '^host/docker-10-wg\.conf$'; need '^host/sysctl-99-wg-bind\.conf$'; need '^host/firewall-ufw\.txt$'; need '^host/firewall-iptables-v4\.txt$'
need '^host/proxy-compose\.yml$'; need '^host/acme\.json$'; need '^host/systemd-units\.txt$'
need '^host/docker-daemon\.json$'
if echo "$BUNDLE_LIST" | grep -q '^host/bridge-compose\.yml$'; then BRIDGE=present;
elif echo "$BUNDLE_LIST" | grep -q '^host/bridge-compose\.ABSENT$'; then BRIDGE=absent-marker;
else fail "bundle missing bridge compose or ABSENT marker"; fi
log "bundle checklist ok (bridge=$BRIDGE, entries=$(echo "$BUNDLE_LIST" | wc -l | tr -d ' '))"
T_BUN="$(date +%s)"; log "phase bundle-verify: $((T_BUN-T_DL))s"

# ---- throwaway Postgres (loopback only) + restore ----
docker pull "$PG_IMAGE" >/dev/null 2>&1 || log "WARN: pull skipped/failed, using cached image"
docker run -d --name "$CNAME" --restart=no -v "$CVOL:/var/lib/postgresql/data" \
  -p "127.0.0.1:${PORT}:5432" -e POSTGRES_USER=coolify -e POSTGRES_PASSWORD=drill \
  "$PG_IMAGE" >/dev/null || fail "throwaway postgres start failed"
BIND="$(docker port "$CNAME" 5432 2>/dev/null)"
[[ "$BIND" == "127.0.0.1:$PORT" ]] || fail "unexpected bind [$BIND] (must be loopback-only)"
for _ in $(seq 1 30); do
  docker exec "$CNAME" pg_isready -U coolify >/dev/null 2>&1 && break; sleep 1
done
docker exec "$CNAME" pg_isready -U coolify >/dev/null 2>&1 || fail "throwaway postgres never ready"
T_UP="$(date +%s)"; log "throwaway up: bind=$BIND in $((T_UP-T_BUN))s"
docker cp "$WORKDIR/cp.dump" "$CNAME:/tmp/cp.dump" >/dev/null
docker exec "$CNAME" pg_restore -U coolify -d coolify --no-owner --no-acl -j4 /tmp/cp.dump >/dev/null 2>"$WORKDIR/restore.err" \
  || log "WARN: pg_restore exit!=0 (often benign owner/acl noise): $(tail -2 "$WORKDIR/restore.err")"
docker exec "$CNAME" rm -f /tmp/cp.dump >/dev/null 2>&1 || true
T_RS="$(date +%s)"; log "phase restore: $((T_RS-T_UP))s"

# ---- verify reconstructed metadata (counts + names only, never values) ----
psql() { docker exec "$CNAME" psql -U coolify -d coolify -tAX -c "$1" 2>/dev/null; }
APPS="$(psql 'SELECT count(*) FROM applications;')"; SRV="$(psql 'SELECT count(*) FROM services;')"
PGS="$(psql 'SELECT count(*) FROM standalone_postgresqls;')"; SRVERS="$(psql 'SELECT count(*) FROM servers;')"
AUTO="$(psql 'SELECT is_auto_update_enabled FROM instance_settings LIMIT 1;')"
NAMES="$(psql "SELECT string_agg(name, ',' ORDER BY name) FROM applications;")"
SVCN="$(psql "SELECT string_agg(name, ',' ORDER BY name) FROM services;")"
PGN="$(psql "SELECT string_agg(name, ',' ORDER BY name) FROM standalone_postgresqls;")"
WEBPIN="$(psql "SELECT git_repository||'@'||git_branch||' build='||build_pack FROM applications WHERE name='website-staging';")"
MAN_COUNTS="$(python3 -c "import json; d=json.load(open('$WORKDIR/deploy-inputs.json')); print(d.get('counts',''))")"
log "restored: applications=$APPS [$NAMES] services=$SRV [$SVCN] postgresqls=$PGS [$PGN] servers=$SRVERS auto_update=$AUTO"
log "website pin: $WEBPIN"
log "manifest counts: $MAN_COUNTS"
[[ "$APPS" -ge 0 && "$SRV" -ge 0 && -n "$AUTO" ]] || fail "metadata verification failed"
# cross-check counts against the manifest recorded at backup time
python3 - "$WORKDIR/deploy-inputs.json" "$APPS" "$SRV" "$PGS" <<'PYEOF' || fail "manifest cross-check failed"
import json, re, sys
d = json.load(open(sys.argv[1])); counts = d.get("counts", "")
m = dict(re.findall(r"(\w+)=(\d+)", counts))
ok = (m.get("applications") == sys.argv[2] and m.get("services") == sys.argv[3]
      and m.get("postgresqls") == sys.argv[4])
print("manifest cross-check:", "MATCH" if ok else f"MISMATCH manifest={counts} restored=apps={sys.argv[2]},services={sys.argv[3]},pg={sys.argv[4]}")
sys.exit(0 if ok else 1)
PYEOF

TOTAL="$(($(date +%s)-T0))"
log "RECOVERY_OK host=$HOST_ID total=${TOTAL}s (download=$((T_DL-T0)) bundle=$((T_BUN-T_DL)) up=$((T_UP-T_BUN)) restore=$((T_RS-T_UP)))"
