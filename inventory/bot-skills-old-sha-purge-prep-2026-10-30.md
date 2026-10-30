# GitHub old `bot-skills` SHA verification and purge preparation — 2026-10-30

- **Intake:** `110bc730-f7d0-4036-90b0-2d3496eb04d1` (`machine-management`)
- **Source inventory:** `/home/alexey/tmp/agent-reports/bot-skills-resync-inventory-2026-10-24.md`
- **Historical verification report:** `/home/alexey/tmp/agent-reports/gh-old-sha-continuation-2026-10-26.txt` (collected 2026-10-26 06:03–06:05 UTC)
- **Live re-verification:** 2026-10-30 12:39 UTC (`/home/alexey/tmp/agent-reports/gh-old-sha-verification-2026-10-30.json`)
- **Mode:** `PREP-ONLY` — read-only `gh api` and local `git` metadata checks only. No GitHub Support request filed, no history rewritten, no clones modified, and nothing deleted in this session.

---

## 1. AC1 — Reachability of the 26 pre-rewrite SHAs via `gh api` only

All GitHub checks were performed exclusively via `gh api --include` with `--jq` filtering so that only HTTP status codes and commit SHA/status metadata were emitted; commit bodies, file trees, patches, and secrets were never printed.

### 1.1 Repository & visible ref checks (2026-10-30 12:39 UTC)

On 2026-10-30 (`t2073u`, intake `efcca5fe`, documented in `alexeygrigorev/bots-management` commit `124ec41b2d77047feb5412996b27d0510e472c10`), `alexeygrigorev/bot-skills` was consolidated into `alexeygrigorev/bots-management` (under `.agents/skills/` from scrubbed post-rewrite history) and `alexeygrigorev/bot-skills` was deleted on GitHub. Both the deleted `alexeygrigorev/bot-skills` endpoint and the active replacement `alexeygrigorev/bots-management` endpoint were probed with `gh api`:

```text
$ GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include 'repos/alexeygrigorev/bot-skills' --jq '{full_name,private,status,message}'
HTTP 404; exit 1; output {"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/repos#get-a-repository","status":"404"}

$ GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include 'repos/alexeygrigorev/bots-management' --jq '{full_name,private}'
HTTP 200; exit 0; output {"full_name":"alexeygrigorev/bots-management","private":true}

$ GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include 'repos/alexeygrigorev/bots-management/branches?per_page=100' --jq 'map({name,sha:.commit.sha})'
HTTP 200; exit 0; output [{"name":"main","sha":"2f9a7c883a5d70b7c1f90fe95bf639cd08ad16e4"}]

$ GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include 'repos/alexeygrigorev/bots-management/tags?per_page=100' --jq 'map({name,sha:.commit.sha})'
HTTP 200; exit 0; output []

$ GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include 'repos/alexeygrigorev/bots-management/pulls?state=all&per_page=100' --jq 'map({number,state})'
HTTP 200; exit 0; output []

$ GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include 'repos/alexeygrigorev/bots-management/forks?per_page=100' --jq 'map({full_name})'
HTTP 200; exit 0; output []
```

### 1.2 Per-SHA HTTP status across `bot-skills` and `bots-management`

Command template executed for each of the 26 full 40-character SHAs:

```bash
GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include "repos/alexeygrigorev/bot-skills/commits/<SHA>" --jq '{sha,status,message}'
GH_CONFIG_DIR=/home/alexey/.config/gh gh api --include "repos/alexeygrigorev/bots-management/commits/<SHA>" --jq '{sha,status,message}'
```

- **2026-10-26 result (before repo consolidation/deletion):** 26/26 returned `HTTP 200` on `repos/alexeygrigorev/bot-skills/commits/<SHA>` and `diverged` (`ahead_by: 76`) against `bot-skills` `main` (`ce19215a67cbb9c04926b2063b268f8435cdf7a1`), with 0 visible branches, tags, PRs, or forks pinning them.
- **2026-10-30 live result (after repo consolidation/deletion):**
  - **26/26** return **`HTTP 404`** (`exit 1`, `{"message":"Not Found","status":"404"}`) on `repos/alexeygrigorev/bot-skills/commits/<SHA>`.
  - **26/26** return **`HTTP 422`** (`exit 1`, `{"message":"No commit found for SHA: <SHA>","status":"422"}`) on `repos/alexeygrigorev/bots-management/commits/<SHA>`.

| # | Pre-rewrite commit SHA | 2026-10-26 `bot-skills` HTTP (`compare` vs `ce19215a`) | 2026-10-30 `bot-skills` HTTP (UTC) | 2026-10-30 `bots-management` HTTP (UTC) |
|---|---|---|---|---|
| 1 | `8522fd1df80815a3b73614654a18c82ac55bd4ac` | `200` (`diverged`, ahead 76, behind 1) | `404` (`12:39:36Z`) | `422` (`12:39:37Z`) |
| 2 | `44745dad619adcb9fe05dcd4ae395e7b0c7d0edd` | `200` (`diverged`, ahead 76, behind 2) | `404` (`12:39:37Z`) | `422` (`12:39:37Z`) |
| 3 | `266f888775aea2d260d03b82083c6428aedf3a20` | `200` (`diverged`, ahead 76, behind 3) | `404` (`12:39:38Z`) | `422` (`12:39:38Z`) |
| 4 | `4684f725f3288ccbf056bf0587b05a639d928163` | `200` (`diverged`, ahead 76, behind 4) | `404` (`12:39:39Z`) | `422` (`12:39:39Z`) |
| 5 | `86014dd56fab3fe127b28122497ede9da6643879` | `200` (`diverged`, ahead 76, behind 5) | `404` (`12:39:39Z`) | `422` (`12:39:40Z`) |
| 6 | `7d4beb70b90d4dd353f0abb92a63e26c75de27ca` | `200` (`diverged`, ahead 76, behind 6) | `404` (`12:39:40Z`) | `422` (`12:39:41Z`) |
| 7 | `6cad95b76fab859edfbfa75c6306f64dd4f01fc3` | `200` (`diverged`, ahead 76, behind 7) | `404` (`12:39:41Z`) | `422` (`12:39:41Z`) |
| 8 | `cb0650e0ea1b18daccc27fc1aff8a6ddeb31f46c` | `200` (`diverged`, ahead 76, behind 8) | `404` (`12:39:42Z`) | `422` (`12:39:42Z`) |
| 9 | `9786c3817b875e1fd6d5adf9aa0bee56432156a3` | `200` (`diverged`, ahead 76, behind 9) | `404` (`12:39:42Z`) | `422` (`12:39:43Z`) |
| 10 | `714cfe904f112a132e0136725c6ee62978477ef8` | `200` (`diverged`, ahead 76, behind 10) | `404` (`12:39:43Z`) | `422` (`12:39:44Z`) |
| 11 | `166f2c284d216a46355fc845a22627e158129355` | `200` (`diverged`, ahead 76, behind 11) | `404` (`12:39:44Z`) | `422` (`12:39:44Z`) |
| 12 | `b5c56cbc6538528124630c48df00b5bd8bbbd333` | `200` (`diverged`, ahead 76, behind 12) | `404` (`12:39:45Z`) | `422` (`12:39:45Z`) |
| 13 | `34a40dde95d8ed56dc2e4f3b861e657d3d3fbc0f` | `200` (`diverged`, ahead 76, behind 13) | `404` (`12:39:46Z`) | `422` (`12:39:46Z`) |
| 14 | `b6d8e2bed5bb418c56a87f1b43e01b669c56c675` | `200` (`diverged`, ahead 76, behind 14) | `404` (`12:39:46Z`) | `422` (`12:39:47Z`) |
| 15 | `b827b463dff6e0517382bcbc0d94654d08233456` | `200` (`diverged`, ahead 76, behind 15) | `404` (`12:39:47Z`) | `422` (`12:39:47Z`) |
| 16 | `209eb2a201754359fb4c949e29755f3bbf86a244` | `200` (`diverged`, ahead 76, behind 16) | `404` (`12:39:48Z`) | `422` (`12:39:48Z`) |
| 17 | `691de2a2f0bebfab0ac56f97bd4637514abc3b0e` | `200` (`diverged`, ahead 76, behind 17) | `404` (`12:39:49Z`) | `422` (`12:39:49Z`) |
| 18 | `1716a24267865efd60f75ec197d513d94ece5ab1` | `200` (`diverged`, ahead 76, behind 18) | `404` (`12:39:49Z`) | `422` (`12:39:50Z`) |
| 19 | `ba68f2534f9b896f65aa9960fb5b8f94a9ce0b0a` | `200` (`diverged`, ahead 76, behind 19) | `404` (`12:39:50Z`) | `422` (`12:39:50Z`) |
| 20 | `84434d8a357ae7c626fba0f93c64da1bd05e355b` | `200` (`diverged`, ahead 76, behind 20) | `404` (`12:39:51Z`) | `422` (`12:39:51Z`) |
| 21 | `59364a9475c5d313d9356c46e63e94893bac095b` | `200` (`diverged`, ahead 76, behind 21) | `404` (`12:39:52Z`) | `422` (`12:39:52Z`) |
| 22 | `e8c59fb7bf03920809c2ffd09351e17f3fb36c24` | `200` (`diverged`, ahead 76, behind 22) | `404` (`12:39:53Z`) | `422` (`12:39:53Z`) |
| 23 | `69911803fe6ddf028e2189d8777b464e530e43dc` | `200` (`diverged`, ahead 76, behind 23) | `404` (`12:39:53Z`) | `422` (`12:39:54Z`) |
| 24 | `7ee722dc8e1c11880d729e582550400d214e91d9` | `200` (`diverged`, ahead 76, behind 24) | `404` (`12:39:54Z`) | `422` (`12:39:55Z`) |
| 25 | `d1b1f70a34b31294ea1f1e844d4b4417c98754e8` | `200` (`diverged`, ahead 76, behind 25) | `404` (`12:39:55Z`) | `422` (`12:39:55Z`) |
| 26 | `5b7126f72853789ad8eac141101765c7ceea50d6` | `200` (`diverged`, ahead 76, behind 52) | `404` (`12:39:56Z`) | `422` (`12:39:56Z`) |

---

## 2. AC2 — Clones and mirrors that may hold old history (read-only inventory)

No clone, worktree, backup, or remote host was modified. Every local Git repository/mirror on Hetzner was checked read-only via `git -C <path> cat-file -e "<SHA>^{commit}"` for all 26 SHAs (`0/26` present in each).

| Host | Path | Type / Status | HEAD / Lineage | Old SHAs present (`cat-file -e`) | Notes |
|---|---|---|---|---|---|
| Hetzner (`RMTHZ`) | `/home/alexey/git/worktrees/bot-skills-contabo-hosts-2026-10-22` | Git clone (`origin` = `git@github.com:alexeygrigorev/bot-skills.git`) | `7e33bc4353dc11aef55780e0f21e38ef811b56b3` (clean post-scrub `main`, 0 stashes, clean working tree) | `0 / 26` | Resynced & GC-pruned on 2026-10-24; `origin` points to deleted `bot-skills` repo. Left untouched. |
| Hetzner (`RMTHZ`) | `/home/alexey/backups/pre-consolidation-20261030/bot-skills.git` (+ `bot-skills.bundle`) | Bare Git mirror + bundle taken 2026-10-30 05:00 CET before repo consolidation | `fa516ede1274b007e42a0c84cce68b8b1d3ff796` (clean post-scrub history) | `0 / 26` | Created during intake `efcca5fe` pre-consolidation backup. Left untouched. |
| Hetzner (`RMTHZ`) | `/home/alexey/git/bots-management` | Consolidated Git clone (`origin` = `git@github.com:alexeygrigorev/bots-management.git`) | `4c79c32d4227bea413e50766fe17b8a21ec69202` | `0 / 26` | Active consolidated repository replacing `bot-skills`. Left untouched. |
| Hetzner (`RMTHZ`) | `/home/alexey/git/bots-management-ops` | Git clone (`origin` = `git@github.com:alexeygrigorev/bots-management.git`) | `31a26dcec8b79f9ebde2b4c6a3c391b8ce77beaf` | `0 / 26` | Ops skill-sync checkout of `bots-management`. Left untouched. |
| Hetzner (`RMTHZ`) | `/home/alexey/git/bot-skills-wt-migrate` | Orphaned worktree directory | `.git` file points to absent `/home/alexey/git/bot-skills-ops/.git/worktrees/bot-skills-wt-migrate` | N/A (no object DB) | Leftover worktree from `efcca5fe` migration; contains working-tree files only, no `.git/objects`. Left untouched. |
| Hetzner (`RMTHZ`) | `/home/alexey/git/bot-skills` | Plain directory (no `.git`) | N/A | N/A | Contains `personal/` pointer files only; not a Git clone. Left untouched. |
| Hetzner (`RMTHZ`) | `/home/alexey/tmp/bot-skills-resync-backup` | Format-patch backup directory (non-Git) | Patch headers reference the 25 old-lineage SHAs | N/A (non-Git) | Created 2026-10-24 (`216K`); sensitive card lines redacted to `[REDACTED-CARD]` per 2026-10-24 inventory. Left untouched. |
| Grok Bot box | `/home/box/tmp/bot-skills-miss` | Git clone | `10b81d6` (new post-scrub history per 2026-10-24 inventory) | `0` (verified 2026-10-24) | Out of Hetzner-only operator scope; not contacted or modified. |
| Grok Bot box | `/home/box/sand-data/workflows` (`= /home/box/agent-data/workflows`) | Live skill store checkout | `10b81d6` (new post-scrub history per 2026-10-24 inventory) | `0` (verified 2026-10-24) | Cutover to `bots-management` tracked separately under intake `1d7cf18d` (`docs/box-cutover.md`). Not contacted or modified. |
| Contabo A (`169.58.119.163`) | Unverified (`contabo-a`) | Potential clone/cache holder | Unknown | Unverified | Out of scope of 2026-10-24 resync; Contabo Coolify prod untouched per operator rules. |
| Contabo B (`169.58.124.141`) | Unverified (`contabo-b`) | Potential clone/cache holder | Unknown | Unverified | Out of scope of 2026-10-24 resync; Contabo Coolify prod untouched per operator rules. |
| External (`win35`, Alexey laptop, CI caches) | Unverified | Potential clone/cache holders | Unknown | Unverified | `win35` (`DESKTOP-FP4OP26`) intentionally offline for 2 weeks per operator rule; laptop and CI caches not contacted. |

---

## 3. AC3 — PREP-ONLY: Draft GitHub Support purge request and re-sync / retirement commands

> **APPROVAL GATE (`PREP-ONLY`):** Purging server-side GitHub tombstones/caches, retiring local clones/backups, or modifying remote checkouts requires Alexey's explicit OK. Do not submit or execute any block below without explicit approval.

### 3.1 Draft GitHub Support purge request (for Alexey's review)

Because `alexeygrigorev/bot-skills` was deleted from GitHub on 2026-10-30 (`t2073u`, intake `efcca5fe`) and all 26 pre-rewrite SHAs now return `HTTP 404` on `repos/alexeygrigorev/bot-skills/commits/<SHA>` and `HTTP 422` on `repos/alexeygrigorev/bots-management/commits/<SHA>`, a Support ticket is only needed if Alexey wants GitHub Support to immediately purge server-side deleted-repository tombstones/backups prior to GitHub's standard retention expiry:

```text
Subject: Confirm permanent purge of deleted repository tombstones and pre-rewrite commits — alexeygrigorev/bot-skills

Account / Owner: alexeygrigorev
Deleted repository: alexeygrigorev/bot-skills (private; deleted on 2026-10-30 after consolidation into alexeygrigorev/bots-management)
Last scrubbed main SHA before repository deletion: fa516ede1274b007e42a0c84cce68b8b1d3ff796 (previously verified at ce19215a67cbb9c04926b2063b268f8435cdf7a1 on 2026-10-26)

Context:
On 2026-10-24, history in alexeygrigorev/bot-skills was rewritten to remove sensitive payment-card details. Prior to repository deletion on 2026-10-30, the 26 dangling pre-rewrite commit SHAs listed below remained reachable via GET /repos/alexeygrigorev/bot-skills/commits/<SHA> (HTTP 200 on 2026-10-26). On 2026-10-30, the clean history was consolidated into alexeygrigorev/bots-management (where all 26 SHAs return HTTP 422) and alexeygrigorev/bot-skills was deleted (all 26 SHAs now return HTTP 404).

Request:
Please purge any remaining server-side object tombstones, cached commit views, or restore snapshots for the deleted repository alexeygrigorev/bot-skills covering the 26 pre-rewrite commit SHAs below, and confirm once server-side retention is permanently cleared:

8522fd1df80815a3b73614654a18c82ac55bd4ac
44745dad619adcb9fe05dcd4ae395e7b0c7d0edd
266f888775aea2d260d03b82083c6428aedf3a20
4684f725f3288ccbf056bf0587b05a639d928163
86014dd56fab3fe127b28122497ede9da6643879
7d4beb70b90d4dd353f0abb92a63e26c75de27ca
6cad95b76fab859edfbfa75c6306f64dd4f01fc3
cb0650e0ea1b18daccc27fc1aff8a6ddeb31f46c
9786c3817b875e1fd6d5adf9aa0bee56432156a3
714cfe904f112a132e0136725c6ee62978477ef8
166f2c284d216a46355fc845a22627e158129355
b5c56cbc6538528124630c48df00b5bd8bbbd333
34a40dde95d8ed56dc2e4f3b861e657d3d3fbc0f
b6d8e2bed5bb418c56a87f1b43e01b669c56c675
b827b463dff6e0517382bcbc0d94654d08233456
209eb2a201754359fb4c949e29755f3bbf86a244
691de2a2f0bebfab0ac56f97bd4637514abc3b0e
1716a24267865efd60f75ec197d513d94ece5ab1
ba68f2534f9b896f65aa9960fb5b8f94a9ce0b0a
84434d8a357ae7c626fba0f93c64da1bd05e355b
59364a9475c5d313d9356c46e63e94893bac095b
e8c59fb7bf03920809c2ffd09351e17f3fb36c24
69911803fe6ddf028e2189d8777b464e530e43dc
7ee722dc8e1c11880d729e582550400d214e91d9
d1b1f70a34b31294ea1f1e844d4b4417c98754e8
5b7126f72853789ad8eac141101765c7ceea50d6
```

### 3.2 PREP-ONLY local re-sync / retirement plan for the remaining Hetzner `bot-skills` clone

Because `alexeygrigorev/bot-skills` has been deleted on GitHub and its scrubbed history is preserved in `/home/alexey/backups/pre-consolidation-20261030/bot-skills.git` (`HEAD` = `fa516ede1274b007e42a0c84cce68b8b1d3ff796`), the legacy Hetzner checkout `/home/alexey/git/worktrees/bot-skills-contabo-hosts-2026-10-22` (`HEAD` = `7e33bc4353dc11aef55780e0f21e38ef811b56b3`, already verified `0/26` old objects) can be fast-forwarded against the local pre-consolidation mirror (rather than the deleted GitHub remote) after Alexey's explicit approval:

```bash
# PREP-ONLY — DO NOT RUN WITHOUT ALEXEY'S EXPLICIT OK
set -euo pipefail
umask 077

repo=/home/alexey/git/worktrees/bot-skills-contabo-hosts-2026-10-22
mirror=/home/alexey/backups/pre-consolidation-20261030/bot-skills.git
backup=/home/alexey/tmp/secrets/bot-skills-pre-resync-110bc730

test ! -e "$backup"
test -d "$mirror"
test -z "$(git -C "$repo" status --porcelain)"
test -z "$(git -C "$repo" stash list --format=%gd)"
test "$(git -C "$repo" symbolic-ref --short HEAD)" = main
test "$(git -C "$repo" rev-parse HEAD)" = 7e33bc4353dc11aef55780e0f21e38ef811b56b3
test "$(git -C "$mirror" rev-parse HEAD)" = fa516ede1274b007e42a0c84cce68b8b1d3ff796

# Verify all 26 old SHAs remain absent in both repo and mirror before touching anything
while IFS= read -r old_sha; do
  if git -C "$repo" cat-file -e "$old_sha^{commit}" 2>/dev/null; then exit 1; fi
  if git -C "$mirror" cat-file -e "$old_sha^{commit}" 2>/dev/null; then exit 1; fi
done < /home/alexey/tmp/agent-reports/gh-old-sha-continuation-2026-10-26-evidence/old-shas.txt

install -d -m 700 "$backup"
git -C "$repo" bundle create "$backup/new-history-before.bundle" --all
git -C "$repo" bundle verify "$backup/new-history-before.bundle"
printf '%s\n' 7e33bc4353dc11aef55780e0f21e38ef811b56b3 > "$backup/old-head.txt"

git -C "$repo" fetch "$mirror" refs/heads/main:refs/remotes/origin/main
git -C "$repo" merge-base --is-ancestor HEAD refs/remotes/origin/main
git -C "$repo" reset --hard fa516ede1274b007e42a0c84cce68b8b1d3ff796
git -C "$repo" reflog expire --expire=now --expire-unreachable=now --all
git -C "$repo" gc --prune=now
```

### 3.3 Rollback for the local clone re-sync (if approved and executed later)

```bash
# PREP-ONLY ROLLBACK
set -euo pipefail
repo=/home/alexey/git/worktrees/bot-skills-contabo-hosts-2026-10-22
backup=/home/alexey/tmp/secrets/bot-skills-pre-resync-110bc730

test -z "$(git -C "$repo" status --porcelain)"
git -C "$repo" fetch "$backup/new-history-before.bundle" refs/heads/main
git -C "$repo" reset --hard 7e33bc4353dc11aef55780e0f21e38ef811b56b3
```

### 3.4 PREP-ONLY discovery & re-sync template for unverified remote hosts (Contabo / laptop)

If Alexey later authorizes checking `contabo-a`, `contabo-b`, or a laptop for any remaining `bot-skills` clone:

```bash
# PREP-ONLY — READ-ONLY DISCOVERY FIRST (run only on an explicitly approved host)
set -euo pipefail
find /home /root /opt /srv -maxdepth 6 -name .git 2>/dev/null | while IFS= read -r g; do
  d=$(dirname "$g")
  u=$(git -C "$d" remote get-url origin 2>/dev/null || true)
  case "$u" in
    *bot-skills*)
      printf 'FOUND %s remote=%s head=%s dirty=%s\n' \
        "$d" "$u" \
        "$(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)" \
        "$(git -C "$d" status --porcelain 2>/dev/null | wc -l)"
      ;;
  esac
done
```

Any discovered clone with uncommitted changes must have its diff backed up privately before switching its remote to `git@github.com:alexeygrigorev/bots-management.git` or retiring it with Alexey's item-specific approval.

---

## 4. AC-STD S2 — Cross-model review and disposition

1. **Codex (`9dda9bdf`, 2026-10-26) review of initial OpenCode (`e71fbd40`) report:**
   - Fixed truncated 35-character SHA (`4684f725f3288ccbf0587b05a639d928163` -> `4684f725f3288ccbf056bf0587b05a639d928163`).
   - Included all 26 full 40-character SHAs inline in the Support purge request draft.
   - Added literal per-SHA `gh api` HTTP status and `compare` proof.
   - Clarified that AC2 requires read-only clone listing without modification.
2. **Antigravity Gemini (`61585582`, 2026-10-30) review and update of 2026-10-26 Codex report:**
   - **Finding 1 (GitHub repository consolidation & deletion on 2026-10-30):** `alexeygrigorev/bot-skills` was consolidated into `alexeygrigorev/bots-management` and deleted on 2026-10-30 (`t2073u`, intake `efcca5fe`). Re-ran all 26 `gh api` commit probes against both `alexeygrigorev/bot-skills` (`26/26 HTTP 404`) and `alexeygrigorev/bots-management` (`26/26 HTTP 422`), proving the 26 old pre-rewrite SHAs are unreachable on both endpoints.
   - **Finding 2 (Hetzner clone re-sync remote):** The 2026-10-26 PREP-ONLY re-sync script fetched from `origin` (`git@github.com:alexeygrigorev/bot-skills.git`), which now fails because that GitHub repository was deleted. Updated the PREP-ONLY re-sync block in Section 3.2 to fetch from the local pre-consolidation bare mirror `/home/alexey/backups/pre-consolidation-20261030/bot-skills.git` (`HEAD` = `fa516ede1274b007e42a0c84cce68b8b1d3ff796`) after verifying `0/26` old SHAs in both.
   - **Finding 3 (Post-consolidation Hetzner clone inventory):** Added `/home/alexey/backups/pre-consolidation-20261030/bot-skills.git`, `/home/alexey/git/bots-management`, `/home/alexey/git/bots-management-ops`, and `/home/alexey/git/bot-skills-wt-migrate` to the AC2 inventory table and verified `0/26` old SHAs present in every Git object database.

