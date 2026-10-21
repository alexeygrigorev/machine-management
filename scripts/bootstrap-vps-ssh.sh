#!/usr/bin/env bash
# Provider-agnostic Ubuntu 24.04 VPS SSH bootstrap (Hetzner-gist style).
# Idempotent: safe to re-run when replacing a dead host.
#
# Installs operator ed25519 pubkeys, creates login user with passwordless sudo,
# hardens sshd, installs fail2ban, enables ufw basics (22 + optional HTTP/S).
#
# Usage:
#   export BOOTSTRAP_PUBKEYS="/path/id_a.pub /path/id_b.pub"
#   # optional first-bootstrap only:
#   export BOOTSTRAP_ROOT_PASSWORD='...'   # or BOOTSTRAP_ROOT_PASSWORD_FILE=/path
#   ./scripts/bootstrap-vps-ssh.sh 203.0.113.10 203.0.113.11
#   # or SSH aliases already in ~/.ssh/config pointing at root@host:
#   ./scripts/bootstrap-vps-ssh.sh contabo-a-root contabo-b-root
#
# Environment:
#   BOOTSTRAP_PUBKEYS          Space-separated pubkey files (required)
#   BOOTSTRAP_USER             Login user (default: alexey)
#   BOOTSTRAP_ROOT_PASSWORD    One-time root password for sshpass first contact
#   BOOTSTRAP_ROOT_PASSWORD_FILE  File containing that password (preferred)
#   BOOTSTRAP_SSH_PORT         SSH port to allow in ufw (default: 22)
#   BOOTSTRAP_OPEN_HTTP        If 1, also ufw allow 80/443/8000 (default: 1)
#   BOOTSTRAP_IDENTITY         Private key for key-based root/user login after install
#   BOOTSTRAP_SKIP_UFW         If 1, skip ufw changes
#   BOOTSTRAP_SKIP_FAIL2BAN    If 1, skip fail2ban
#
# Does NOT call any cloud provider API. Needs only IP (or SSH alias) + root access.
set -euo pipefail

USER_NAME="${BOOTSTRAP_USER:-alexey}"
SSH_PORT="${BOOTSTRAP_SSH_PORT:-22}"
OPEN_HTTP="${BOOTSTRAP_OPEN_HTTP:-1}"
SKIP_UFW="${BOOTSTRAP_SKIP_UFW:-0}"
SKIP_FAIL2BAN="${BOOTSTRAP_SKIP_FAIL2BAN:-0}"

if [[ $# -lt 1 ]]; then
  echo "usage: BOOTSTRAP_PUBKEYS='a.pub b.pub' $0 <host-or-alias> [more...]" >&2
  exit 2
fi

if [[ -z "${BOOTSTRAP_PUBKEYS:-}" ]]; then
  echo "BOOTSTRAP_PUBKEYS is required (space-separated .pub files)" >&2
  exit 2
fi

PUB_FILES=()
for p in ${BOOTSTRAP_PUBKEYS}; do
  if [[ ! -f "$p" ]]; then
    echo "missing pubkey file: $p" >&2
    exit 2
  fi
  PUB_FILES+=("$p")
done

ROOT_PW=""
if [[ -n "${BOOTSTRAP_ROOT_PASSWORD_FILE:-}" ]]; then
  ROOT_PW="$(tr -d '\n' < "$BOOTSTRAP_ROOT_PASSWORD_FILE")"
elif [[ -n "${BOOTSTRAP_ROOT_PASSWORD:-}" ]]; then
  ROOT_PW="$BOOTSTRAP_ROOT_PASSWORD"
fi

ssh_common=(-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes)
if [[ -n "${BOOTSTRAP_IDENTITY:-}" ]]; then
  ssh_common+=(-i "$BOOTSTRAP_IDENTITY")
fi

remote_root() {
  local host="$1"; shift
  local cmd=("$@")
  if ssh "${ssh_common[@]}" -o BatchMode=yes "root@${host}" true 2>/dev/null; then
    ssh "${ssh_common[@]}" -o BatchMode=yes "root@${host}" "$@"
    return
  fi
  # host may already be a full SSH alias (User root)
  if ssh "${ssh_common[@]}" -o BatchMode=yes "${host}" true 2>/dev/null; then
    ssh "${ssh_common[@]}" -o BatchMode=yes "${host}" "$@"
    return
  fi
  if [[ -z "$ROOT_PW" ]]; then
    echo "cannot reach ${host} with keys and no BOOTSTRAP_ROOT_PASSWORD(_FILE)" >&2
    exit 1
  fi
  if ! command -v sshpass >/dev/null; then
    echo "sshpass required for password bootstrap" >&2
    exit 1
  fi
  SSHPASS="$ROOT_PW" sshpass -e ssh "${ssh_common[@]}" "root@${host}" "$@"
}

copy_keys() {
  local host="$1"
  local pub
  for pub in "${PUB_FILES[@]}"; do
    if ssh "${ssh_common[@]}" -o BatchMode=yes "root@${host}" true 2>/dev/null \
      || ssh "${ssh_common[@]}" -o BatchMode=yes "${host}" true 2>/dev/null; then
      # key path already works — still ensure pub is present via ssh-copy-id if available
      if command -v ssh-copy-id >/dev/null; then
        ssh-copy-id -o StrictHostKeyChecking=accept-new ${BOOTSTRAP_IDENTITY:+-i "$BOOTSTRAP_IDENTITY"} -i "$pub" "root@${host}" 2>/dev/null \
          || ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$pub" "${host}" 2>/dev/null \
          || true
      fi
    elif [[ -n "$ROOT_PW" ]]; then
      SSHPASS="$ROOT_PW" sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$pub" "root@${host}"
    else
      echo "cannot install $pub on $host" >&2
      exit 1
    fi
  done
}

REMOTE_SCRIPT=$(cat <<'EOS'
set -euo pipefail
USER_NAME="__USER_NAME__"
SSH_PORT="__SSH_PORT__"
OPEN_HTTP="__OPEN_HTTP__"
SKIP_UFW="__SKIP_UFW__"
SKIP_FAIL2BAN="__SKIP_FAIL2BAN__"
PUBKEYS_B64="__PUBKEYS_B64__"

if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$USER_NAME"
else
  usermod -aG sudo "$USER_NAME" || true
fi

mkdir -p "/home/${USER_NAME}/.ssh" /root/.ssh
chmod 700 "/home/${USER_NAME}/.ssh" /root/.ssh
touch /root/.ssh/authorized_keys "/home/${USER_NAME}/.ssh/authorized_keys"

# merge operator pubs into root + user authorized_keys
tmp=$(mktemp)
printf '%s' "$PUBKEYS_B64" | base64 -d > "$tmp.pubs"
cat /root/.ssh/authorized_keys "$tmp.pubs" | sed '/^$/d' | sort -u > "$tmp"
mv "$tmp" /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
cat /root/.ssh/authorized_keys "/home/${USER_NAME}/.ssh/authorized_keys" | sed '/^$/d' | sort -u > "$tmp"
mv "$tmp" "/home/${USER_NAME}/.ssh/authorized_keys"
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.ssh"
chmod 700 "/home/${USER_NAME}/.ssh"
chmod 600 "/home/${USER_NAME}/.ssh/authorized_keys"
rm -f "$tmp.pubs"

echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER_NAME}"
chmod 440 "/etc/sudoers.d/${USER_NAME}"
visudo -cf "/etc/sudoers.d/${USER_NAME}"

mkdir -p /etc/ssh/sshd_config.d
# neutralize cloud-init password auth if present
for f in /etc/ssh/sshd_config.d/*; do
  [ -f "$f" ] || continue
  if grep -qi 'PasswordAuthentication' "$f"; then
    sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/I' "$f"
  fi
done

cat > /etc/ssh/sshd_config.d/99-harden.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxStartups 10:30:100
PubkeyAuthentication yes
EOF

cat > /etc/ssh/sshd_config.d/harden.conf <<'EOF'
PermitRootLogin prohibit-password
MaxStartups 10:30:100
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

if systemctl list-unit-files | grep -q '^ssh\.service'; then
  systemctl reload ssh
else
  systemctl reload sshd
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

if [[ "$SKIP_FAIL2BAN" != "1" ]]; then
  apt-get install -y -qq fail2ban
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 5m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
findtime = 5m
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
fi

if [[ "$SKIP_UFW" != "1" ]]; then
  apt-get install -y -qq ufw
  ufw allow "${SSH_PORT}/tcp"
  if [[ "$OPEN_HTTP" == "1" ]]; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8000/tcp
  fi
  ufw --force enable
fi

echo "BOOTSTRAP_OK user=${USER_NAME}"
sshd -T | grep -E 'permitrootlogin|passwordauthentication|maxstartups|pubkeyauthentication' || true
EOS
)

# fill placeholders
PUBKEYS_B64=$(cat "${PUB_FILES[@]}" | base64 -w0 2>/dev/null || cat "${PUB_FILES[@]}" | base64)
REMOTE_FILLED=${REMOTE_SCRIPT}
REMOTE_FILLED=${REMOTE_FILLED//__USER_NAME__/$USER_NAME}
REMOTE_FILLED=${REMOTE_FILLED//__SSH_PORT__/$SSH_PORT}
REMOTE_FILLED=${REMOTE_FILLED//__OPEN_HTTP__/$OPEN_HTTP}
REMOTE_FILLED=${REMOTE_FILLED//__SKIP_UFW__/$SKIP_UFW}
REMOTE_FILLED=${REMOTE_FILLED//__SKIP_FAIL2BAN__/$SKIP_FAIL2BAN}
REMOTE_FILLED=${REMOTE_FILLED//__PUBKEYS_B64__/$PUBKEYS_B64}

for host in "$@"; do
  echo "==== bootstrap $host ===="
  copy_keys "$host"
  remote_root "$host" bash -s <<<"$REMOTE_FILLED"

  # verify user key login when identity provided or default agent works
  verify_target="${USER_NAME}@${host}"
  if ssh "${ssh_common[@]}" -o BatchMode=yes "$verify_target" 'sudo -n true' 2>/dev/null; then
    echo "VERIFY_OK $verify_target"
  else
    echo "VERIFY_WARN: could not BatchMode login as $verify_target (add Host stanza / IdentityFile)"
  fi
done

echo "ALL_DONE"
