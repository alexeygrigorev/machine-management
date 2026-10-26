# Coolify proxy maintenance-window live recreate — runbook (PREP-ONLY)

Status: plan only. Do NOT run the recreate steps without Alexey's explicit
window approval. The live `coolify-proxy` containers were last recreated
2026-10-25 (t1425u proof) and must not be recreated again until Alexey picks
a window below.

Related: intake `62eeec31-ca9f-4549-8287-e43bea48676c`
(`proxy-recreate-pager`). Durable-fix design: `edge/README.md`
§"Proxy network durability". Last verified green 2026-10-26 (keeper
`--check` CHECK_OK on both hosts, all 7 health endpoints 200).

## 0. Pre-checks (read-only, may run any time)

From the operator box (Hetzner), SSH aliases `contabo-a` (.163) and
`contabo-b` (.141):

```bash
# keeper + pager installed and current (fb89e19 SHAs)
ssh contabo-a 'sudo sha256sum /usr/local/sbin/ensure-coolify-proxy-networks.sh /usr/local/sbin/coolify-proxy-networks.sh'
# expect 47f4b558… (keeper) and bdb8d706… (pager); compare with origin/main
ssh contabo-b 'sudo sha256sum /usr/local/sbin/ensure-coolify-proxy-networks.sh /usr/local/sbin/coolify-proxy-networks.sh'

# declarative compose already holds the service networks
ssh contabo-a "sudo grep -A4 '^networks:' /data/coolify/proxy/docker-compose.yml"
# expect qjnpmney8j8ehfuqcmzpjtzt + coolify, both external: true
ssh contabo-b "sudo grep -A4 '^networks:' /data/coolify/proxy/docker-compose.yml"
# expect t9uudl5ik40webxrzamrm8qy + coolify, both external: true

# runtime agrees with compose (must be CHECK_OK on both before any window)
ssh contabo-a 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --check'
ssh contabo-b 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --check'

# crons present
ssh contabo-a 'sudo cat /etc/cron.d/coolify-proxy-network-keep /etc/cron.d/coolify-proxy-networks'
ssh contabo-b 'sudo cat /etc/cron.d/coolify-proxy-network-keep /etc/cron.d/coolify-proxy-networks'
```

Baseline health (from Hetzner, all must be 200 before starting):

```bash
for u in https://relay.datatalks.club/health/ \
         https://dev.relay.datatalks.club/health/ \
         https://aishippinglabs.com/ \
         https://courses.datatalks.club/api/health/ \
         https://dev.courses.datatalks.club/ping \
         https://datatalks.club/ \
         https://prod.datatalks.club/; do
  echo -n "$u -> "
  curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 20 "$u"
done
```

Optional continuous sampler during the window (every ~2 s, stop afterwards):

```bash
while true; do
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  for u in https://relay.datatalks.club/health/ \
           https://dev.relay.datatalks.club/health/ \
           https://aishippinglabs.com/ \
           https://courses.datatalks.club/api/health/ \
           https://dev.courses.datatalks.club/ping \
           https://datatalks.club/ \
           https://prod.datatalks.club/; do
    printf '%s ' "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u")"
  done
  echo
  sleep 2
done | tee ~/tmp/agent-reports/proxy-recreate-<date>/health-samples.tsv
```

## 1. Recreate — contabo-b FIRST (serves Relay prod + AISHL)

```bash
ssh contabo-b "sudo docker inspect coolify-proxy --format '{{.Created}} {{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}},{{end}}'"
ssh contabo-b 'cd /data/coolify/proxy && sudo docker compose up -d --force-recreate'
# wait ~15 s, then:
ssh contabo-b "sudo docker inspect coolify-proxy --format '{{.Created}} {{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}},{{end}}'"
# expect new Created timestamp and nets: coolify,t9uudl5ik40webxrzamrm8qy
ssh contabo-b 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --check'
# expect CHECK_OK
```

Expected impact (t1425u measured): ~2 s container swap; exactly one
sample during the swap may read 000/504 on relay prod/dev + AISHL;
200 again on the next sample. The staging attachments
(`fjnpmzwomg…`, `mekt9kz74…`, routing disabled) correctly drop off.

## 2. Recreate — contabo-a SECOND (serves CMP prod/dev, dapier)

Only after contabo-b is CHECK_OK and health is 200 for ≥ 2 min.

```bash
ssh contabo-a "sudo docker inspect coolify-proxy --format '{{.Created}} {{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}},{{end}}'"
ssh contabo-a 'cd /data/coolify/proxy && sudo docker compose up -d --force-recreate'
# Traefik graceful stop takes ~10 s; wait ~20 s, then:
ssh contabo-a "sudo docker inspect coolify-proxy --format '{{.Created}} {{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}},{{end}}'"
# expect new Created timestamp and nets: coolify,qjnpmney8j8ehfuqcmzpjtzt
ssh contabo-a 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --check'
# expect CHECK_OK
```

Expected impact (t1425u measured): ~10 s stop/start window; cmp prod/dev
000 and dapier 504 for ~5 samples (~10 s); 200 from the next sample.
Website (separate path) showed zero failures.

## 3. Post-checks (both hosts)

```bash
ssh contabo-a 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --check'
ssh contabo-b 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --check'
# keeper log shows APPLY_OK already durable; pager shows OK check=proxy-networks
ssh contabo-a 'sudo tail -n 6 /var/log/coolify-proxy-networks.log; sudo tail -n 4 /var/log/coolify-healthcheck.log'
ssh contabo-b 'sudo tail -n 6 /var/log/coolify-proxy-networks.log; sudo tail -n 4 /var/log/coolify-healthcheck.log'
```

Re-run the §0 baseline table: all 7 endpoints 200 (dev ≤ 2 s). Keep the
sampler running ≥ 2 min after the second recreate with zero non-200.

## 4. Rollback

No data changes are involved (proxy is stateless Traefik; compose patch
only adds external-network declarations with timestamped backups
`docker-compose.yml.bak-proxy-nets-*`).

- If `--check` reports MISSING after a recreate (not expected — compose
  declares the networks): run the keeper once per host, it reconnects
  without restart:
  `ssh <host> 'sudo /usr/local/sbin/ensure-coolify-proxy-networks.sh --apply'`
  then re-run `--check`.
- If the proxy fails to start: inspect
  `ssh <host> 'cd /data/coolify/proxy && sudo docker compose logs traefik --tail 50'`;
  restore the newest backup compose
  (`sudo cp docker-compose.yml.bak-proxy-nets-<ts> docker-compose.yml`)
  and `sudo docker compose up -d traefik`, then `--apply` + `--check`.
- Never detach networks by hand, never `docker network rm`, never touch
  volumes/containers of apps, never touch Coolify itself.

## 5. Rules of engagement

- One host at a time; contabo-b first, then contabo-a after ≥ 2 min green.
- No file edits, no deletions, no fixer runs needed (fixer only if
  something stays down > 2 min or stays detached).
- No AWS access needed (all SSH + docker + curl). Never use main-temp.
- Record before/after `docker inspect` Created + nets, both `--check`
  outputs, and the sampler file as the acceptance evidence.
