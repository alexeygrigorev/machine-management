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
        self.saturated = False

    def check_once(self):
        success = False
        try:
            with urllib.request.urlopen(self.url, timeout=2) as response:
                success = response.status == 200
                response.read()
        except Exception:
            pass
        self.saturated = not success
        if success:
            self.failures = 0
            # Readiness is a startup gate. Once the app has answered once,
            # transient slowness is reported separately and does not eject
            # the only serving replica.
            self.ready = True
        else:
            self.failures += 1

    def run(self):
        while True:
            self.check_once()
            time.sleep(2)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/ready':
            status = 200 if not MARKER.exists() and PROBE is not None and PROBE.ready else 503
            body = b''
        elif self.path == '/saturated':
            status = 200
            body = b'true' if PROBE is not None and PROBE.saturated else b'false'
        else:
            status = 404
            body = b''
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

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
