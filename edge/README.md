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
| Coolify `:8000`, Soketi `:6001/:6002`, cAdvisor `:9101`, and other Docker-published ports via DOCKER-USER | trusted-source allowlist; public `:80/:443` only; generic inbound DROP (`docker-user-fw.sh`) | same |
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

`edge-docker-user-restore.sh` persists only the `DOCKER-USER` chain and
restores it with `iptables-restore --noflush`; it never replays a full host
snapshot. The firewall installer backs up the previous chain files, service,
and script before changing one host. It also removes the audited stale public
UFW allows for ports 8000/6001/6002 (and 3100/9090/9093 on contabo-a) after
preserving the UFW files. The unused public `:8080` dashboard publish is
removed during the next planned proxy recreate by `install-traefik-metrics.sh`.

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
`origin-verify-canary.yml` (`origin-verify-canary-allow` uses the Relay
production header); no app/env/Coolify env or monitor sends the header
(monitors check public health only); prod-website
`E1VNMGFFIXBOXX` and dev-website `E33FS79KPFSAOM` use distinct values.

Procedure (operator box Hetzner RMTHZ; use only an explicitly authorized MAIN
AWS session through AWS Gate. Never use `main-temp` for this rotation.):

1. Back up both `origin-enforce.yml` and `origin-verify-canary.yml` on
   contabo-b before editing. Keep timestamped backups at mode `0600` on the
   host.
2. Generate one new 48-char alnum value per side (prod, dev) into 0600 files, env vars only (never print/log/commit; e.g. `python3 -c "import secrets,string;..."`).
3. Dual-accept first: in `origin-enforce.yml`, edit each live Relay allow
   router to accept old OR new (`Header(old) || Header(new)`) for its side,
   keeping the deny routers. Also change
   `origin-verify-canary.yml`'s `origin-verify-canary-allow` to accept old OR
   new production headers. Install both files at mode `0600`, wait 5s, and
   check `docker logs coolify-proxy` for origin errors. Verify direct live
   origin requests without a header return 403, old and new return 200, and a
   wrong value returns 403 for HTTP and HTTPS on all four Relay hostnames.
   Verify the HTTP canary route the same way. Public health must return 200.
4. Switch CloudFront to the new value one distribution at a time, dev first:
   read-modify-write only the target distribution's origin CustomHeader using
   `get-distribution-config` + `update-distribution` and its ETag. Keep config
   and response files mode `0600`; pass values through files or environment
   variables and never print them or put them in command arguments. Wait for
   each distribution to reach `Deployed`, then verify public health 200 and
   direct origin with the new value returns 200. The current Terraform roots
   are tombstoned, so do not use Terraform for this rotation.
5. Single-accept only new after both distributions are deployed and verified:
   remove the old `Header()` alternative from every live Relay allow router in
   `origin-enforce.yml`, and remove it from the canary allow router in
   `origin-verify-canary.yml` (the canary keeps only the new production-side
   value). Reinstall both files at mode `0600`. Verify direct live origin
   requests without a header, with the old value, or with a wrong value return
   403; the corresponding new value returns 200. Verify the canary route
   rejects no-header, old, and wrong-value requests and accepts only the new
   production value. Verify both public health URLs still return 200. Keep
   host backups at mode `0600`.
6. If a future Terraform root manages either live distribution, or an
   out-of-band update could conflict with a pending apply, STOP after step 3
   and record the exact scoped CloudFront change needed for Alexey. Do not run
   the pending MAIN AWS Terraform apply, DMARC or the F10 gate.

See `edge/origin-tls-enforce/README.md` for transport/rollback verification (`test-origin.sh`, `verify-rollback.py`, `verify_stability.py`). Rotation 2026-10-25 stopped at dual-accept pending Alexey: report `~/tmp/agent-reports/relay-origin-verify-rotation-2026-10-25.md`.

## X-Origin-Verify rotation (Website prod/dev, dual-accept live since 2026-10-27)

Same procedure as above, applied to contabo-a (website): leaked values from
agent tool output (hub intake `b429de1e`). Inventory: CloudFront
`E1VNMGFFIXBOXX` (`prod.datatalks.club`) + `E33FS79KPFSAOM`
(`dev.datatalks.club`) CustomHeaders → contabo-a
`/data/coolify/proxy/dynamic/origin-enforce.yml` allow routers
`origin-websiteprod-allow-*`, `origin-websitedev-allow-*` and shared
`origin-website-allow-*`; `datatalks.club` apex is CloudFront→S3 (no header).

State: dual-accept live on contabo-a since 2026-10-27 (old + new accepted,
16 header refs, backup `origin-enforce.yml.bak-20261027-rotate` 0600 kept,
new values staged 0600 in operator `~/tmp/secrets/website-rotate-20261027/`,
report `~/tmp/agent-reports/origin-verify-rotation-2026-10-27.md`).
Re-verified 2026-10-30 (drain): all origin/public probes pass, old still
accepted by design.

Note for step 4/6: since aws-infra `a30e685` (2026-10-27) the Terraform roots
`main/website`, `main/dev`, `main/relay` are tombstoned — the website and
relay CloudFront distributions are orphaned live config, so the Terraform
option is gone. The CF switch (one distribution at a time, dev first, ETag
read-modify-write `update-distribution`, values via files/stdin only) now
requires an authorized MAIN AWS session (AWS gate) — stopped at dual-accept
pending Alexey for both website and relay rotations.

## AISHL proxy rate limit

`traefik/aishl-ratelimit.yml` defines a per-client rate limit of 10 requests
per second with a burst of 40, plus a 128-request in-flight cap. The rolling
follower attaches both middlewares to the AISHL production routers and reduces
its equivalent domain-specific backend services to one. The dev router is
file-provider managed; `traefik/patch-aisl-dev-route.py` adds the middlewares
to its existing HTTPS router while preserving the current Coolify-owned
backend service and HTTP-to-HTTPS redirect.

After merge, install on contabo-b (the script backs up the existing middleware
and route files and does not recreate the proxy):

```bash
./edge/install-aishl-proxy-guard.sh contabo-b
```

Let the rolling follower deploy the AISHL application once. Verify that a
short 50 requests/second probe from one client gets HTTP 429 while a second
client still gets HTTP 200 from `/ping`; keep the test brief. The limiter uses
Traefik's direct client address. If AISHL is later put behind CloudFront,
restrict the origin and configure trusted forwarded-client addresses through
the AWS gate before relying on per-client limiting behind that edge. Never
trust arbitrary forwarded headers from the public internet.

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
  (self-heal, no recreation). The cron is `/etc/cron.d/coolify-proxy-network-keep`,
  distinct from the pager. Installation backs up existing files and runs
  `--apply` once, appending evidence to `/var/log/coolify-proxy-networks.log`.
- `edge/install-traefik-metrics.sh` now preserves attachments itself: before
  `docker compose up -d traefik` it declares current proxy networks in the
  compose file (via the keeper when installed, else inline), and re-runs
  `--apply` afterwards. The same planned recreate enables JSON access logs for
  5xx responses and requests slower than 500 ms, with only client IP, host,
  path, status, duration, and User-Agent retained. Query parameters and other
  headers are dropped; OBS Vector ships the normalized event to VictoriaLogs.
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
python3 edge/tests/test-proxy-network-installers.py
```

Do NOT `docker compose up -d traefik` on a live proxy outside Alexey's
maintenance window — the recreate itself drops attachments until the compose
patch lands, and the shared proxy serves prod. Prove recreate-safety on a
throwaway replica (see the intake report), never on the live proxy.
