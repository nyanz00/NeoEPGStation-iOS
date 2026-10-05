"""Reuse only a previously verified binary whose application sources are unchanged."""
import json
import re
import subprocess
from pathlib import Path

artifact = Path('reused/artifact/dist')
info = json.loads((artifact / 'build-info.json').read_text())
run = json.loads(Path('reused/run.json').read_text())
commit = info.get('commit', '')
if not re.fullmatch(r'[0-9a-f]{40}', commit) or commit != run['headSha']:
    raise RuntimeError('Artifact commit does not match the selected build')
if info['bundleIdentifier'] != 'io.github.nyanz00.NeoEPGStation' or info['minimumOS'] != '18.0':
    raise RuntimeError('Unexpected application identity or deployment target')
repository = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True, encoding='utf-8').strip()
subprocess.run(['git', 'diff', '--exit-code', commit, 'HEAD', '--',
                'App.tsx', 'src', 'ios', 'package.json', 'package-lock.json'], check=True, cwd=repository)
required = ['storage-smoke', 'danmaku-smoke', 'pip-composition-smoke', 'pip-player-smoke',
            'ui-iphone-recorded', 'ui-iphone-menu', 'ui-iphone-settings']
if Path('ios/NeoEPGStation/NeoPlayerChrome.swift').exists():
    required += ['player-ui-smoke', 'player-playback-smoke']
for name in required:
    result = json.loads((artifact / f'{name}.json').read_text())
    if result.get('success') is not True:
        raise RuntimeError(f'Cannot reuse an unverified build: {name}')
if not json.loads((artifact / 'storage-smoke.json').read_text()).get('navigationSuccess'):
    raise RuntimeError('Navigation storage was not verified')
Path('dist/reused-build-info.json').write_text(json.dumps(info, indent=2) + '\n')
print(f'Reusing verified application build {info["build"]} at {commit}', flush=True)
