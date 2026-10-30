"""Focused player settings, live log UI and selected/disabled HLS commentary."""
import json
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


dist = Path('dist')
phone = json.loads((dist/'simulator-device.json').read_text())['udid']
device = phone
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
run('xcrun', 'simctl', 'install', device,
    'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app', timeout=300)
available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
runtime = next(key for key, values in available.items() if any(d['udid'] == phone for d in values))
pad = next(d['udid'] for d in available[runtime] if d['isAvailable'] and d['name'].startswith('iPad Pro'))
hls = Path('tests/fixtures/aether-connected-hls')
video = Path('tests/fixtures/encoded-seek-1080.mkv').read_bytes()
header = """[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
"""


def stamp(seconds):
    return f'0:{seconds//60:02}:{seconds%60:02}.00'


results = []
for platform, choice in [('phone', 2), ('phone', -1), ('pad', 2)]:
    target = pad if platform == 'pad' else phone
    if target != device:
        run('xcrun', 'simctl', 'shutdown', device, timeout=90)
        state = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
        info = next(d for values in state.values() for d in values if d['udid'] == target)
        if info['state'] == 'Shutdown':
            run('xcrun', 'simctl', 'boot', target)
        run('xcrun', 'simctl', 'bootstatus', target, '-b', timeout=600)
        run('xcrun', 'simctl', 'install', target,
            'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app', timeout=300)
        device = target
    documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data'))/'Documents'
    rows = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, data=b'{}', mime='application/json', code=200, head=False):
            self.send_response(code)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Content-Type', mime)
            self.end_headers()
            if not head:
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def json(self, value):
            self.respond(json.dumps(value).encode())

        def do_HEAD(self):
            self.get(True)

        def do_GET(self):
            self.get(False)

        def get(self, head):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            rows.append({'path': path, 'query': query})
            if path.endswith('/duration'):
                self.json({'duration': 72})
                return
            if path.endswith('/subtitles'):
                self.json({'items': [
                    dict(subtitleIndex=i, streamIndex=i+2, codecName='ass',
                         displayName=name, title=title, language='jpn')
                    for i, name, title in [(0, 'Comments A', 'comments'),
                                          (1, '日本語字幕', '字幕'),
                                          (2, 'Comments B', 'comments')]]})
                return
            if '/subtitles/' in path and path.endswith('/text'):
                index = int(path.split('/')[-2])
                text = 'CHOSEN B' if index == 2 else 'WRONG A' if index == 0 else 'Ordinary subtitle'
                body = header + ''.join(
                    f'Dialogue: 0,{stamp(i)},{stamp(i+4)},Default,,0,0,0,,{{\\move(1280,80,-300,80)}}{text}\n'
                    for i in range(65))
                self.json({'subtitleText': body})
                return
            if path.endswith('/vodhls/playlist'):
                lines = (hls/'playlist.m3u8').read_text().splitlines()
                lines.insert(1, '#EXT-X-START:TIME-OFFSET='+query.get('ss', ['20'])[0]+',PRECISE=YES')
                lines = [line if line.startswith('#') else 'segments/'+line+'?client=ios' for line in lines]
                self.respond(('\n'.join(lines)+'\n').encode(), 'application/vnd.apple.mpegurl', head=head)
                return
            if '/vodhls/segments/' in path:
                target = hls/path.rsplit('/', 1)[-1]
                if target.suffix == '.ts' and target.is_file():
                    self.respond(target.read_bytes(), 'video/mp2t', head=head)
                    return
            if path == '/api/videos/1':
                self.respond(video, 'video/x-matroska', head=head)
                return
            self.respond(code=404)

        def do_DELETE(self):
            self.json({})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    label = 'pad-selected-b' if platform == 'pad' else 'selected-b' if choice == 2 else 'none'
    try:
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
        names = ['player-feedback.json', 'player-feedback-diagnostics.json',
                 'feedback-pad-panel.png', 'feedback-stream-dialog.png']
        for name in names:
            (documents/name).unlink(missing_ok=True)
        env = os.environ.copy()
        env['SIMCTL_CHILD_NEO_EPG_FEEDBACK_BASE'] = f'http://127.0.0.1:{server.server_port}'
        env['SIMCTL_CHILD_NEO_EPG_FEEDBACK_CHOICE'] = str(choice)
        subprocess.check_call(['xcrun', 'simctl', 'launch', device, bundle], env=env, timeout=30)
        deadline = time.monotonic()+65
        while time.monotonic() < deadline and not (documents/names[0]).exists():
            time.sleep(.5)
        result = json.loads((documents/names[0]).read_text()) if (documents/names[0]).exists() else {
            'success': False, 'error': 'probe timeout'}
        for name in names:
            if (documents/name).exists():
                shutil.copy2(documents/name, dist/(label+'-'+name))
        comments = [r['path'] for r in rows if '/subtitles/' in r['path']
                    and r['path'].endswith('/text') and not r['path'].endswith('/1/text')]
        result['serverSelection'] = (
            bool(comments) and all(p.endswith('/2/text') for p in comments)) if choice == 2 else not comments
        # UIKit does not propagate the legacy idiom override used by the
        # embedded probe. Assert phone placement on an actual phone, and Pad
        # placement on an actual Pad, retaining every raw observation below.
        result['nativeOverallAssertion'] = result.get('success', False)
        result['platform'] = platform
        panels = result.get('panelChecks', {})
        result['nativePanelChecks'] = dict(panels)
        required = {'closeTouchTarget', 'commentSelectionFirst', 'continuesFollowing',
                    'followsActualLivePosition', 'manualReadingStopsFollowing',
                    'pastLogAnchorPreserved', 'recordedTimeUnchanged',
                    'remainingSettingsOrder', 'returnResumesFollowing', 'wallClockDisplayed'}
        required |= {'padTraitApplied', 'padCloseAtRight'} if platform == 'pad' else {'phoneClosePreserved'}
        irrelevant = {'phoneClosePreserved'} if platform == 'pad' else {'padTraitApplied', 'padCloseAtRight'}
        result['notApplicableToDevice'] = sorted(irrelevant)
        result['panelChecks'] = {key: value for key, value in panels.items() if key not in irrelevant}
        result['success'] = (result['serverSelection']
            and required <= result['panelChecks'].keys()
            and all(result['panelChecks'].values())
            and bool(result.get('checks')) and all(result['checks'].values())
            and bool(result.get('dialogChecks')) and all(result['dialogChecks'].values()))
        results.append(result)
        (dist/(label+'-feedback-result.json')).write_text(json.dumps({'result': result, 'requests': rows}, indent=2))
        print(label, json.dumps(result), flush=True)
    finally:
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
        server.shutdown()
        server.server_close()
if device != phone:
    run('xcrun', 'simctl', 'shutdown', device, timeout=90)
    run('xcrun', 'simctl', 'boot', phone)
    run('xcrun', 'simctl', 'bootstatus', phone, '-b', timeout=600)
(dist/'player-feedback-results.json').write_text(json.dumps(
    {'success': all(r['success'] for r in results), 'cases': results}, indent=2))
assert all(r['success'] for r in results), 'Player feedback checks failed'
