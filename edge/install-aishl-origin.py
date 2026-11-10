#!/usr/bin/env python3
"""Install AISHL origin verification without exposing CloudFront credentials.

Read-only unless --apply. Requires aws-gate MAIN on the operator SSH alias.
Only the new aishl-origin.yml file is changed; existing origin gates are kept.
"""
import argparse
import datetime
import json
import re
import subprocess
import sys


def run(args, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True,
                          check=True, timeout=60).stdout


def render(secret, service):
    if not re.fullmatch(r'[A-Za-z0-9_=-]{16,128}', secret):
        raise ValueError('Invalid origin credential format')
    if not re.fullmatch(r'[a-zA-Z0-9_-]+@docker', service):
        raise ValueError('Invalid backend service')
    hosts = ' || '.join(f'Host(`{host}`)' for host in (
        'aishippinglabs.com', 'www.aishippinglabs.com',
        'prod.aishippinglabs.com', 'aisl-staging.169.58.124.141.sslip.io'))
    routers = {}
    for protocol in ('http', 'https'):
        for allow in (True, False):
            name = f'aishl-origin-{"allow" if allow else "deny"}-{protocol}'
            rule = f'({hosts})'
            if allow:
                rule += f' && Header(`X-Origin-Verify`, `{secret}`)'
            router = {'rule': rule, 'service': service,
                      'entryPoints': [protocol], 'priority': 200 if allow else 150,
                      'middlewares': ['rolling-retry@docker', 'aishl-rate-limit', 'aishl-in-flight']
                      if allow else ['aishl-origin-deny']}
            if protocol == 'https':
                router['tls'] = {'certResolver': 'letsencrypt'}
            routers[name] = router
    # JSON is a YAML subset; use .yml for Traefik's file provider.
    return json.dumps({'http': {'routers': routers, 'middlewares': {
        'aishl-origin-deny': {'ipAllowList': {'sourceRange': ['127.0.0.1/32']}}}}})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    config = json.loads(run(['ssh', 'hetzner',
        'AWS_PROFILE=main aws cloudfront get-distribution-config --id E2OP0JZ5341CAI --output json']))['DistributionConfig']
    origin = next(o for o in config['Origins']['Items'] if o['DomainName'] == 'prod.aishippinglabs.com')
    secret = next(h['HeaderValue'] for h in origin['CustomHeaders']['Items']
                  if h['HeaderName'].lower() == 'x-origin-verify')
    inspect = json.loads(run(['ssh', 'contabo-b',
        'sudo docker inspect $(sudo docker ps -q --filter label=dtc.rolling-web.application=w3mxfr6wzjnpg3hqaw3y0obq)']))
    if len(inspect) != 1 or inspect[0]['State']['Health']['Status'] != 'healthy':
        raise ValueError('Need exactly one healthy AISHL public replica')
    labels = inspect[0]['Config']['Labels']
    services = {v for k, v in labels.items() if k.startswith('traefik.http.routers.') and k.endswith('.service')}
    if len(services) != 1:
        raise ValueError('AISHL services are not collapsed')
    service = services.pop().removesuffix('@docker') + '@docker'
    content = render(secret, service)
    if not args.apply:
        print('Plan: gate four AISHL production aliases on HTTP/HTTPS; preserve existing origin and dev routes.')
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    command = ('sudo sh -c \'set -eu; p=/data/coolify/proxy/dynamic/aishl-origin.yml; '
               f'[ ! -f "$p" ] || cp -p "$p" "$p.bak-{stamp}"; '
               'umask 077; cat > "$p.tmp"; mv "$p.tmp" "$p"\'')
    run(['ssh', 'contabo-b', command], content)
    print('Installed private AISHL origin gate; verify public and direct-origin health before acceptance.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Origin installation failed (' + type(error).__name__ + '); details withheld.', file=sys.stderr)
        sys.exit(1)
