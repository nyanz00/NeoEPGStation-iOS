"""Production common player: real video, comments/ASS/PiP/history and HLS outage recovery."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlparse
from http_byte_range import byte_range


def run(*args, timeout=120):
    return subprocess.check_output(args,text=True,timeout=timeout).strip()


dist = Path('dist')
device = json.loads((dist/'simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun','simctl','bootstatus',device,'-b',timeout=600)
run('xcrun','simctl','install',device,'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app',timeout=300)
documents = Path(run('xcrun','simctl','get_app_container',device,bundle,'data'))/'Documents'
checker = (dist/'aether-picture-check').resolve()
reference = Path('tests/fixtures/aether-seek-reference')
manifest = json.loads((reference/'manifest.json').read_text())['fixtures']
header = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
'''


def stamp(value):
    return f'0:{value//60:02}:{value%60:02}.00'


comments = header+''.join(f'Dialogue: 0,{stamp(i)},{stamp(i+4)},Default,,0,0,0,,{{\\move(1280,80,-300,80)}}Synthetic 日本語 comment\n' for i in range(90))
captions = header.replace(',1,2,0,2,',',3,2,0,2,')+''.join(f'Dialogue: 0,{stamp(i)},{stamp(i+3)},Default,,0,0,0,,{{\\c&HFFFF00&}}Styled ordinary ASS {i}\n' for i in range(0,90,3))
results = []
cases = [('encoded-seek-1080.mkv',False,False),('encoded-seek-1080.mkv',True,False),
         ('hevc-seek-10.mkv',False,False),('av1-seek-10.mkv',False,True),('encoded-seek-1080.mkv',False,True)]
for fixture,streaming,checkpoint in cases:
    label = fixture+('-hls' if streaming else '-play')+('-checkpoint' if checkpoint else '')
    rows, fault_until = [], [0.0]
    video = Path('tests/fixtures',fixture).read_bytes()
    assert hashlib.sha256(video).hexdigest() == manifest[fixture]['sha256']
    hls = dist/'aether-connected-hls'
    if streaming:
        origin=Path('tests/fixtures/aether-connected-hls')
        recipe=json.loads((origin/'manifest.json').read_text())
        assert recipe['source']==fixture and recipe['sourceSHA256']==hashlib.sha256(video).hexdigest()
        for name,digest in recipe['files'].items():
            assert hashlib.sha256((origin/name).read_bytes()).hexdigest()==digest,name
        shutil.copytree(origin,hls,dirs_exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_): pass
        def respond(self,data=b'',code=200,mime='application/json',head=False):
            self.send_response(code); self.send_header('Content-Type',mime); self.send_header('Content-Length',str(len(data))); self.end_headers()
            if not head:
                try:self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError):pass
        def json(self,value):self.respond(json.dumps(value).encode())
        def do_HEAD(self):self.get(True)
        def do_GET(self):self.get(False)
        def get(self,head):
            parsed = urlparse(self.path);path=parsed.path;query=parse_qs(parsed.query)
            if path=='/api/test-fault':
                fault_until[0]=time.monotonic()+6;rows.append({'fault':True});self.json({});return
            if time.monotonic()<fault_until[0] and (path=='/api/videos/1' or '/vodhls/' in path):
                rows.append({'failed':path});self.respond(code=503);return
            if path=='/api/videos/1':
                try:begin,end=byte_range(self.headers.get('Range'),len(video))
                except ValueError:self.respond(code=416);return
                self.send_response(206 if self.headers.get('Range') else 200)
                self.send_header('Content-Type','video/x-matroska');self.send_header('Accept-Ranges','bytes')
                self.send_header('Content-Length',str(end-begin+1));self.send_header('Content-Range',f'bytes {begin}-{end}/{len(video)}');self.end_headers()
                rows.append({'video':True,'bytes':end-begin+1})
                if not head:
                    try:self.wfile.write(video[begin:end+1])
                    except (BrokenPipeError,ConnectionResetError):pass
                return
            if path.endswith('/duration'):self.json({'duration':90});return
            if path.endswith('/subtitles'):
                self.json({'items':[dict(subtitleIndex=0,streamIndex=2,codecName='ass',displayName='実況comments',title='comments',language='jpn'),
                                    dict(subtitleIndex=1,streamIndex=3,codecName='ass',displayName='日本語字幕',title='字幕',language='jpn')]});return
            if path.endswith('/subtitles/0/text'):
                time.sleep(.3);rows.append({'comments':True});self.json({'subtitleText':comments});return
            if path.endswith('/subtitles/1/text'):rows.append({'caption':True});self.json({'subtitleText':captions});return
            if path.endswith('/vodhls/playlist'):
                rows.append({'playlist':query});lines=(hls/'playlist.m3u8').read_text().splitlines()
                lines.insert(1,'#EXT-X-START:TIME-OFFSET='+query['ss'][0]+',PRECISE=YES')
                lines=[line if line.startswith('#') else 'segments/'+line+'?client=ios' for line in lines]
                self.respond(('\n'.join(lines)+'\n').encode(),mime='application/vnd.apple.mpegurl');return
            if '/vodhls/segments/' in path:
                name=path.rsplit('/',1)[-1]
                if name.endswith('.ts') and name[:-3].isdigit() and (hls/name).is_file():
                    rows.append({'segment':name});self.respond((hls/name).read_bytes(),mime='video/mp2t');return
            self.respond(code=404)
        def do_PUT(self):
            value=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
            rows.append({'put':urlparse(self.path).path,'value':value,'user':self.headers.get('X-EPGStation-User-Id')})
            self.json({})
        def do_DELETE(self):rows.append({'delete':urlparse(self.path).path});self.json({})

    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        names=['aether-connected-smoke.json','aether-connected-diagnostics.json','connected-30.png','connected-40.png']
        for name in names:(documents/name).unlink(missing_ok=True)
        subprocess.run(['xcrun','simctl','terminate',device,bundle],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        env=os.environ.copy()
        env.update(SIMCTL_CHILD_NEO_EPG_AETHER_CONNECTED=f'http://127.0.0.1:{server.server_port}',
                   SIMCTL_CHILD_NEO_EPG_CONNECTED_STREAM='1' if streaming else '0',
                   SIMCTL_CHILD_NEO_EPG_CONNECTED_CHECKPOINT='1' if checkpoint else '0')
        launched=subprocess.check_output(['xcrun','simctl','launch',device,bundle],text=True,env=env)
        print(launched.strip(),flush=True)
        pid=re.search(r': (\d+)',launched)
        deadline=time.monotonic()+180
        while time.monotonic()<deadline and not (documents/names[0]).exists():time.sleep(.5)
        for name in names:
            if (documents/name).exists():shutil.copyfile(documents/name,dist/(label+'-'+name))
        if not (documents/names[0]).exists():
            if pid:
                subprocess.run(['sample',pid[1],'1','-file',str(dist/(label+'-process.txt'))],timeout=30,check=False)
            crashdir=Path.home()/'Library/Logs/DiagnosticReports'
            for report in crashdir.glob('NeoEPGStation*.ips'):
                shutil.copyfile(report,dist/(label+'-'+report.stem+'.log'))
            with (dist/(label+'-system.log')).open('w') as log:
                subprocess.run(['xcrun','simctl','spawn',device,'log','show','--last','4m','--style','compact',
                                '--predicate','process == "NeoEPGStation"'],stdout=log,stderr=subprocess.STDOUT,timeout=40,check=False)
            raise AssertionError('No result from the common production player; process evidence saved')
        result=json.loads((documents/names[0]).read_text())
        assert result['success'] and all(result['checks'].values()),result
        pictures=[]
        for target in [30,40]:
            image=dist/(label+f'-connected-{target}.png')
            check=json.loads(run(str(checker),str(image),str(reference),fixture,str(target)))
            assert check['nonBlack'] and check['targetMatches'],check
            pictures.append(check)
        events=json.loads((documents/names[1]).read_text())['events']
        connected=[e for e in events if e['event']=='aether.connected']
        assert connected and all(e['hlsDirect']==streaming for e in connected),connected
        if checkpoint and fixture.startswith('av1'):
            assert any(e['event']=='checkpoint.restored' and e['status']==0 for e in events),'No actual AV1 state restore'
        if checkpoint and not fixture.startswith('av1'):
            assert not any(e['event']=='checkpoint.restored' for e in events),'AV1 state was applied to another codec'
            assert all(not e['checkpoint'] for e in connected),'Unsupported codec retained checkpoint worker'
        assert any(row.get('fault') for row in rows),'Origin outage not injected'
        # A complete PLAY byte cache can reopen without contacting the origin.
        # HLS must exercise actual playlist failures; PLAY instead verifies
        # muted transport recovery and latest pause using retained cached bytes.
        assert any(e['event']=='aether.recoveryRequested' for e in events),'Transport recovery not exercised'
        assert len([r for r in rows if 'failed' in r]) <= 30,'Unbounded retry loop'
        histories=[r for r in rows if r.get('put')=='/api/recorded/1/playback']
        assert histories and all(r['user']=='1' for r in histories)
        assert any(r['value']['position']>=29 for r in histories),'History did not follow actual seek positions'
        if streaming:
            assert any(row.get('failed') for row in rows),'Real HLS outage not exercised'
            playlists=[r['playlist'] for r in rows if 'playlist' in r]
            assert playlists and all(p.get('client')==['ios'] and p.get('subtitleIndex')==['-1'] for p in playlists)
            assert any('/sessions/' in r.get('delete','') for r in rows),'HLS server session not released'
            assert any(e['event']=='aether.route' and e['route']=='remoteBypass' for e in events),'HLS did not use direct native playback'
        results.append({'case':label,'success':True,'checks':result['checks'],'targetImagesVerified':len(pictures),'pictureChecks':pictures})
        print(label,'PASS',flush=True)
    except Exception as error:
        results.append({'case':label,'success':False,'error':type(error).__name__+': '+str(error)[:1800]})
        print(label,'FAIL',repr(error)[:1800],flush=True)
        # Diagnose the first failed integration before spending three minutes
        # on every remaining codec with the same unexamined failure.
        break
    finally:
        (dist/(label+'-connected-requests.json')).write_text(json.dumps(rows,indent=2))
        server.shutdown();server.server_close()
        (dist/'aether-connected-results.json').write_text(json.dumps({'success':len(results)==len(cases) and all(r['success'] for r in results),'cases':results},indent=2))
if len(results)!=len(cases) or not all(r['success'] for r in results):raise SystemExit(1)
