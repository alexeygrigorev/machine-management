#!/usr/bin/env python3
"""Small HTTP readiness probe for application images without curl or wget."""
import os
import sys
import urllib.request

try:
    # Docker liveness checks should reach the application itself. The
    # Traefik-facing /ready endpoint intentionally stays open after startup.
    url = sys.argv[1] if len(sys.argv) > 1 else os.environ['ROLLING_APP_URL']
    with urllib.request.urlopen(url, timeout=2) as response:
        if response.status != 200:
            sys.exit(1)
        response.read()
except Exception:
    sys.exit(1)
