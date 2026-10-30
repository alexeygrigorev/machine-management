#!/usr/bin/env python3
"""Scoped CloudFront transport changes and certificate-validating probes.

Credentials stay in memory/stdin; never print AWS responses or HTTP bodies.
"""
import argparse
import copy
from dataclasses import dataclass
import json
import os
import re
import subprocess
import sys
import time


@dataclass(frozen=True)
class Origin:
    distribution: str
    origin_id: str
    domain: str
    viewer: str
    ip: str
    path: str
    ssh_host: str


ORIGINS = (
    Origin("E1VNMGFFIXBOXX", "website-production-alb", "origin.website.datatalks.club",
           "prod.datatalks.club", "169.58.119.163", "/health/ready", "contabo-a"),
    Origin("E33FS79KPFSAOM", "website-dev-alb", "origin.website.datatalks.club",
           "dev.datatalks.club", "169.58.119.163", "/health/ready", "contabo-a"),
    Origin("E3L9KUTE15WFJF", "relay-production-shared-alb", "origin.relay.datatalks.club",
           "relay.datatalks.club", "169.58.124.141", "/health/", "contabo-b"),
    Origin("E35QPYDA1452SA", "relay-dev-shared-alb", "origin.dev.relay.datatalks.club",
           "dev.relay.datatalks.club", "169.58.124.141", "/health/", "contabo-b"),
)


class Refused(RuntimeError):
    pass


def aws(*args):
    result = subprocess.run(
        ["aws", "--profile", os.environ.get("AWS_PROFILE", "default"),
         "--region", "eu-west-1", *args, "--output", "json"],
        capture_output=True, text=True, timeout=90,
    )
    if result.returncode:
        raise Refused("AWS request failed; check the operator credential profile")
    return json.loads(result.stdout)


def config_origin(snapshot, scope):
    distribution = snapshot["Distribution"]
    if distribution["Status"] != "Deployed":
        raise Refused("distribution is still deploying")
    config = distribution["DistributionConfig"]
    hits = [o for o in config["Origins"]["Items"] if o["Id"] == scope.origin_id]
    if len(hits) != 1 or hits[0]["DomainName"] != scope.domain:
        raise Refused("origin identity/domain does not match the approved scope")
    if scope.viewer not in config.get("Aliases", {}).get("Items", []):
        raise Refused("expected viewer alias is missing")
    origin = hits[0]
    if origin.get("CustomOriginConfig", {}).get("HTTPSPort") != 443:
        raise Refused("expected custom HTTPS origin port 443")
    headers = [h["HeaderValue"] for h in origin.get("CustomHeaders", {}).get("Items", [])
               if h["HeaderName"].lower() == "x-origin-verify"]
    if len(headers) != 1 or not re.fullmatch(r"[A-Za-z0-9_=-]{16,128}", headers[0]):
        raise Refused("missing or unsupported origin verification header")
    return config, origin, headers[0]


def probe(scope, hostname, scheme="https", header=None, public=False, path=None):
    # Validate trust, expiry and SAN; use hostname for both SNI and Host.
    # Pin viewer names to the origin, rather than accidentally probing the CDN.
    # Sensitive headers go through stdin, never process arguments.
    args = ["curl", "--disable", "--silent", "--noproxy", "*", "--max-time", "12",
            "--output", "/dev/null", "--write-out", "%{http_code}", "--config", "-"]
    if not public:
        port = 443 if scheme == "https" else 80
        args += ["--resolve", f"{hostname}:{port}:{scope.ip}"]
    args += [f"{scheme}://{hostname}{path if path is not None else scope.path}"]
    config = ""
    if header is not None:
        if not re.fullmatch(r"[A-Za-z0-9_=-]{16,128}", header):
            raise Refused("unsupported verification header")
        config = f'header = "X-Origin-Verify: {header}"\n'
    result = subprocess.run(args, input=config, capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise Refused(f"{hostname} {scheme} connection/certificate validation failed (curl {result.returncode})")
    return result.stdout


def readiness(scope, header):
    for hostname in (scope.domain, scope.viewer):
        # Both origin-domain and forwarded viewer Host/SNI must work.
        for scheme in ("http", "https"):
            for value in (None, "invalid-origin-verification-value"):
                if probe(scope, hostname, scheme, value) != "403":
                    raise Refused(f"{hostname} {scheme} missing/wrong header was not denied")
            if probe(scope, hostname, scheme, header) != "200":
                raise Refused(f"{hostname} {scheme} authenticated readiness is not 200")
        print(f"PASS: {hostname} trusted TLS, authenticated health, missing/wrong header denied")


def patch_config(config, origin_id, want):
    patched = copy.deepcopy(config)
    hits = [o for o in patched["Origins"]["Items"] if o["Id"] == origin_id]
    if len(hits) != 1:
        raise Refused("origin is not unique")
    hits[0]["CustomOriginConfig"]["OriginProtocolPolicy"] = want
    return patched


def flip(scope, want):
    # One snapshot binds configuration and ETag; no eval or temporary secrets.
    snapshot = aws("cloudfront", "get-distribution", "--id", scope.distribution)
    config, origin, header = config_origin(snapshot, scope)
    current = origin["CustomOriginConfig"]["OriginProtocolPolicy"]
    print(f"{scope.distribution} {scope.origin_id}: {current} -> {want}")
    if current == want:
        print("Already configured; no change")
        return
    if want == "https-only":
        readiness(scope, header)
        if probe(scope, scope.viewer, public=True) != "200":
            raise Refused("public viewer baseline is not healthy")
    print("Before applying, verify the documented rollback against current backends.")
    print(f"ROLLBACK: cf-origin-flip.sh {scope.distribution} {scope.origin_id} {current}")
    if input("Apply this single origin transport change? [type YES] ") != "YES":
        raise Refused("aborted")
    latest = aws("cloudfront", "get-distribution", "--id", scope.distribution)
    if latest["ETag"] != snapshot["ETag"]:
        raise Refused("distribution changed while readiness was being checked")
    patched = patch_config(config, scope.origin_id, want)
    # /dev/stdin keeps the secret-bearing configuration out of files and argv.
    result = subprocess.run(
        ["aws", "--profile", os.environ.get("AWS_PROFILE", "default"),
         "--region", "eu-west-1", "cloudfront", "update-distribution",
         "--id", scope.distribution, "--if-match", snapshot["ETag"],
         "--distribution-config", "file:///dev/stdin", "--output", "json"],
        input=json.dumps(patched), capture_output=True, text=True, timeout=90,
    )
    if result.returncode:
        raise Refused("update failed or outcome uncertain; read distribution state before retrying")
    for _ in range(30):
        state = aws("cloudfront", "get-distribution", "--id", scope.distribution)
        if state["Distribution"]["Status"] == "Deployed":
            _, deployed, _ = config_origin(state, scope)
            if deployed["CustomOriginConfig"]["OriginProtocolPolicy"] != want:
                raise Refused("deployed transport differs from requested transport")
            if probe(scope, scope.viewer, public=True) != "200":
                raise Refused("public health failed after deployment; use the printed rollback")
            print("Deployed; public health 200")
            return
        print("Deploying", flush=True)
        time.sleep(30)
    raise Refused("still deploying; verify state before any further changes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("distribution")
    parser.add_argument("origin_id")
    parser.add_argument("protocol", choices=("https-only", "http-only"))
    args = parser.parse_args()
    scope = next((o for o in ORIGINS if (o.distribution, o.origin_id) ==
                  (args.distribution, args.origin_id)), None)
    if scope is None:
        raise Refused("distribution/origin pair is outside the approved scope")
    flip(scope, args.protocol)


if __name__ == "__main__":
    try:
        main()
    except Refused as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        sys.exit(1)
    except (KeyError, ValueError, EOFError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"REFUSED: operation failed ({type(exc).__name__}); inspect live state", file=sys.stderr)
        sys.exit(1)
