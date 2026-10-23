#!/usr/bin/env python3
"""Patch the tested Coolify 4.4.7 job; refuse any unreviewed source version.

Usage: patch-coolify-drain.py ORIGINAL OUTPUT. Mount OUTPUT over the original
job in the control-plane container; see coolify-rolling-web.md.
"""
import hashlib
from pathlib import Path
import sys

EXPECTED = 'd1b0549a351722f133556460534411fe436953e5eed7ea2fef0cc178004ab2e1'
ANCHOR = '''    private function graceful_shutdown_container(string $containerName, bool $skipRemove = false)
    {
        try {
'''
HOOK = '''            // DTC web drain: the replacement is healthy before old traffic is withdrawn.
            if ($this->newVersionIsHealthy
                && $containerName !== $this->container_name
                && str_contains((string) $this->application->health_check_command, '8099/ready')) {
                $this->application_deployment_queue->addLogEntry('Draining old web backend before termination.');
                $this->execute_remote_command([
                    'python3 /usr/local/sbin/coolify-web-drain.py '.escapeshellarg($containerName),
                    'hidden' => true,
                ]);
            }
'''


def patch(original):
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Untested Coolify source; re-review the drain hook before upgrading')
    text = original.decode()
    if text.count(ANCHOR) != 1:
        raise ValueError('Drain insertion point is not unique')
    return text.replace(ANCHOR, ANCHOR + HOOK).encode()


if __name__ == '__main__':
    Path(sys.argv[2]).write_bytes(patch(Path(sys.argv[1]).read_bytes()))
