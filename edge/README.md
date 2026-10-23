# Edge harden P1 (t1037u) — DR recovery plan Phase 4, risk R-06/R-08

Status: applied 2026-10-22 (see `~/tmp/agent-reports/dr-p1-edge-harden-t1037u-2026-10-22.md`).

Scope (hard boundary): **no RDS delete, no DNS/CF flip, no app restarts.**
CloudFront stays `http-only`; prod Traefik routers untouched. This kit closes
what can be closed without a traffic flip and proves the rest on canary routes.

| Item | .163 (contabo-a) | .141 (contabo-b) |
|------|------------------|------------------|
| cAdvisor `:9101` public leak | no listener (nothing to bind) | rebound to `10.100.0.2` + `127.0.0.1` (`cadvisor-bind.sh`) |
| Coolify `:8000`, Soketi `:6001/:6002`, cAdvisor `:9101` via DOCKER-USER | allowlist + LOG/DROP (`docker-user-fw.sh`) | same |
| `X-Origin-Verify` enforcement | canary proof only (`install-origin-verify.sh`) | canary proof only |
| `acme.json` off-host backup | `acme-backup.sh` → GPG-encrypted + decrypt-verified storagebox `edge-tls/` (daily via `storagebox-sync`) | same |
| Origin TLS for `origin.website` | GAP (no LE cert; needs Coolify FQDN add + deploy — follow-up, documented in report) | OK (`origin.relay` LE cert present) |

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
