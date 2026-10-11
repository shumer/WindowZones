#!/usr/bin/env python3
"""Check catalog completeness and format contracts without launching the app."""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
catalogs = {}
for language in ('en', 'ru'):
    path = root / 'Resources' / f'{language}.lproj' / 'Localizable.strings'
    catalogs[language] = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
assert catalogs['en'].keys() == catalogs['ru'].keys(), 'Catalog keys differ.'
for key, english in catalogs['en'].items():
    russian = catalogs['ru'][key]
    assert english and russian, f'Empty translation: {key}'
    assert re.findall(r'%[@df]', english) == re.findall(r'%[@df]', russian), f'Format mismatch: {key}'
for path in (root / 'Sources' / 'WindowZones').glob('*.swift'):
    for key in re.findall(r'\bL[F]?\("([^"\\]*)"', path.read_text()):
        assert not key or key in catalogs['en'], f'Missing key: {path.name}: {key}'
print(f"Validated {len(catalogs['en'])} English/Russian keys and format placeholders.")
