"""Compare native ARIB lifetimes with the web's delayed-clear semantics."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path('tests/fixtures').resolve()))
from arib_timing import inject

def run(*args):
    return subprocess.check_output(args, text=True, timeout=120).strip()

device = json.loads(Path('dist/simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
container = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data')) / 'Documents'
if not shutil.which('ffmpeg'):
    subprocess.check_call(['brew', 'install', 'ffmpeg'], timeout=600)
subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi',
    '-i', 'color=c=0x203040:s=640x360:r=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
    '-t', '19', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-bf', '0', '-c:a', 'aac',
    '-mpegts_start_pid', '256', '-mpegts_pmt_start_pid', '4096', '-muxdelay', '0', '-muxpreload', '0',
    '-f', 'mpegts', str(container / 'arib-base.ts')], timeout=120)
inject(container / 'arib-base.ts', container / 'arib-timing.ts')
result = container / 'arib-timing-smoke.json'
os.environ['SIMCTL_CHILD_NEO_EPG_ARIB_PROBE'] = '1'
observations = []
for attempt in range(3):
    result.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
    run('xcrun', 'simctl', 'launch', device, bundle)
    for _ in range(50):
        if result.exists():
            break
        time.sleep(1)
    value = json.loads(result.read_text())
    observations.append(value)
    evidence = Path('dist') / f'arib-attempt-{attempt+1}'
    evidence.mkdir(exist_ok=True)
    for path in container.glob('arib-*.png'):
        shutil.copyfile(path, evidence / path.name)
    shutil.copyfile(result, evidence / result.name)
    print(f'ARIB attempt {attempt+1}: '+json.dumps(value), flush=True)
summary = dict(observations[-1])
summary.update(success=all(v['success'] for v in observations),
               matchesWebTiming=all(v['matchesWebTiming'] for v in observations), runs=observations)
Path('dist/arib-timing-smoke.json').write_text(json.dumps(summary, indent=2))
assert summary['success'], 'Native ARIB timing comparison failed; inspect all three preserved attempts'
assert summary['matchesWebTiming'], 'Native ARIB captions expired before the broadcast replacement/clear'
