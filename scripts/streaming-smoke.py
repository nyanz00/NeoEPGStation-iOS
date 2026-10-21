"""Real VLC HLS: full recording clock, seeking, quality, outage, session release."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


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

header = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans JP,56,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
'''


def stamp(value):
    return f'0:{int(value)//60:02}:{int(value)%60:02}.00'


comments = header + ''.join(f'Dialogue: 0,{stamp(i)},{stamp(i+4)},Default,,0,0,0,,{{\\move(1280,100,-400,100)}}Synthetic 日本語 Comment\n' for i in range(86))
captions = header + ''.join(f'Dialogue: 0,{stamp(i)},{stamp(i+3)},Default,,0,0,0,,Synthetic ordinary subtitle {i}\n' for i in range(0,87,3))

for kind, segment, fps, gop in [('encoded', 4, '25', '100'), ('ts', 6.006, '30000/1001', '180')]:
    root = dist / f'hls-fixture-{kind}'
    root.mkdir(exist_ok=True)
    subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
        f'testsrc2=size=320x180:rate={fps}', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-t', '90', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', gop, '-sc_threshold', '0',
        '-c:a', 'aac', '-b:a', '64k', '-f', 'hls', '-hls_time', str(segment), '-hls_playlist_type', 'vod',
        '-hls_segment_filename', str(root / '%d.ts'), str(root / 'playlist.m3u8')], timeout=180)
    rows = []
    fault_until = [0.0]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, data=b'', code=200, mime='application/json'):
            self.send_response(code)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def json(self, obj):
            self.respond(json.dumps(obj).encode())

        def do_GET(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            if path == '/api/test-fault':
                fault_until[0] = time.monotonic()+12
                rows.append({'fault': True})
                self.json({}); return
            if '/vodhls/' in path:
                if query.get('client') != ['ios']:
                    rows.append({'invalidClient': path, 'client': query.get('client')})
                    self.respond(code=400); return
                if time.monotonic() < fault_until[0]:
                    rows.append({'failed': path}); self.respond(code=503); return
                if path.endswith('/playlist'):
                    rows.append({'playlist': query})
                    text = (root / 'playlist.m3u8').read_text()
                    lines = ['#EXT-X-START:TIME-OFFSET='+query['ss'][0]+',PRECISE=YES']
                    for line in text.splitlines():
                        if not line.startswith('#'):
                            line = 'segments/'+line+'?mode='+query['mode'][0]+'&client='+query['client'][0]
                        lines.append(line)
                    # EXTM3U must be the first line.
                    lines[0], lines[1] = lines[1], lines[0]
                    self.respond(('\n'.join(lines)+'\n').encode(), mime='application/vnd.apple.mpegurl'); return
                name = path.rsplit('/', 1)[-1]
                if name.endswith('.ts') and (root / name).is_file():
                    rows.append({'segment': int(name[:-3]), 'mode': query.get('mode'), 'client': query.get('client')})
                    body = (root / name).read_bytes()
                    self.send_response(200); self.send_header('Content-Type', 'video/mp2t')
                    self.send_header('Content-Length', str(len(body))); self.end_headers()
                    try:
                        split = max(188, len(body)//2)
                        self.wfile.write(body[:split]); self.wfile.flush(); time.sleep(.2)
                        self.wfile.write(body[split:]); self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError): pass
                    return
            if path.endswith('/subtitles'):
                self.json({'items': [dict(subtitleIndex=0, streamIndex=2, codecName='ass', displayName='実況comments', title='comments', language='jpn'),
                    dict(subtitleIndex=1, streamIndex=3, codecName='ass', displayName='日本語字幕', title='字幕', language='jpn')]}); return
            if path.endswith('/subtitles/0/text'):
                time.sleep(.3); self.json({'subtitleText': comments}); return
            if path.endswith('/subtitles/1/text'):
                self.json({'subtitleText': captions}); return
            if path.endswith('/comments'):
                time.sleep(.3)
                self.json({'isSuccess': True, 'source': 'jikkyo', 'timeBase': 'video', 'comments': [dict(time=i/4,
                    text='Synthetic 日本語 Comment', color='#FFFFFF', position='right', size='medium') for i in range(360)]}); return
            self.respond(code=404)

        def do_PUT(self):
            rows.append({'keep': self.path, 'failed': time.monotonic() < fault_until[0]})
            # Keep the control API reachable while media/playlist is down.
            # This must not turn availability probes into a tight reopen loop.
            self.respond(code=204)

        def do_DELETE(self):
            rows.append({'release': self.path}); self.respond(code=204)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    names = ['streaming-smoke.json', 'streaming-diagnostics.json']
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
    for name in names:
        (documents / name).unlink(missing_ok=True)
    try:
        environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_STREAMING=f'http://127.0.0.1:{server.server_port}', SIMCTL_CHILD_NEO_EPG_STREAM_TYPE=kind)
        subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
        deadline = time.monotonic()+180
        while not (documents / names[0]).exists() and time.monotonic() < deadline:
            time.sleep(1)
        time.sleep(.5)
        for name in names:
            if (documents / name).exists(): shutil.copyfile(documents / name, dist / f'{kind}-{name}')
        if (documents / 'streaming-dialog.png').exists(): shutil.copyfile(documents / 'streaming-dialog.png', dist / 'streaming-dialog.png')
        (dist / f'{kind}-hls-requests.json').write_text(json.dumps(rows, indent=2))
        result = json.loads((documents / names[0]).read_text())
        assert result['success'] and all(result['checks'].values()), result
        assert any('fault' in row for row in rows) and any(row.get('failed') for row in rows), 'Outage not injected'
        failed_playlists = [row for row in rows if isinstance(row.get('failed'), str) and row['failed'].endswith('/playlist')]
        assert len(failed_playlists) <= 10, 'Unbounded playlist retry loop during a 12-second media outage'
        playlists = [row['playlist'] for row in rows if 'playlist' in row]
        assert {p['mode'][0] for p in playlists} == {'0', '1'}, playlists
        assert all(p['subtitleIndex'] == ['-1'] for p in playlists), 'Burned subtitles requested'
        assert all(p.get('client') == ['ios'] for p in playlists), 'Missing iOS HLS compatibility on playlist requests'
        segments = [row for row in rows if 'segment' in row]
        assert segments and all(row.get('client') == ['ios'] for row in segments), 'Lost iOS HLS compatibility on proxied segments'
        assert not any('invalidClient' in row for row in rows), 'Request bypassed iOS HLS compatibility'
        sessions = {p['vodSessionId'][0] for p in playlists}
        released = {row['release'].rsplit('/', 1)[-1] for row in rows if 'release' in row}
        assert sessions <= released and len(sessions) == 2, (sessions, released)
        assert any('keep' in row for row in rows), 'No session heartbeat'
        events = json.loads((documents / names[1]).read_text())['events']
        assert any(first['elapsed'] < complete['elapsed'] for first in events if first['event'] == 'hls.firstDelivered'
                   for complete in events if complete['event'] == 'hls.segment' and complete.get('index') == first.get('index')), 'VLC received no segment bytes before upstream EOF'
        wait = next(e for e in events if e['event'] == 'hls.networkWaiting')
        restored = next(e for e in events if e['event'] == 'input.restoreReady' and e['elapsed'] > wait['elapsed'])
        assert restored['elapsed']-wait['elapsed'] < 20, 'HLS did not actually restore within 20 seconds of the 12-second outage'
        assert not any(e['event'] == 'input.retiredAfterDeadline' for e in events), 'Known playlist failure waited for the input deadline'
        assert not any(e['event'] in ('seek.timeout', 'ts.positionFailed') for e in events), 'Seek fell back after a deadline'
        if kind == 'ts':
            assert any(e['event'] == 'ts.positionReady' and e.get('seek') == 1 and e.get('outputChanged') for e in events), 'Replaced video output not exercised'
        print(f"PASS {kind}: {len(result['checks'])} native HLS assertions, actual outage/recovery, two sessions released", flush=True)
    finally:
        server.shutdown()
