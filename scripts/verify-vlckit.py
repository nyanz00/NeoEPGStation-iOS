"""A cache/artifact is usable only when its binary and compilation inputs match."""
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sdk = sys.argv[1]
assert sdk in ('iphoneos', 'iphonesimulator')
output = root / f'build/vlckit-output-{sdk}'
try:
    value = json.loads((output / 'provenance.json').read_text())
    expected = json.loads((root / 'vendor/vlckit/source.json').read_text())
    assert all(value[k] == v for k, v in expected.items())
    assert value['sdk'] == sdk and 'Xcode 26.6' in value['xcode']
    for path in [root / 'vendor/vlckit/source.json', root / 'vendor/vlckit/av1.c.inc', root / 'vendor/vlckit/neo_preroll.h',
                 *sorted((root / 'vendor/vlckit/patches').glob('*.patch'))]:
        assert value['patches'][str(path.relative_to(root))] == hashlib.sha256(path.read_bytes()).hexdigest()
    binary = (output / 'VLCKit.framework/VLCKit').read_bytes()
    assert value['sha256'] == hashlib.sha256(binary).hexdigest()
    assert b'neo-av1-selection hardware=1' in binary
    assert b'videotoolbox-av1-hardware' in binary
    assert b'neo-preroll-ready optimized=' in binary
    assert b'neo-preroll-filter enabled=' in binary
    assert b'neo-preroll-reference version=5' in binary
    assert b'neo-preroll-cost codec=' in binary
    assert b'neo-initial-position targetUs=' in binary
    valid = True
except (OSError, ValueError, AssertionError, KeyError):
    valid = False
if 'GITHUB_OUTPUT' in os.environ:
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'usable={str(valid).lower()}\n')
print(f'{sdk}: matching AV1 dependency={valid}')
if '--required' in sys.argv and not valid:
    raise SystemExit(1)
