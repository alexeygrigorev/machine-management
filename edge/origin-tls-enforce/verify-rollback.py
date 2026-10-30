#!/usr/bin/env python3
"""Exercise file-provider rollback on a private, unique path on each node.

The test route requires the real origin credential. Existing public paths and
unauthenticated deny routers remain untouched. Always remove the test file.
"""
import json
import shlex
import subprocess
import sys
import time
import uuid

from origin_transport import ORIGINS, Refused, probe
from verify_origin import origin_state, ssh


def fingerprint(host):
    return ssh(host, "sudo sha256sum /data/coolify/proxy/dynamic/origin-enforce.yml && "
               "sudo iptables -S DOCKER-USER && sudo ip6tables -S DOCKER-USER")


def verify(scope):
    _, header = origin_state(scope)
    marker = uuid.uuid4().hex
    path = scope.path + "?origin_rollback_probe=" + marker
    target = "/data/coolify/proxy/dynamic/origin-rollback-" + uuid.uuid4().hex + ".yml"
    before = fingerprint(scope.ssh_host)
    baseline = {s: probe(scope, scope.domain, s, header, path=path) for s in ("http", "https")}
    if any(code != "200" for code in baseline.values()):
        raise Refused("rollback test baseline is not a healthy application response")
    rule = (f"Host(`{scope.domain}`) && Path(`{scope.path}`) && "
            f"Query(`origin_rollback_probe`, `{marker}`) && Header(`X-Origin-Verify`, `{header}`)")
    routers = {}
    for scheme in ("http", "https"):
        router = {"rule": rule, "service": "noop@file", "priority": 300,
                  "entryPoints": [scheme]}
        if scheme == "https":
            router["tls"] = {}
        routers["rollback-" + marker + "-" + scheme] = router
    program = """import os,pathlib,sys,tempfile
target=pathlib.Path(sys.argv[1])
with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.rollback-', suffix='.tmp', mode='w', delete=False) as f:
    f.write(sys.stdin.read())
    temporary=f.name
os.replace(temporary,target)
"""
    command = "sudo python3 -c " + shlex.quote(program) + " " + shlex.quote(target)
    try:
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", scope.ssh_host, command],
            input=json.dumps({"http": {"routers": routers}}), capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise Refused("temporary rollback route installation failed")
        time.sleep(4)
        for scheme in ("http", "https"):
            if probe(scope, scope.domain, scheme, header, path=path) != "503":
                raise Refused("temporary rollback route was not observed")
            if probe(scope, scope.domain, scheme, path=path) != "403":
                raise Refused("unauthenticated denial failed during rollback exercise")
    finally:
        ssh(scope.ssh_host, "sudo rm -f -- " + shlex.quote(target))
        time.sleep(4)
    for scheme, expected in baseline.items():
        if probe(scope, scope.domain, scheme, header, path=path) != expected:
            raise Refused("original route was not restored after rollback")
        if probe(scope, scope.domain, scheme, path=path) != "403":
            raise Refused("unauthenticated denial failed after rollback")
    if before != fingerprint(scope.ssh_host):
        raise Refused("enforcement file or administrative firewall changed during the exercise")
    if probe(scope, scope.viewer, public=True) != "200":
        raise Refused("public health failed after rollback exercise")
    print(f"PASS: {scope.ssh_host} HTTP/HTTPS file-provider rollback observed; enforcement and firewall identical; public health 200")


if __name__ == "__main__":
    try:
        for scope in (ORIGINS[0], ORIGINS[2]):
            verify(scope)
    except Refused as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    except (KeyError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: rollback verification unavailable ({type(exc).__name__})", file=sys.stderr)
        sys.exit(1)
