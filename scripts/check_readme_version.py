#!/usr/bin/env python3
from __future__ import annotations
import re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PUBSPEC = ROOT / 'pubspec.yaml'
README = ROOT / 'README.md'
text = PUBSPEC.read_text(encoding='utf-8')
m = re.search(r'^version:\s*([^\s]+)\s*$', text, flags=re.MULTILINE)
if not m:
    raise SystemExit('Cannot find pubspec version')
pub = m.group(1).split('+',1)[0]
rt = README.read_text(encoding='utf-8')
m2 = re.search(r'badge/Версия-([0-9]+\.[0-9]+\.[0-9]+)-', rt)
if not m2:
    raise SystemExit('Cannot find README badge version')
readme = m2.group(1)
if pub != readme:
    print(f'Version mismatch: pubspec={pub} README_badge={readme}', file=sys.stderr)
    raise SystemExit(1)
print(f'Version check passed: {pub}')
