# pg-shared WG bridge — reboot-surviving 10.100.0.2:5432 (t1035u)

CMP (`cmp-staging`) and Website (`website-staging`) on contabo-a (`.163`)
reach `pg-shared` on contabo-b (`.141`) via WireGuard at `10.100.0.2:5432`.
That port used to be served by a hand-started `docker run` container
(`pg-shared-wg-bridge`) with two reboot hazards:

1. `net.ipv4.ip_nonlocal_bind = 0` — Docker could not bind `10.100.0.2`
   before `wg0` was up, so the bridge (and the `:9187`/`:9188`
   postgres-exporters) stayed dead after a reboot until manual restart.
2. `docker.service` had no ordering against `wg-quick@wg0.service`.

This directory codifies the Phase 3 (DR plan t1006u, risk R-05) fix:

| File | Installed to (on node) | Purpose |
|------|------------------------|---------|
| `99-wg-bind.conf` | `/etc/sysctl.d/99-wg-bind.conf` | `ip_nonlocal_bind=1`, live + persisted |
| `docker-override.conf` | `/etc/systemd/system/docker.service.d/10-wg.conf` | `After=`/`Wants=` `wg-quick@wg0` |
| `docker-compose.yml` | `/opt/pg-shared-wg-bridge/docker-compose.yml` | compose-managed bridge (pinned `alpine/socat:1.8.0.1`) |
| `pg-shared-wg-bridge.service` | `/etc/systemd/system/pg-shared-wg-bridge.service` | starts bridge after wg0 + docker, enabled at boot |

The bridge compose is deliberately **separate** from Coolify's generated
`/data/coolify/databases/ekm57uezdngrrscn0aqzidr8/docker-compose.yml`
(Coolify regenerates that file on every deploy — edits there would be lost).

## Install

Run from an operator box (Hetzner) — never develop on Contabo prod boxes:

```bash
# 1) harden both ends (sysctl + docker ordering, no container changes)
./wg-bridge/install-wg-bridge.sh --sysctl-only contabo-a
./wg-bridge/install-wg-bridge.sh contabo-b   # full: hardening + bridge

# 2) restart proof (seconds of SQL blip on .141 while bridge swaps;
#    docker restart proof restarts pg-shared/pg-relay too — maintenance ok)
ssh contabo-b 'sudo systemctl restart pg-shared-wg-bridge'
ssh contabo-b 'sudo ss -tlnp | grep 10.100.0.2:5432'
ssh contabo-a 'pg_isready -h 10.100.0.2 -p 5432'
```

Full reboot of `.141` is intentionally **not** required: the
docker/wg restart proof plus `systemctl show` ordering evidence closes AC 3.

## Verify

```bash
./wg-bridge/tests/test-wg-bridge.sh   # repo-side regression test (no nodes needed)
```

On nodes:

```bash
sysctl net.ipv4.ip_nonlocal_bind                          # expect 1
systemctl show docker.service -p After | grep wg-quick    # expect wg-quick@wg0
systemctl is-enabled pg-shared-wg-bridge                  # expect enabled (contabo-b)
sudo ss -tlnp | grep 10.100.0.2:5432                      # expect LISTEN (contabo-b)
pg_isready -h 10.100.0.2 -p 5432                          # expect accepting (from contabo-a)
```

## Secrets policy

No secrets in this directory or in git. Node-side files contain only the
Coolify container **name** (`ekm57uezdngrrscn0aqzidr8`) as the socat target —
no passwords.
