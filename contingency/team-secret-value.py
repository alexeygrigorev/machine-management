"""Pipe one sandbox DR escrow value into its consuming process; never log it."""
import argparse
import sys

import boto3
from dataops_secrets import SecretReader


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('name', choices=['dr-escrow.coolify-cp-backup-gpg-passphrase', 'dr-escrow.acme-backup-gpg-passphrase'])
    parser.add_argument('--region', default='eu-west-1', choices=['eu-west-1'])
    args = parser.parse_args()
    session = boto3.Session(profile_name='default', region_name=args.region)
    if session.client('sts').get_caller_identity()['Account'] != '817685572750':
        raise RuntimeError('Sandbox account required')
    reader = SecretReader(table_name='dataops-v1-secrets',
                          key_id='arn:aws:kms:eu-west-1:817685572750:key/420b802e-1d2c-4a51-95e7-f798381303bb',
                          region=args.region, dynamodb=session.client('dynamodb'), kms=session.client('kms'))
    value = reader.read(args.name)['value']
    if not value:
        raise ValueError('Empty DR escrow value')
    sys.stdout.write(value)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Team store read failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
