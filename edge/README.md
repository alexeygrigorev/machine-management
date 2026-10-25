# Edge harden P1 (t1037u) — DR recovery plan Phase 4, risk R-06/R-08

Original t1037u stage: applied 2026-10-22 (see `~/tmp/agent-reports/dr-p1-edge-harden-t1037u-2026-10-22.md`).

The original stage below made no DNS/CloudFront changes or app restarts.
The subsequent [origin TLS and enforcement stage](origin-tls-enforce/README.md)
now protects live Website/Relay routes: three origins use HTTPS; website-dev
remains deferred behind its isolation guard. Use that runbook for current
verification and rollback. Do not replay historical canary/bootstrap routing
over the current rolling backends.

| Item | .163 (contabo-a) | .141 (contabo-b) |
|------|------------------|------------------|
| cAdvisor `:9101` public leak | no listener (nothing to bind) | rebound to `10.100.0.2` + `127.0.0.1` (`cadvisor-bind.sh`) |
| Coolify `:8000`, Soketi `:6001/:6002`, cAdvisor `:9101` via DOCKER-USER | allowlist + LOG/DROP (`docker-user-fw.sh`) | same |
| `X-Origin-Verify` enforcement | live Website origin/viewer routes; dev guard retained | live Relay production/development origin/viewer routes |
| `acme.json` off-host backup | `acme-backup.sh` → GPG-encrypted + decrypt-verified storagebox `edge-tls/` (daily via `storagebox-sync`) | same |
| Origin TLS | Website origin + viewer certificates verified | Relay production/development origin + viewer certificates verified |

## Run from operator box (Hetzner RMTHZ), never develop on Contabo

```bash
./edge/acme-backup.sh                                # 1. backup certs first
./edge/cadvisor-bind.sh contabo-b                    # 2. close :9101 leak
./edge/docker-user-fw.sh contabo-a                   # 3. DOCKER-USER allowlist
./edge/docker-user-fw.sh contabo-b
X_ORIGIN_VERIFY="$(aws --profile main-temp cloudfront get-distribution \
  --id E3L9KUTE15WFJF --query \
  'Distribution.DistributionConfig.Origins.Items[0].CustomHeaders.Items[0].HeaderValue' \
  --output text)" ./edge/install-origin-verify.sh contabo-a  # 4. canary
X_ORIGIN_VERIFY="..." ./edge/install-origin-verify.sh contabo-b
./edge/tests/test-edge.sh                            # 5. verify
```

Rollback (each step is independent, one ssh command):

```bash
ssh <host> sudo systemctl stop edge-docker-user-restore
ssh <host> sudo iptables -F DOCKER-USER && sudo ip6tables -F DOCKER-USER  # UI open again
ssh contabo-b 'cd /data/lgtm/exporters && sudo sed -i "s/10.100.0.2:9101:8080/9101:8080/" docker-compose.node.yml && sudo docker compose up -d cadvisor'
ssh <host> sudo rm /data/coolify/proxy/dynamic/origin-verify-canary.yml   # canary gone
```

No secrets in git: `origin-verify-canary.yml` (with the real header value) is
rendered on the operator box from `$X_ORIGIN_VERIFY` and exists only on the
Contabo hosts (`0600`). The repo holds only `origin-verify.yml.example` with
a placeholder.

## Coolify API for GHA (t1040u)

DOCKER-USER keeps host `:8000` closed. GHA reaches Coolify via Traefik:

- File: `edge/traefik/coolify-api-gha.yml` → `/data/coolify/proxy/dynamic/` on contabo-a
- URL: `https://coolify.169.58.119.163.sslip.io` (LE cert; `/api` only)
- GitHub env secret `COOLIFY_URL` for website / AISHL / CMP / relay `coolify-staging`

## X-Origin-Verify rotation (Relay prod/dev, zero-downtime)

Inventory (names/locations only, never values): CloudFront CustomHeaders
`X-Origin-Verify` on `E3L9KUTE15WFJF` (`relay.datatalks.club`,
origin `origin.relay.datatalks.club`) and `E35QPYDA1452SA`
(`dev.relay.datatalks.club`, origin `origin.dev.relay.datatalks.club`);
Contabo-b `/data/coolify/proxy/dynamic/origin-enforce.yml` allow routers
`origin-relay-allow-*`, `origin-relaypub-allow-*` (prod) and
`origin-relaydev-allow-*`, `origin-relaydevpub-allow-*` (dev), plus
`origin-verify-canary.yml` (canary proof only); no app/env/Coolify env or
monitor sends the header (monitors check public health only); prod-website
`E1VNMGFFIXBOXX` and dev-website `E33FS79KPFSAOM` use distinct values.

Procedure (operator box Hetzner RMTHZ, `aws --profile main-temp`):

1. Backup: `ssh contabo-b 'sudo cp -a /data/coolify/proxy/dynamic/origin-enforce.yml /data/coolify/proxy/dynamic/origin-enforce.yml.bak-YYYYMMDD-rotate && sudo chmod 0600 ...bak...'` (0600 on host).
2. Generate one new 48-char alnum value per side (prod, dev) into 0600 files, env vars only (never print/log/commit; e.g. `python3 -c "import secrets,string;..."`).
3. Dual-accept first: edit each allow router to accept old OR new (`Header(old) || Header(new)`), keep deny routers, `install -m 0600`, wait 5s, check `docker logs coolify-proxy` for origin errors. Verify direct origin: no-header 403, old 200, new 200, wrong 403 on http+https for all four hostnames; public health 200.
4. Switch CloudFront to new value (one distribution at a time, dev first): read-modify-write via ETag (`get-distribution-config` + `update-distribution`), or via Terraform (`taint random_password...` + apply). Verify public health 200, then direct origin with new 200.
5. Single-accept only new: remove old `Header()` alternative, reinstall 0600, verify no-header 403, old 403, new 200, public 200. Keep host backups 0600.
6. If distributions are Terraform-managed such that an out-of-band CloudFront change would conflict/drift (main/relay `random_password.origin_verify`, main/dev `random_password.relay_origin_verify`), STOP after step 3 and record the exact `update-distribution` / Terraform change for Alexey. Do not run the pending MAIN AWS terraform apply, DMARC or F10 gate.

See `edge/origin-tls-enforce/README.md` for transport/rollback verification (`test-origin.sh`, `verify-rollback.py`, `verify_stability.py`). Rotation 2026-10-25 stopped at dual-accept pending Alexey: report `~/tmp/agent-reports/relay-origin-verify-rotation-2026-10-25.md`.

## Proxy network durability (2026-10-25 relay-dev/cmp-dev incident)

`coolify-proxy` (Traefik) lost its ephemeral attachments to Coolify service
networks on every recreate (proxy compose declares only `coolify`; service
networks like relay-dev `t9uu…` / cmp-dev `qjnp…` are attached out-of-band by
Coolify). After the 00:09 UTC metrics recreate, Traefik blackholed those
backends (SYN into an unattached bridge → hang, curl 000) while
`coolify`-network backends (prod rolling containers) stayed green. Manual
`docker network connect` restored relay-dev but is not durable.

Durable fix (this repo, versioned):

- `edge/ensure-coolify-proxy-networks.sh` — idempotent reconciler (runs on the
  node): discovers every running `traefik.enable=true` container's
  `traefik.docker.network`, `docker network connect`s the missing ones (no
  restart), and patches `/data/coolify/proxy/docker-compose.yml` to declare
  them (`external: true` + service attachment, backup before write) so the
  NEXT recreate preserves them. `--check` is read-only for monitors.
- `edge/install-proxy-network-keep.sh` + `edge/proxy-network-keep.cron` —
  installs the script to `/usr/local/sbin` and runs `--apply` every 2 min
  (self-heal, no recreation).
- `edge/install-traefik-metrics.sh` now preserves attachments itself: before
  `docker compose up -d traefik` it declares current proxy networks in the
  compose file (via the keeper when installed, else inline), and re-runs
  `--apply` afterwards.
- Pager: `monitors/coolify-proxy-networks.sh` (+ cron/env/installer) verifies
  independently every 5 min and mails **dev@dtcdev.click ONLY** (same
  dedupe/recover rules) when the proxy is still detached.

```bash
./edge/install-proxy-network-keep.sh contabo-a contabo-b
ssh contabo-a 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --apply'
ssh contabo-b 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --apply'
./monitors/install-coolify-proxy-networks.sh contabo-a contabo-b
./edge/tests/test-proxy-networks.sh
bash monitors/tests/test-coolify-proxy-networks.sh
```

Do NOT `docker compose up -d traefik` on a live proxy outside Alexey's
maintenance window — the recreate itself drops attachments until the compose
patch lands, and the shared proxy serves prod. Prove recreate-safety on a
throwaway replica (see the intake report), never on the live proxy.
