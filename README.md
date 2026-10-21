# coolify-hosts

Public ops repo for **Contabo Coolify VPS** bootstrap, non-secret inventory, and
host-replacement contingencies.

Canonical home for scripts that used to live inside
[`DataTalksClub/dataops-knowledge`](https://github.com/DataTalksClub/dataops-knowledge).
That knowledge repo keeps **thin SOP / reference pages that link here** — it does
not carry a second copy of the heavy bootstrap script.

## Contents

| Path | Purpose |
|------|---------|
| [`scripts/bootstrap-vps-ssh.sh`](scripts/bootstrap-vps-ssh.sh) | Provider-agnostic Ubuntu 24.04 SSH bootstrap (keys, sudo user, sshd harden, fail2ban, ufw) |
| [`inventory/hosts.md`](inventory/hosts.md) | Contabo Coolify IPs, order refs, SSH aliases — **no secrets** |
| [`contingency/replace-host.md`](contingency/replace-host.md) | Dead-host / replace stubs |

## Quick start

```bash
git clone https://github.com/alexeygrigorev/coolify-hosts.git
cd coolify-hosts

export BOOTSTRAP_PUBKEYS="$HOME/.ssh/id_contabo.pub $HOME/.ssh/id_contabo_tabo.pub"
export BOOTSTRAP_IDENTITY="$HOME/.ssh/id_contabo"
# first contact only — prefer a file, never shell history:
# export BOOTSTRAP_ROOT_PASSWORD_FILE="$HOME/tmp/secrets/.vps-root-pw"
./scripts/bootstrap-vps-ssh.sh 169.58.119.163 169.58.124.141
```

Current inventory IPs (also in `inventory/hosts.md`):

- **169.58.119.163** — primary Coolify UI (`contabo-a`)
- **169.58.124.141** — second node (`contabo-b`)

## Secrets policy

- **Never** commit private keys, root passwords, or panel passwords.
- Secrets live in the private Google Drive credentials doc and on operator hosts
  under `~/tmp/secrets/` (not in git).
- This repository is public on purpose: inventory IPs and bootstrap mechanics are
  fine to share; credentials are not.

## Knowledge pointers

In `DataTalksClub/dataops-knowledge`:

- Reference: Coolify Contabo hosts (short pointer → this repo)
- SOP: Harden VPS root access to SSH keys (procedure summary → script here)

Agents and Coolify control stay on Hetzner (RMTHZ); these Contabo VPS run Coolify
workloads / UI.
