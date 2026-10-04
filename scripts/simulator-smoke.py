"""Launch the Release bundle without Metro and catch immediate native crashes."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()

Path('dist').mkdir(exist_ok=True)
device_file = Path('dist/simulator-device.json')
if '--prepare' in sys.argv or not device_file.exists():
    available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
    devices = [(runtime, d) for runtime, items in available.items() if '.iOS-' in runtime
               for d in items if d['isAvailable'] and d['name'].startswith('iPhone')]
    if not devices:
        raise RuntimeError('No installed iPhone simulator is available')
    runtime, source = devices[0]
    types = json.loads(run('xcrun', 'simctl', 'list', 'devicetypes', '--json'))['devicetypes']
    device_type = next(item['identifier'] for item in types if item['name'] == source['name'])
    device = {'name': source['name'], 'udid': run('xcrun', 'simctl', 'create', 'NeoEPGStation-CI', device_type, runtime)}
    device_file.write_text(json.dumps(device))
    run('xcrun', 'simctl', 'boot', device['udid'])
    if '--prepare' in sys.argv:
        sys.exit(0)
else:
    device = json.loads(device_file.read_text())
app = Path('build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app')
run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b', timeout=600)
run('xcrun', 'simctl', 'install', device['udid'], str(app))
os.environ['SIMCTL_CHILD_NEO_EPG_STORAGE_SMOKE'] = '1'
try:
    launch = run('xcrun', 'simctl', 'launch', device['udid'], 'io.github.nyanz00.NeoEPGStation')
except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
    logs = run('xcrun', 'simctl', 'spawn', device['udid'], 'log', 'show', '--last', '3m',
               '--style', 'compact', '--predicate',
               'process == "NeoEPGStation" OR process == "runningboardd" OR process == "SpringBoard"')
    Path('dist/simulator-launch-errors.log').write_text(logs)
    raise
pid = launch.rsplit(':', 1)[1].strip()
container = Path(run('xcrun', 'simctl', 'get_app_container', device['udid'], 'io.github.nyanz00.NeoEPGStation', 'data'))
for attempt in range(12):
    time.sleep(5)
    if (container / 'Documents/pip-player-smoke.json').exists() and (container / 'Documents/pip-composition-smoke.json').exists():
        break
processes = run('xcrun', 'simctl', 'spawn', device['udid'], 'launchctl', 'list')
if not any(line.split()[0] == pid for line in processes.splitlines() if line.split()):
    raise RuntimeError('Application exited after launch; inspect simulator crash logs')
Path('dist/simulator-launch.txt').write_text(f"{device['name']}\n{launch}\nProcess remained running through native rendering tests.\n")
run('xcrun', 'simctl', 'io', device['udid'], 'screenshot', 'dist/simulator.png')
container = Path(run('xcrun', 'simctl', 'get_app_container', device['udid'], 'io.github.nyanz00.NeoEPGStation', 'data'))
storage = json.loads((container / 'Documents/storage-smoke.json').read_text())
Path('dist/storage-smoke.json').write_text(json.dumps(storage, indent=2) + '\n')
if storage.get('success') is not True:
    raise RuntimeError(f"Keychain storage round-trip failed: {storage.get('error')}")
danmaku = json.loads((container / 'Documents/danmaku-smoke.json').read_text())
Path('dist/danmaku-smoke.json').write_text(json.dumps(danmaku, indent=2) + '\n')
if danmaku.get('success') is not True:
    raise RuntimeError(f"Native comment rendering failed: {danmaku.get('error')}")
Path('dist/danmaku-smoke.png').write_bytes((container / 'Documents/danmaku-smoke.png').read_bytes())

for name in ['pip-composition-smoke', 'player-landscape-smoke']:
    source = container / f'Documents/{name}.png'
    if source.exists():
        Path(f'dist/{name}.png').write_bytes(source.read_bytes())
results = {}
for name in ['pip-composition-smoke', 'pip-player-smoke']:
    result = json.loads((container / f'Documents/{name}.json').read_text())
    Path(f'dist/{name}.json').write_text(json.dumps(result, indent=2) + '\n')
    results[name] = result
for name, result in results.items():
    if result.get('success') is not True:
        raise RuntimeError(f"{name} failed: {result}")
