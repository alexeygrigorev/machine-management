#!/usr/bin/env bash
# Conservative RMTHZ disk GC. Dry-run is the default; --apply is explicit.
set -euo pipefail

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

human_size() { du -sh -- "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
record() {
  local path="$1" bytes="$2" reason="$3" action="$4"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$action" "$bytes" "$reason" "$path" >> "$LOG"
  local row
  row=$(printf '%-10s %10s  %-38s %s' "$action" "$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "$bytes B")" "$reason" "$path")
  printf '%s\n' "$row"
  [[ -z "${report_tmp:-}" ]] || printf '%s\n' "$row" >> "$report_tmp"
}
size_bytes() { du -s -B1 -- "$1" 2>/dev/null | awk '{print $1+0}'; }
is_open() {
  python3 - "$1" <<'PY'
import glob, os, sys
target = os.path.realpath(sys.argv[1])
for proc in glob.glob('/proc/[0-9]*'):
    for name in ('cwd', 'fd/*'):
        for item in glob.glob(os.path.join(proc, name)):
            try: opened = os.path.realpath(os.readlink(item))
            except (OSError, PermissionError): continue
            if opened == target or opened.startswith(target + os.sep):
                raise SystemExit(0)
raise SystemExit(1)
PY
}
remove_path() {
  local path="$1" reason="$2" bytes
  [[ -e "$path" || -L "$path" ]] || return 0
  bytes=$(size_bytes "$path")
  if [[ "$MODE" == dry-run ]]; then record "$path" "$bytes" "$reason" WOULD_REMOVE; return; fi
  if is_open "$path"; then record "$path" "$bytes" "$reason (open; skipped)" SKIPPED; return; fi
  rm -rf --one-file-system -- "$path"
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

live_cwd_in() {
  local target="$1" proc cwd
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/cwd" ]] || continue
    cwd=$(readlink "$proc/cwd" 2>/dev/null) || continue
    case "$cwd" in "$target"|"$target"/*) return 0 ;; esac
  done
  return 1
}
hub_refs_worktree() {
  local target="$1"
  [[ "$hub_safe" -eq 1 ]] || return 0
  python3 - "$target" "$hub_sessions_json" "$hub_open_intakes_json" <<'PY'
import json, os, sys
target = os.path.realpath(sys.argv[1])
data = [json.loads(sys.argv[2]).get("sessions", []), json.loads(sys.argv[3])]
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
raise SystemExit(1)
PY
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
if [[ "$hub_safe" -ne 1 ]]; then
  printf 'Hub open-intake/session snapshot unavailable; listing sizes only.\n'
  while IFS=$'\t' read -r bytes wt; do
    [[ -d "$wt" ]] || continue
    record "$wt" "$bytes" "Hub open-intake/session snapshot unavailable; safety unverified" SKIPPED
  done < <(du -s -B1 -- "${worktrees[@]}" 2>/dev/null || true)
else
for wt in "${worktrees[@]}"; do
  [[ -d "$wt" ]] || continue
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$top" || "$(realpath "$top")" != "$(realpath "$wt")" ]]; then
    record "$wt" "$(size_bytes "$wt")" "orphaned worktree directory; report only" ORPHAN
    continue
  fi
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  locked=$(git -C "$wt" worktree list --porcelain 2>/dev/null | awk -v p="$(realpath "$wt")" '$1=="worktree"{w=$2} $1=="locked" && w==p{print "yes"}' || true)
  status=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null || echo UNKNOWN)
  last_head_activity=$(git -C "$wt" reflog --date=unix --format=%gd -1 HEAD 2>/dev/null | sed -nE 's/.*@\{([0-9]+)\}.*/\1/p')
  age=0
  if [[ "$last_head_activity" =~ ^[0-9]+$ ]]; then age=$(( (now_epoch - last_head_activity) / 86400 )); fi
  reason="candidate"
  safe=1
  [[ -n "$branch" ]] || { safe=0; reason="detached or unreadable HEAD"; }
  [[ -z "$locked" ]] || { safe=0; reason="git worktree locked"; }
  [[ "$status" == "" ]] || { safe=0; reason="dirty or unreadable status"; }
  (( age > 2 )) || { safe=0; reason="idle less than 48h or HEAD activity time unavailable"; }
  git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null || { safe=0; reason="HEAD not proven ancestor of origin/main"; }
  live_cwd_in "$(realpath "$wt")" && { safe=0; reason="live process cwd inside worktree"; }
  [[ "$hub_safe" -eq 1 ]] || { safe=0; reason="Hub session/intake snapshot unavailable or not parseable"; }
  hub_refs_worktree "$(realpath "$wt")" && { safe=0; reason="Hub session/intake references worktree or open-state ambiguous"; }
  bytes=$(size_bytes "$wt")
  if (( safe )); then
    record "$wt" "$bytes" "finished clean merged worktree; branch=${branch}; idle>${age}d" WOULD_REMOVE
    if [[ "$MODE" == apply ]]; then
      git -C "$wt" worktree remove "$wt"
      if git -C "$(dirname "$wt")" branch -d "$branch"; then
        record "$wt" "$bytes" "removed merged worktree and deleted branch ${branch}" REMOVED
      else
        record "$wt" "$bytes" "worktree removed; branch -d refused for ${branch}" SKIPPED
      fi
    fi
  else
    record "$wt" "$bytes" "$reason" SKIPPED
  fi
done
fi

# Regenerable temp locations from AC4, strictly bounded to named roots.
printf '\nTemporary candidates older than three days:\n'
temp_candidates=( "$HOME"/git/*/.local/tmp "$HOME"/git/*/.tmp/worktrees /tmp/tsx-1000 /tmp/node-compile-cache /tmp/playwright-transform-cache-1000 /tmp/go-build* /tmp/miniflare-* )
for p in "${temp_candidates[@]}"; do
  [[ -e "$p" ]] || continue
  [[ -d "$p" ]] || continue
  age=$(( (now_epoch - $(stat -c %Y "$p" 2>/dev/null || echo "$now_epoch")) / 86400 ))
  (( age > 3 )) || continue
  if is_open "$p"; then record "$p" "$(size_bytes "$p")" "older than 3d but open/in-use" SKIPPED; else remove_path "$p" "regenerable temp older than 3d"; fi
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
protected_paths=("$HOME/.codex" "$HOME/.zcodex" "$HOME/.zodex" "$HOME/.godex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.local/share/opencode" "$HOME/prod" "$HOME"/git/*placement-recovery* "$HOME"/git/*backup* /tmp/rds-export)
for protected in "${protected_paths[@]}"; do
  [[ -e "$protected" ]] || continue
  record "$protected" "$(size_bytes "$protected")" "protected data inventory; needs Alexey's OK" NEEDS_OK
done

# Weekly-only jobs use a state stamp. No volumes/containers are touched.
if [[ "$TRIGGER" == daily && $(date +%u) == 7 ]]; then
  last_week=$(cat "$STATE_DIR/weekly.stamp" 2>/dev/null || echo 0)
  if (( now_epoch - last_week > 6*86400 )); then
    if [[ "$MODE" == dry-run ]]; then
      for cache in "$HOME/.cache/uv" "$HOME/.cache/pip" "$HOME/.npm"; do
        [[ -d "$cache" ]] && record "$cache" "$(size_bytes "$cache")" "weekly package-cache prune candidate (tool lock check required)" WOULD_PRUNE
      done
      if command -v docker >/dev/null 2>&1; then
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
      fi
    else
      if command -v uv >/dev/null 2>&1; then
        if is_open "$HOME/.cache/uv"; then record "$HOME/.cache/uv" "$(size_bytes "$HOME/.cache/uv")" "uv cache is open/in-use" SKIPPED
        else before=$(size_bytes "$HOME/.cache/uv"); uv cache prune 2>&1 | sed 's/^/uv: /'; after=$(size_bytes "$HOME/.cache/uv"); record "$HOME/.cache/uv" "$((before-after))" "uv cache prune (aggregate reclaimed size)" REMOVED; fi
      fi
      if command -v pip >/dev/null 2>&1; then
        if is_open "$HOME/.cache/pip"; then record "$HOME/.cache/pip" "$(size_bytes "$HOME/.cache/pip")" "pip cache is open/in-use" SKIPPED
        else before=$(size_bytes "$HOME/.cache/pip"); pip cache purge 2>&1 | sed 's/^/pip: /'; after=$(size_bytes "$HOME/.cache/pip"); record "$HOME/.cache/pip" "$((before-after))" "pip cache purge (aggregate reclaimed size)" REMOVED; fi
      fi
      if command -v npm >/dev/null 2>&1; then
        if ! is_open "$HOME/.npm" && ! pgrep -af '[n]pm (install|ci|cache)' >/dev/null && [[ ! -e "$HOME/.npm/_locks" ]]; then
          before=$(size_bytes "$HOME/.npm"); npm cache clean --force 2>&1 | sed 's/^/npm: /'; after=$(size_bytes "$HOME/.npm"); record "$HOME/.npm" "$((before-after))" "npm cache clean after process and lock checks (aggregate reclaimed size)" REMOVED
        else
          record "$HOME/.npm" "$(size_bytes "$HOME/.npm")" "npm cache lock or npm process present" SKIPPED
        fi
      fi
      if command -v docker >/dev/null 2>&1; then
        builder_before=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F '\t' '$1=="Build Cache"{print $2; exit}' | numfmt --from=iec 2>/dev/null || echo 0)
        docker builder prune --filter until=168h -f
        builder_after=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F '\t' '$1=="Build Cache"{print $2; exit}' | numfmt --from=iec 2>/dev/null || echo 0)
        builder_removed=$((builder_before-builder_after)); (( builder_removed < 0 )) && builder_removed=0
        record "docker-builder-cache" "$builder_removed" "docker builder prune --filter until=168h (aggregate reclaimed size)" REMOVED
        while IFS= read -r image_id; do
          [[ -n "$image_id" ]] || continue
          labels=$(docker image inspect --format '{{json .Config.Labels}}' "$image_id" 2>/dev/null || echo '{}')
          if [[ "${labels,,}" == *coolify* ]]; then
            record "$image_id" 0 "Coolify-labelled dangling image retained" SKIPPED
          else
            docker image rm "$image_id"
            record "$image_id" 0 "dangling image pruned" REMOVED
          fi
        done < <(docker image ls --filter dangling=true --quiet | sort -u)
      fi
      printf '%s\n' "$now_epoch" > "$STATE_DIR/weekly.stamp"
    fi
  fi
fi

cp -- "$report_tmp" "$REPORT_DIR/rmthz-disk-gc-$(date -u +%Y%m%dT%H%M%SZ).txt"
echo "Report: $REPORT_DIR (every removal and candidate is recorded in $LOG)"
