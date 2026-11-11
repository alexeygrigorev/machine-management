#!/usr/bin/env bash
# H4/H7: add a host memory safety margin and tighten SSH without removing keys.
set -euo pipefail
host="${1:?usage: install-contabo-host-guards.sh contabo-a|contabo-b}"
[[ "$host" == contabo-a || "$host" == contabo-b ]]
ssh -o BatchMode=yes "$host" sudo bash -s <<'SH'
set -euo pipefail
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
backup="/var/backups/fable-host-guards-$stamp"
ssh_config=/etc/ssh/sshd_config.d/00-infra-audit.conf
swap_config=/etc/sysctl.d/60-infra-swap.conf
# Do not adopt or overwrite an existing swapfile owned by another installer.
add_swap=0
if [[ -z "$(swapon --show=NAME --noheadings)" ]]; then
  [[ ! -e /swapfile ]] || { echo 'Existing inactive /swapfile requires review' >&2; exit 1; }
  [[ "$(findmnt -n -o FSTYPE /)" == ext4 ]] || { echo 'Review swap support on this filesystem' >&2; exit 1; }
  [[ "$(df -B1 --output=avail / | tail -1)" -gt 8589934592 ]]
  add_swap=1
fi
install -d -m 0700 "$backup"
cp -p /etc/fstab "$backup/fstab"
sysctl -n vm.swappiness > "$backup/swappiness"
for file in "$ssh_config" "$swap_config"; do
  [[ ! -f "$file" ]] || cp -p "$file" "$backup/$(basename "$file")"
done
swap_created=0
committed=0
rollback() {
  if [[ "$committed" == 0 ]]; then
    cp -p "$backup/fstab" /etc/fstab
    for file in "$ssh_config" "$swap_config"; do
      if [[ -f "$backup/$(basename "$file")" ]]; then
        cp -p "$backup/$(basename "$file")" "$file"
      else
        rm -f -- "$file"
      fi
    done
    sysctl -w "vm.swappiness=$(cat "$backup/swappiness")" >/dev/null
    if [[ "$swap_created" == 1 ]]; then
      swapoff /swapfile || true
      # Never unlink a swapfile if swapoff failed.
      if ! swapon --show=NAME --noheadings | grep -Fxq /swapfile; then rm -f /swapfile; fi
    fi
    sshd -t && systemctl reload ssh
    echo "Host guard install failed; restored previous config from $backup" >&2
  fi
}
trap rollback EXIT
if [[ "$add_swap" == 1 ]]; then
  swap_created=1
  (umask 077; fallocate -l 4G /swapfile)
  chmod 0600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  printf '\n/swapfile none swap sw 0 0\n' >> /etc/fstab
fi
printf 'vm.swappiness=10\n' > "$swap_config"
sysctl -p "$swap_config"
printf 'X11Forwarding no\nMaxAuthTries 3\n' > "$ssh_config"
chmod 0644 "$ssh_config" "$swap_config"
sshd -t
sshd -T | grep -Fxq 'x11forwarding no'
sshd -T | grep -Fxq 'maxauthtries 3'
systemctl reload ssh
swapon --show
committed=1
printf 'Host guards installed without restart; rollback snapshot %s\n' "$backup"
SH
# Establish a fresh SSH connection after the reload rather than reusing a master.
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 "$host" 'sudo sshd -T | grep -E "^(x11forwarding|maxauthtries) "; uptime'
