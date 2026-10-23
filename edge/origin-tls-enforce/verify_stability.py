#!/usr/bin/env python3
"""Sample active public/origin traffic without retries or configuration writes.

Evidence contains target labels, timestamps and status codes only. Credentials
remain in memory and curl stdin. A transient failure fails the whole window.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

from origin_transport import ORIGINS, Refused, aws, config_origin, probe


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def targets():
    # Website-dev has a separate isolation prerequisite; verify_origin checks
    # its exact deferred state. Never misreport its deliberate 503 as healthy.
    result = []
    for scope in (ORIGINS[0], ORIGINS[2], ORIGINS[3]):
        _, _, header = config_origin(
            aws("cloudfront", "get-distribution", "--id", scope.distribution), scope)
        name = scope.origin_id.removesuffix("-alb")
        result.extend([
            (name + "-public-health", scope, True, None, scope.path, "200"),
            (name + "-authenticated-origin", scope, False, header, scope.path, "200"),
            (name + "-missing-header", scope, False, None, scope.path, "403"),
            (name + "-wrong-header", scope, False, "invalid-origin-verification-value", scope.path, "403"),
        ])
        if scope == ORIGINS[0]:
            result.append((name + "-public-home", scope, True, None, "/", "200"))
    return result


def measure(checks, rounds, interval, evidence):
    evidence["started_at"] = timestamp()
    evidence["rounds"] = rounds
    evidence["minimum_round_interval_seconds"] = interval
    evidence["samples"] = []
    for number in range(rounds):
        start = time.monotonic()
        for label, scope, public, header, path, expected in checks:
            row = {"round": number + 1, "target": label, "at": timestamp(),
                   "expected": expected}
            began = time.monotonic()
            try:
                # Cache busting prevents cached public health from hiding a
                # backend failure. Each Relay public target is sampled at most
                # once per five seconds to respect its existing rate limit.
                separator = "&" if "?" in path else "?"
                row["status"] = probe(
                    scope, scope.viewer if public else scope.domain,
                    header=header, public=public,
                    path=path + separator + "origin_stability=" + uuid.uuid4().hex)
            except (Refused, subprocess.TimeoutExpired):
                # Never serialize exception text or HTTP response bodies.
                row["status"] = "connection-or-tls-error"
            row["elapsed_ms"] = round((time.monotonic() - began) * 1000)
            row["passed"] = row["status"] == expected
            evidence["samples"].append(row)
        failures = sum(not row["passed"] for row in evidence["samples"])
        print(f"Round {number + 1}/{rounds}: {len(evidence['samples'])} samples, {failures} failures", flush=True)
        if number + 1 < rounds:
            time.sleep(max(0, interval - (time.monotonic() - start)))
    evidence["finished_at"] = timestamp()
    evidence["summary"] = {
        label: dict(Counter(row["status"] for row in evidence["samples"] if row["target"] == label))
        for label, *_ in checks
    }
    evidence["accepted"] = bool(evidence["samples"]) and all(row["passed"] for row in evidence["samples"])
    return evidence["accepted"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, default=60)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--output", type=Path, required=True, help="New sanitized JSON evidence file")
    args = parser.parse_args()
    if args.rounds < 1 or args.interval < 5:
        parser.error("require at least one round and an interval of at least five seconds")
    # Reserve exclusively before network activity so existing evidence is safe.
    with args.output.open("x") as stream:
        evidence = {"accepted": False}
        try:
            accepted = measure(targets(), args.rounds, args.interval, evidence)
        finally:
            # Preserve completed samples on interruption; accepted stays false.
            json.dump(evidence, stream, indent=2)
            stream.write("\n")
    return 0 if accepted else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Refused, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: stability verification unavailable ({type(exc).__name__})", file=sys.stderr)
        sys.exit(1)
