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
                'App.tsx', 'src', 'ios', 'vendor/vlckit', 'vendor/aether', 'package.json', 'package-lock.json'], check=True, cwd=repository)
# A checkpoint-only recheck must also retain the private native library,
# compression sources and their build recipe; ordinary app paths are insufficient.
if os.environ.get('CHECK_SCOPE') in ('checkpoint-trial', 'checkpoint-player', 'checkpoint-analysis', 'aether-connected', 'aether-recovery'):
    subprocess.run(['git', 'diff', '--exit-code', commit, 'HEAD', '--',
        'vendor/checkpoint', 'vendor/lscomp', 'vendor/rcomp-metal',
        'scripts/build-checkpoint.py', 'scripts/checkpoint_compression_sources.py',
        'experiments/dav1d-checkpoint'], check=True, cwd=repository)
    if os.environ.get('CHECK_SCOPE') == 'checkpoint-trial':
        subprocess.run(['git', 'diff', '--exit-code', commit, 'HEAD', '--', 'tests/fixtures'], check=True, cwd=repository)
    else:
        # Matcher/reference corrections can reuse the same app, but both video
        # inputs must remain byte-identical to the original replay.
        for fixture in (['av1-seek-10.mkv','encoded-seek-1080.mkv','hevc-seek-10.mkv'] if os.environ.get('CHECK_SCOPE') in ('aether-connected','aether-recovery') else ['av1-seek-10.mkv','av1-seek-10-gop6.mkv']):
            subprocess.run(['git', 'diff', '--exit-code', commit, 'HEAD', '--', 'tests/fixtures/'+fixture], check=True, cwd=repository)
required = ['storage-smoke', 'danmaku-smoke', 'pip-composition-smoke', 'pip-player-smoke',
            'ui-iphone-recorded', 'ui-iphone-menu', 'ui-iphone-settings']
if Path('ios/NeoEPGStation/NeoPlayerChrome.swift').exists():
    required += ['player-ui-smoke', 'player-playback-smoke']
full_recheck = os.environ.get('RECHECK_PLAYBACK') == 'true'
network_probe = os.environ.get('NETWORK_PROBE') == 'true'
focused = os.environ.get('CHECK_SCOPE') in ('zoom-font', 'ts-comments', 'recovery-ui', 'streaming', 'encoded-seek', 'av1-decoder', 'startup-preroll', 'aether-compare', 'avplayer-compare', 'aether-seek', 'decode-trial', 'checkpoint-trial', 'checkpoint-player', 'checkpoint-analysis', 'aether-connected', 'aether-recovery')
for name in ([] if full_recheck or network_probe or focused else required):
    result = json.loads((artifact / f'{name}.json').read_text())
    if result.get('success') is not True:
        raise RuntimeError(f'Cannot reuse an unverified build: {name}')
if not full_recheck and not network_probe and not focused and not json.loads((artifact / 'storage-smoke.json').read_text()).get('navigationSuccess'):
    raise RuntimeError('Navigation storage was not verified')
# Full rechecks may start from a failed test run, but only from successful native
# builds/type checks. The workflow then runs every playback and UI assertion;
# no previous pass or failed result is used to satisfy the new check.
if full_recheck or network_probe or focused:
    jobs = json.loads(subprocess.check_output(['gh', 'run', 'view', info['run'], '--json', 'jobs']))['jobs']
    steps = {step['name']: step['conclusion'] for job in jobs for step in job['steps']}
    for name in ['Native ASS parser and playback clock tests', 'Native UI type checks',
                 'Build device application', 'Verify device FFmpeg import isolation',
                 'Package LiveContainer IPA', 'Build simulator application', 'Verify simulator FFmpeg import isolation']:
        if steps.get(name) != 'success':
            raise RuntimeError(f'Cannot retest a failed application build: {name}')
# Reuse retained-VLC checks only when both its code/fixtures and the binary
# are identical. A test-only Aether image matcher correction needs no new VLC run.
if os.environ.get('CHECK_SCOPE') == 'aether-compare':
    unchanged = subprocess.run(['git', 'diff', '--quiet', commit, 'HEAD', '--',
        'scripts/encoded-seek-smoke.py', 'tests/fixtures'], cwd=repository).returncode == 0
    names = ['startup-h264-mkv-baseline', 'startup-h264-mkv', 'startup-h264-mp4',
             'startup-hevc10-mkv', 'startup-av1-8-mkv', 'startup-av1-10-mkv']
    files = [artifact/(name+'-encoded-seek-smoke.json') for name in names]
    if unchanged and all(p.exists() and json.loads(p.read_text()).get('success') is True for p in files):
        Path('dist/reused-vlc-startup.json').write_text(json.dumps({'success': True,
            'sourceRun': info['run'], 'commit': commit, 'cases': names}, indent=2)+'\n')
Path('dist/reused-build-info.json').write_text(json.dumps(info, indent=2) + '\n')
print(f'Reusing application build {info["build"]} at {commit} for the requested checks', flush=True)
