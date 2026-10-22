#!/usr/bin/env bash
# On-host DOCKER-USER allowlist (installed by edge/docker-user-fw.sh).
# `apply` is idempotent: flush + rebuild. Env: OPERATOR_V4, OPERATOR_V6, PEER_V4.
set -euo pipefail

# NOTE: rules match `--ctorigdstport` (the PRE-DNAT host port), not `--dport`.
# DOCKER-USER sees packets after DNAT, where dport is the *container* port
# (e.g. host :8000 -> container :8080), so `--dport 8000` NEVER matches here.
# Verified live 2026-10-22: dport-8000 DROP got 0 packets while probes passed;
# ctorigdstport-8000 matched immediately.
ADMIN_PORTS="8000 6001 6002 9101"

apply_v4() {
  iptables -F DOCKER-USER
  # Established traffic (return path of allowed connections) skips the checks.
  iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  iptables -A DOCKER-USER -s 127.0.0.0/8 -j RETURN
  iptables -A DOCKER-USER -s 10.100.0.0/24 -j RETURN
  iptables -A DOCKER-USER -s 10.0.0.0/8 -j RETURN
  iptables -A DOCKER-USER -s 172.16.0.0/12 -j RETURN
  iptables -A DOCKER-USER -s 192.168.0.0/16 -j RETURN
  iptables -A DOCKER-USER -s "${PEER_V4}" -j RETURN
  iptables -A DOCKER-USER -s "${OPERATOR_V4}" -j RETURN
  for P in $ADMIN_PORTS; do
    iptables -A DOCKER-USER -m conntrack --ctorigdstport "$P" \
      -m limit --limit 5/min -j LOG --log-prefix "edge-deny-v4 " --log-level 4
    iptables -A DOCKER-USER -m conntrack --ctorigdstport "$P" -j DROP
  done
}

apply_v6() {
  ip6tables -F DOCKER-USER
  ip6tables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  ip6tables -A DOCKER-USER -s ::1 -j RETURN
  ip6tables -A DOCKER-USER -s "${OPERATOR_V6}" -j RETURN
  # Docker v6 bridge nets (default) — keep local v6 container traffic working.
  ip6tables -A DOCKER-USER -s fd00::/8 -j RETURN
  for P in $ADMIN_PORTS; do
    ip6tables -A DOCKER-USER -m conntrack --ctorigdstport "$P" \
      -m limit --limit 5/min -j LOG --log-prefix "edge-deny-v6 " --log-level 4
    ip6tables -A DOCKER-USER -m conntrack --ctorigdstport "$P" -j DROP
  done
}

case "${1:-apply}" in
  apply)
    : "${OPERATOR_V4:?}"; : "${OPERATOR_V6:?}"; : "${PEER_V4:?}"
    apply_v4
    apply_v6 || echo "WARN: ip6tables rules not applied" >&2
    iptables-save > /etc/edge-docker-user-rules.v4
    ip6tables-save > /etc/edge-docker-user-rules.v6 2>/dev/null || true
    echo "OK: DOCKER-USER allowlist applied + saved"
    ;;
  restore)
    # Boot path: docker.service recreates the chain; re-add our rules.
    sleep 5
    iptables-restore < /etc/edge-docker-user-rules.v4
    ip6tables-restore < /etc/edge-docker-user-rules.v6 2>/dev/null || true
    echo "OK: DOCKER-USER rules restored"
    ;;
  *) echo "usage: $0 [apply|restore]" >&2; exit 2 ;;
esac
