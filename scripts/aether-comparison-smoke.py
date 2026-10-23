"""Use the shipping comparison screen against a real synthetic Range origin."""
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


device = json.loads(Path('dist/simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
run('xcrun', 'simctl', 'install', device, 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app', timeout=300)
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data'))/'Documents'
documents.mkdir(exist_ok=True)
video = b''
transferred = 0
requests = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.respond(True)

    def do_GET(self):
        self.respond(False)

    def respond(self, head):
        global transferred, requests
        if self.path != '/api/videos/1':
            self.send_error(404); return
        begin, end = 0, len(video)-1
        ranged = self.headers.get('Range')
        if ranged:
            first, last = ranged.removeprefix('bytes=').split('-')
            begin, end = int(first), min(int(last) if last else end, end)
        if begin > end or begin >= len(video):
            self.send_response(416); self.send_header('Content-Range', f'bytes */{len(video)}'); self.end_headers(); return
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Type', 'video/x-matroska')
        self.send_header('Content-Length', str(end-begin+1))
        self.send_header('Accept-Ranges', 'bytes')
        if ranged:
            self.send_header('Content-Range', f'bytes {begin}-{end}/{len(video)}')
        self.end_headers(); requests += 1
        if head:
            return
        try:
            for offset in range(begin, end+1, 65536):
                body = video[offset:min(end+1, offset+65536)]
                self.wfile.write(body); transferred += len(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []
try:
    for fixture in ('encoded-seek-1080.mkv', 'hevc-seek-10.mkv', 'av1-seek-10.mkv'):
        video = Path('tests/fixtures', fixture).read_bytes(); transferred = requests = 0
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
        names = ['aether-comparison-smoke.json', 'aether-comparison-diagnostics.json']
        for name in names:
            (documents/name).unlink(missing_ok=True)
        environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_AETHER_COMPARE=f'http://127.0.0.1:{server.server_port}')
        subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
        deadline = time.monotonic()+100
        while not all((documents/name).exists() for name in names) and time.monotonic()<deadline:
            time.sleep(.5)
        for name in names:
            if (documents/name).exists():
                shutil.copyfile(documents/name, Path('dist', fixture+'-'+name))
        result = json.loads((documents/names[0]).read_text())
        events = json.loads((documents/names[1]).read_text())['events']
        resumes = [e for e in events if e['event'] == 'seek.videoResume']
        assert len(resumes) == 5 and all(abs(e['mediaMs']-e['targetMs'])<500 for e in resumes), resumes
        assert result['success'] and all(result['checks'].values()), result
        assert not any(e['event'] in ('aether.failure', 'aether.seekFailed', 'seek.timeout') for e in events), events[-10:]
        results.append({'fixture': fixture, 'success': True, 'checks': result['checks'],
                        'seekMs': [e['durationMs'] for e in resumes], 'originBytes': transferred, 'originRequests': requests})
finally:
    server.shutdown()
    Path('dist/aether-comparison-results.json').write_text(json.dumps({'success': len(results)==3,
        'cases': results, 'hardwarePerformanceVerified': False}, indent=2)+'\n')
