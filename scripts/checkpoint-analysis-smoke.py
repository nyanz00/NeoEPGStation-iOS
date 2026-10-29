"""Exercise detail prefetch and the real play-preparation flow, without decoding media."""
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def run(*args):
    return subprocess.check_output(args, text=True, timeout=120).strip()


recording = dict(id=1, name='Synthetic analysis', startAt=0, endAt=120000, isRecording=False,
                 videoFiles=[dict(id=17, name='AV1', type='encoded', size=1024)])
requests = []
began = 0
scenario = ''
first_info_at = None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global first_info_at
        requests.append(dict(path=self.path, time=time.monotonic()-began))
        if self.path.startswith('/api/recorded/1?'):
            value = recording
        elif self.path == '/api/videos/17/info':
            if first_info_at is None:
                first_info_at = time.monotonic()
            ready = scenario == 'short' or scenario == 'stale' and time.monotonic()-first_info_at >= 4
            keys = dict(status='ready' if ready else 'pending', version=2 if ready else 1,
                        currentVersion=2, stale=not ready, averageInterval=4, minInterval=2,
                        maxInterval=6 if scenario == 'short' else 25, intervalCount=8, keyframeCount=11)
            value = dict(videoCodec='av1', width=1440, height=1080, keyframes=keys)
        else:
            self.send_error(404)
            return
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        requests.append(dict(path=self.path, method='POST'))
        self.send_error(405)


device = json.loads(Path('dist/simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b')
run('xcrun', 'simctl', 'install', device, 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app')
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data'))/'Documents'
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []
try:
    for scenario in ('stale', 'short', 'cancel'):
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
        target = documents/'checkpoint-analysis-smoke.json'
        target.unlink(missing_ok=True)
        requests = []
        first_info_at = None
        began = time.monotonic()
        environment = dict(os.environ, SIMCTL_CHILD_NEO_EPG_CHECKPOINT_ANALYSIS=f'http://127.0.0.1:{server.server_port}',
                           SIMCTL_CHILD_NEO_EPG_ANALYSIS_CASE=scenario)
        subprocess.run(['xcrun', 'simctl', 'launch', device, bundle], env=environment, check=True, timeout=60)
        deadline = time.monotonic()+35
        while not target.exists() and time.monotonic() < deadline:
            time.sleep(.2)
        assert target.exists(), 'No play-preparation result for '+scenario
        value = json.loads(target.read_text())
        assert value['success'] and all(value['checks'].values()), value
        infos = [r for r in requests if r['path']=='/api/videos/17/info']
        assert len(infos) >= (3 if scenario == 'stale' else 2), requests
        assert not any(r.get('method')=='POST' for r in requests), requests
        assert not any(r['path']=='/api/videos/17' for r in requests), 'A player was opened before the test accepted the decision'
        if scenario == 'stale':
            assert value['requests'] >= 2 and infos[-1]['time']-infos[1]['time'] >= 2.5, infos
        if scenario == 'cancel':
            count = len(infos)
            time.sleep(3.5)
            assert len([r for r in requests if r['path']=='/api/videos/17/info']) == count, 'Cancelled preparation kept polling'
        results.append(dict(scenario=scenario, success=True, checks=value['checks'], reason=value['reason'], requests=requests.copy()))
        print(scenario, 'passed', flush=True)
finally:
    server.shutdown()
    Path('dist/checkpoint-analysis-results.json').write_text(json.dumps(dict(
        success=len(results)==3 and all(r['success'] for r in results), cases=results), indent=2)+'\n')
assert len(results)==3
