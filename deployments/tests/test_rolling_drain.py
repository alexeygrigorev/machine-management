import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import socket
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


readiness = module('readiness', 'rolling-readiness.py')
drain = module('drain', 'coolify-web-drain.py')


class Application(BaseHTTPRequestHandler):
    status = 200

    def do_GET(self):
        self.send_response(self.status)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *args):
        pass


class DrainTests(unittest.TestCase):
    def test_synchronized_proxy_health_burst_fits_listen_queue(self):
        # Seven AISHL load-balancer checks plus Docker health can arrive
        # together while the accept loop is momentarily descheduled.
        server = readiness.ReadinessServer(('127.0.0.1', 0), readiness.Handler)
        connections = []
        try:
            for _ in range(12):
                connections.append(socket.create_connection(server.server_address, timeout=.2))
        finally:
            for connection in connections:
                connection.close()
            server.server_close()

    def test_readiness_requires_app_and_draining_keeps_app_serving(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'drain'
            app = ThreadingHTTPServer(('127.0.0.1', 0), Application)
            ready = readiness.ReadinessServer(('127.0.0.1', 0), readiness.Handler)
            for server in [app, ready]:
                threading.Thread(target=server.serve_forever, daemon=True).start()
            app_url = 'http://127.0.0.1:' + str(app.server_port) + '/ping'
            ready_url = 'http://127.0.0.1:' + str(ready.server_port) + '/ready'
            def status(url):
                try:
                    with urllib.request.urlopen(url, timeout=2) as response:
                        return response.status
                except urllib.error.HTTPError as error:
                    return error.code
            try:
                probe = readiness.Readiness(app_url)
                with patch.object(readiness, 'MARKER', marker), patch.object(readiness, 'PROBE', probe):
                    Application.status = 503
                    probe.check_once()
                    self.assertEqual(status(ready_url), 503)
                    Application.status = 200
                    probe.check_once()
                    self.assertEqual(status(ready_url), 200)
                    marker.touch()
                    self.assertEqual(status(ready_url), 503)
                    self.assertEqual(status(app_url), 200)
                    marker.unlink()
                    Application.status = 503
                    probe.check_once()
                    self.assertEqual(status(ready_url), 200)
                    probe.check_once()
                    probe.check_once()
                    self.assertEqual(status(ready_url), 503)
            finally:
                Application.status = 200
                for server in [ready, app]:
                    server.shutdown()
                    server.server_close()

    def test_only_healthy_replica_is_never_drained(self):
        old = {'Id': 'old', 'Config': {'Labels': {'dtc.rolling-web.application': 'app'}},
               'State': {'Health': {'Status': 'healthy'}}}
        new = {'Id': 'new', 'State': {'Health': {'Status': 'starting'}}}
        calls = []
        def docker(*args):
            calls.append(args)
            if args == ('inspect', 'web-old'):
                return json.dumps([old])
            if args[0] == 'ps':
                return 'old\nnew\n'
            return json.dumps([old, new])
        with patch.object(drain, 'docker', docker), patch.object(drain.time, 'sleep'):
            with self.assertRaises(ValueError):
                drain.main('web-old')
        self.assertFalse(any(c[0] == 'exec' for c in calls))

    def test_healthy_replacement_allows_local_drain_without_stopping_app(self):
        old = {'Id': 'old', 'Config': {'Labels': {'dtc.rolling-web.application': 'app'}}}
        new = {'Id': 'new', 'State': {'Health': {'Status': 'healthy'}}}
        calls = []
        def docker(*args):
            calls.append(args)
            if args == ('inspect', 'web-old'):
                return json.dumps([old])
            if args[0] == 'ps':
                return 'old\nnew\n'
            return json.dumps([old, new])
        with patch.object(drain, 'docker', docker), patch.object(drain.time, 'sleep'):
            drain.main('web-old')
        self.assertIn(('exec', 'web-old', 'python', '/opt/rolling-readiness.py', 'drain'), calls)
        self.assertFalse(any(c[0] in ('stop', 'kill', 'rm') for c in calls))


if __name__ == '__main__':
    unittest.main()
