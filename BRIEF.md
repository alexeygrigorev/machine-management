# One-shot: Coolify pg-shared (Postgres 16) on Contabo .141

Hub parent: https://hub.dtcdev.click/#/intake/75d33355-28df-4bf4-916e-9696bd0d43ef
Alexey literal: «другие сервисы начать там заводить тоже»
Related migration: https://hub.dtcdev.click/#/intake/ed166b97-d052-471e-9fca-936d006d4b37
Plans: ~/tmp/agent-reports/coolify-migration-plan-{argon,opencode}-2026-10-22.md

## AC (verify before exit)
1. Via Coolify primary API http://169.58.119.163:8000 (token ~/tmp/secrets/coolify-api-169.58.119.163.token), on server contabo-vps16-2 (uuid 5dn3ejiqwkmvcwvf08drxarq / 169.58.124.141): create Postgres **16** database service named `pg-shared` in project dtc-prod (uuid jiayjv9m9koroe8wt4b4ykhx), internal-only (not public).
2. Create logical databases + unprivileged owners for `cmp`, `aisl`, `website` (document names; store passwords only under ~/tmp/secrets/ chmod 600 — never print values, never git).
3. Wire daily backup with save_s3=true to existing Coolify S3 storage if possible (bucket dtc-coolify-backups-387546586013); else document exact next step.
4. Do NOT: reuse PG17 dtc-postgres for these DBs; touch pg-relay / Relay (owned by coolify-relay-prep 5efefece); DNS/CF cut; delete AWS RDS; touch Coolify install session 281f6877; Contabo coding agents; buy; secrets in git.
5. Push any mm inventory/scripts with [skip ci] if useful; cleanup worktree after push.
6. Report ~/tmp/agent-reports/coolify-pg-shared-2026-10-22.md with Coolify uuids, status, blockers.

Work from this machine-management worktree. Agents stay on Hetzner (ssh contabo-* OK). Exit 0 when report written.
