"""Investigation only: unchanged VLCKit, controlled HLS origins, optional seek."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=120, **kwargs)


dist = Path('dist')
dist.mkdir(exist_ok=True)
device = json.loads((dist / 'simulator-device.json').read_text())['udid']
run(['xcrun', 'simctl', 'bootstatus', device, '-b'])
if not shutil.which('ffmpeg'):
    run(['brew', 'install', 'ffmpeg'])
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
ff = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y']
movie = root / 'source.mp4'
run(ff + ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25', '-f', 'lavfi', '-i',
          'sine=sample_rate=48000', '-t', '70', '-c:v', 'libx264', '-preset', 'ultrafast',
          '-g', '100', '-c:a', 'aac', str(movie)])
for name, start, offset in [('full', 0, 0), ('rebased-absolute', 48, 48), ('rebased-relative', 48, 0)]:
    out = root / name
    out.mkdir(exist_ok=True)
    run(ff + ['-ss', str(start), '-i', str(movie), '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '100',
              '-force_key_frames', 'expr:gte(t,n_forced*4)', '-c:a', 'aac', '-muxdelay', '0', '-muxpreload', '0',
              '-f', 'hls', '-hls_time', '4', '-hls_list_size', '0', '-hls_playlist_type', 'vod',
              '-hls_segment_type', 'mpegts', '-hls_flags', 'independent_segments', '-start_number', str(start//4),
              '-output_ts_offset', str(offset), '-hls_segment_filename', str(out / '%d.ts'), str(out / 'playlist.m3u8')])
out = root / 'remux-absolute'
out.mkdir(exist_ok=True)
# TS STREAMING performs a second MPEG-TS -> HLS copy mux. Inspect whether this
# mux preserves the original absolute recording timestamps without -copyts.
run(ff + ['-i', str(root / 'rebased-absolute/playlist.m3u8'), '-map', '0', '-c', 'copy',
          '-hls_time', '4', '-hls_list_size', '0', '-hls_playlist_type', 'vod', '-hls_segment_type', 'mpegts',
          '-hls_flags', 'independent_segments', '-start_number', '12', '-hls_segment_filename', str(out / '%d.ts'),
          str(out / 'playlist.m3u8')])
probes = {}
for name in ['full', 'rebased-absolute', 'rebased-relative', 'remux-absolute']:
    index = 0 if name == 'full' else 12
    probes[name] = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
                    'format=start_time,duration', '-of', 'json', str(root/name/f'{index}.ts')], text=True))
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
cases = [(name, seek, False) for name in probes for seek in [False, True]]
cases += [('rebased-relative', True, True)]
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
        result = dict(case=label, finished=data['finished'], exitCode=code, samples=len(samples),
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
