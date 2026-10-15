"""Reuse only a previously verified binary whose application sources are unchanged."""
import json
import os
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
full_recheck = os.environ.get('RECHECK_PLAYBACK') == 'true'
network_probe = os.environ.get('NETWORK_PROBE') == 'true'
for name in ([] if full_recheck or network_probe else required):
    result = json.loads((artifact / f'{name}.json').read_text())
    if result.get('success') is not True:
        raise RuntimeError(f'Cannot reuse an unverified build: {name}')
if not full_recheck and not network_probe and not json.loads((artifact / 'storage-smoke.json').read_text()).get('navigationSuccess'):
    raise RuntimeError('Navigation storage was not verified')
# Full rechecks may start from a failed test run, but only from successful native
# builds/type checks. The workflow then runs every playback and UI assertion;
# no previous pass or failed result is used to satisfy the new check.
if full_recheck or network_probe:
    jobs = json.loads(subprocess.check_output(['gh', 'run', 'view', info['run'], '--json', 'jobs']))['jobs']
    steps = {step['name']: step['conclusion'] for job in jobs for step in job['steps']}
    for name in ['Native ASS parser and playback clock tests', 'Native UI type checks',
                 'Build device application', 'Package LiveContainer IPA', 'Build simulator application']:
        if steps.get(name) != 'success':
            raise RuntimeError(f'Cannot retest a failed application build: {name}')
Path('dist/reused-build-info.json').write_text(json.dumps(info, indent=2) + '\n')
print(f'Reusing application build {info["build"]} at {commit} for the requested checks', flush=True)
