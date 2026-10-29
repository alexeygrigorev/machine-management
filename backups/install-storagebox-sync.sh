#!/usr/bin/env bash
# Install the daily Storagebox mirror job on the Hetzner OPERATOR box
# (has the Storagebox mount + AWS read creds + SSH to Contabo).
#
# Run from the repo root on Hetzner:  sudo ./backups/install-storagebox-sync.sh
#
# Copies backups/storagebox-sync.sh + backups/prune-storagebox.sh +
# edge/acme-backup.sh to /usr/local/sbin, installs the 04:30 Europe/Berlin
# cron entry. Never writes credentials: AWS comes from the cron user's
# standard chain (AWS_PROFILE=storagebox-mirror-reader default — the
# dedicated read-only IAM principal; main-temp is forbidden); the acme GPG
# passphrase must already exist at ~/.secrets/acme-backup-gpg.pass (600) — the
# installer refuses to invent one, it only checks presence hint.
#
# Log: ~/.local/state/storagebox-sync/storagebox-backup-sync.log owned by the
# cron user alexey (the old /var/log redirect failed: /var/log is
# root:syslog 755, so cron could never open it and the job never ran).
#
# No secrets in git: this script copies code only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

echo "== copy sync scripts to /usr/local/sbin =="
install -m 0755 "$REPO/backups/storagebox-sync.sh" /usr/local/sbin/storagebox-backup-sync.sh
install -m 0755 "$REPO/backups/prune-storagebox.sh" /usr/local/sbin/prune-storagebox.sh
install -m 0755 "$REPO/edge/acme-backup.sh" /usr/local/sbin/acme-backup.sh

echo "== cron entry (04:30 Europe/Berlin daily) =="
install -m 0644 "$REPO/backups/storagebox-sync.cron" /etc/cron.d/storagebox-backup-sync

echo "== writable log dir for cron user alexey =="
sudo -u alexey mkdir -p /home/alexey/.local/state/storagebox-sync
sudo -u alexey touch /home/alexey/.local/state/storagebox-sync/storagebox-backup-sync.log
chown alexey:alexey /home/alexey/.local/state/storagebox-sync /home/alexey/.local/state/storagebox-sync/storagebox-backup-sync.log
chmod 755 /home/alexey/.local/state/storagebox-sync
chmod 644 /home/alexey/.local/state/storagebox-sync/storagebox-backup-sync.log

echo "== verify =="
bash -n /usr/local/sbin/storagebox-backup-sync.sh && echo SYNTAX_OK
cat /etc/cron.d/storagebox-backup-sync
echo
echo "Prereqs (not created here):"
echo "  - SSH for the cron user to contabo-a/contabo-b + sudo -n find on contabo-b outbox (no AWS creds needed since t1852u)"
echo "  - ~/.secrets/acme-backup-gpg.pass (600) for that user, escrowed offline"
echo "Manual run: sudo -u alexey /usr/local/sbin/storagebox-backup-sync.sh"
