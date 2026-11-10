#!/usr/bin/env bash
# On-host DOCKER-USER allowlist (installed by edge/docker-user-fw.sh).
# `apply` is idempotent: flush + rebuild. Persistence stores only the
# DOCKER-USER chain, never a host-wide iptables snapshot.
set -euo pipefail

# NOTE: rules match `--ctorigdstport` (the PRE-DNAT host port), not `--dport`.
# DOCKER-USER sees packets after DNAT, where dport is the *container* port
# (e.g. host :8000 -> container :8080), so `--dport 8000` NEVER matches here.
# Verified live 2026-10-22: dport-8000 DROP got 0 packets while probes passed;
# ctorigdstport-8000 matched immediately.
ADMIN_PORTS="8000 6001 6002 9101"
PUBLIC_WEB_PORTS="80 443"
STATE_DIR="${EDGE_DOCKER_USER_STATE_DIR:-/etc}"
RULES_V4="${EDGE_DOCKER_USER_RULES_V4:-${STATE_DIR}/edge-docker-user-rules.v4}"
RULES_V6="${EDGE_DOCKER_USER_RULES_V6:-${STATE_DIR}/edge-docker-user-rules.v6}"

save_docker_user_chain() {
  local save_command="$1" output="$2" tmp
  tmp="${output}.tmp.$$"
  "$save_command" -t filter | awk '
    $0 == "*filter" { in_filter=1; print; next }
    in_filter && $0 == "COMMIT" { print; in_filter=0; next }
    in_filter && /^:DOCKER-USER / { print; found=1; next }
    in_filter && /^-A DOCKER-USER / { print; next }
    END { if (!found) exit 1 }
  ' > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$output"
}

restore_docker_user_chain() {
  local firewall_command="$1" restore_command="$2" rules_file="$3"
  [[ -s "$rules_file" ]] || { echo "ERROR: missing DOCKER-USER rules: $rules_file" >&2; return 1; }
  "$firewall_command" -F DOCKER-USER
  "$restore_command" --noflush < "$rules_file"
}

apply_v4() {
  iptables -F DOCKER-USER
  # Established traffic (return path of allowed connections) skips the checks.
  iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  iptables -A DOCKER-USER -i lo -j RETURN
  iptables -A DOCKER-USER -s "${PEER_V4}" -j RETURN
  iptables -A DOCKER-USER -s "${OPERATOR_V4}" -j RETURN
  for P in $PUBLIC_WEB_PORTS; do
    iptables -A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport "$P" -j RETURN
  done
  # Private Docker and WireGuard sources are trusted only when they arrive
  # through a non-public interface. A forged RFC1918 source on eth0 must not
  # bypass the public-interface default deny below.
  for NET in 10.100.0.0/24 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    iptables -A DOCKER-USER ! -i eth0 -s "$NET" -j RETURN
  done
  for P in $ADMIN_PORTS; do
    iptables -A DOCKER-USER -m conntrack --ctorigdstport "$P" \
      -m limit --limit 5/min -j LOG --log-prefix "edge-deny-v4 " --log-level 4
    iptables -A DOCKER-USER -m conntrack --ctorigdstport "$P" -j DROP
  done
  iptables -A DOCKER-USER -i eth0 -m limit --limit 5/min \
    -j LOG --log-prefix "edge-deny-v4 " --log-level 4
  # Default-deny every other new inbound Docker-published port on the public
  # interface. Keep this as the final rule so new published ports stay closed.
  iptables -A DOCKER-USER -i eth0 -j DROP
}

apply_v6() {
  ip6tables -F DOCKER-USER
  ip6tables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  ip6tables -A DOCKER-USER -i lo -j RETURN
  ip6tables -A DOCKER-USER -s "${OPERATOR_V6}" -j RETURN
  for P in $PUBLIC_WEB_PORTS; do
    ip6tables -A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport "$P" -j RETURN
  done
  # Docker v6 bridge nets (default) — keep local v6 container traffic working,
  # but only when the source is not arriving from the public interface.
  ip6tables -A DOCKER-USER ! -i eth0 -s fd00::/8 -j RETURN
  for P in $ADMIN_PORTS; do
    ip6tables -A DOCKER-USER -m conntrack --ctorigdstport "$P" \
      -m limit --limit 5/min -j LOG --log-prefix "edge-deny-v6 " --log-level 4
    ip6tables -A DOCKER-USER -m conntrack --ctorigdstport "$P" -j DROP
  done
  ip6tables -A DOCKER-USER -i eth0 -m limit --limit 5/min \
    -j LOG --log-prefix "edge-deny-v6 " --log-level 4
  ip6tables -A DOCKER-USER -i eth0 -j DROP
}

case "${1:-apply}" in
  apply)
    : "${OPERATOR_V4:?}"; : "${OPERATOR_V6:?}"; : "${PEER_V4:?}"
    install -d -m 0755 "$STATE_DIR"
    apply_v4
    save_docker_user_chain iptables-save "$RULES_V4"
    if command -v ip6tables >/dev/null && command -v ip6tables-save >/dev/null; then
      apply_v6
      save_docker_user_chain ip6tables-save "$RULES_V6"
    else
      echo "WARN: ip6tables unavailable; IPv6 DOCKER-USER rules not applied" >&2
    fi
    echo "OK: DOCKER-USER allowlist applied; only DOCKER-USER chain persisted"
    ;;
  restore)
    # Docker recreates its chains before this service runs. Flush and restore
    # only DOCKER-USER so the current Docker NAT/filter rules remain intact.
    sleep 5
    restore_docker_user_chain iptables iptables-restore "$RULES_V4"
    if [[ -s "$RULES_V6" ]] && command -v ip6tables >/dev/null && command -v ip6tables-restore >/dev/null; then
      restore_docker_user_chain ip6tables ip6tables-restore "$RULES_V6"
    fi
    echo "OK: DOCKER-USER rules restored without replacing Docker tables"
    ;;
  *) echo "usage: $0 [apply|restore]" >&2; exit 2 ;;
esac
