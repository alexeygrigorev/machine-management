#!/usr/bin/env python3
"""Internal readiness endpoint with a local-only drain actuator."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import sys
import threading
import time
import urllib.request

MARKER = Path('/tmp/coolify-web-draining')
PROBE = None


class ReadinessServer(ThreadingHTTPServer):
    # Multiple domain-specific Traefik services probe this same listener on
    # the same tick. The stdlib backlog of five drops their synchronized burst.
    request_queue_size = 128


class Readiness:
    def __init__(self, url):
        self.url = url
        self.ready = False
        self.failures = 0

    def check_once(self):
        success = False
        try:
            with urllib.request.urlopen(self.url, timeout=2) as response:
                success = response.status == 200
                response.read()
        except Exception:
            pass
        if success:
            self.failures = 0
            self.ready = True
        else:
            self.failures += 1
            if self.failures >= 3:
                self.ready = False

    def run(self):
        while True:
            self.check_once()
            time.sleep(1)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status = 503
        if self.path == '/ready' and not MARKER.exists() and PROBE is not None and PROBE.ready:
            status = 200
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    if sys.argv[1] == 'drain':
        MARKER.touch()
    elif sys.argv[1] == 'serve':
        PROBE = Readiness(os.environ['ROLLING_APP_URL'])
        threading.Thread(target=PROBE.run, daemon=True).start()
        ReadinessServer(('0.0.0.0', 8099), Handler).serve_forever()
    else:
        sys.exit(2)
