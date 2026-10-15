"""Real VLC + Range cache with controlled, loopback-only network faults."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

def run(*args):
    return subprocess.check_output(args, text=True, timeout=120).strip()

device = json.loads(Path('dist/simulator-device.json').read_text())['udid']
subprocess.run(['xcrun', 'simctl', 'boot', device], capture_output=True)
run('xcrun', 'simctl', 'bootstatus', device, '-b')
bundle = 'io.github.nyanz00.NeoEPGStation'
container = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data')) / 'Documents'
fixture = container / 'network-fixture.mkv'
if not shutil.which('ffmpeg'):
    subprocess.check_call(['brew', 'install', 'ffmpeg'], timeout=600)
# Constant bitrate makes each 1MiB Range represent ~4s of media, so three
# successful-but-9s-late responses actually exhaust the normal 5s look-ahead.
subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '85',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-b:v', '2M', '-minrate', '2M', '-maxrate', '2M', '-bufsize', '4M',
    '-x264-params', 'nal-hrd=cbr:force-cfr=1', '-g', '48', '-c:a', 'aac', '-b:a', '64k', str(fixture)], timeout=120)
sys.path.insert(0, str(Path('tests/fixtures').resolve()))
from http_range_server import start_server
server = start_server(container)
os.environ['SIMCTL_CHILD_NEO_EPG_NETWORK_PROBE'] = f'http://127.0.0.1:{server.server_port}'
for mode in ['slow', 'disconnect']:
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
    for name in ['network-recovery-smoke.json', 'network-diagnostics.json']:
        (container / name).unlink(missing_ok=True)
    os.environ['SIMCTL_CHILD_NEO_EPG_NETWORK_MODE'] = mode
    run('xcrun', 'simctl', 'launch', device, bundle)
    result = container / 'network-recovery-smoke.json'
    for _ in range(100):
        if result.exists(): break
        time.sleep(1)
    for name in ['network-recovery-smoke.json', 'network-diagnostics.json']:
        if (container / name).exists(): shutil.copyfile(container / name, Path('dist') / f'{mode}-{name}')
    value = json.loads(result.read_text())
    picture = container / 'player-pinch-zoom.png'
    if picture.exists(): shutil.copyfile(picture, Path('dist') / f'{mode}-player-pinch-zoom.png')
    assert value['success'] and all(value['zoomChecks'].values()), value
    assert any(e['mode'] == mode for e in server.fault_events), 'Network fault was never exercised'
    print(mode, 'network probe captured', len(value['rows']), 'samples', flush=True)
Path('dist/network-faults.json').write_text(json.dumps(server.fault_events, indent=2))
server.shutdown()
checked = run(sys.executable, 'scripts/check-network-recovery.py', 'dist')
Path('dist/network-flow-checks.json').write_text(checked+'\n')
print(checked, flush=True)
