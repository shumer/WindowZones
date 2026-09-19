#!/usr/bin/env python3
"""Prepare an isolated CI signing keychain without logging credentials."""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import subprocess

required = ['DEVELOPER_ID_P12', 'DEVELOPER_ID_P12_PASSWORD', 'NOTARY_KEY_P8', 'NOTARY_KEY_ID', 'NOTARY_ISSUER_ID']
if any(not os.environ.get(key) for key in required):
    raise SystemExit('Release signing secrets are incomplete')
root = Path(os.environ['RUNNER_TEMP']) / 'windowzones-signing'
root.mkdir(mode=0o700, exist_ok=True)
keychain = root / 'signing.keychain-db'
certificate = root / 'certificate.p12'
key = root / 'AuthKey.p8'
password = secrets.token_urlsafe(32)
old = subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True)
(root / 'keychains.json').write_text(json.dumps(re.findall(r'"([^"]+)"', old)))

def run(*args):
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit('Signing setup failed: ' + args[0] + ' ' + args[1])

certificate.write_bytes(base64.b64decode(os.environ['DEVELOPER_ID_P12']))
key.write_bytes(base64.b64decode(os.environ['NOTARY_KEY_P8']))
certificate.chmod(0o600)
key.chmod(0o600)
run('security', 'create-keychain', '-p', password, str(keychain))
run('security', 'set-keychain-settings', '-lut', '7200', str(keychain))
run('security', 'unlock-keychain', '-p', password, str(keychain))
run('security', 'import', str(certificate), '-P', os.environ['DEVELOPER_ID_P12_PASSWORD'],
    '-k', str(keychain), '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain))
run('security', 'list-keychains', '-d', 'user', '-s', str(keychain), *json.loads((root / 'keychains.json').read_text()))
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)], text=True)
identity = re.search(r'([A-F0-9]{40}) "Developer ID Application:', identities)
if not identity:
    raise SystemExit('No Developer ID Application identity in the release certificate')
run('xcrun', 'notarytool', 'store-credentials', 'WindowZones-CI', '--keychain', str(keychain),
    '--key', str(key), '--key-id', os.environ['NOTARY_KEY_ID'], '--issuer', os.environ['NOTARY_ISSUER_ID'])
with open(os.environ['GITHUB_ENV'], 'a') as environment:
    environment.write('CODE_SIGN_IDENTITY=' + identity[1] + '\n')
    environment.write('WINDOWZONES_NOTARY_KEYCHAIN=' + str(keychain) + '\n')
certificate.unlink()
key.unlink()
