"""Repeated accurate cached seeks before/after an encoded PLAY resume point."""
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
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
    av1 = '--av1' in sys.argv
    compare = '--compare-preroll' in sys.argv
    comparisons = []
    containers = ('av1-seek-8.mkv', 'av1-seek-10.mkv', 'av1-seek-8.mp4', 'av1-seek-10.mp4') if av1 else ('mkv', 'mp4')
    cases = [(c, False, c) for c in containers]
    if compare:
        # Paired runs of the same 1080p/24fps, 24-second GOP input and targets.
        # Reverse order for MP4 to avoid attributing process warm-up to the patch.
        cases = [(f'encoded-seek-1080.{ext}', baseline, f'1080-{ext}-{label}')
                 for ext, modes in [('mkv', [('baseline', True), ('optimized', False)]),
                                    ('mp4', [('optimized', False), ('baseline', True)])]
                 for label, baseline in modes]
    for container, baseline, output_name in cases:
        # Deliberately sparse keyframes (24s), not an all-intra/short-GOP clip.
        # Exact targets between them must be retained; fast approximate seeking
        # could look faster while landing on a different picture.
        video = Path(f'tests/fixtures/{container}' if av1 or compare else f'tests/fixtures/encoded-seek.{container}').read_bytes()
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
        names = ['encoded-seek-smoke.json', 'encoded-seek-diagnostics.json']
        for name in names:
            (documents / name).unlink(missing_ok=True)
        environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_ENCODED_SEEK=f'http://127.0.0.1:{server.server_port}')
        environment['SIMCTL_CHILD_NEO_EPG_PREROLL_BASELINE'] = '1' if baseline else '0'
        subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
        deadline = time.monotonic()+90
        while not all((documents / name).exists() for name in names) and time.monotonic() < deadline:
            time.sleep(.5)
        for name in names:
            if (documents / name).exists():
                shutil.copyfile(documents / name, dist / f'{output_name}-{name}')
        result = json.loads((dist / f'{output_name}-{names[0]}').read_text())
        diagnostic = json.loads((dist / f'{output_name}-{names[1]}').read_text())
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
        if av1:
            # The real OS result controls the expected path. On simulator this
            # normally proves dav1d fallback, not AV1 hardware performance.
            capability = [e for e in events if e['event'] == 'vlc.av1Preflight']
            assert capability and all(e['hardwareSupported'] == capability[0]['hardwareSupported'] for e in capability)
            decisions = diagnostic['decoderDecisions']
            assert decisions, 'The bundled native decoder extension was not reached'
            videos = [e for e in diagnostic['decoders'] if e['kind'] == 'video decoder']
            if not capability[0]['hardwareSupported']:
                assert all(e['module'] == 'dav1d' and e['acceleration'] == 'software' for e in videos), videos
                assert all(e['decision'] == 'capability' and e['value'] == 0 for e in decisions), decisions
            else:
                assert all(e['module'] in ('videotoolbox', 'dav1d') for e in videos), videos
                assert any(e['decision'] == 'hardware' or e['decision'] == 'fallback' for e in decisions), decisions
                assert all(e['acceleration'] == 'hardware' for e in videos if e['module'] == 'videotoolbox'), videos
            # Module/session selection is per input, never per cached seek.
            assert not any(1 <= e['seek'] <= 7 for e in decisions), decisions
            print(container, 'OS AV1 hardware:', capability[0]['hardwareSupported'], 'actual:', videos, flush=True)
        gates = [e for e in events if e['event'] == 'audio.primeGate']
        assert gates and all(e['actualMute'] == 1 for e in gates), gates
        releases = [e for e in events if e['event'] == 'audio.primeReleased' and not e['wantsPlayback']]
        assert releases and all(e['paused'] for e in releases), releases
        starts = [e for e in events if e['event'] == 'seek.start']
        assert len(starts) == 8 and any(e['targetMs'] < 30000 for e in starts), starts
        seeks = [row for row in result['rows'] if 'phase' in row]
        assert all(row['networkBytes'] == 0 for row in seeks), seeks
        if compare:
            preroll = [e for e in events if e['event'] == 'vlc.prerollReady' and 1 <= e['seek'] <= 8]
            assert len(preroll) >= 6 and all(e['frames'] > 0 for e in preroll), preroll
            assert all(e['optimized'] != baseline for e in preroll), preroll
            if baseline:
                assert all(e['noOutput'] == 0 for e in preroll) and sum(e['pictures'] for e in preroll) > 100, preroll
            else:
                assert all(e['noOutput'] > 0 and e['pictures'] == 0 for e in preroll), preroll
            comparisons.append({'case': output_name, 'baseline': baseline,
                                'seekToVideoMs': [row['videoReadyMs'] for row in seeks],
                                'prerollMs': [e['durationMs'] for e in preroll],
                                'suppressedImages': sum(e['noOutput'] for e in preroll),
                                'wrappedImages': sum(e['pictures'] for e in preroll)})
        print(output_name, 'PASS', len(result['checks']), 'assertions; exact cached seek-to-video ms:',
              [round(row['videoReadyMs']) for row in seeks], flush=True)
    if compare:
        summary = []
        for ext in ('mkv', 'mp4'):
            before = next(c for c in comparisons if c['case'] == f'1080-{ext}-baseline')
            after = next(c for c in comparisons if c['case'] == f'1080-{ext}-optimized')
            summary.append({'container': ext,
                            'baselineMedianMs': statistics.median(before['seekToVideoMs']),
                            'optimizedMedianMs': statistics.median(after['seekToVideoMs']),
                            'baselinePrerollMedianMs': statistics.median(before['prerollMs']),
                            'optimizedPrerollMedianMs': statistics.median(after['prerollMs'])})
        (dist / 'preroll-comparison.json').write_text(json.dumps({'runs': comparisons, 'summary': summary}, indent=2))
        print('Paired same-binary preroll comparison:', json.dumps(summary), flush=True)
finally:
    server.shutdown()
