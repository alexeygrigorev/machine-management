#!/usr/bin/env bash
# Install systemd resilience (Restart=always, RestartSec=10, MemoryHigh/Max,
# enabled on boot) and scheduled job-workdir cleanup on a self-hosted GitHub
# Actions runner host.
#
# Usage:
#   ./monitors/install-gha-runner-hardening.sh                  # local host (e.g., Hetzner RMTHZ)
#   ./monitors/install-gha-runner-hardening.sh alexey@62.171.137.73  # remote host (e.g., contabo-ci)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SRC="${HERE}/gha-runner-cleanup.sh"
TARGET="${1:-local}"

SERVICE_UNIT='[Unit]
Description=GitHub Actions self-hosted runner workdir cleanup and resilience check
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gha-runner-cleanup.sh
Nice=10
IOSchedulingClass=idle
'

TIMER_UNIT='[Unit]
Description=Run GitHub Actions runner workdir cleanup every 6 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
'

install_local() {
  echo "== installing gha-runner-cleanup.sh locally =="
  sudo install -m 0755 "$CLEANUP_SRC" /usr/local/sbin/gha-runner-cleanup.sh
  bash -n /usr/local/sbin/gha-runner-cleanup.sh && echo "SYNTAX_OK"

  printf '%s' "$SERVICE_UNIT" | sudo tee /etc/systemd/system/gha-runner-cleanup.service >/dev/null
  printf '%s' "$TIMER_UNIT" | sudo tee /etc/systemd/system/gha-runner-cleanup.timer >/dev/null
  sudo chmod 0644 /etc/systemd/system/gha-runner-cleanup.service /etc/systemd/system/gha-runner-cleanup.timer

  sudo systemctl daemon-reload
  sudo systemctl enable --now gha-runner-cleanup.timer

  echo "== applying runner drop-ins and running initial cleanup =="
  sudo /usr/local/sbin/gha-runner-cleanup.sh
  echo "== verifying runner systemd properties =="
  systemctl list-unit-files --no-legend 'actions.runner.*.service' | awk '{print $1}' | while read -r u; do
    [[ -n "$u" ]] || continue
    printf '%s: ' "$u"
    systemctl show -p UnitFileState,ActiveState,SubState,Restart,RestartSec,MemoryHigh,MemoryMax "$u" | tr '\n' ' '
    echo ""
  done
}

install_remote() {
  local host="$1"
  echo "== installing gha-runner-cleanup.sh on ${host} =="
  scp -q -o BatchMode=yes "$CLEANUP_SRC" "${host}:/tmp/gha-runner-cleanup.sh"
  ssh -o BatchMode=yes "$host" bash -s <<EOF
set -euo pipefail
sudo install -m 0755 /tmp/gha-runner-cleanup.sh /usr/local/sbin/gha-runner-cleanup.sh
rm -f /tmp/gha-runner-cleanup.sh
bash -n /usr/local/sbin/gha-runner-cleanup.sh && echo "SYNTAX_OK"

cat <<'UNIT' | sudo tee /etc/systemd/system/gha-runner-cleanup.service >/dev/null
${SERVICE_UNIT}UNIT

cat <<'TIMER' | sudo tee /etc/systemd/system/gha-runner-cleanup.timer >/dev/null
${TIMER_UNIT}TIMER

sudo chmod 0644 /etc/systemd/system/gha-runner-cleanup.service /etc/systemd/system/gha-runner-cleanup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now gha-runner-cleanup.timer

echo "== applying runner drop-ins and running initial cleanup on ${host} =="
sudo /usr/local/sbin/gha-runner-cleanup.sh
echo "== verifying runner systemd properties on ${host} =="
systemctl list-unit-files --no-legend 'actions.runner.*.service' | awk '{print \$1}' | while read -r u; do
  [[ -n "\$u" ]] || continue
  printf '%s: ' "\$u"
  systemctl show -p UnitFileState,ActiveState,SubState,Restart,RestartSec,MemoryHigh,MemoryMax "\$u" | tr '\n' ' '
  echo ""
done
EOF
}

if [[ "$TARGET" == "local" ]]; then
  install_local
else
  install_remote "$TARGET"
fi
