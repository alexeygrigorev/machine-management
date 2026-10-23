#!/usr/bin/env python3
"""Small HTTP readiness probe for application images without curl or wget."""
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
        if response.status != 200:
            sys.exit(1)
        response.read()
except Exception:
    sys.exit(1)
