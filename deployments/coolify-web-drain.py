#!/usr/bin/env python3
"""Remote-host pre-stop hook: remove old web from traffic before SIGTERM."""
import json
import re
import subprocess
import sys
import time


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True, timeout=15)


def main(name):
    if not re.fullmatch(r'[a-zA-Z0-9_.-]+', name):
        raise ValueError('Invalid container name')
    old = json.loads(docker('inspect', name))[0]
    application = old['Config']['Labels'].get('dtc.rolling-web.application')
    # First adoption replaces a legacy container without the readiness agent.
    # Use a distinct, higher-priority new namespace for that migration.
    if not application:
        return
    candidates = docker('ps', '-q', '--filter', 'label=dtc.rolling-web.application=' + application).split()
    containers = json.loads(docker('inspect', *candidates))
    ready = [c for c in containers if c['Id'] != old['Id']
             and c['State'].get('Health', {}).get('Status') == 'healthy']
    if not ready:
        raise ValueError('Refusing to drain the only healthy web replica')
    # Keep the serving process alive while the proxy discovers the replacement.
    time.sleep(3)
    docker('exec', name, 'python', '/opt/rolling-readiness.py', 'drain')
    # Active Traefik checks run every two seconds; allow three full intervals
    # before Docker sends TERM. In-flight application requests can finish.
    time.sleep(6)
    print('Old web backend drained; healthy replacement retained.', flush=True)


if __name__ == '__main__':
    try:
        main(sys.argv[1])
    except Exception as error:
        print('Web drain refused (' + type(error).__name__ + '); keep old container.', file=sys.stderr)
        sys.exit(1)
