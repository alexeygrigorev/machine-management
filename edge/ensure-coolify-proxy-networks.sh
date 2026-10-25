#!/usr/bin/env bash
# Keep coolify-proxy attached to every Coolify app service network it routes.
#
# Root cause (2026-10-25, relay-dev + cmp-dev): Coolify creates one bridge
# network per compose service (e.g. t9uudl5ik40webxrzamrm8qy for relay-dev,
# qjnpmney8j8ehfuqcmzpjtzt for cmp-dev). The proxy compose file
# (/data/coolify/proxy/docker-compose.yml) declares ONLY the `coolify`
# network. Coolify attaches the proxy to service networks with an ephemeral
# `docker network connect` when the service is (re)deployed — that state is
# NOT in the compose file, so the next `docker compose up -d traefik`
# (e.g. the 00:09 UTC metrics-endpoint change) reconciles the proxy back to
# `coolify` alone and drops every service attachment. Traefik then blackholes
# those backends (SYN into an unattached bridge -> DOCKER-ISOLATION DROP ->
# hang, 0 bytes, curl 000) while `coolify`-network backends (prod rolling
# containers) stay green.
#
# What this script does (idempotent, no deletions, no restarts):
#   - discovers required networks: every RUNNING container with
#     traefik.enable=true and a non-coolify traefik.docker.network label;
#   - --check: exit 0 when the proxy has them all, exit 1 listing MISSING
#     (for monitors; changes nothing);
#   - --apply (default): `docker network connect` each missing network,
#     then patch the proxy compose file declaratively so the NEXT recreate
#     preserves them (backup before write, never removes anything);
#   - --patch-compose-only: only the compose-file step (used by the metrics
#     installer before `docker compose up -d traefik`).
#
# Run ON the Contabo host (as root or a docker-capable user). No secrets.
# Cron: edge/proxy-network-keep.cron runs --apply every 2 min (self-heal);
# monitors/coolify-proxy-networks.sh runs --check logic independently and
# pages dev@ when the proxy is still detached.
#
# Usage:
#   sudo ./edge/ensure-coolify-proxy-networks.sh [--check|--apply|--patch-compose-only]
#   PROXY_CONTAINER=coolify-proxy COMPOSE_FILE=/data/coolify/proxy/docker-compose.yml \
#     sudo -E ./edge/ensure-coolify-proxy-networks.sh --check
set -euo pipefail

MODE="--apply"
for a in "$@"; do
  case "$a" in
    --check|--apply|--patch-compose-only) MODE="$a" ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--check|--apply|--patch-compose-only]" >&2; exit 2 ;;
  esac
done

PROXY_CONTAINER="${PROXY_CONTAINER:-coolify-proxy}"
COMPOSE_FILE="${COMPOSE_FILE:-/data/coolify/proxy/docker-compose.yml}"
SKIP_NETS="coolify bridge host none"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing required binary: $1"; exit 1; }; }
need docker
[[ "$MODE" == "--check" ]] || need python3

in_skip() {
  local n="$1" s
  for s in $SKIP_NETS; do [[ "$n" == "$s" ]] && return 0; done
  return 1
}

# ---- discover required service networks from live Traefik routing labels ----
discover_required() {
  local names n en net
  names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
  for n in $names; do
    en="$(docker inspect --format '{{index .Config.Labels "traefik.enable"}}' "$n" 2>/dev/null || true)"
    [[ "$en" == "true" ]] || continue
    net="$(docker inspect --format '{{index .Config.Labels "traefik.docker.network"}}' "$n" 2>/dev/null || true)"
    # Template renders "<no value>" when the label is absent — treat as empty.
    case "$net" in ""|"<no value>"|"<no value> "*|*" <no value>"*) continue ;; esac
    in_skip "$net" && continue
    # Only require networks that exist locally (a routed container implies it,
    # but a half-removed stack must not fail the check on a ghost name).
    if docker network inspect "$net" >/dev/null 2>&1; then
      echo "$net"
    else
      log "WARN: routed container $n wants missing network $net — skipping"
    fi
  done | sort -u
}

proxy_has_network() {
  # $1=network -> 0 when attached
  local net="$1"
  docker inspect "$PROXY_CONTAINER" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); nets=(d[0] if isinstance(d,list) else d).get("NetworkSettings",{}).get("Networks",{}); sys.exit(0 if sys.argv[1] in nets else 1)' "$net" 2>/dev/null
}

REQUIRED="$(discover_required || true)"
if [[ -z "${REQUIRED// /}" ]]; then
  log "OK: no non-coolify routed service networks required (proxy=$PROXY_CONTAINER)"
  exit 0
fi
log "required service networks: $(echo "$REQUIRED" | tr '\n' ' ')proxy=$PROXY_CONTAINER"

MISSING=""
for net in $REQUIRED; do
  if proxy_has_network "$net"; then
    log "OK attached: $net"
  else
    log "MISSING: proxy $PROXY_CONTAINER not on $net"
    MISSING="$MISSING $net"
  fi
done

if [[ "$MODE" == "--check" ]]; then
  if [[ -n "${MISSING// /}" ]]; then
    log "CHECK_FAIL missing:${MISSING}"
    exit 1
  fi
  log "CHECK_OK proxy has all routed service networks"
  exit 0
fi

# ---- --apply: reconnect missing (no restart, fully reversible) ----
if [[ "$MODE" == "--apply" ]]; then
  for net in $MISSING; do
    # $MISSING has a leading space; guard the empty expansion.
    [[ -n "$net" ]] || continue
    if docker network connect "$net" "$PROXY_CONTAINER" 2>/dev/null; then
      log "CONNECTED: $PROXY_CONTAINER -> $net"
    else
      # Re-check: a concurrent healer may have beaten us (idempotent).
      if proxy_has_network "$net"; then
        log "OK attached (raced): $net"
      else
        log "ERROR: docker network connect $net $PROXY_CONTAINER failed"
        exit 1
      fi
    fi
  done
fi

# ---- declarative compose patch (both --apply and --patch-compose-only) ----
if [[ ! -f "$COMPOSE_FILE" ]]; then
  log "WARN: compose file not found: $COMPOSE_FILE (connect step done; declarative patch skipped)"
  [[ -n "${MISSING// /}" && "$MODE" == "--apply" ]] && log "APPLY_OK runtime reattached; compose patch skipped (file absent)"
  exit 0
fi

NETS_ARG="$(echo "$REQUIRED" | tr '\n' ' ')"
# shellcheck disable=SC2086
if python3 - "$COMPOSE_FILE" $NETS_ARG <<'PY'
import re, sys
path, nets = sys.argv[1], [n for n in sys.argv[2:] if n]
t = open(path).read()
orig = t
changed = []
for net in nets:
  # 1. top-level networks: exact "<net>:" key (regex, never a prefix match —
  #    a network named e.g. "coolifylike" must not match "coolify").
  if not re.search(rf"^  {re.escape(net)}:\s*$", t, re.M):
    anchor = "\nnetworks:\n"
    if anchor in t:
      t = t.replace(anchor, f"{anchor}  {net}:\n    external: true\n", 1)
      changed.append(f"top-network:{net}")
    else:
      # No top-level networks block (unexpected for the Coolify proxy file):
      # append one rather than failing silently.
      if not t.endswith("\n"):
        t += "\n"
      t += f"networks:\n  {net}:\n    external: true\n"
      changed.append(f"top-network:{net}")
  # 2. service attachment: exact "      - <net>" line under
  #    services.traefik.networks (again exact — never a prefix of another
  #    network name, and never a label value like traefik.docker.network=X).
  if not re.search(rf"^      - {re.escape(net)}\s*$", t, re.M):
    m = re.search(r"^      - coolify\s*$", t, re.M)
    if m:
      t = t[:m.end()] + f"\n      - {net}" + t[m.end():]
      changed.append(f"service-net:{net}")
    else:
      print(f"WARN no service anchor for {net}; runtime connect still applies")
if t != orig:
  import datetime
  bak = path + ".bak-proxy-nets-" + datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
  open(bak, "w").write(orig)
  open(path, "w").write(t)
  print("PATCHED", path, "backup", bak, "added", ",".join(changed))
else:
  print("COMPOSE_OK", path, "already declares", ",".join(nets))
PY
then
  log "compose declarative step done"
else
  log "ERROR: compose patch failed for $COMPOSE_FILE"
  exit 1
fi

if [[ "$MODE" == "--patch-compose-only" ]]; then
  log "PATCH_ONLY_OK (no runtime connect attempted)"
  exit 0
fi

if [[ -n "${MISSING// /}" ]]; then
  log "APPLY_OK reattached:${MISSING} + compose declares required networks (next recreate preserves them)"
else
  log "APPLY_OK already durable (runtime + compose agree)"
fi
