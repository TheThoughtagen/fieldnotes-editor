#!/usr/bin/env python3
"""Validate local Apple credentials; upload only with --upload. Never logs secrets."""
import argparse
import base64
import getpass
import pathlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', required=True, help='GitHub owner/repository')
parser.add_argument('--certificate', required=True, type=pathlib.Path, help='Developer ID Application certificate and private key (.p12)')
parser.add_argument('--notary-key', required=True, type=pathlib.Path, help='App Store Connect private key (.p8)')
parser.add_argument('--developer-id', required=True, help='Full Developer ID Application identity from Keychain Access')
parser.add_argument('--team-id', required=True)
parser.add_argument('--key-id', required=True)
parser.add_argument('--issuer', default='', help='Team API key issuer UUID; omit for individual API keys')
parser.add_argument('--upload', action='store_true', help='Set GitHub repository secrets after validation (default: validation only)')
args = parser.parse_args()

def fail(message):
    sys.exit(message)

if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
    fail('Invalid repository name')
if not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
    fail('Invalid Apple team ID')
if not args.developer_id.startswith('Developer ID Application: ') or not args.developer_id.endswith(f' ({args.team_id})'):
    fail('Developer ID Application identity must match the expected team ID')
if not re.fullmatch(r'[A-Za-z0-9]{10,}', args.key_id):
    fail('Invalid API key ID')
if args.issuer and not re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', args.issuer):
    fail('Invalid issuer UUID')
repo_root = pathlib.Path(__file__).resolve().parent.parent
for path in [args.certificate, args.notary_key]:
    if not path.is_file() or repo_root in path.resolve().parents:
        fail('Credential files must exist outside this repository')
if not sys.stdin.isatty():
    fail('Run interactively in a terminal for a hidden certificate password prompt')
password = getpass.getpass('PKCS#12 password (hidden): ')
if not password or '\n' in password or '\r' in password:
    fail('A nonempty single-line PKCS#12 password is required')
# Pass the password through stdin, never command arguments or the environment.
checked = subprocess.run(['openssl', 'pkcs12', '-in', str(args.certificate), '-passin', 'stdin', '-info', '-noout'], input=(password+'\n').encode(), capture_output=True)
if checked.returncode:
    fail('Cannot read PKCS#12 with this password; check the export and local OpenSSL compatibility')
# -info reports bag types, without printing private key or certificate contents.
if b'Shrouded Keybag' not in checked.stderr or b'Certificate bag' not in checked.stderr:
    fail('PKCS#12 must contain an encrypted private key and certificate')
checked = subprocess.run(['openssl', 'pkey', '-in', str(args.notary_key), '-check', '-noout'], capture_output=True, stdin=subprocess.DEVNULL)
if checked.returncode:
    fail('Cannot read the App Store Connect private key')
print('Local formats validated. Apple authorization and certificate identity are checked during release.')
if not args.upload:
    print('No secrets uploaded. Repeat with --upload when ready.')
    sys.exit(0)
secrets = {
    'DEVELOPER_ID': args.developer_id.encode(),
    'APPLE_TEAM_ID': args.team_id.encode(),
    'SIGNING_CERTIFICATE': base64.b64encode(args.certificate.read_bytes()),
    'SIGNING_PASSWORD': password.encode(),
    'NOTARY_PRIVATE_KEY': args.notary_key.read_bytes(),
    'NOTARY_KEY_ID': args.key_id.encode(),
    'NOTARY_ISSUER': args.issuer.encode(),
}
for name, value in secrets.items():
    # Empty issuer must replace any previous team issuer when switching key types.
    result = subprocess.run(['gh', 'secret', 'set', name, '--repo', args.repo], input=value, capture_output=True)
    if result.returncode:
        fail(f'Failed to set {name}; check GitHub authentication and repository permissions. Earlier secrets may have been set; rerun after fixing access.')
    print(f'Set {name}')
print('Release secrets configured. No tag or release was created.')
