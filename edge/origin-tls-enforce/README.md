# Origin TLS + verification enforcement (t1143u, child origin-security)
#
# Closes: plaintext CF->origin (http-only) + unauthenticated direct-origin
# bypass for the 3 in-scope origin hostnames behind 4 CF distributions:
#   origin.website.datatalks.club (.163, dists E1VNMGFFIXBOXX + E33FS79KPFSAOM)
#   origin.relay.datatalks.club   (.141, dist E3L9KUTE15WFJF)
#   origin.dev.relay.datatalks.club (.141, dist E35QPYDA1452SA)
#
# Method: Traefik FILE provider only (like edge/traefik/coolify-api-gha.yml).
# No Coolify saves, no container restarts, no DNS changes. Coolify docker
# routers stay as the instant fallback: removing the rendered file restores
# yesterday's behavior with zero restarts (rollback is tested live).
#
# Per hostname, 3 routers + 1 middleware (priorities beat Coolify docker
# routers, whose priority ~= rule length ~55):
#   allow-http (200): Host && (Header(verify) || acme-challenge path) [http]
#   allow-tls  (200): Host && Header(verify) [https] + LE certResolver
#   deny       (150): Host [http,https] -> ipAllowList(127.0.0.1) = 403
# origin.website accepts TWO header values (prod + dev dists share the origin
# with different CustomHeader values): Header(V1) || Header(V2).
#
# Secrets: header values are rendered on the operator box from read-only
# `cloudfront get-distribution` calls into files mode 0600 on the Contabo
# hosts. The repo holds only this README + `origin-enforce.yml.example`
# (placeholders). Never commit rendered files, never print values.
#
# Order of operations (staged, each step verified before the next):
#   1. ./install-origin-tls.sh contabo-a|contabo-b   # TLS routers first (no enforcement yet)
#   2. wait for LE issuance, verify https serves app cert per hostname
#   3. ./install-origin-enforce.sh ...               # add allow/deny gate
#   4. ./verify-origin.sh                            # certs + gate + rollback test
#   5. ./cf-origin-flip.sh <dist> <origin-id> https-only   # one origin at a time, dev first
#   6. ./tests/test-origin.sh                        # full AC matrix
#
# Rollback (any stage): `ssh <host> sudo rm /data/coolify/proxy/dynamic/origin-*.yml`
# (keep the t1037u canary file out of this), wait ~4s for file-watch, direct
# no-header probes return 200 again via Coolify docker routers.
# CF rollback: ./cf-origin-flip.sh <dist> <origin-id> http-only
