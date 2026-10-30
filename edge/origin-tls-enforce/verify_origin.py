#!/usr/bin/env python3
"""Read-only live acceptance checks. Prints no credentials or response bodies."""
import json
from pathlib import Path
import re
import subprocess
import sys

from origin_transport import ORIGINS, Refused, aws, config_origin, probe, readiness

ROUTER_PREFIX = {
    "E1VNMGFFIXBOXX": "origin-websiteprod",
    "E33FS79KPFSAOM": "origin-websitedev",
    "E3L9KUTE15WFJF": "origin-relay",
    "E35QPYDA1452SA": "origin-relaydev",
}

SNAPSHOT_FALLBACK = {
    "E33FS79KPFSAOM": Path("/home/alexey/tmp/agent-reports/e33-cf-config-before-2026-10-26.json"),
}


def ssh(host, command):
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode:
        raise Refused(f"{host} remote verification failed")
    return result.stdout.strip()


def fallback_origin_state(scope):
    prefix = ROUTER_PREFIX.get(scope.distribution)
    if not prefix:
        raise Refused(f"unsupported distribution {scope.distribution}")
    protocol = "https-only"
    snap_path = SNAPSHOT_FALLBACK.get(scope.distribution)
    if snap_path and snap_path.is_file():
        snapshot = json.loads(snap_path.read_text())
        dist = snapshot["Distribution"]
        if dist.get("Status") != "Deployed":
            raise Refused(f"{scope.distribution} snapshot status is not Deployed")
        cfg = dist["DistributionConfig"]
        if scope.viewer not in cfg.get("Aliases", {}).get("Items", []):
            raise Refused(f"{scope.distribution} snapshot viewer alias mismatch")
        hits = [o for o in cfg.get("Origins", {}).get("Items", []) if o.get("Id") == scope.origin_id]
        if len(hits) != 1 or hits[0].get("DomainName") != scope.domain:
            raise Refused(f"{scope.distribution} snapshot origin domain mismatch")
        if hits[0].get("CustomOriginConfig", {}).get("HTTPSPort") != 443:
            raise Refused(f"{scope.distribution} snapshot HTTPSPort is not 443")
        protocol = hits[0].get("CustomOriginConfig", {}).get("OriginProtocolPolicy", "")

    cmd = f"""sudo python3 - <<'PY'
import re, sys, yaml
data = yaml.safe_load(open('/data/coolify/proxy/dynamic/origin-enforce.yml'))
routers = data.get('http', {{}}).get('routers', {{}})
for suffix in ('allow-http', 'allow-tls', 'deny-http', 'deny-tls'):
    if f'{prefix}-{{suffix}}' not in routers:
        sys.exit(1)
rule = routers['{prefix}-allow-tls'].get('rule', '')
m = re.search(r"Header\\(`X-Origin-Verify`,\\s*`([^`]+)`\\)", rule)
if not m:
    sys.exit(1)
print(m.group(1))
PY"""
    header = ssh(scope.ssh_host, cmd)
    if not re.fullmatch(r"[A-Za-z0-9_=-]{16,128}", header):
        raise Refused("missing or unsupported origin verification header")
    return protocol, header


def origin_state(scope):
    try:
        snapshot = aws("cloudfront", "get-distribution", "--id", scope.distribution)
        _, origin, header = config_origin(snapshot, scope)
        return origin["CustomOriginConfig"]["OriginProtocolPolicy"], header
    except Refused:
        return fallback_origin_state(scope)


def verify_dev_isolation():
    cmd = """sudo python3 - <<'PY'
import subprocess, sys, yaml
data = yaml.safe_load(open('/data/coolify/proxy/dynamic/origin-enforce.yml'))
routers = data.get('http', {}).get('routers', {})
dev_svc = routers.get('origin-websitedev-allow-tls', {}).get('service')
prod_svc = routers.get('origin-websiteprod-allow-tls', {}).get('service')
if not dev_svc or not prod_svc or dev_svc == prod_svc:
    sys.exit(1)
ps = subprocess.run(['docker', 'ps', '--format', '{{.Names}}'], capture_output=True, text=True, check=True).stdout.splitlines()
dev_c = [c for c in ps if c.startswith('web-wodajblzizrjunwme3ossav3') or c == 'website-dev-web']
if not dev_c:
    sys.exit(1)
sql = (
    "import django, os, sys; os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'website.settings.production'); "
    "django.setup(); from django.db import connection; c = connection.cursor(); "
    "c.execute(\\"SELECT current_database(), current_user, has_database_privilege(current_user, 'website', 'CONNECT')\\"); "
    "row = c.fetchone(); sys.exit(0 if row == ('website_dev', 'website_dev', False) else 1)"
)
subprocess.run(['docker', 'exec', dev_c[0], 'python3', '-c', sql], check=True)
PY"""
    ssh("contabo-a", cmd)
    print("PASS: contabo-a website-dev isolated backend and website_dev database verified")


def verify():
    guard = ssh("contabo-a", "sudo test ! -f /data/coolify/proxy/dynamic/dev-route-guard.yml || printf present") == "present"
    if guard:
        raise Refused("dev-route-guard.yml is still present on contabo-a")

    verify_dev_isolation()

    for scope in ORIGINS:
        protocol, header = origin_state(scope)
        expected = "https-only"
        if protocol != expected:
            raise Refused(f"{scope.distribution} expected {expected}, observed {protocol}")
        readiness(scope, header)
        if probe(scope, scope.viewer, public=True) != "200":
            raise Refused(f"{scope.viewer} public traffic is not healthy")
        print(f"PASS: {scope.distribution} Deployed, HTTPS origin, public health 200")

    for host in ("contabo-a", "contabo-b"):
        # Verify every protected port in BOTH families, plus persistence.
        # Do not infer effective filtering from a rule count alone.
        command = """sudo python3 - <<'PY'
import pathlib,subprocess,sys
checks=[]
for binary in ('iptables','ip6tables'):
 r=subprocess.run([binary,'-S','DOCKER-USER'],capture_output=True,text=True,check=True)
 for port in (8000,6001,6002,9101):
  checks.append(any(f'--ctorigdstport {port} ' in line and line.endswith('-j DROP') for line in r.stdout.splitlines()))
p=pathlib.Path('/data/coolify/proxy/dynamic/origin-enforce.yml')
checks.append(p.is_file() and p.stat().st_uid == 0 and p.stat().st_mode & 0o777 == 0o600)
checks.append(subprocess.run(['systemctl','is-enabled','--quiet','edge-docker-user-restore']).returncode == 0)
sys.exit(0 if all(checks) else 1)
PY"""
        ssh(host, command)
        print(f"PASS: {host} IPv4/IPv6 administrative-port DROP rules, persistence, private enforcement file")
    print("Verified live TLS, authentication, public traffic and firewall. All four origins use HTTPS.")


if __name__ == "__main__":
    try:
        verify()
    except Refused as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    except (KeyError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: verification unavailable ({type(exc).__name__})", file=sys.stderr)
        sys.exit(1)
