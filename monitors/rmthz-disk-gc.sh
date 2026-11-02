#!/usr/bin/env bash
# Conservative RMTHZ disk GC. Dry-run is the default; --apply is explicit.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: rmthz-disk-gc.sh [--dry-run|--apply] [--trigger daily|disk-warn|manual]

Dry-run is the default. --apply enables only the bounded cleanup rules below.
The script is intended to run as Alexey's normal user on RMTHZ.
EOF
}

MODE="${RMTHZ_GC_MODE:-dry-run}"
TRIGGER=manual
while (($#)); do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --trigger) shift; (($#)) || { usage >&2; exit 2; }; TRIGGER="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$TRIGGER" in daily|disk-warn|manual) ;; *) echo "invalid trigger: $TRIGGER" >&2; exit 2 ;; esac

host_short="$(hostname -s 2>/dev/null || hostname)"
[[ "${host_short,,}" == *rmthz* || "${RMTHZ_GC_ALLOW_HOST:-0}" == 1 ]] || {
  echo "Refusing: host is not RMTHZ (set RMTHZ_GC_ALLOW_HOST=1 only for isolated development)." >&2; exit 1;
}

STATE_DIR="${RMTHZ_GC_STATE_DIR:-$HOME/.local/state/rmthz-disk-gc}"
LOG="$STATE_DIR/removals.tsv"
REPORT_DIR="${RMTHZ_GC_REPORT_DIR:-$HOME/tmp/agent-reports}"
[[ "$MODE" == dry-run || "$MODE" == apply ]] || { echo "RMTHZ_GC_MODE must be dry-run or apply" >&2; exit 2; }
mkdir -p "$STATE_DIR" "$REPORT_DIR"
touch "$LOG"
chmod 600 "$LOG"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { echo "GC already running; skipping"; exit 0; }

now_epoch=$(date +%s)
printf 'run=%s mode=%s trigger=%s root=' "$(date -u +%FT%TZ)" "$MODE" "$TRIGGER"
df -B1 --output=avail / | tail -n 1 | tr -d ' '

record() {
  local path="$1" bytes="$2" reason="$3" action="$4"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$action" "$bytes" "$reason" "$path" >> "$LOG"
  local row
  row=$(printf '%-10s %10s  %-38s %s' "$action" "$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "$bytes B")" "$reason" "$path")
  printf '%s\n' "$row"
  [[ -z "${report_tmp:-}" ]] || printf '%s\n' "$row" >> "$report_tmp"
}
size_bytes() { du -s -B1 -- "$1" 2>/dev/null | awk '{print $1+0}'; }
newest_mtime() {
  python3 - "$1" <<'PY'
import os, sys
import time
root = sys.argv[1]
latest = os.stat(root, follow_symlinks=False).st_mtime
started = time.monotonic()
seen = 0
pending = [root]
while pending:
    base = pending.pop()
    try: entries = os.scandir(base)
    except OSError:
        print('incomplete')
        raise SystemExit(2)
    with entries:
        for entry in entries:
            seen += 1
            if seen > 50000 or time.monotonic() - started > 5:
                print('incomplete')
                raise SystemExit(2)
            try:
                st = entry.stat(follow_symlinks=False)
                latest = max(latest, st.st_mtime)
                if entry.is_dir(follow_symlinks=False): pending.append(entry.path)
            except OSError:
                print('incomplete')
                raise SystemExit(2)
print(int(latest))
PY
}
has_protected_content() {
  local found
  found=$(timeout 5s find "$1" \( -type f \( -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' -o -name '*.sqlite-*' -o -name '*.sqlite3' -o -name '*.sqlite3-*' -o -name '*-wal' -o -name '*-shm' \) \
      -o -type d \( -iname '*backup*' -o -iname '*placement-recovery*' \) \) -print -quit 2>/dev/null) || return 0
  [[ -n "$found" ]]
}
docker_builder_reclaimable_bytes() {
  local reclaimable
  reclaimable=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F '|' '$1=="Build Cache"{print $2; exit}')
  python3 - "$reclaimable" <<'PY'
import re, sys
m = re.search(r'([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)', sys.argv[1], re.I)
if not m: print(0); raise SystemExit
unit = m.group(2).upper()
base = 1024 if unit.endswith('IB') else 1000
power = {'B': 0, 'KB': 1, 'KIB': 1, 'MB': 2, 'MIB': 2, 'GB': 3, 'GIB': 3, 'TB': 4, 'TIB': 4}[unit]
print(int(float(m.group(1)) * base**power))
PY
}
declare -A OPEN_PATHS=()
OPEN_SCAN_READY=0
OPEN_SCAN_FAILED=0
load_open_snapshot() {
  (( OPEN_SCAN_READY )) && return 0
  OPEN_SCAN_READY=1
  local -a opened=()
  mapfile -t opened < <(python3 - "${temp_candidates[@]}" "$HOME/.cache/uv" "$HOME/.cache/pip" "$HOME/.npm" <<'PY'
import glob, os, sys
targets = {os.path.realpath(p): p for p in sys.argv[1:] if os.path.isdir(p)}
found = set()
uncertain = False
def check(path):
    if not path or not path.startswith('/'): return
    path = os.path.normpath(path.removesuffix(' (deleted)'))
    while path != '/':
        if path in targets:
            found.add(targets[path]); return
        path = os.path.dirname(path)
for proc in glob.glob('/proc/[0-9]*'):
    for name in ('cwd', 'fd/*'):
        for item in glob.glob(os.path.join(proc, name)):
            try: check(os.readlink(item))
            except PermissionError: uncertain = True
            except OSError: continue
    try:
        with open(os.path.join(proc, 'maps'), errors='replace') as maps:
            for line in maps:
                parts = line.rstrip().split(None, 5)
                if len(parts) == 6: check(parts[5])
    except PermissionError: uncertain = True
    except OSError: pass
for path in sorted(found): print(path)
print('__OPEN_SCAN_COMPLETE__' if not uncertain else '__OPEN_SCAN_INCOMPLETE__')
PY
)
  if [[ "${opened[-1]:-}" != '__OPEN_SCAN_COMPLETE__' ]]; then
    OPEN_SCAN_FAILED=1
    return 0
  fi
  local last=$(( ${#opened[@]} - 1 ))
  unset "opened[$last]"
  local p
  for p in "${opened[@]}"; do OPEN_PATHS["$p"]=1; done
}
is_open() {
  load_open_snapshot
  (( OPEN_SCAN_FAILED )) && return 0
  [[ -n "${OPEN_PATHS[$1]:-}" ]]
}
remove_path() {
  local path="$1" reason="$2" bytes
  [[ -e "$path" || -L "$path" ]] || return 0
  bytes=$(size_bytes "$path")
  if is_open "$path"; then record "$path" "$bytes" "$reason (open; skipped)" SKIPPED; return; fi
  if [[ "$MODE" == dry-run ]]; then record "$path" "$bytes" "$reason" WOULD_REMOVE; return; fi
  record "$path" "$bytes" "$reason; removal starting" REMOVE_PENDING
  if ! rm -rf --one-file-system -- "$path"; then
    record "$path" "$bytes" "$reason; removal command failed" REMOVE_FAILED
    return 1
  fi
  record "$path" "$bytes" "$reason" REMOVED
}

# Hub state must be available for worktree pruning. Fail closed on partial,
# malformed, or unavailable session/intake snapshots.
hub_sessions_json=""
hub_open_intakes_json=""
if command -v hub >/dev/null 2>&1; then
  hub_sessions_json=$(hub sessions list --json --limit 100 2>/dev/null) || hub_sessions_json=""
  hub_open_intakes_json=$(hub intake list --all --status open 2>/dev/null) || hub_open_intakes_json=""
fi
hub_safe=0
if [[ -n "$hub_sessions_json" && -n "$hub_open_intakes_json" ]] && \
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,dict) and isinstance(d.get("sessions"),list) and d.get("next_cursor") is None' <<<"$hub_sessions_json" 2>/dev/null && \
  python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$hub_open_intakes_json" 2>/dev/null; then
  hub_safe=1
fi

declare -A LIVE_CWD_WORKTREES=()
LIVE_CWD_READY=0
LIVE_CWD_FAILED=0
live_cwd_in() {
  local target="$1"
  if [[ "$LIVE_CWD_READY" -eq 0 ]]; then
    LIVE_CWD_READY=1
    local -a snapshot=()
    mapfile -t snapshot < <(python3 - "${worktrees[@]}" <<'PY'
import glob, os, sys
targets = {os.path.realpath(p): p for p in sys.argv[1:] if os.path.isdir(p)}
found, uncertain = set(), False
def check(path):
    if not path or not path.startswith('/'): return
    path = os.path.normpath(path.removesuffix(' (deleted)'))
    while path != '/':
        if path in targets:
            found.add(path); return
        path = os.path.dirname(path)
for proc in glob.glob('/proc/[0-9]*'):
    try: check(os.readlink(os.path.join(proc, 'cwd')))
    except PermissionError: uncertain = True
    except OSError: continue
for path in sorted(found): print(path)
print('__LIVE_CWD_COMPLETE__' if not uncertain else '__LIVE_CWD_INCOMPLETE__')
PY
)
    if [[ "${snapshot[-1]:-}" != '__LIVE_CWD_COMPLETE__' ]]; then
      LIVE_CWD_FAILED=1
    else
      local last=$(( ${#snapshot[@]} - 1 )) p
      unset "snapshot[$last]"
      for p in "${snapshot[@]}"; do LIVE_CWD_WORKTREES["$p"]=1; done
    fi
  fi
  (( LIVE_CWD_FAILED )) && return 0
  [[ -n "${LIVE_CWD_WORKTREES[$target]:-}" ]]
}
hub_refs_worktree() {
  local target="$1"
  [[ "$hub_safe" -eq 1 ]] || return 0
  python3 - "$target" "$hub_sessions_json" "$hub_open_intakes_json" <<'PY'
import json, os, sys
target = os.path.realpath(sys.argv[1])
data = [json.loads(sys.argv[2]).get("sessions", []), json.loads(sys.argv[3])]
def collect_open_intakes(value):
    if isinstance(value, list): return value
    if isinstance(value, dict):
        for key in ("items", "tasks", "intakes"):
            if isinstance(value.get(key), list): return value[key]
        if value.get("status") == "open": return [value]
        for item in value.values():
            if isinstance(item, dict):
                found = collect_open_intakes(item)
                if found is not None: return found
    return None
open_intakes = collect_open_intakes(data[1])
if open_intakes is None:
    # A successful response without an enumerable intake list is not proof.
    raise SystemExit(0)
def walk(v):
    if isinstance(v, dict):
        for k, x in v.items():
            if isinstance(x, str) and ("worktree" in k.lower() or "cwd" in k.lower() or "path" in k.lower()):
                if os.path.realpath(x) == target or os.path.realpath(x).startswith(target + os.sep):
                    raise SystemExit(0)
            walk(x)
    elif isinstance(v, list):
        for x in v: walk(x)
for item in data: walk(item)
# A positive open-intake list must expose its complete linked-worktree/session
# inventory. Otherwise we cannot establish that a path has no unresolved link.
def has_link_manifest(item):
    if isinstance(item, dict):
        for key, value in item.items():
            if key.lower() in ("worktrees", "worktree_paths", "linked_worktrees", "worktree_links", "linked_sessions"):
                return True
            if has_link_manifest(value): return True
    elif isinstance(item, list):
        return any(has_link_manifest(x) for x in item)
    return False
if open_intakes and not all(has_link_manifest(item) for item in open_intakes):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

declare -A SCANNED_COMMON_DIRS=() REGISTERED_WORKTREES=()
declare -A LOCKED_WORKTREES=()
worktree_lock_state() {
  local target="$1" common listing line current
  target=$(realpath "$target")
  common=$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 2
  common=$(realpath "$common")
  if [[ -z "${SCANNED_COMMON_DIRS[$common]:-}" ]]; then
    listing=$(git -C "$target" worktree list --porcelain 2>/dev/null) || return 2
    SCANNED_COMMON_DIRS["$common"]=1
    current=""
    while IFS= read -r line; do
      case "$line" in
        'worktree '*) current=$(realpath "${line#worktree }"); REGISTERED_WORKTREES["$current"]=1 ;;
        locked*) [[ -n "$current" ]] && LOCKED_WORKTREES["$current"]=1 ;;
        '') current="" ;;
      esac
    done <<<"$listing"
  fi
  [[ -n "${REGISTERED_WORKTREES[$target]:-}" ]] || return 3
  [[ -n "${LOCKED_WORKTREES[$target]:-}" ]]
}

report_tmp=$(mktemp "$REPORT_DIR/rmthz-disk-gc.XXXXXX")
trap 'rm -f -- "$report_tmp"' EXIT
{
  printf 'RMTHZ disk GC dry-run %s\nTrigger: %s\n' "$(date -u +%FT%TZ)" "$TRIGGER"
  df -h / | tail -n 1
  printf '\n%-10s %10s  %-38s %s\n' ACTION SIZE REASON PATH
} > "$report_tmp"

printf '\nWorktree candidates (~/git/*-wt-*):\n'
shopt -s nullglob
worktrees=("$HOME"/git/*-wt-*)
declare -A WORKTREE_SIZE_BYTES=()
if ((${#worktrees[@]})); then
  mapfile -t worktree_sizes < <(du -s -B1 -- "${worktrees[@]}" 2>/dev/null || true)
  for size_line in "${worktree_sizes[@]}"; do
    size_bytes_value=${size_line%%$'\t'*}
    size_path=${size_line#*$'\t'}
    [[ "$size_bytes_value" =~ ^[0-9]+$ && "$size_path" != "$size_line" ]] && WORKTREE_SIZE_BYTES["$size_path"]="$size_bytes_value"
  done
fi
for wt in "${worktrees[@]}"; do
  [[ -d "$wt" ]] || continue
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$top" || "$(realpath "$top")" != "$(realpath "$wt")" ]]; then
    record "$wt" "$(size_bytes "$wt")" "orphaned worktree directory; report only" ORPHAN
    continue
  fi
  git_dir=$(git -C "$wt" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [[ -n "$git_dir" && -n "$common" && "$(realpath "$git_dir")" == "$(realpath "$common")" ]]; then
    bytes=${WORKTREE_SIZE_BYTES[$wt]:-0}
    record "$wt" "$bytes" "main checkout, not a linked worktree; report only" SKIPPED
    continue
  fi
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if worktree_lock_state "$wt"; then
    locked=yes
  else
    rc=$?
    case "$rc" in
      1) locked="" ;;
      3) record "$wt" "${WORKTREE_SIZE_BYTES[$wt]:-0}" "not registered by git worktree list; orphan report only" ORPHAN; continue ;;
      *) locked=unknown ;;
    esac
  fi
  status=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null || echo UNKNOWN)
  last_head_activity=$(git -C "$wt" reflog --date=unix --format=%gd -1 HEAD 2>/dev/null | sed -nE 's/.*@\{([0-9]+)\}.*/\1/p')
  age=0
  if [[ "$last_head_activity" =~ ^[0-9]+$ ]]; then age=$(( (now_epoch - last_head_activity) / 86400 )); fi
  reason="candidate"
  safe=1 candidate=1
  [[ -n "$branch" ]] || { safe=0; candidate=0; reason="detached or unreadable HEAD"; }
  [[ -z "$locked" ]] || { safe=0; candidate=0; reason="git worktree locked or lock state unavailable"; }
  [[ "$status" == "" ]] || { safe=0; candidate=0; reason="dirty or unreadable status"; }
  (( age > 2 )) || { safe=0; candidate=0; reason="idle less than 48h or HEAD activity time unavailable"; }
  git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null || { safe=0; candidate=0; reason="HEAD not proven ancestor of origin/main"; }
  live_cwd_in "$(realpath "$wt")" && { safe=0; candidate=0; reason="live process cwd inside worktree"; }
  if [[ "$hub_safe" -eq 1 ]]; then
    hub_refs_worktree "$(realpath "$wt")" && { safe=0; candidate=0; reason="Hub session/intake references worktree or open-state ambiguous"; }
  else
    safe=0
    reason="all Git/process gates pass; Hub session/intake safety unavailable"
  fi
  if [[ -z "${WORKTREE_SIZE_BYTES[$wt]:-}" ]]; then
    record "$wt" 0 "worktree size unavailable; skipped" SKIPPED
    continue
  fi
  bytes=${WORKTREE_SIZE_BYTES[$wt]}
  if (( safe )); then
    record "$wt" "$bytes" "finished clean merged worktree; branch=${branch}; idle>${age}d" WOULD_REMOVE
    if [[ "$MODE" == apply ]]; then
      record "$wt" "$bytes" "merged clean idle worktree removal starting" REMOVE_PENDING
      if ! git -C "$wt" worktree remove "$wt"; then
        record "$wt" "$bytes" "git worktree remove failed" REMOVE_FAILED
        continue
      fi
      record "$wt" "$bytes" "merged clean idle worktree removed" REMOVED
      if [[ -n "$common" ]] && git --git-dir="$common" branch -d "$branch"; then
        record "branch:$branch" 0 "branch -d after merged worktree removal" REMOVED
      else
        record "branch:$branch" 0 "worktree removed; branch -d refused" SKIPPED
      fi
    fi
  elif (( candidate && hub_safe != 1 )); then
    record "$wt" "$bytes" "$reason; report-only hold" HUB_HOLD
  else
    record "$wt" "$bytes" "$reason" SKIPPED
  fi
done

# Regenerable temp locations from AC4, strictly bounded to named roots.
printf '\nTemporary candidates older than three days:\n'
temp_candidates=( "$HOME"/git/*/.local/tmp "$HOME"/git/*/.tmp/worktrees /tmp/tsx-1000 /tmp/node-compile-cache /tmp/playwright-transform-cache-1000 /tmp/go-build* /tmp/miniflare-* )
for p in "${temp_candidates[@]}"; do
  [[ -e "$p" ]] || continue
  [[ -d "$p" ]] || continue
  root_age=$(( (now_epoch - $(stat -c %Y "$p" 2>/dev/null || echo "$now_epoch")) / 86400 ))
  (( root_age > 3 )) || continue
  latest_mtime=$(newest_mtime "$p" 2>/dev/null || true)
  if [[ ! "$latest_mtime" =~ ^[0-9]+$ ]]; then
    record "$p" "$(size_bytes "$p")" "age scan incomplete; safety unverified" SKIPPED
    continue
  fi
  age=$(( (now_epoch - latest_mtime) / 86400 ))
  (( age > 3 )) || continue
  if has_protected_content "$p"; then
    record "$p" "$(size_bytes "$p")" "contains a protected database/backup path" SKIPPED
  elif is_open "$p"; then
    record "$p" "$(size_bytes "$p")" "older than 3d but open/in-use" SKIPPED
  else
    remove_path "$p" "regenerable temp older than 3d"
  fi
done

# Report the newest-three retention candidates for review. AC3 protects current
# RDS dumps from automatic deletion; cleanup requires Alexey's explicit OK.
if [[ -d /tmp/rds-export ]]; then
  for app in /tmp/rds-export/*; do
    [[ -d "$app" ]] || { [[ -e "$app" ]] && record "$app" "$(size_bytes "$app")" "unknown export layout; report only" REVIEW; continue; }
    mapfile -t exports < <(find "$app" -mindepth 1 -maxdepth 1 -type f -printf '%T@\t%p\n' | sort -rn | cut -f2-)
    for ((i=3; i<${#exports[@]}; i++)); do
      record "${exports[$i]}" "$(size_bytes "${exports[$i]}")" "rds export exceeds newest 3 for $(basename "$app"); needs Alexey's OK" NEEDS_OK
    done
  done
fi

# Protected data classes are inventory-only and require Alexey's explicit OK.
protected_paths=("$HOME/.codex" "$HOME/.zcodex" "$HOME/.zodex" "$HOME/.godex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.opencode" "$HOME/.config/opencode" "$HOME/.local/share/opencode" "$HOME/prod" "$HOME"/git/*placement-recovery* "$HOME"/git/*backup* /tmp/rds-export)
for protected in "${protected_paths[@]}"; do
  [[ -e "$protected" ]] || continue
  record "$protected" "$(size_bytes "$protected")" "protected data inventory; needs Alexey's OK" NEEDS_OK
done
while IFS=$'\t' read -r bytes db_path; do
  [[ -n "$db_path" ]] || continue
  record "$db_path" "$bytes" "database file protected; needs Alexey's OK" NEEDS_OK
done < <(find /tmp "$HOME/tmp" -maxdepth 5 -type f \( -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' -o -name '*.sqlite-*' -o -name '*.sqlite3' -o -name '*.sqlite3-*' -o -name '*-wal' -o -name '*-shm' \) -printf '%s\t%p\n' 2>/dev/null || true)

# Weekly-only jobs use a state stamp. No volumes/containers are touched.
if [[ "$TRIGGER" == daily && $(date +%u) == 7 ]]; then
  last_week=$(cat "$STATE_DIR/weekly.stamp" 2>/dev/null || echo 0)
  [[ "$last_week" =~ ^[0-9]+$ ]] || last_week=0
  if (( now_epoch - last_week > 6*86400 )); then
    if [[ "$MODE" == dry-run ]]; then
      for cache in "$HOME/.cache/uv" "$HOME/.cache/pip" "$HOME/.npm"; do
        [[ -d "$cache" ]] && record "$cache" "$(size_bytes "$cache")" "weekly package-cache prune candidate (tool lock check required)" WOULD_PRUNE
      done
      if command -v docker >/dev/null 2>&1; then
        docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
        if [[ "$docker_root" == /data || "$docker_root" == /data/* ]]; then
          builder_du=$(docker builder du 2>/dev/null || true)
          printf '%s\n' "$builder_du" | sed 's/^/DRY-RUN docker builder: /'
          [[ -z "$report_tmp" ]] || printf '%s\n' "$builder_du" | sed 's/^/DRY-RUN docker builder: /' >> "$report_tmp"
          while IFS= read -r image_id; do
            [[ -n "$image_id" ]] || continue
            labels=$(docker image inspect --format '{{json .Config.Labels}}' "$image_id" 2>/dev/null || echo '{}')
            if [[ "${labels,,}" == *coolify* ]]; then
              record "$image_id" 0 "Coolify-labelled dangling image retained" SKIPPED
            else
              record "$image_id" "$(docker image inspect --format '{{.Size}}' "$image_id" 2>/dev/null || echo 0)" "dangling image candidate; Docker reports dangling=true" WOULD_PRUNE
            fi
          done < <(docker image ls --filter dangling=true --quiet | sort -u)
        else
          record "docker" 0 "Docker root is not on /data; GC skipped (root=${docker_root:-unknown})" SKIPPED
        fi
      fi
    else
      if command -v uv >/dev/null 2>&1; then
        if is_open "$HOME/.cache/uv" || pgrep -af '(^|/)uv (pip|sync|run|tool|cache)' >/dev/null; then record "$HOME/.cache/uv" "$(size_bytes "$HOME/.cache/uv")" "uv cache is open or uv process is active" SKIPPED
        else
          before=$(size_bytes "$HOME/.cache/uv")
          record "$HOME/.cache/uv" "$before" "uv cache prune starting" REMOVE_PENDING
          if uv cache prune 2>&1 | sed 's/^/uv: /'; then after=$(size_bytes "$HOME/.cache/uv"); record "$HOME/.cache/uv" "$((before-after))" "uv cache prune (aggregate reclaimed size)" REMOVED
          else record "$HOME/.cache/uv" "$before" "uv cache prune failed" REMOVE_FAILED; exit 1; fi
        fi
      fi
      if command -v pip >/dev/null 2>&1; then
        if is_open "$HOME/.cache/pip" || pgrep -af '(^|/)(pip|pip3)( |$)|python(3(\.[0-9]+)?)? -m pip' >/dev/null; then record "$HOME/.cache/pip" "$(size_bytes "$HOME/.cache/pip")" "pip cache is open or pip process is active" SKIPPED
        else
          before=$(size_bytes "$HOME/.cache/pip")
          record "$HOME/.cache/pip" "$before" "pip cache purge starting" REMOVE_PENDING
          if pip cache purge 2>&1 | sed 's/^/pip: /'; then after=$(size_bytes "$HOME/.cache/pip"); record "$HOME/.cache/pip" "$((before-after))" "pip cache purge (aggregate reclaimed size)" REMOVED
          else record "$HOME/.cache/pip" "$before" "pip cache purge failed" REMOVE_FAILED; exit 1; fi
        fi
      fi
      if command -v npm >/dev/null 2>&1; then
        if ! is_open "$HOME/.npm" && ! pgrep -af '(^|/)npm( |$)' >/dev/null && [[ ! -e "$HOME/.npm/_locks" ]] && [[ ! -e "$HOME/.npm/_cacache/tmp" ]]; then
          before=$(size_bytes "$HOME/.npm")
          record "$HOME/.npm" "$before" "npm cache clean starting after process and lock checks" REMOVE_PENDING
          if npm cache clean --force 2>&1 | sed 's/^/npm: /'; then after=$(size_bytes "$HOME/.npm"); record "$HOME/.npm" "$((before-after))" "npm cache clean after process and lock checks (aggregate reclaimed size)" REMOVED
          else record "$HOME/.npm" "$before" "npm cache clean failed" REMOVE_FAILED; exit 1; fi
        else
          record "$HOME/.npm" "$(size_bytes "$HOME/.npm")" "npm cache lock or npm process present" SKIPPED
        fi
      fi
      if command -v docker >/dev/null 2>&1; then
        docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
        if [[ "$docker_root" == /data || "$docker_root" == /data/* ]]; then
          builder_before=$(docker_builder_reclaimable_bytes || echo 0)
          record "docker-builder-cache" "$builder_before" "docker builder prune --filter until=168h starting" REMOVE_PENDING
          if ! docker builder prune --filter until=168h -f; then
            record "docker-builder-cache" "$builder_before" "docker builder prune failed" REMOVE_FAILED
            exit 1
          fi
          builder_after=$(docker_builder_reclaimable_bytes || echo 0)
          builder_removed=$((builder_before-builder_after)); (( builder_removed < 0 )) && builder_removed=0
          record "docker-builder-cache" "$builder_removed" "docker builder prune --filter until=168h (aggregate reclaimed size)" REMOVED
          while IFS= read -r image_id; do
            [[ -n "$image_id" ]] || continue
            labels=$(docker image inspect --format '{{json .Config.Labels}}' "$image_id" 2>/dev/null || echo '{}')
            image_size=$(docker image inspect --format '{{.Size}}' "$image_id" 2>/dev/null || echo 0)
            if [[ "${labels,,}" == *coolify* ]]; then
              record "$image_id" "$image_size" "Coolify-labelled dangling image retained" SKIPPED
            else
              record "$image_id" "$image_size" "dangling image removal starting" REMOVE_PENDING
              if docker image rm "$image_id"; then
                record "$image_id" "$image_size" "dangling image pruned" REMOVED
              else
                record "$image_id" "$image_size" "dangling image prune failed" REMOVE_FAILED
                exit 1
              fi
            fi
          done < <(docker image ls --filter dangling=true --quiet | sort -u)
        else
          record "docker" 0 "Docker root is not on /data; GC skipped (root=${docker_root:-unknown})" SKIPPED
        fi
      fi
      printf '%s\n' "$now_epoch" > "$STATE_DIR/weekly.stamp"
    fi
  fi
fi

cp -- "$report_tmp" "$REPORT_DIR/rmthz-disk-gc-$(date -u +%Y%m%dT%H%M%SZ).txt"
echo "Report: $REPORT_DIR (every removal and candidate is recorded in $LOG)"
