#!/usr/bin/env python3
"""Execute both installers' remote payloads against an isolated fake host."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='proxy-installers-') as temporary:
    root = Path(temporary)
    for directory in ('etc/cron.d', 'usr/local/sbin', 'var/log', 'var/lib', 'bin', 'staging'):
        (root / directory).mkdir(parents=True)
    # The keeper must not need real Docker or an app change to install/run.
    for command in ('docker', 'msmtp'):
        p = root / 'bin' / command
        p.write_text('#!/bin/bash\nexit 0\n')
        p.chmod(0o755)
    for source, target in [
        ('edge/ensure-coolify-proxy-networks.sh', 'ensure.sh'),
        ('edge/proxy-network-keep.cron', 'keeper.cron'),
        ('monitors/coolify-proxy-networks.sh', 'monitor.sh'),
        ('monitors/coolify-proxy-networks.cron', 'monitor.cron'),
        ('monitors/coolify-proxy-networks.env.example', 'monitor.env'),
    ]:
        (root / 'staging' / target).write_bytes((repo / source).read_bytes())
    env_path = root / 'etc/coolify-proxy-networks.env'
    old_env = ('ALERT_TO=dev@dtcdev.click\nALERT_FROM=noreply@datatalks.club\n'
               'STATE_DIR=/var/lib/coolify-healthcheck\nALERT_REPEAT_MIN=60\n')
    env_path.write_text(old_env)
    env_path.chmod(0o600)
    (root / 'etc/cron.d/coolify-proxy-networks').write_text('OLD PAGER\n')

    def install(source):
        script = (repo / source).read_text().split("<<'EOF'\n", 1)[1].split('\nEOF', 1)[0]
        # Rewrite absolute host paths in the payload, including Python env migration.
        script = re.sub(r'/(?:etc|usr/local/sbin|var/log|var/lib)(?=/|\b)',
                        lambda m: str(root) + m[0], script)
        # Rewrite its regex fixture as well (it still matches the rewritten old env).
        env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'])
        subprocess.run(['bash', '-s', '--', str(root / 'staging')],
                       input=script, text=True, env=env, check=True, capture_output=True)

    # The isolated env should represent paths on this fake host.
    env_path.write_text(old_env.replace('/var/lib', str(root / 'var/lib')))
    for source in ('edge/install-proxy-network-keep.sh', 'monitors/install-coolify-proxy-networks.sh') * 2:
        install(source)
    keeper = (root / 'etc/cron.d/coolify-proxy-network-keep').read_text()
    pager = (root / 'etc/cron.d/coolify-proxy-networks').read_text()
    assert '*/2 ' in keeper and 'ensure-coolify-proxy-networks.sh --apply' in keeper
    assert '*/5 ' in pager and '/usr/local/sbin/coolify-proxy-networks.sh' in pager
    print('PASS: both installer orders preserve distinct keeper and pager cron entries')
    assert 'OK:' in (root / 'var/log/coolify-proxy-networks.log').read_text()
    print('PASS: keeper installation executes apply and produces log evidence')
    migrated = env_path.read_text()
    assert 'ALERT_TO=dev@dtcdev.click' in migrated
    assert 'ALERT_FROM=alerts@dtcdev.click' in migrated
    assert 'ALERT_MSMTP_ACCOUNT=alerts' in migrated
    assert str(root / 'var/lib/coolify-proxy-networks') in migrated
    assert (env_path.stat().st_mode & 0o777) == 0o600
    print('PASS: legacy env migrates sender/state while preserving recipient and permissions')
    assert any('noreply@datatalks.club' in p.read_text()
               for p in env_path.parent.glob(env_path.name + '.bak-*'))
    assert any(p.read_text() == 'OLD PAGER\n'
               for p in (root / 'etc/cron.d').glob('coolify-proxy-networks.bak-*'))
    assert list((root / 'usr/local/sbin').glob('*.bak-*'))
    print('PASS: overwritten scripts, cron and env have retained backups')
