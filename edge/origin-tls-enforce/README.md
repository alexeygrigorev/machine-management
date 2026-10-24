# Origin TLS and verification enforcement (t1143u)

Live verification on 2026-10-24: website production, website development,
Relay production and Relay development all use HTTPS origins. Website development
is isolated and routes to a distinct dev website backend backed by the
website_dev database. All four origins are https-only with active origin
verification. No DNS or unrelated distribution changes were made.

**The three active origins passed sustained re-verification at
16:40:20–16:45:19 UTC on 2026-10-23.** Sixty rounds produced 780 matching
responses: public health and authenticated HTTPS origin health for Website,
Relay production and Relay development, the Website homepage, and missing/wrong
header rejection on every active origin. All 420 serving responses were 200;
all 360 unauthenticated responses were 403. Public caching was disabled on the
three distributions. Trusted certificates, HTTP/HTTPS credential enforcement,
current deployment states and the IPv4/IPv6 administrative-port firewall were
checked separately. File-provider rollback passed on both nodes with unchanged
enforcement files and firewall rules. No new transport change was necessary:
production was already HTTPS; the guarded Website-dev cutover was refused
before any write. This closes active-origin security/traffic verification;
Website-dev cutover remains explicitly deferred under the readiness condition.

The failed earlier window is retained: at 15:58:59–16:00:15 UTC, Website public
health, homepage and authenticated direct-origin health each returned two 503s
and one connection timeout in ten samples. Unauthenticated origin requests
were denied throughout. Subsequent rolling-web work landed the Website
`GUNICORN_CMD_ARGS=--threads 4` capacity override in `e82fe3e`; its serving
container now has that setting. See [the availability diagnosis and
remediation](../../deployments/coolify-rolling-web.md). The fresh passing
window above follows that deployed change; it does not erase the failed
window or claim uninterrupted availability outside the measured interval.

| Distribution | Origin ID | Transport | Viewer |
| --- | --- | --- | --- |
| E1VNMGFFIXBOXX | website-production-alb | https-only | prod.datatalks.club |
| E33FS79KPFSAOM | website-dev-alb | https-only | dev.datatalks.club |
| E3L9KUTE15WFJF | relay-production-shared-alb | https-only | relay.datatalks.club |
| E35QPYDA1452SA | relay-dev-shared-alb | https-only | dev.relay.datatalks.club |

Seven origin/viewer names serve trusted certificates with valid hostnames and
chains. The file-provider configuration uses separate HTTP and TLS routers:
credential-gated allow routes at priority 200 and deny routes at priority 150.
Direct requests with missing or incorrect `X-Origin-Verify` receive 403.
Website-dev's priority-500 isolation guard supersedes these routes and returns
503 even with the correct credential. Production website's shared origin
accepts both configured website credentials; viewer-specific routes use only
their own credential. HTTP-01 challenge handling remains available for renewal.

CloudFront may forward viewer Host and SNI. Readiness therefore validates both
the configured origin domain and the viewer name, pinned to the actual node.
Certificate trust, expiry and SAN matching are checked by curl without insecure
options. See [AWS origin TLS requirements](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/http-502-bad-gateway.html).

## Current backend ownership

The installed private `origin-enforce.yml` files were migrated by the rolling
web deployment work. Website production uses
`http-0-nax9srpks6z7w1jgpebiuwuov3-web-2567@docker`; Relay production uses
`http-0-oascx5kjeimc0ivpttag9z3qv3-web-2567@docker`. Their allow routes preserve
`rolling-retry@docker`. See [rolling deployment ownership](../../deployments/coolify-rolling-web.md).
Relay-dev retains `http-0-t9uudl5ik40webxrzamrm8qy-web-2567@docker`.

The original bootstrap installers contain historical Compose backend mappings.
They now refuse to overwrite existing enforcement. Preserve installed backend
references, middleware, credentials and deny routers when making a deliberate
routing change; replaying the old renderer is not a recovery procedure.

Website-dev routes to the isolated dev backend `website-dev-web` backed by
the `website_dev` database on pg-shared (`10.100.0.2:5432`). The priority-500
isolation guard has been retired, and origin verification routes requests to this
distinct dev backend with valid TLS and credential enforcement. Both origin domain
and viewer hostname (`dev.datatalks.club`) pass readiness checks. E33 uses https-only.

## Verification

Run from the operator box with its existing AWS credential profile and SSH
aliases. Override `AWS_PROFILE` if needed; the default is `main-temp`. Isolated
workers can point `AWS_SHARED_CREDENTIALS_FILE` and `AWS_CONFIG_FILE` at the
operator's existing private files without copying or printing credentials.

```sh
bash edge/origin-tls-enforce/tests/test-origin.sh
python3 edge/origin-tls-enforce/verify-rollback.py
python3 edge/origin-tls-enforce/verify_stability.py --rounds 60 --interval 5 --output /tmp/origin-stability-UNIQUE.json
python3 -m unittest discover -s edge/origin-tls-enforce/tests -p 'test_*.py' -v
```

The first command is read-only. It checks live authenticated HTTP/HTTPS health,
missing and wrong headers, trusted TLS, all four deployment/transport states,
public health, IPv4/IPv6 administrative-port DROP rules, persistence and secret
file permissions. Website-dev is explicitly reported as deferred only when its
observed HTTP/HTTPS/public responses match the recorded isolation state. It
cannot silently skip a healthy dev route that still needs an HTTPS cutover.

The stability command samples the three active origins' public health,
authenticated HTTPS health, missing/wrong-header denial, and the public Website
homepage. Every request uses a unique query parameter. Relay public requests
are spaced at least five seconds apart to respect the existing rate limit.
A single nonmatching response or connection/certificate error fails the whole
window; no retry erases a failed sample. The new JSON file retains sanitized
timestamps/statuses, including partial evidence on interruption. Run the full
live matrix before and after the window to check HTTP, forwarded viewer SNI,
Website-dev's explicit deferred state, deployment state and firewall as well.
Passing finite samples describe that observation window, not an availability
guarantee or permission to remove the dev guard.

The rollback command temporarily adds a priority-300 file-provider route on
each node, matching only the real credential and a unique query parameter on
the health path. It verifies the temporary response, removes that exact test
file in a `finally` block, and verifies normal responses return. It also checks
that the enforcement file and both firewall rule sets remain identical and
public health stays 200. It never removes active verification or exposes an
unauthenticated bypass. This proves file-provider routing rollback; it does
not claim to repeat a CloudFront transport rollback.

The initial implementation separately exercised full enforcement removal and
reinstallation before its original transport changes, and an actual Relay-dev
HTTPS-to-HTTP rollback during SNI diagnosis (source history `08fb297`,
`7f7f2d0`, `bd3617f`; dated private origin-security report). Those are historical
evidence, not new mutations during this re-verification.

## A future transport change

After origin readiness **and rollback** have been verified, change one named
origin at a time, dev first when ready:

```sh
bash edge/origin-tls-enforce/cf-origin-flip.sh E35QPYDA1452SA relay-dev-shared-alb https-only
```

The wrapper runs `origin_transport.py`. It accepts only the four exact
(distribution, origin ID) pairs above and checks their domain, viewer alias,
HTTPS port and configured credential. It requires authenticated health 200 and
missing/wrong-header denial on both protocols for both origin and viewer names,
plus healthy public traffic. The config and ETag come from one snapshot; an
ETag race prevents the write. Only the named origin's `OriginProtocolPolicy`
changes. The secret-bearing configuration goes through stdin, not argv or disk.
It waits for deployment, checks the deployed value and public health, and prints
the exact command restoring the preceding transport. The existing typed-YES
operator confirmation remains in this utility.

A failed/uncertain update must be reconciled by reading the distribution before
retrying. Use the printed inverse command for transport rollback. Keep origin
TLS and credential enforcement active during transport rollback. For routing
recovery, restore a private known-good configuration with **current healthy
backend references** atomically and re-run verification; do not wildcard-delete
origin files or reopen direct access. No app restarts, firewall changes or DNS
changes are part of these procedures.

Header values remain private: installed enforcement files are root-owned mode
0600; AWS responses and response bodies are never printed by the verifiers.
