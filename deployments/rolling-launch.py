#!/usr/bin/env python3
"""Start the internal readiness process, then preserve the image's startup."""
import os
import json
import shlex
import subprocess
import sys

arguments = json.loads(os.environ['ROLLING_ORIGINAL_COMMAND']) if 'ROLLING_ORIGINAL_COMMAND' in os.environ else sys.argv[1:]
command = shlex.split(os.environ.get('ROLLING_ORIGINAL_ENTRYPOINT', '')) + arguments
if not command:
    raise SystemExit('No application startup command configured')
subprocess.Popen([sys.executable, '/opt/rolling-readiness.py', 'serve'])
os.execvp(command[0], command)
