#!/usr/bin/env bash
# Verify rmthz-disk-gc.sh prunes unreferenced clean merged idle worktrees across
# *-wt-*, drain-*, and .claude/worktrees/*, respects hub items schema, cleans
# old temp dirs, and prunes managed-engines uv caches on --trigger disk-warn.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/rmthz-disk-gc.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

FAKE_HOME="$TMP/home"
FAKE_BIN="$TMP/bin"
STATE="$TMP/state"
REPORTS="$TMP/reports"
mkdir -p "$FAKE_HOME/git" "$FAKE_BIN" "$STATE" "$REPORTS"

# Create bare origin and main repo
git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$FAKE_HOME/git/demo"
(
  cd "$FAKE_HOME/git/demo"
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  git branch -M main
  git push -q -u origin main
)
git --git-dir="$TMP/origin.git" symbolic-ref HEAD refs/heads/main

# Helper to create a worktree with >3d reflog age
make_wt() {
  local path="$1" branch="$2"
  mkdir -p "$(dirname "$path")"
  git -C "$FAKE_HOME/git/demo" worktree add -q -b "$branch" "$path" origin/main
  # Backdate reflog entry to 5 days ago
  local old_epoch=$(( $(date +%s) - 5*86400 ))
  local gd
  gd="$(git -C "$path" rev-parse --path-format=absolute --git-dir)"
  python3 - "$gd/logs/HEAD" "$old_epoch" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
txt = re.sub(r'> \d+ ', f'> {sys.argv[2]} ', txt)
p.write_text(txt)
PY
}

WT_CLEAN="$FAKE_HOME/git/demo-wt-clean"
WT_DRAIN="$FAKE_HOME/git/drain-clean"
WT_CLAUDE="$FAKE_HOME/git/demo/.claude/worktrees/clean"
WT_HUB_REF="$FAKE_HOME/git/demo-wt-hubref"
WT_DIRTY="$FAKE_HOME/git/demo-wt-dirty"

make_wt "$WT_CLEAN" "b-clean"
make_wt "$WT_DRAIN" "b-drain"
make_wt "$WT_CLAUDE" "b-claude"
make_wt "$WT_HUB_REF" "b-hubref"
make_wt "$WT_DIRTY" "b-dirty"
echo "dirty" > "$WT_DIRTY/untracked.txt"

# Old temp dir (>4d)
OLD_TMP="$FAKE_HOME/git/demo/.local/tmp"
mkdir -p "$OLD_TMP"
echo "junk" > "$OLD_TMP/file.txt"
touch -d "5 days ago" "$OLD_TMP/file.txt" "$OLD_TMP"

# Managed-engines uv cache
ME_UV="$FAKE_HOME/.config/agent-hub/managed-engines/eng1/home/.cache/uv"
mkdir -p "$ME_UV"
echo "wheel" > "$ME_UV/pkg.whl"

# Fake hub CLI returning real schema ("items", not "sessions")
cat > "$FAKE_BIN/hub" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "sessions list" ]]; then
  cat <<JSON
{"items":[{"id":"sess-1","state":"running","request":{"workspace":"$WT_HUB_REF"}}],"next_cursor":null}
JSON
  exit 0
elif [[ "\$1 \$2" == "intake list" ]]; then
  cat <<JSON
{"items":[{"id":"int-1","status":"open","session_id":"sess-1"}],"next":null,"total":1}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/hub"

# Fake docker and pgrep so test is hermetic and never touches host Docker
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then echo "/var/lib/docker"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE_BIN/docker"

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

# Fake uv CLI recording UV_CACHE_DIR prune calls
UV_CALLS="$TMP/uv_calls.txt"
cat > "$FAKE_BIN/uv" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "cache prune" ]]; then
  echo "\${UV_CACHE_DIR:-default}" >> "$UV_CALLS"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/uv"

HOME="$FAKE_HOME" \
PATH="$FAKE_BIN:$PATH" \
RMTHZ_GC_ALLOW_HOST=1 \
RMTHZ_GC_STATE_DIR="$STATE" \
RMTHZ_GC_REPORT_DIR="$REPORTS" \
"$SCRIPT" --apply --trigger disk-warn > "$TMP/out.txt"

[[ ! -d "$WT_CLEAN" ]] || { echo "FAIL: WT_CLEAN not removed"; cat "$TMP/out.txt"; exit 1; }
[[ ! -d "$WT_DRAIN" ]] || { echo "FAIL: WT_DRAIN not removed"; cat "$TMP/out.txt"; exit 1; }
[[ ! -d "$WT_CLAUDE" ]] || { echo "FAIL: WT_CLAUDE not removed"; cat "$TMP/out.txt"; exit 1; }
[[ -d "$WT_HUB_REF" ]] || { echo "FAIL: WT_HUB_REF was removed despite hub ref"; exit 1; }
[[ -d "$WT_DIRTY" ]] || { echo "FAIL: WT_DIRTY was removed despite dirty state"; exit 1; }
[[ ! -d "$OLD_TMP" ]] || { echo "FAIL: OLD_TMP not removed"; cat "$TMP/out.txt"; exit 1; }
grep -qF "$ME_UV" "$UV_CALLS" || { echo "FAIL: managed-engines uv cache not pruned on disk-warn"; cat "$UV_CALLS"; exit 1; }

echo "PASS: rmthz-disk-gc-pruning.sh"
