#!/usr/bin/env bash
# Shared Relay transport for monitor alerts that do not monitor Relay itself.
# The configured `alerts` sender owns the From header; callers never construct
# a From header or use AWS directly.

relay_sanitize_body() {
  # The Relay CloudFront WAF rejects bodies containing IP-literal URLs. Keep
  # the address readable while removing only the scheme, as DR alerts do.
  sed -E 's#https?://(\[?[0-9A-Fa-f:.]+\]?)([/:?#]|$)#\1\2#g'
}

relay_send_alert() {
  local recipients="${1// /,}" subject="$2" body="$3"
  local recipient config bin sent=0
  local -a addresses=()
  IFS=',' read -r -a addresses <<< "$recipients"

  config="${RELAY_MONITOR_CONFIG:-}"
  if [[ -z "$config" ]]; then
    if [[ -r /etc/relay-monitors.toml ]]; then
      config=/etc/relay-monitors.toml
    elif [[ -r /home/alexey/.config/datamailer/config.toml ]]; then
      # The Hetzner host's daily digest runs as root but uses Alexey's
      # separately managed Relay Maintenance client.
      config=/home/alexey/.config/datamailer/config.toml
    else
      config="${HOME}/.config/datamailer/config.toml"
    fi
  fi
  bin="${DATAMAILER_BIN:-}"
  if [[ -z "$bin" ]]; then
    if [[ -x /usr/local/bin/datamailer ]]; then
      bin=/usr/local/bin/datamailer
    elif [[ -x /home/alexey/.local/bin/datamailer ]]; then
      bin=/home/alexey/.local/bin/datamailer
    elif [[ -x "${HOME}/.local/bin/datamailer" ]]; then
      bin="${HOME}/.local/bin/datamailer"
    else
      bin="$(command -v datamailer 2>/dev/null || true)"
    fi
  fi

  [[ -x "$bin" ]] || return 1
  for recipient in "${addresses[@]}"; do
    [[ -n "$recipient" ]] || continue
    if ! printf '%s\n' "$body" | relay_sanitize_body \
      | env -u DATAMAILER_API_KEY -u DATAMAILER_URL \
        DATAMAILER_CONFIG="$config" "$bin" send --from alerts \
        --to "$recipient" --subject "$subject" >/dev/null 2>&1; then
      return 1
    fi
    sent=$((sent + 1))
  done
  [[ "$sent" -gt 0 ]]
}
