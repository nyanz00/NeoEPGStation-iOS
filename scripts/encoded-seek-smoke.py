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
        # Deliberately sparse keyframes (24s), not an all-intra/short-GOP clip.
        # Exact targets between them must be retained; fast approximate seeking
        # could look faster while landing on a different picture.
        video = Path(f'tests/fixtures/encoded-seek.{container}').read_bytes()
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
        assert not any(e['event'] in ('seek.timeout', 'ts.positionFailed') for e in events), events[-15:]
        # Only the explicit paused-recovery probe may reopen after the eight
        # ordinary cached seeks have completed without a new input.
        reloads = [e for e in events if e['event'] == 'input.reloadRequested']
        assert len(reloads) == 1 and reloads[0]['seek'] == 8, reloads
        policies = [e for e in events if e['event'] == 'vlc.decoderPolicy']
        assert policies and all(e['order'] == 'videotoolbox,any' and e['hardwareOnlyVideoToolbox'] for e in policies), policies
        assert any(e['event'] == 'vlc.decoderSearch' for e in events), 'VLC did not apply the requested decoder order'
        assert any(e['kind'] == 'video decoder' and e['module'] != 'other' for e in diagnostic['decoders']), diagnostic['decoders']
        gates = [e for e in events if e['event'] == 'audio.primeGate']
        assert gates and all(e['actualMute'] == 1 for e in gates), gates
        releases = [e for e in events if e['event'] == 'audio.primeReleased' and not e['wantsPlayback']]
        assert releases and all(e['paused'] for e in releases), releases
        starts = [e for e in events if e['event'] == 'seek.start']
        assert len(starts) == 8 and any(e['targetMs'] < 30000 for e in starts), starts
        assert all(row['networkBytes'] == 0 for row in result['rows']), result['rows']
        print(container, 'PASS', len(result['checks']), 'assertions; exact cached seek-to-video ms:',
              [round(row['videoReadyMs']) for row in result['rows']], flush=True)
finally:
    server.shutdown()
