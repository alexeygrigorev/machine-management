# Contingency: replace a dead Contabo / Coolify host

Stub runbook. Keep secrets out of this repo.

1. Order a new Ubuntu 24.04 VPS in Contabo; note the **new IPv4** and one-time
   root password (Drive / `~/.secrets` only — never commit).
2. From an operator box (e.g. Hetzner RMTHZ) run:

   ```bash
   export BOOTSTRAP_PUBKEYS="$HOME/.ssh/id_contabo.pub $HOME/.ssh/id_contabo_tabo.pub"
   export BOOTSTRAP_IDENTITY="$HOME/.ssh/id_contabo"
   export BOOTSTRAP_ROOT_PASSWORD_FILE="$HOME/.secrets/.vps-root-pw"
   ./scripts/bootstrap-vps-ssh.sh <NEW_IP>
   ```

3. Update [`inventory/hosts.md`](../inventory/hosts.md) and local `~/.ssh/config`
   `HostName` for `contabo-a` / `contabo-b` (or add a new alias).
4. Point Coolify at the new host (Servers → validate remote from the primary UI
   on `.163`, or reinstall UI if the primary died).
5. Remove the dead IP from inventory; update the Drive credentials doc note so
   password root is not the access path.

## Contingency stubs (fill when exercised)

| Scenario | Status | Notes |
|----------|--------|-------|
| Primary UI (`.163`) unreachable | stub | Promote `.141` or rebuild UI; update DNS/bookmarks |
| Second node (`.141`) unreachable | stub | Drop remote server; re-add after bootstrap |
| Both Contabo VPS lost | stub | Re-order 2× Cloud VPS 16; bootstrap both; restore Coolify from backups if any |
| SSH lockout (keys wrong) | stub | Contabo rescue / reinstall + bootstrap with known pubs |
| Coolify data corruption | stub | Document restore source when one exists |
