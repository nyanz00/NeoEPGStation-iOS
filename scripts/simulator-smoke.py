"""Launch the Release UIKit application and verify playback, storage and UI."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()

def capture_ui(udid, stage, prefix, terminate_existing=True):
    print(f'UI smoke: starting {prefix}/{stage}', flush=True)
    if terminate_existing:
        subprocess.run(['xcrun', 'simctl', 'terminate', udid, 'io.github.nyanz00.NeoEPGStation'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    ui_container = Path(run('xcrun', 'simctl', 'get_app_container', udid, 'io.github.nyanz00.NeoEPGStation', 'data'))
    (ui_container / 'Documents').mkdir(exist_ok=True)
    marker = ui_container / f'Documents/ui-{stage}-smoke.json'
    marker.unlink(missing_ok=True)
    os.environ['SIMCTL_CHILD_NEO_EPG_UI_SMOKE'] = stage
    run('xcrun', 'simctl', 'launch', udid, 'io.github.nyanz00.NeoEPGStation')
    for _ in range(90):
        if marker.exists():
            break
        time.sleep(1)
    result = json.loads(marker.read_text())
    if (result.get('success') is not True or result.get('recordCount') != 4
        or result.get('theme') != 'neon-teal-dark'
        or result.get('uiEngine') != 'Swift / UIKit'
        or result.get('retainedList') is not True
        or result.get('route') != ('settings' if stage == 'settings' else 'recorded')):
        raise RuntimeError(f'UI smoke failed: {result}')
    if prefix == 'ui-ipad' and result.get('sidebarWidth') != 240:
        raise RuntimeError(f"Unexpected iPad sidebar width: {result.get('sidebarWidth')}")
    Path(f'dist/{prefix}-{stage}.json').write_text(json.dumps(result, indent=2) + '\n')
    run('xcrun', 'simctl', 'io', udid, 'screenshot', f'dist/{prefix}-{stage}.png')
    print(f'UI smoke: captured {prefix}/{stage}', flush=True)

def capture_ipad(app, device):
    available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
    runtime = next(runtime for runtime, devices in available.items()
        if any(item['udid'] == device['udid'] for item in devices))
    pad_source = next(item for item in available[runtime]
                      if item['isAvailable'] and item['name'].startswith('iPad Pro'))
    pad = pad_source['udid']
    print(f"UI smoke: booting {pad_source['name']}", flush=True)
    print('UI smoke: shutting down iPhone', flush=True)
    phone_state = next(item['state'] for item in available[runtime] if item['udid'] == device['udid'])
    if phone_state != 'Shutdown':
        run('xcrun', 'simctl', 'shutdown', device['udid'], timeout=90)
    print('UI smoke: starting iPad boot', flush=True)
    run('xcrun', 'simctl', 'boot', pad)
    run('xcrun', 'simctl', 'bootstatus', pad, '-b', timeout=600)
    print('UI smoke: iPad boot completed', flush=True)
    print('UI smoke: installing application on iPad', flush=True)
    run('xcrun', 'simctl', 'install', pad, str(app), timeout=600)
    print('UI smoke: iPad installation completed', flush=True)
    capture_ui(pad, 'recorded', 'ui-ipad', terminate_existing=False)
    capture_ui(pad, 'detail', 'ui-ipad')

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
    if '--no-boot' not in sys.argv:
        run('xcrun', 'simctl', 'boot', device['udid'])
    if '--prepare' in sys.argv:
        sys.exit(0)
else:
    device = json.loads(device_file.read_text())
app = Path('build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app')
if '--ipad-only' in sys.argv:
    capture_ipad(app, device)
    sys.exit(0)
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
    # Keep diagnostics even if a native worker crashes before UI checks finish.
    for name in ['storage-smoke', 'danmaku-smoke', 'pip-composition-smoke', 'pip-player-smoke']:
        for extension in ['json', 'png']:
            source = container / f'Documents/{name}.{extension}'
            if source.exists():
                Path(f'dist/{name}.{extension}').write_bytes(source.read_bytes())
    logs = run('xcrun', 'simctl', 'spawn', device['udid'], 'log', 'show', '--last', '3m',
               '--style', 'compact', '--predicate', 'process == "NeoEPGStation"')
    Path('dist/simulator-crash.log').write_text(logs)
    reports = sorted((Path.home() / 'Library/Logs/DiagnosticReports').glob('NeoEPGStation*.ips'))
    for index, report in enumerate(reports[-3:]):
        Path(f'dist/native-crash-{index}.log').write_bytes(report.read_bytes())
    raise RuntimeError('Application exited after launch; inspect simulator crash logs')
Path('dist/simulator-launch.txt').write_text(f"{device['name']}\n{launch}\nProcess remained running through native rendering tests.\n")
run('xcrun', 'simctl', 'io', device['udid'], 'screenshot', 'dist/simulator.png')
container = Path(run('xcrun', 'simctl', 'get_app_container', device['udid'], 'io.github.nyanz00.NeoEPGStation', 'data'))
storage = json.loads((container / 'Documents/storage-smoke.json').read_text())
Path('dist/storage-smoke.json').write_text(json.dumps(storage, indent=2) + '\n')
if storage.get('success') is not True:
    raise RuntimeError(f"Keychain storage round-trip failed: {storage.get('error')}")
if storage.get('navigationSuccess') is not True:
    raise RuntimeError('Navigation preferences round-trip or invalid-item validation failed')
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

# Further launches check the actual UIKit Release UI and interactive transitions.
# Fixtures are enabled only on the simulator, never in the device application.
del os.environ['SIMCTL_CHILD_NEO_EPG_STORAGE_SMOKE']
for stage in ['recorded', 'pagination', 'detail', 'menu', 'settings', 'gestures']:
    capture_ui(device['udid'], stage, 'ui-iphone')
if '--iphone-only' not in sys.argv:
    capture_ipad(app, device)
