#!/usr/bin/env python3
"""Internal readiness endpoint with a local-only drain actuator."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import sys
import urllib.request

MARKER = Path('/tmp/coolify-web-draining')

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status = 503
        if self.path == '/ready' and not MARKER.exists():
            try:
                with urllib.request.urlopen(os.environ['ROLLING_APP_URL'], timeout=1) as response:
                    if response.status == 200:
                        response.read()
                        status = 200
            except Exception:
                pass
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    if sys.argv[1] == 'drain':
        MARKER.touch()
    elif sys.argv[1] == 'serve':
        ThreadingHTTPServer(('0.0.0.0', 8099), Handler).serve_forever()
    else:
        sys.exit(2)
