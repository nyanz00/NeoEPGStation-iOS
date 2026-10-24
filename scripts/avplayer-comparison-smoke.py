"""Exercise direct MP4 playback over HTTP Range, including real target images."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http_byte_range import byte_range


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


device = json.loads(Path('dist/simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
run('xcrun', 'simctl', 'install', device, 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app', timeout=300)
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data'))/'Documents'
documents.mkdir(exist_ok=True)
video = b''
transferred = requests = 0
paths = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_HEAD(self): self.respond(True)
    def do_GET(self): self.respond(False)
    def respond(self, head):
        global transferred, requests
        paths.add(self.path)
        if self.path != '/api/videos/1/web':
            self.send_error(404); return
        ranged = self.headers.get('Range')
        try: begin, end = byte_range(ranged, len(video))
        except ValueError:
            self.send_response(416); self.send_header('Content-Range', f'bytes */{len(video)}'); self.end_headers(); return
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Type', 'video/mp4'); self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end-begin+1))
        if ranged: self.send_header('Content-Range', f'bytes {begin}-{end}/{len(video)}')
        self.end_headers(); requests += 1
        if head: return
        try:
            for offset in range(begin, end+1, 65536):
                body = video[offset:min(end+1, offset+65536)]
                self.wfile.write(body); transferred += len(body)
        except (BrokenPipeError, ConnectionResetError): pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []
reference_root = Path('tests/fixtures/aether-seek-reference')
references = json.loads((reference_root/'manifest.json').read_text())['fixtures']
checker = Path('dist/aether-picture-check').resolve()
if not checker.exists(): run('xcrun', 'swiftc', 'scripts/check-aether-picture.swift', '-o', str(checker))
# Simulator does not establish AV1 hardware support. AV1 remains a physical-device comparison.
fixtures = ('encoded-seek-1080.mp4', 'hevc-seek-10.mp4')
try:
    for fixture in fixtures:
        try:
            video = Path('tests/fixtures', fixture).read_bytes(); transferred = requests = 0; paths.clear()
            if fixture.startswith('hevc'):
                # This remux retains AAC's 21 ms lead: at exact integer item
                # times AVPlayer presents the preceding source frame. Compare
                # against MP4-time references, not MKV's zero-origin counter.
                reference_root = Path('tests/fixtures/avplayer-seek-reference'); reference = fixture
                manifest = json.loads((reference_root/'manifest.json').read_text())
                assert hashlib.sha256(video).hexdigest() == manifest['sha256']
                for target, row in manifest['references'].items():
                    assert hashlib.sha256((reference_root/(reference+'-'+target+'.png')).read_bytes()).hexdigest() == row['sha256']
            else:
                reference_root = Path('tests/fixtures/aether-seek-reference'); reference = fixture.replace('.mp4', '.mkv')
                assert hashlib.sha256(Path('tests/fixtures', reference).read_bytes()).hexdigest() == references[reference]['sha256']
                for target, digest in references[reference]['references'].items():
                    assert hashlib.sha256((reference_root/(reference+'-'+target+'.png')).read_bytes()).hexdigest() == digest
            subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
            names = ['avplayer-comparison-smoke.json', 'avplayer-comparison-diagnostics.json', 'avplayer-startup.png']
            names += [f'avplayer-seek-{i}.png' for i in range(5)]
            for name in names: (documents/name).unlink(missing_ok=True)
            environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_AVPLAYER_COMPARE=f'http://127.0.0.1:{server.server_port}')
            subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
            deadline = time.monotonic()+130
            while not (documents/names[1]).exists() and time.monotonic()<deadline: time.sleep(.5)
            for name in names:
                if (documents/name).exists(): shutil.copyfile(documents/name, Path('dist', fixture+'-'+name))
            result = json.loads((documents/names[0]).read_text())
            events = json.loads((documents/names[1]).read_text())['events']
            assert result['success'] and all(result['checks'].values()), result
            assert paths == {'/api/videos/1/web'}, paths
            assert any(e['event']=='player.engine' and e['engine']=='avplayer-direct' for e in events)
            resumes = [e for e in events if e['event']=='seek.videoResume']
            assert len(resumes)==5 and all(e['verification']=='nativePixelBuffer' and abs(e['mediaMs']-e['targetMs'])<500 for e in resumes)
            assert len([e for e in events if e['event']=='avplayer.seekCompleted' and e['finished']])==5
            assert not any(e['event'] in ('avplayer.failure', 'seek.timeout') or e['event'].startswith('aether.') for e in events)
            picture_checks = []
            for i, target in enumerate((20, 40, 30, 20, 30)):
                match = json.loads(run(str(checker), str(documents/f'avplayer-seek-{i}.png'), str(reference_root), reference, str(target)))
                assert match['targetMatches'], (fixture, i, match)
                picture_checks.append(match)
            results.append({'fixture': fixture, 'success': True, 'checks': result['checks'], 'pictureChecks': picture_checks,
                            'seekMs': [e['durationMs'] for e in resumes], 'originBytes': transferred, 'originRequests': requests})
        except Exception as error:
            results.append({'fixture': fixture, 'success': False, 'failure': type(error).__name__+': '+str(error)[:900]})
            print(fixture, 'FAIL', str(error)[:400], flush=True)
finally:
    server.shutdown()
    Path('dist/avplayer-comparison-results.json').write_text(json.dumps({'success': len(results)==len(fixtures) and all(r['success'] for r in results),
        'cases': results, 'hardwarePerformanceVerified': False, 'av1DeviceCheckRequired': True}, indent=2)+'\n')
if len(results)!=len(fixtures) or not all(r['success'] for r in results): raise SystemExit(1)
