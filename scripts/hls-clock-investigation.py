"""Investigation only: unchanged VLCKit, controlled HLS origins, optional seek."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import hashlib
import zipfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def run(args, timeout=120, **kwargs):
    return subprocess.run(args, check=True, timeout=timeout, **kwargs)


dist = Path('dist')
dist.mkdir(exist_ok=True)
device = json.loads((dist / 'simulator-device.json').read_text())['udid']
run(['xcrun', 'simctl', 'bootstatus', device, '-b'])
app = Path('build/HLSClockProbe.app')
app.mkdir(parents=True, exist_ok=True)
frameworks = app / 'Frameworks'
frameworks.mkdir(exist_ok=True)
source = Path('build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app/Frameworks/VLCKit.framework')
shutil.copytree(source, frameworks / 'VLCKit.framework', dirs_exist_ok=True)
info = dict(CFBundleIdentifier='io.github.nyanz00.HLSClockProbe', CFBundleExecutable='HLSClockProbe',
            CFBundleName='HLSClockProbe', CFBundlePackageType='APPL', CFBundleVersion='1',
            CFBundleShortVersionString='1.0', MinimumOSVersion='18.0', LSRequiresIPhoneOS=True,
            UIDeviceFamily=[1, 2], UILaunchScreen={},
            NSAppTransportSecurity={'NSAllowsArbitraryLoads': True, 'NSAllowsLocalNetworking': True})
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-arch', 'arm64', '-mios-simulator-version-min=18.0',
     '-isysroot', sdk, '-fobjc-arc', '-F'+str(frameworks), '-framework', 'UIKit', '-framework', 'QuartzCore',
     '-framework', 'VLCKit', '-Wl,-rpath,@executable_path/Frameworks', 'tests/hls-clock-probe/main.m',
     '-o', str(app / 'HLSClockProbe')])
run(['codesign', '--force', '--deep', '--sign', '-', str(app)])
run(['xcrun', 'simctl', 'install', device, str(app)])
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device,
                                        'io.github.nyanz00.HLSClockProbe', 'data'], text=True).strip())
documents = container / 'Documents'
documents.mkdir(exist_ok=True)
root = dist / 'clock-fixtures'
root.mkdir(exist_ok=True)
archive = Path('tests/hls-clock-probe/fixtures.zip')
expected = archive.with_suffix('.sha256').read_text().split()[0]
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
with zipfile.ZipFile(archive) as fixtures:
    for name in fixtures.namelist():
        assert not Path(name).is_absolute() and '..' not in Path(name).parts
    fixtures.extractall(root)
probes = json.loads((root / 'origins.json').read_text())
(dist / 'hls-timestamp-origins.json').write_text(json.dumps(probes, indent=2))
print('Timestamp origins:', json.dumps(probes), flush=True)
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        parts = path.strip('/').split('/')
        if len(parts) != 3 or parts[1] not in probes:
            self.send_error(404)
            return
        variant, name = parts[1:]
        requests.append(dict(case=variant, path=name, at=time.monotonic()))
        if name.startswith('playlist'):
            text = (root / 'full/playlist.m3u8').read_text()
            lines = ['#EXTM3U']
            if name != 'playlist-zero.m3u8':
                lines.append('#EXT-X-START:TIME-OFFSET=49,PRECISE=YES')
            for line in text.splitlines()[1:]:
                lines.append(line if line.startswith('#') else '/case/'+variant+'/'+line)
            data = ('\n'.join(lines)+'\n').encode()
            mime = 'application/vnd.apple.mpegurl'
        else:
            file = root / variant / name
            if not file.is_file():
                file = root / 'full' / name
            if not file.is_file():
                self.send_error(404)
                return
            data, mime = file.read_bytes(), 'video/mp2t'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
cases = [('full-default-mux', False, False), ('full-default-mux', True, False),
         ('nvenc-absolute', False, False), ('nvenc-absolute', True, False),
         ('nvenc-default-mux', False, False), ('nvenc-default-mux', True, False),
         ('x264-bframes-absolute', False, False), ('x264-bframes-default-mux', False, False),
         ('remux-absolute', False, False), ('remux-copyts', False, False),
         ('remux-copyts', True, False), ('remux-copyts-zero', False, False)]
results = []
try:
    for variant, seek, zero in cases:
        label = variant+('-seek' if seek else '-no-seek')+('-from-zero' if zero else '')
        result_file = documents / 'clock-probe.json'
        result_file.unlink(missing_ok=True)
        playlist = 'playlist-zero.m3u8' if zero else 'playlist.m3u8'
        env = dict(os.environ, SIMCTL_CHILD_HLS_PROBE_URL=f'http://127.0.0.1:{server.server_port}/case/{variant}/{playlist}',
                   SIMCTL_CHILD_HLS_PROBE_SEEK='1' if seek else '0')
        began = time.time()
        print('START', label, flush=True)
        with (dist / (label+'.log')).open('w') as output:
            process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process',
                                        device, 'io.github.nyanz00.HLSClockProbe'], env=env, stdout=output, stderr=output)
            try:
                code = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                subprocess.run(['xcrun', 'simctl', 'terminate', device, 'io.github.nyanz00.HLSClockProbe'], capture_output=True)
                process.kill()
                code = -999
        data = json.loads(result_file.read_text()) if result_file.exists() else {'finished': False, 'rows': []}
        (dist / (label+'.json')).write_text(json.dumps(data, indent=2))
        samples = [r for r in data['rows'] if r['event'] == 'sample']
        console = (dist / (label+'.log')).read_text(errors='replace')
        result = dict(case=label, finished=data['finished'], exitCode=code,
                      matchingAssertion='input_normal_time >= VLC_TICK_0' in console, samples=len(samples),
                      first=samples[0] if samples else None, last=samples[-1] if samples else None,
                      seeks=[r for r in data['rows'] if r['event']=='seek'])
        results.append(result)
        print('RESULT', json.dumps(result), flush=True)
        crashes = Path.home() / 'Library/Logs/DiagnosticReports'
        for report in crashes.glob('HLSClockProbe*.ips'):
            if report.stat().st_mtime >= began:
                shutil.copyfile(report, dist / (label+'-'+report.name))
finally:
    server.shutdown()
    (dist / 'clock-investigation-results.json').write_text(json.dumps(results, indent=2))
    (dist / 'clock-investigation-requests.json').write_text(json.dumps(requests, indent=2))
assert len(results) == len(cases), 'Investigation did not exercise every case'
assert results[0]['finished'] and results[1]['finished'], 'Reference timeline failed; do not interpret other cases'
print('Completed controlled clock investigation; crashes in non-reference cases are observations, not passing playback.', flush=True)
