#!/usr/bin/env python3
"""Add AISHL's shared rate limiters to the existing file-provider dev router."""

from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import sys
import tempfile


ROUTER_LINE = "    aisl-dev-https:"
REQUIRED_MIDDLEWARES = ("aishl-rate-limit", "aishl-in-flight")


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def patch_route(text: str) -> str:
    lines = text.splitlines()
    router_indices = [i for i, line in enumerate(lines) if line == ROUTER_LINE]
    if len(router_indices) != 1:
        raise ValueError("expected exactly one aisl-dev-https router")

    start = router_indices[0]
    if not any(line == "  routers:" for line in lines[:start]):
        raise ValueError("aisl-dev-https is not under http.routers")
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and _indent(line) <= 4:
            break
        end += 1

    block = lines[start + 1 : end]
    if not any("Host(`dev.aishippinglabs.com`)" in line for line in block):
        raise ValueError("aisl-dev-https does not route dev.aishippinglabs.com")
    if not any(re.match(r"^      service:\s*\S", line) for line in block):
        raise ValueError("aisl-dev-https has no existing service to preserve")

    middleware_headers = [i for i, line in enumerate(block) if line == "      middlewares:"]
    inline_headers = [i for i, line in enumerate(block) if line == "      middlewares: []"]
    if len(middleware_headers) + len(inline_headers) > 1:
        raise ValueError("aisl-dev-https has an ambiguous middleware block")

    if inline_headers:
        index = inline_headers[0]
        block[index : index + 1] = ["      middlewares:"]
        middleware_headers = [index]

    if not middleware_headers:
        service_index = next(i for i, line in enumerate(block) if re.match(r"^      service:\s*\S", line))
        block[service_index:service_index] = [
            "      middlewares:",
            *(f"        - {name}" for name in REQUIRED_MIDDLEWARES),
        ]
    else:
        header = middleware_headers[0]
        list_end = header + 1
        while list_end < len(block):
            line = block[list_end]
            if line.strip() and _indent(line) <= 6:
                break
            list_end += 1
        existing = set()
        for line in block[header + 1 : list_end]:
            stripped = line.strip()
            if stripped.startswith("- "):
                existing.add(stripped[2:].strip().strip("\"'").split("@", 1)[0])
            elif stripped:
                raise ValueError("unsupported aisl-dev-https middleware syntax")
        additions = [f"        - {name}" for name in REQUIRED_MIDDLEWARES if name not in existing]
        block[list_end:list_end] = additions

    lines[start + 1 : end] = block
    result = "\n".join(lines)
    return result + ("\n" if text.endswith("\n") else "")


def patch_file(path: Path) -> bool:
    original = path.read_text()
    updated = patch_route(original)
    if updated == original:
        return False

    metadata = path.stat()
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(updated)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <aisl-dev-route.yml>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    try:
        changed = patch_file(path)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print("patched AISHL dev router" if changed else "AISHL dev router already guarded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
