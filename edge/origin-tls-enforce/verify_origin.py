#!/usr/bin/env python3
"""Read-only live acceptance checks. Prints no credentials or response bodies."""
import subprocess
import sys

from origin_transport import ORIGINS, Refused, aws, config_origin, probe, readiness


def ssh(host, command):
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode:
        raise Refused(f"{host} remote verification failed")
    return result.stdout.strip()


def verify():
    guard = ssh("contabo-a", "sudo test ! -f /data/coolify/proxy/dynamic/dev-route-guard.yml || printf present") == "present"
    for scope in ORIGINS:
        snapshot = aws("cloudfront", "get-distribution", "--id", scope.distribution)
        _, origin, header = config_origin(snapshot, scope)
        protocol = origin["CustomOriginConfig"]["OriginProtocolPolicy"]
        deferred = scope.viewer == "dev.datatalks.club" and guard
        expected = "http-only" if deferred else "https-only"
        if protocol != expected:
            raise Refused(f"{scope.distribution} expected {expected}, observed {protocol}")
        if deferred:
            # Still check the shared origin using this distribution's credential.
            # The guard's existence alone never licenses an arbitrary dev failure.
            for scheme in ("http", "https"):
                for value in (None, "invalid-origin-verification-value", header):
                    if probe(scope, scope.viewer, scheme, value) != "503":
                        raise Refused("website-dev no longer matches the recorded isolation state")
                for value in (None, "invalid-origin-verification-value"):
                    if probe(scope, scope.domain, scheme, value) != "403":
                        raise Refused("shared website origin bypass is open")
                if probe(scope, scope.domain, scheme, header) != "200":
                    raise Refused("shared website origin authentication failed")
            if probe(scope, scope.viewer, public=True) != "503":
                raise Refused("website-dev public isolation state changed")
            print("DEFER: website-dev cutover; trusted TLS but isolation guard returns 503; transport remains HTTP")
        else:
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
    print("Verified live TLS, authentication, public traffic and firewall."
          + (" Website-dev cutover remains deferred." if guard else " All four origins use HTTPS."))


if __name__ == "__main__":
    try:
        verify()
    except Refused as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    except (KeyError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: verification unavailable ({type(exc).__name__})", file=sys.stderr)
        sys.exit(1)
