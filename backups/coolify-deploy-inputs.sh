#!/usr/bin/env bash
# Sanitized Coolify deployment-inputs manifest for host reconstruction (t1143u).
#
# Runs ON a Coolify CP host (called by backups/coolify-cp-backup.sh, or
# standalone for inspection). Emits a JSON manifest with the exact inputs
# needed to reproduce every Coolify-managed resource WITHOUT any secret
# values: resource identity, git source pins, build packs, image digests,
# ports, domains, destinations, plus sha256/length fingerprints (never
# content) of blobs that may embed credentials (compose raw, Dockerfiles,
# acme.json) and a required-host-config checklist with present/absent state.
#
# Secret policy (load-bearing): this script must NEVER output secret values.
# Only allow-listed columns are SELECTed; sensitive blobs are fingerprinted
# with sha256sum (hashes + byte lengths only). `environment_variables`,
# `private_keys`, `s3_storages`, passwords, tokens and webhook secrets are
# never queried. `git_full_url` is excluded (may embed a PAT).
#
# Env (all optional; CP_*_CMD support shim testing):
#   CP_HOST_ID, CP_DB_CONTAINER (default coolify-db), CP_DB_USER (coolify),
#   CP_DB_NAME (coolify), STAMP (default Europe/Berlin now),
#   CP_PSQL_CMD (default: docker exec "$CP_DB_CONTAINER" psql -U.. -d.. -tAX),
#   CP_DOCKER_CMD (default: docker), WG_DIR, BRIDGE_COMPOSE, PROXY_DIR,
#   UFW_CMD (default: ufw status numbered), IPTABLES_CMD.
# Output: $1 (file path) or stdout when omitted.
set -euo pipefail

CP_HOST_ID="${CP_HOST_ID:-unknown-host}"
CP_DB_CONTAINER="${CP_DB_CONTAINER:-coolify-db}"
CP_DB_USER="${CP_DB_USER:-coolify}"
CP_DB_NAME="${CP_DB_NAME:-coolify}"
STAMP="${STAMP:-$(TZ=Europe/Berlin date '+%Y%m%dT%H%M%z')}"
CP_DOCKER_CMD="${CP_DOCKER_CMD:-docker}"
CP_PSQL_CMD="${CP_PSQL_CMD:-docker exec $CP_DB_CONTAINER psql -U $CP_DB_USER -d $CP_DB_NAME -tAX -F	-q}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
BRIDGE_COMPOSE="${BRIDGE_COMPOSE:-/opt/pg-shared-wg-bridge/docker-compose.yml}"
PROXY_DIR="${PROXY_DIR:-/data/coolify/proxy}"
OUT="${1:-/dev/stdout}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# q <outfile> <sql> — run one allow-listed SELECT, never fail the manifest.
q() { $CP_PSQL_CMD -c "$2" >"$WORK/$1" 2>"$WORK/$1.err" || { echo "SQL_ERROR $1" >"$WORK/$1"; }; }

# ---- resource metadata (allow-listed columns only) ----
q counts "SELECT 'applications='||(SELECT count(*) FROM applications)||' services='||(SELECT count(*) FROM services)||' postgresqls='||(SELECT count(*) FROM standalone_postgresqls)||' dockers='||(SELECT count(*) FROM standalone_dockers)||' servers='||(SELECT count(*) FROM servers)||' projects='||(SELECT count(*) FROM projects)||' envs='||(SELECT count(*) FROM environments)||' private_keys='||(SELECT count(*) FROM private_keys)||' s3_storages='||(SELECT count(*) FROM s3_storages)||' env_vars='||(SELECT count(*) FROM environment_variables);"
q autoupdate "SELECT is_auto_update_enabled||'|'||auto_update_frequency||'|'||update_check_frequency FROM instance_settings LIMIT 1;"
q applications "SELECT uuid||'|'||name||'|'||coalesce(fqdn,'')||'|'||git_repository||'|'||git_branch||'|'||git_commit_sha||'|'||build_pack||'|'||coalesce(docker_registry_image_name,'')||'|'||coalesce(docker_registry_image_tag,'')||'|'||coalesce(ports_exposes,'')||'|'||coalesce(ports_mappings,'')||'|'||base_directory||'|'||coalesce(dockerfile_location,'')||'|'||health_check_path||'|'||status||'|'||coalesce(destination_type,'') FROM applications ORDER BY name;"
q services "SELECT uuid||'|'||name||'|'||coalesce(service_type,'')||'|'||coalesce(destination_type,'')||'|'||coalesce(config_hash,'')||'|'||coalesce(length(docker_compose_raw),0) FROM services ORDER BY name;"
# Compose-body fingerprints hashed in a pipe (content never touches disk).
: >"$WORK/service_hashes"
for svc in $($CP_PSQL_CMD -c "SELECT uuid FROM services ORDER BY name;" 2>/dev/null); do
  [[ -n "$svc" ]] || continue
  h="$($CP_PSQL_CMD -c "SELECT docker_compose_raw FROM services WHERE uuid='$svc';" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  printf '%s|%s\n' "$svc" "$h" >>"$WORK/service_hashes"
done
q postgresqls "SELECT uuid||'|'||name||'|'||coalesce(image,'')||'|'||status||'|'||coalesce(is_public::text,'')||'|'||coalesce(public_port::text,'')||'|'||coalesce(postgres_user,'')||'|'||coalesce(postgres_db,'')||'|'||coalesce(ports_mappings,'') FROM standalone_postgresqls ORDER BY name;"
q dockers "SELECT uuid||'|'||name FROM standalone_dockers ORDER BY name;"
q servers "SELECT uuid||'|'||name||'|'||coalesce(ip,'')||'|'||coalesce(port::text,'')||'|'||coalesce(\"user\",'') FROM servers ORDER BY name;"
q deploys "SELECT application_name||'|'||left(commit,40)||'|'||status||'|'||updated_at FROM application_deployment_queues ORDER BY id DESC LIMIT 20;"

# ---- running image digests (content-addressed repro inputs) ----
{
$CP_DOCKER_CMD inspect coolify --format '{{.Image}}' 2>/dev/null || echo unknown
} >"$WORK/coolify_image" 2>/dev/null || echo unknown >"$WORK/coolify_image"
{
for c in $($CP_DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -vE '^(coolify|coolify-db|coolify-redis|coolify-proxy|coolify-sentinel|victoria|vector|lgtm|pg-shared-wg-bridge)' || true); do
  img="$($CP_DOCKER_CMD inspect "$c" --format '{{.Config.Image}} {{.Image}}' 2>/dev/null || true)"
  [[ -n "$img" ]] || continue
  iid="${img##* }"
  digests="$($CP_DOCKER_CMD inspect "$iid" --format '{{.RepoDigests}}' 2>/dev/null || true)"
  printf '%s image=%s digests=%s\n' "$c" "$img" "${digests:-none}"
done
} >"$WORK/app_images" 2>/dev/null || true

# ---- host config checklist: present/absent + fingerprints (no content) ----
fp() { # fp <label> <path>: "<label>:present:sha256:bytes" or "<label>:absent"
  if [[ -f "$1" ]]; then printf '%s:present:%s:%s\n' "$2" "$(sha256sum <"$1" | cut -d' ' -f1)" "$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1")";
  elif [[ -d "$1" ]]; then printf '%s:dir:%d-files\n' "$2" "$(find "$1" -type f 2>/dev/null | wc -l | tr -d ' ')";
  else printf '%s:absent\n' "$2"; fi
}
{
  fp "$WG_DIR/wg0.conf" wg0_conf
  n=0; for f in "$WG_DIR"/*.conf "$WG_DIR"/*.key "$WG_DIR"/*.pub; do [[ -e "$f" ]] && n=$((n+1)); done
  echo "wireguard_files=$n"
  fp "$BRIDGE_COMPOSE" bridge_compose
  fp /etc/systemd/system/docker.service.d/10-wg.conf docker_wg_dropin
  fp /etc/sysctl.d/99-wg-bind.conf sysctl_wg_bind
  fp /etc/docker/daemon.json docker_daemon
  fp "$PROXY_DIR/docker-compose.yml" proxy_compose
  fp "$PROXY_DIR/acme.json" proxy_acme
  if [[ -d "$PROXY_DIR/dynamic" ]]; then
    find "$PROXY_DIR/dynamic" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | tr '\n' ',' | xargs -I{} echo "proxy_dynamic={}"
  else echo "proxy_dynamic=absent"; fi
  for u in pg-shared-wg-bridge edge-docker-user-restore docker wg-quick@wg0; do
    e="$(systemctl is-enabled "$u" 2>/dev/null)"; e="${e:-unknown}"
    a="$(systemctl is-active "$u" 2>/dev/null)"; a="${a:-unknown}"
    printf '%s:enabled=%s:active=%s\n' "$u" "$e" "$a"
  done
  echo -n "ufw_rules="; (sudo -n ufw status numbered 2>/dev/null || ufw status numbered 2>/dev/null) | grep -cE '^\[' || echo 0
  echo -n "docker_user_rules="; (sudo -n iptables -S DOCKER-USER 2>/dev/null || iptables -S DOCKER-USER 2>/dev/null) | grep -cE '^-A' || echo 0
} >"$WORK/hostcheck" 2>/dev/null || echo "hostcheck_failed" >"$WORK/hostcheck"

python3 - "$WORK" "$OUT" "$CP_HOST_ID" "$STAMP" <<'PYEOF'
import json, sys
w, out, host, stamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def read(n):
    try:
        with open(f"{w}/{n}") as f: return f.read()
    except Exception: return ""
def rows(n, fields):
    out_r = []
    for line in read(n).splitlines():
        if not line or line.startswith("SQL_ERROR"): continue
        parts = line.split("|")
        if len(parts) < len(fields): continue
        out_r.append(dict(zip(fields, parts)))
    return out_r
hashes = {}
for line in read("service_hashes").splitlines():
    if "|" in line:
        u, h = line.split("|", 1)
        hashes[u.strip()] = h.strip()
services = rows("services", ["uuid","name","service_type","destination_type","config_hash","compose_bytes"])
for s in services:
    s["compose_sha256"] = hashes.get(s["uuid"], "unavailable")
manifest = {
  "schema": "coolify-deploy-inputs/v1",
  "host_id": host, "stamp_berlin": stamp,
  "counts": read("counts").strip(),
  "auto_update": read("autoupdate").strip(),
  "coolify_image": read("coolify_image").strip(),
  "running_app_images": [l for l in read("app_images").splitlines() if l.strip()],
  "applications": rows("applications", ["uuid","name","fqdn","git_repository","git_branch","git_commit_sha","build_pack","registry_image","registry_tag","ports_exposes","ports_mappings","base_directory","dockerfile_location","health_check_path","status","destination_type"]),
  "services": services,
  "postgresqls": rows("postgresqls", ["uuid","name","image","status","is_public","public_port","pg_user","pg_db","ports_mappings"]),
  "standalone_dockers": rows("dockers", ["uuid","name"]),
  "servers": rows("servers", ["uuid","name","ip","port","user"]),
  "recent_deployments": rows("deploys", ["application","commit","status","updated_at"]),
  "host_config": [l for l in read("hostcheck").splitlines() if l.strip()],
}
with open(out, "w") as f: json.dump(manifest, f, indent=2, sort_keys=True)
print(f"MANIFEST_OK host={host} apps={len(manifest['applications'])} services={len(manifest['services'])} pg={len(manifest['postgresqls'])}")
PYEOF
