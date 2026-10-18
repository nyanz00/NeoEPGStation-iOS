"""Exercise only rotation reflow and full-display zoom on iPhone and iPad."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


phone = json.loads(Path('dist/simulator-device.json').read_text())['udid']
available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
runtime = next(key for key, devices in available.items() if any(d['udid'] == phone for d in devices))
pad = next(d['udid'] for d in available[runtime] if d['name'].startswith('iPad Pro'))
app = 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app'
bundle = 'io.github.nyanz00.NeoEPGStation'
for name, device in [('iphone', phone), ('ipad', pad)]:
    if device != phone:
        subprocess.run(['xcrun', 'simctl', 'shutdown', phone], capture_output=True)
    subprocess.run(['xcrun', 'simctl', 'boot', device], capture_output=True)
    run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
    run('xcrun', 'simctl', 'install', device, app, timeout=300)
    documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data'))/'Documents'
    documents.mkdir(exist_ok=True); marker = documents/'reflow-zoom-smoke.json'; marker.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
    environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_REFLOW_ZOOM='1')
    subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
    deadline = time.monotonic()+60
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(1)
    result = json.loads(marker.read_text())
    shutil.copyfile(marker, f'dist/{name}-reflow-zoom-smoke.json')
    run('xcrun', 'simctl', 'io', device, 'screenshot', f'dist/{name}-reflow-zoom.png')
    assert result['success'] and all(result['checks'].values()), result
    print(name, len(result['checks']), 'reflow/zoom checks passed', flush=True)
run('xcrun', 'simctl', 'shutdown', pad)
