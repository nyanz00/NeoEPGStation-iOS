"""Repeated accurate cached seeks before/after an encoded PLAY resume point."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


dist = Path('dist')
device = json.loads((dist / 'simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
run('xcrun', 'simctl', 'install', device, 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app', timeout=300)
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data')) / 'Documents'
documents.mkdir(exist_ok=True)
if not shutil.which('ffmpeg'):
    subprocess.check_call(['brew', 'install', 'ffmpeg'], timeout=600)

video = b''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.endswith('/duration'):
            body = b'{"duration":72}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Type', 'application/json')
            self.end_headers(); self.wfile.write(body); return
        if self.path != '/api/videos/1':
            self.send_error(404); return
        value = self.headers.get('Range', 'bytes=0-').removeprefix('bytes=')
        begin, end = value.split('-')
        begin = int(begin); end = min(int(end) if end else len(video)-1, len(video)-1)
        if begin >= len(video) or end < begin:
            self.send_error(416); return
        self.send_response(206)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(end-begin+1))
        self.send_header('Content-Range', f'bytes {begin}-{end}/{len(video)}')
        self.send_header('Accept-Ranges', 'bytes'); self.end_headers()
        try:
            self.wfile.write(video[begin:end+1])
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    for container in ('mkv', 'mp4'):
        fixture = documents / f'encoded-seek-fixture.{container}'
        # Deliberately sparse keyframes (24s), not an all-intra/short-GOP clip.
        # Exact targets between them must be retained; fast approximate seeking
        # could look faster while landing on a different picture.
        subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '72',
            '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-b:v', '200k',
            '-g', '576', '-keyint_min', '576', '-sc_threshold', '0', '-bf', '3',
            '-c:a', 'aac', '-b:a', '64k',
            *(['-movflags', '+faststart'] if container == 'mp4' else []), str(fixture)], timeout=180)
        video = fixture.read_bytes()
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
        names = ['encoded-seek-smoke.json', 'encoded-seek-diagnostics.json']
        for name in names:
            (documents / name).unlink(missing_ok=True)
        environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_ENCODED_SEEK=f'http://127.0.0.1:{server.server_port}')
        subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
        deadline = time.monotonic()+90
        while not all((documents / name).exists() for name in names) and time.monotonic() < deadline:
            time.sleep(.5)
        for name in names:
            if (documents / name).exists():
                shutil.copyfile(documents / name, dist / f'{container}-{name}')
        result = json.loads((dist / f'{container}-{names[0]}').read_text())
        diagnostic = json.loads((dist / f'{container}-{names[1]}').read_text())
        assert result['success'] and all(result['checks'].values()), result
        events = diagnostic['events']
        assert not any(e['event'] in ('input.reloadRequested', 'seek.timeout', 'ts.positionFailed') for e in events), events[-15:]
        starts = [e for e in events if e['event'] == 'seek.start']
        assert len(starts) == 8 and any(e['targetMs'] < 30000 for e in starts), starts
        assert all(row['networkBytes'] == 0 for row in result['rows']), result['rows']
        print(container, 'PASS', len(result['checks']), 'assertions; exact cached seek-to-video ms:',
              [round(row['videoReadyMs']) for row in result['rows']], flush=True)
finally:
    server.shutdown()
