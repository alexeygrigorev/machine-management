# PG standbys on contabo-a (.163) — built 2026-10-23 (t1143u)

Non-promoted async streaming replicas for BOTH production PG stacks on
contabo-vps16-2 (.141). Mitigates the sole-data-host failure without touching
production traffic, endpoints, or DNS. Off-Contabo path remains
`contingency/fast-pg-raise.sh` from S3 (weekly-tested, ~26 s).

## Inventory (no secrets in this file)

| Item | pg-shared standby | pg-relay standby |
|---|---|---|
| Container (.163) | `pg-standby-shared` | `pg-standby-relay` |
| Data dir (.163) | `/srv/pg-standby-shared` | `/srv/pg-standby-relay` |
| Loopback only | `127.0.0.1:5544→5432` | `127.0.0.1:5545→5432` |
| Image (pinned) | `postgres:16.15@sha256:9e2cf6…ff0a97` | same |
| Primary slot | `standby_163_shared` | `standby_163_relay` |
| Slot retention bound | `max_slot_wal_keep_size=2GB` on both primaries (reload-only) | same |
| Replication login | `replicator` role; pw in operator `~/.secrets/pg-{shared,relay}-replicator.pw` (0600) + `/root/.pgpass-standby-*` on .163 (0600) | same |
| Replication path | existing WG `10.100.0.2:5432` (socat bridge on .141) | NEW `pg-relay-wg-bridge` on .141: `10.100.0.2:5433 → mqimefrti7ratmaliirnikov:5432` (`--network coolify`, `unless-stopped`) |
| Primary pg_hba | `host replication replicator 10.0.1.0/24 scram-sha-256` (bridge-NAT source; reload-only, no restart) | same |

Verified 2026-10-23 ~12:00 UTC: both `pg_is_in_recovery()=t`,
`pg_stat_replication` shows `streaming/async/0 bytes` lag, row counts match
primaries (`cmp` 37874 / `relay` 16759).

## Rebuild a standby (no primary restart, reversible)

```bash
# on .163 (pgpass files already in /root, 0600):
sudo env PGPASSFILE=/root/.pgpass-standby-shared pg_basebackup \
  -h 10.100.0.2 -p 5432 -U replicator -D /srv/pg-standby-shared \
  -Fp -Xs -P -S standby_163_shared
# append primary_conninfo + primary_slot_name to postgresql.auto.conf
# (password from operator ~/.secrets), touch standby.signal,
# chown -R 999:999, then:
sudo docker run -d --name pg-standby-shared --restart unless-stopped \
  -v /srv/pg-standby-shared:/var/lib/postgresql/data \
  -p 127.0.0.1:5544:5432 postgres:16.15@sha256:9e2cf6…
```

## Failover (declared .141 loss + human sign-off ONLY)

1. `sudo docker exec pg-standby-shared psql -U pgadmin -c 'SELECT pg_promote();'`
   (same for relay). Verify `pg_is_in_recovery()=f`.
2. Re-point apps via Coolify env change per app (staggered) — no DNS/CF flip.
3. After .141 recovers: reverse `pg_basebackup` to make it the new standby.
Rollback before promote: standby takes no writes — delete it.

## Caveats (open, honest)

- The `pg_hba` replication line lives in Coolify-managed `pg_hba.conf`; a
  Coolify pg redeploy may drop it (standby then fails loudly on reconnect —
  re-add + reload, no restart). Consider moving to Coolify-native config if
  Coolify gains support.
- `.backup` label files and pre-base WAL in S3 are tolerated by
  `backups/coolify-pg-replay.sh` (explicit allowlist; unknowns still fail).
- Whole-provider (Contabo) loss is NOT covered by these standbys — use the
  S3 `fast-pg-raise.sh` path (tested, ~26 s). Host reboot of .163/.141 with
  standbys attached is untested; containers are `unless-stopped` and WG
  ordering (`10-wg.conf`) is in place.
- Lag alerting is not yet wired into `monitors/coolify-healthcheck.sh`
  (suggested: alert on `replay_lag > 60 s`); coordinate with monitoring owner.
