"""Use the shipping comparison screen against a real synthetic Range origin."""
import json
import math
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
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
        ranged = self.headers.get('Range')
        try:
            begin, end = byte_range(ranged, len(video))
        except ValueError:
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
reference_root = Path('tests/fixtures/aether-seek-reference')
references = json.loads((reference_root/'manifest.json').read_text())['fixtures']
checker = Path('dist/aether-picture-check').resolve()
if not checker.exists(): run('xcrun', 'swiftc', 'scripts/check-aether-picture.swift', '-o', str(checker))
inspect = os.environ.get('AETHER_INSPECT_RENDERER') == '1'
if inspect:
    sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    run('xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios18.0-simulator',
        '-isysroot', sdk, 'scripts/aether-renderer-inspect.m', '-o', 'dist/aether-renderer-inspect.dylib',
        '-framework', 'UIKit', '-framework', 'AVFoundation', '-framework', 'CoreImage', '-framework', 'CoreVideo',
        '-framework', 'CoreGraphics', '-framework', 'CoreFoundation', '-framework', 'QuartzCore', '-framework', 'Foundation', '-framework', 'IOSurface')
    run('codesign', '--force', '--sign', '-', 'dist/aether-renderer-inspect.dylib')
fixtures = (os.environ['AETHER_FIXTURE'],) if os.environ.get('AETHER_FIXTURE') else (('hevc-seek-10.mkv',) if inspect else ('encoded-seek-1080.mkv', 'hevc-seek-10.mkv', 'av1-seek-10.mkv'))
assert set(fixtures) <= set(references), 'Unknown synthetic fixture'
checkpoint_player = '--checkpoint-player' in sys.argv
if checkpoint_player: fixtures = ('av1-seek-10.mkv', 'av1-seek-10-gop6.mkv')
seek_work = '--seek-work' in sys.argv
cases = ([(fixture, baseline) for fixture in fixtures for baseline in (False, True)] if checkpoint_player else ([(fixtures[0], True)] if seek_work else []) + [(fixture, False) for fixture in fixtures])
print('Aether fixture scope:', cases, flush=True)
try:
    for fixture, baseline in cases:
        case_name = fixture + (('-checkpoint-off' if baseline else '-checkpoint-on') if checkpoint_player else ('-ui-baseline' if baseline else ''))
        try:
            video = Path('tests/fixtures', fixture).read_bytes(); transferred = requests = 0
            assert hashlib.sha256(video).hexdigest() == references[fixture]['sha256']
            for target, digest in references[fixture]['references'].items():
                assert hashlib.sha256((reference_root/(fixture+'-'+target+'.png')).read_bytes()).hexdigest() == digest
            subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
            names = ['aether-comparison-smoke.json', 'aether-comparison-diagnostics.json']
            (documents/'aether-comparison-picture.png').unlink(missing_ok=True)
            for index in range(11 if checkpoint_player else 5): (documents/f'aether-seek-{index}.png').unlink(missing_ok=True)
            for name in names:
                (documents/name).unlink(missing_ok=True)
            environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_AETHER_COMPARE=f'http://127.0.0.1:{server.server_port}', SIMCTL_CHILD_NEO_EPG_AETHER_UI_BASELINE='1' if baseline else '0')
            if checkpoint_player:
                environment['SIMCTL_CHILD_NEO_EPG_CHECKPOINT_COMPARE'] = 'off' if baseline else 'on'
                environment['SIMCTL_CHILD_NEO_EPG_CHECKPOINT_SHORT_GOP'] = '1' if '-gop6' in fixture else '0'
                environment['SIMCTL_CHILD_NEO_EPG_AETHER_UI_BASELINE'] = '0'
            if inspect:
                environment['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] = str(Path('dist/aether-renderer-inspect.dylib').resolve())
                for extra in ('aether-renderer-inspection.json', 'aether-renderer-picture.png'):
                    (documents/extra).unlink(missing_ok=True)
            # Synthetic sources only: collect the engine's release-visible routing and
            # renderer diagnostics. No real server URL or credentials enter this log.
            with Path('dist', case_name+'-aether-engine.log').open('w') as log:
                observer = subprocess.Popen(['xcrun', 'simctl', 'spawn', device, 'log', 'stream',
                    '--style', 'compact', '--level', 'info', '--predicate',
                    'subsystem == "de.superuser404.AetherEngine"'], stdout=log, stderr=log)
                try:
                    subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
                    deadline = time.monotonic()+(240 if checkpoint_player else 180)
                    while not all((documents/name).exists() for name in names) and time.monotonic()<deadline:
                        if inspect and (documents/'aether-renderer-inspection.json').exists(): break
                        time.sleep(.5)
                finally:
                    observer.terminate()
                    try: observer.wait(timeout=5)
                    except subprocess.TimeoutExpired: observer.kill(); observer.wait()
            for name in names:
                if (documents/name).exists():
                    shutil.copyfile(documents/name, Path('dist', case_name+'-'+name))
            if inspect:
                for extra in ('aether-renderer-inspection.json', 'aether-renderer-picture.png'):
                    if (documents/extra).exists(): shutil.copyfile(documents/extra, Path('dist', case_name+'-'+extra))
            picture = documents/'aether-comparison-picture.png'
            if picture.exists(): shutil.copyfile(picture, Path('dist', case_name+'-aether-picture.png'))
            assert picture.exists(), 'No actual output picture for '+fixture
            stats = json.loads(run(str(checker), str(picture)))
            assert stats['nonBlack'], 'Black/flat picture for '+fixture
            result = json.loads((documents/names[0]).read_text())
            events = json.loads((documents/names[1]).read_text())['events']
            resumes = [e for e in events if e['event'] == 'seek.videoResume']
            assert any(e['event']=='aether.binaryABI' and e['compatible'] for e in events), 'FFmpeg header/binary ABI'
            assert all(e['verification'] in ('displayedPixelBuffer', 'nativePixelBuffer') for e in resumes)
            decoded = [e for e in events if e['event']=='aether.seekDecodedTarget']
            assert all(e['displayTimeVerified'] is False and 'durationMs' not in e for e in decoded)
            a, b = (22, 34) if '-gop6' in fixture else (20, 30)
            targets = (a, 40, b, a, b) + ((a, 40, b, a, 40, b) if checkpoint_player else ())
            assert len(resumes)+len(decoded) == len(targets)
            assert all(abs(e['mediaMs']-e['targetMs'])<500 for e in resumes)
            assert all(abs(e['decodedMs']-e['targetMs'])<500 for e in decoded)
            for index in range(len(targets)):
                captured = documents/f'aether-seek-{index}.png'
                if captured.exists(): shutil.copyfile(captured, Path('dist', case_name+f'-seek-{index}.png'))
            picture_checks = []
            for index, target in enumerate(targets):
                captured = documents/f'aether-seek-{index}.png'
                assert captured.exists(), 'No actual target image'
                shutil.copyfile(captured, Path('dist', case_name+f'-seek-{index}.png'))
                match = json.loads(run(str(checker), str(captured), str(reference_root), fixture, str(target)))
                assert match['targetMatches'], (fixture, index, target, match)
                picture_checks.append(match)
            if fixture.startswith('av1'):
                decisions = [e.get('decision') for e in events if e['event']=='aether.engineDecision']
                hardware = next(e['av1'] for e in events if e['event']=='aether.hardware')
                assert ('decoder-checkpoint-dav1d' if checkpoint_player else ('av1-native-route' if hardware else 'decoder-libdav1d')) in decisions, decisions
            ui = next((e for e in events if e['event']=='aether.uiSummary'), None)
            if seek_work:
                assert ui and ui['ticks'] > 0 and ui['uiThrottled'] == (not baseline), ui
                if baseline: assert ui['playbackUpdates'] == ui['ticks'] and ui['diagnosticUpdates'] == ui['ticks'], ui
                else: assert ui['playbackUpdates'] < ui['ticks']/3 and ui['diagnosticUpdates'] < ui['ticks']/3, ui
                samples = [e for e in events if e['event']=='aether.seekSnapshot']
                assert {e.get('originSeek') for e in samples} == {1, 2, 3, 4, 5} and all('requestedAfterSeekMs' in e for e in samples), samples
                route = next(e['route'] for e in reversed(events) if e['event']=='aether.route')
                if route == 'loopback':
                    native = [e for e in samples if e.get('avSampleAvailable')==1]
                    assert native and all('targetResident' in e and 'serverRequests' in e and 'segmentOffsetMs' in e for e in native), samples
                else: assert all(e.get('avSampleAvailable')==0 for e in samples), samples
                assert len([e for e in events if e['event']=='aether.seekUIWork']) == 5
            if checkpoint_player:
                configurations = [e for e in events if e['event']=='checkpoint.configuration']
                assert configurations and configurations[-1]['enabled'] == (not baseline)
                caches = [e for e in events if e['event']=='checkpoint.cache']
                assert caches and all(e['heldBytes'] <= 128*1024*1024 for e in caches)
                assert not any(e['event']=='checkpoint.fallback' for e in events)
                anchors = [e for e in events if e['event']=='aether.cacheSeekAnchor']
                assert len(anchors) >= 2 and any(e['videoKeyMs'] > 1000 for e in anchors), anchors
                assert all(e['independent']==1 and e['videoKeyMs']<=e['targetMs'] for e in anchors), anchors
                assert all(99<=e['videoKeyMs']-e['audioStartMs']<=600
                           for e in anchors if e['videoKeyMs']>1000), anchors
                if not baseline:
                    restored = [e for e in events if e['event']=='checkpoint.restored' and e['status']==0]
                    assert len(restored)>=2, restored
                    rejected = [e for e in events if e['event']=='checkpoint.probeRejection']
                    recoveries = [e for e in events if e['event']=='checkpoint.recovery']
                    assert len(rejected)==len(recoveries)==1, (rejected, recoveries)
                    assert recoveries[0]['reason']==7 and recoveries[0]['action']=='ordinary-seek-once'
                    assert sum(e['elapsed']>recoveries[0]['elapsed'] for e in restored)>=2, restored
                    placed = [e for e in events if e['event']=='checkpoint.saved' and e.get('stored') and e.get('provisional') is False]
                    assert placed, 'No checkpoints placed using known bounding keyframes'
                    assert all(e['nearestSavedGapMs'] == -1 or e['nearestSavedGapMs'] >= e['minimumSpacingMs']
                               for e in events if e['event']=='checkpoint.saved' and e.get('stored')), 'Crowded saved points'
                    for e in placed:
                        span = (e['nextKeyframeMs']-e['keyframeMs'])/1000
                        assert e['keyframeMs'] < e['plannedMs'] < e['nextKeyframeMs']-50, e
                        assert 0<=e['positionMs']-e['plannedMs']<=500, e
                        if e.get('basis') == 'time':
                            count = max(2, math.ceil((span-0.05)/6))
                            ordinal = (e['plannedMs']-e['keyframeMs'])/(span*1000/count)
                            assert 1<=round(ordinal)<count and abs(ordinal-round(ordinal))<0.001, e
                        else:
                            assert e['basis'] in ('decode-cost','midpoint','maximum-gap'), e
                            if e['basis']=='decode-cost': assert e['decodeMs'] >= e['decodeBudgetMs'], e
                    assert any(e['event']=='checkpoint.decodeCost' and e['decodeMs']>0 for e in events)
                    assert any(e['event']=='checkpoint.preroll' for e in events)
                    for e in (e for e in events if e['event']=='checkpoint.seekPlan' and e['hit']):
                        assert e['keyframeMs']<e['checkpointMs']<e['targetMs']-50, e
                    assert any(e['event']=='checkpoint.saved' and e['source']=='lookahead' for e in events)
                else: assert not any(e['event'] in ('checkpoint.saved', 'checkpoint.recovery', 'checkpoint.probeRejection') for e in events)
            assert result['success'] and all(result['checks'].values()), result
            assert not any(e['event'] in ('aether.failure', 'aether.seekFailed', 'seek.timeout') for e in events), events[-10:]
            results.append({'fixture': fixture, 'uiBaseline': baseline, 'uiWork': ui, 'success': True, 'checks': result['checks'],
                            'seekMs': [e['durationMs'] for e in resumes], 'decodedTargetReadyMs': [e['decodeReadyMs'] for e in decoded],
                            'displayTimingVerified': len(resumes)==len(targets), 'targetImagesVerified': len(picture_checks), 'pictureChecks': picture_checks, 'originBytes': transferred, 'originRequests': requests})
        except Exception as error:
            results.append({'fixture': fixture, 'uiBaseline': baseline, 'success': False, 'failure': type(error).__name__+': '+str(error)[:900]})
            print(fixture, 'FAIL', type(error).__name__, str(error)[:300], flush=True)

finally:
    server.shutdown()
    Path('dist/aether-comparison-results.json').write_text(json.dumps({'success': len(results)==len(cases) and all(r['success'] for r in results), 'requestedFixtures': list(fixtures), 'seekWorkComparison': seek_work,
        'cases': results, 'hardwarePerformanceVerified': False}, indent=2)+'\n')

if len(results)!=len(cases) or not all(r['success'] for r in results): raise SystemExit(1)
