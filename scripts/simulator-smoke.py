"""Launch the Release bundle without Metro and catch immediate native crashes."""
import json
import os
import subprocess
import time
from pathlib import Path

def run(*args):
    return subprocess.check_output(args, text=True).strip()

available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
devices = [d for runtime, items in available.items() if '.iOS-' in runtime
           for d in items if d['isAvailable'] and d['name'].startswith('iPhone')]
if not devices:
    raise RuntimeError('No installed iPhone simulator is available')
device = devices[0]
app = Path('build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app')
for framework in (app / 'Frameworks').glob('*.framework'):
    run('codesign', '--force', '--sign', '-', str(framework))
run('codesign', '--force', '--sign', '-', '--entitlements', 'ios/Simulator.entitlements', str(app))
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', device['udid'])
run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
run('xcrun', 'simctl', 'install', device['udid'], str(app))
os.environ['SIMCTL_CHILD_NEO_EPG_STORAGE_SMOKE'] = '1'
launch = run('xcrun', 'simctl', 'launch', device['udid'], 'io.github.nyanz00.NeoEPGStation')
pid = launch.rsplit(':', 1)[1].strip()
time.sleep(15)
processes = run('xcrun', 'simctl', 'spawn', device['udid'], 'launchctl', 'list')
if not any(line.split()[0] == pid for line in processes.splitlines() if line.split()):
    raise RuntimeError('Application exited after launch; inspect simulator crash logs')
Path('dist/simulator-launch.txt').write_text(f"{device['name']}\n{launch}\nProcess remained running after 15 seconds.\n")
run('xcrun', 'simctl', 'io', device['udid'], 'screenshot', 'dist/simulator.png')
container = Path(run('xcrun', 'simctl', 'get_app_container', device['udid'], 'io.github.nyanz00.NeoEPGStation', 'data'))
storage = json.loads((container / 'Documents/storage-smoke.json').read_text())
Path('dist/storage-smoke.json').write_text(json.dumps(storage, indent=2) + '\n')
if storage.get('success') is not True:
    raise RuntimeError(f"Keychain storage round-trip failed: {storage.get('error')}")
