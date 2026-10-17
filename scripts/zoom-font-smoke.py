"""Focused Release app checks: pinch feedback and shaped comment-font metadata."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


dist = Path('dist')
device = json.loads((dist / 'simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
app = 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
run('xcrun', 'simctl', 'install', device, app, timeout=300)
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data')) / 'Documents'
documents.mkdir(exist_ok=True)
names = ['player-zoom-font-smoke.json', 'font-diagnostics.json']
for name in names:
    (documents / name).unlink(missing_ok=True)
environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_ZOOM_FONT_SMOKE='1')
subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], check=True, env=environment, timeout=60)
marker = documents / names[0]
deadline = time.monotonic() + 60
while not marker.exists() and time.monotonic() < deadline:
    time.sleep(1)
for name in names:
    source = documents / name
    if source.exists():
        shutil.copyfile(source, dist / name)
run('xcrun', 'simctl', 'io', device, 'screenshot', str(dist / 'zoom-font-smoke.png'))
if not marker.exists():
    raise RuntimeError('Focused app checks did not complete within 60 seconds')
result = json.loads(marker.read_text())
if result.get('success') is not True or not result.get('checks') or not all(result['checks'].values()):
    raise RuntimeError(f'Focused app checks failed: {result}')
if not (dist / names[1]).exists():
    raise RuntimeError('Actual font diagnostic export is missing')
print(f"PASS: {len(result['checks'])} focused zoom/haptic/font assertions", flush=True)
