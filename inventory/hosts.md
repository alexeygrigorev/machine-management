# Coolify Contabo hosts (non-secret inventory)

Canonical public inventory for Contabo Cloud VPS used with Coolify.
**No passwords or private keys** — those stay in the private Google Drive
credentials doc and on operator machines under `~/tmp/secrets/` (not in git).

| Host | Instance | IPv4 | IPv6 | Role | SSH alias |
|------|----------|------|------|------|-----------|
| vmd210004 | 100210004 | **169.58.119.163** | 2a02:c207:3021:0004:0000:0000:0000:0001/64 | Primary Coolify UI | `contabo-a` |
| vmd210005 | 100210005 | **169.58.124.141** | 2a02:c207:3021:0005:0000:0000:0000:0001/64 | Second node (prefer as remote under primary) | `contabo-b` |

## Spec (both)

- Cloud VPS 16 NVMe — 16 vCPU / 64 GB RAM / 250 GB NVMe
- Region: EU
- OS target: Ubuntu 24.04
- Login user after bootstrap: `alexey` (passwordless sudo); root keys only

## Contabo account (no passwords)

| Field | Value |
|-------|-------|
| Panel | https://my.contabo.com |
| Login email | alexey@datatalks.club |
| Customer ID | 300638 |
| Order refs | 300639, 300640 |
| VAT (business) | DE343190995 |

**Ready:** 2026-10-22  
**Cost:** €70.44/mo incl. 19% DE VAT (2× Cloud VPS 16, 24-month term)

## Coolify URLs

- Primary UI: http://169.58.119.163:8000
- Second node: http://169.58.124.141:8000 (long-term: add as **remote server** under primary)

## Operator SSH model

- Same public keys on every host; two operator keypairs:
  - Hetzner / agents: `~/.ssh/id_contabo`
  - Tabo laptop: `~/.ssh/id_contabo_tabo`
- Example `~/.ssh/config` HostName values → the IPv4s above.
- Secrets (panel password, historical root password, private key material):
  private Drive doc *Contabo Coolify VPS — credentials 2026-10-22*
  (My Drive → Documents private).

## Related

- Bootstrap: [`scripts/bootstrap-vps-ssh.sh`](../scripts/bootstrap-vps-ssh.sh)
- Daily DB backups: [`backups/`](../backups/) — `pg_dump` → S3, `30 2 * * *` Europe/Berlin (pg-shared + pg-relay, separate)
- Contingency: [`contingency/replace-host.md`](../contingency/replace-host.md)
- Thin SOP pointers (DataTalksClub knowledge only — no script copies):
  `DataTalksClub/dataops-knowledge` → Coolify Contabo hosts reference + Harden VPS SSH SOP
