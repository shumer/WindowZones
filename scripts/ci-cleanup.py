#!/usr/bin/env python3
"""Remove release credentials even when an earlier build step fails."""
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(os.environ['RUNNER_TEMP']) / 'windowzones-signing'
if (root / 'keychains.json').exists():
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *json.loads((root / 'keychains.json').read_text())], check=False)
if (root / 'signing.keychain-db').exists():
    subprocess.run(['security', 'delete-keychain', str(root / 'signing.keychain-db')], check=False)
if root.exists():
    shutil.rmtree(root)
