# machine-management

Public ops for VPS / Coolify host bootstrap and non-secret inventory.

Canonical home for the provider-agnostic SSH bootstrap that matches the Hetzner
gist pattern ([`02-ssh.md`](https://gist.github.com/alexeygrigorev/5c1135fdfce97d3938a24c0f3dcc0ab2)):
user **alexey** + **NOPASSWD** sudo, ed25519 operator keys, `PermitRootLogin
prohibit-password`, `MaxStartups 10:30:100`, fail2ban, ufw.

[`DataTalksClub/dataops-knowledge`](https://github.com/DataTalksClub/dataops-knowledge)
keeps **thin SOP / reference pages that link here** — no duplicate heavy scripts.

## Contents

| Path | Purpose |
|------|---------|
| [`deployments/aisl-qcluster.md`](deployments/aisl-qcluster.md) | AISHL Coolify worker deployment, heartbeat verification, and key decision |
| [`deployments/aisl-auto-deploy.md`](deployments/aisl-auto-deploy.md) | AISHL pinned-image poller, idempotent web/worker rollout, and five-minute recreate fix |
| [`deployments/relay-aux-ownership.md`](deployments/relay-aux-ownership.md) | Relay inbound disabled policy, scheduler pruning owner, and safe verification |
| [`scripts/bootstrap-vps-ssh.sh`](scripts/bootstrap-vps-ssh.sh) | Ubuntu 24.04 SSH bootstrap (keys, sudo user, sshd harden, fail2ban, ufw) |
| [`backups/`](backups/) | Daily Coolify `pg_dump` → S3 job (pg-shared + pg-relay), cron, installer, S3 lifecycle example |
| [`monitors/`](monitors/) | **Permanent continuous** healthcheck (pg-shared + pg-relay + HTTP apps, every 5 min, alerts dev@), cron, installer |
| [`inventory/hosts.md`](inventory/hosts.md) | Contabo Coolify IPs, order refs, SSH aliases — **no secrets** |
| [`contingency/replace-host.md`](contingency/replace-host.md) | Dead-host / replace stubs |
| [`contingency/dr-status-t1143u.md`](contingency/dr-status-t1143u.md) | Fresh DR audit closure evidence and started implementation children |

## Quick start

```bash
git clone https://github.com/alexeygrigorev/machine-management.git
cd machine-management

export BOOTSTRAP_PUBKEYS="$HOME/.ssh/id_contabo.pub $HOME/.ssh/id_contabo_tabo.pub"
export BOOTSTRAP_IDENTITY="$HOME/.ssh/id_contabo"
# first contact only — prefer a file, never shell history:
# export BOOTSTRAP_ROOT_PASSWORD_FILE="$HOME/.secrets/.vps-root-pw"
./scripts/bootstrap-vps-ssh.sh 169.58.119.163 169.58.124.141
```

Current Contabo Coolify inventory (also in `inventory/hosts.md`):

- **169.58.119.163** — primary Coolify UI (`contabo-a`)
- **169.58.124.141** — second node (`contabo-b`)

## What the bootstrap does (gist-aligned)

On each target host, idempotently:

1. Installs operator **ed25519** public keys for `root` and login user
2. Creates user **`alexey`** with **`NOPASSWD` sudo**
3. Hardens sshd: `PermitRootLogin prohibit-password`, `PasswordAuthentication no`,
   `MaxStartups 10:30:100`
4. Installs **fail2ban** (`banaction = ufw`) for sshd
5. Enables **ufw** (22; optionally 80/443/8000 for Coolify via `BOOTSTRAP_OPEN_HTTP=1`)

Does **not** call any cloud provider API — needs only IP (or SSH alias) + root access.

## Secrets policy

- **Never** commit private keys, root passwords, or panel passwords.
- Secrets live in the private Google Drive credentials doc and on operator hosts
  under `~/.secrets/` (not in git; `~/tmp/secrets` is a compat symlink).
  `~/.secrets` is `700`, secret files `600` (public keys `644`).
  Tabo laptop: mirror the same `~/.secrets/` layout there.

## Knowledge pointers

In `DataTalksClub/dataops-knowledge`:

- Reference: Coolify Contabo hosts (short pointer → this repo)
- SOP: Harden VPS root access to SSH keys (procedure summary → script here)
- SOP: Coolify Contabo contingency and database backups (schedule + S3 layout → [`backups/`](backups/) here)

Upstream pattern: gist `alexeygrigorev/5c1135fdfce97d3938a24c0f3dcc0ab2`
(`01-hetzner.md`, `02-ssh.md`).

## Observability

Live stack: VictoriaMetrics + VictoriaLogs + Vector — [`alexeygrigorev/coolify-observability`](https://github.com/alexeygrigorev/coolify-observability).  
Thin pointer + retention/S3 notes: [`observability/README.md`](observability/README.md). Healthchecks: [`monitors/`](monitors/).
