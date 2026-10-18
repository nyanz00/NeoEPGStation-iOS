"""Focused native HTTP TS positioning and comment-start gate verification."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


codec = sys.argv[1] if len(sys.argv) > 1 else 'h264'
assert codec in ('h264', 'mpeg2')
prefix = '' if codec == 'h264' else 'mpeg2-'
dist = Path('dist')
device = json.loads((dist / 'simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data')) / 'Documents'
fixture = documents / 'ts-resume-fixture.ts'
if not shutil.which('ffmpeg'):
    subprocess.check_call(['brew', 'install', 'ffmpeg'], timeout=600)
# Broadcast-like constant mux rate and a nonzero PCR/PTS origin. Unknown native
# HTTP duration exercises the same byte-position fallback as recorded TS PLAY.
subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '90',
    *( ['-c:v', 'libx264', '-preset', 'ultrafast'] if codec == 'h264' else ['-c:v', 'mpeg2video'] ), '-pix_fmt', 'yuv420p',
    '-b:v', '700k', '-maxrate', '700k', '-bufsize', '1400k', '-g', '24',
    '-c:a', 'aac', '-b:a', '64k', '-muxrate', '1500k',
    '-output_ts_offset', '3390', '-f', 'mpegts', str(fixture)], timeout=120)
video = fixture.read_bytes()
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.endswith('/duration'):
            self.json({'duration': 90}); return
        if self.path.endswith('/comments'):
            # A deliberate preparation delay proves the wait setting gates VLC
            # opening, rather than merely hiding an already running overlay.
            time.sleep(1)
            self.json({'isSuccess': True, 'source': 'jikkyo', 'timeBase': 'video',
                'comments': [{'time': i/4, 'text': 'Synthetic 日本語 Comment', 'color': '#FFFFFF',
                    'position': 'right', 'size': 'medium'} for i in range(360)]})
            return
        if self.path != '/api/videos/1':
            self.send_error(404); return
        value = self.headers.get('Range', 'bytes=0-').removeprefix('bytes=')
        begin, end = value.split('-')
        begin = int(begin); end = min(int(end) if end else len(video)-1, len(video)-1)
        if begin >= len(video) or end < begin:
            self.send_error(416); return
        requests.append({'offset': begin, 'bytes': end-begin+1})
        body = video[begin:end+1]
        self.send_response(206)
        self.send_header('Content-Type', 'video/mp2t')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Range', f'bytes {begin}-{end}/{len(video)}')
        self.send_header('Accept-Ranges', 'bytes'); self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
names = ['ts-resume-smoke.json', 'ts-resume-diagnostics.json']
subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
for name in names:
    (documents / name).unlink(missing_ok=True)
try:
    environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_TS_RESUME=f'http://127.0.0.1:{server.server_port}')
    subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
    deadline = time.monotonic()+100
    while not (documents / names[0]).exists() and time.monotonic() < deadline:
        time.sleep(1)
    # The app writes the diagnostic export immediately after the result marker.
    for _ in range(10):
        if (documents / names[1]).exists(): break
        time.sleep(.1)
    for name in names:
        if (documents / name).exists(): shutil.copyfile(documents / name, dist / (prefix+name))
    (dist / (prefix+'ts-resume-ranges.json')).write_text(json.dumps(requests, indent=2))
    result = json.loads((dist / (prefix+names[0])).read_text())
    assert result['success'] and all(result['checks'].values()), result
    diagnostic = json.loads((dist / (prefix+names[1])).read_text())
    events = diagnostic['events']
    warm = next(i for i, event in enumerate(events) if event['event'] == 'comments.previewWarm')
    opened = next(i for i, event in enumerate(events) if event['event'] == 'input.restart')
    assert warm < opened, 'TS input opened before comment textures were prepared'
    arrivals = [e for e in events if e['event'] == 'ts.positionReady']
    assert len(arrivals) >= 4, arrivals
    assert all(e.get("nativeClockConfirmed") and e.get("newVideo") for e in arrivals), arrivals
    assert all(abs(e['nativeMs']-e['targetMs']) <= 2000 for e in arrivals), arrivals
    assert any(e['event'] == 'ts.positionRequested' and e['bytes'] for e in events), 'Unknown-duration TS fallback not exercised'
    print(f"PASS: {len(result['checks'])} native TS assertions, comment gate, retained paused repair and verified output arrivals", flush=True)
finally:
    server.shutdown()
