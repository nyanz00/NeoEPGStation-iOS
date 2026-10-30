"""Focused live UI, continuous TS, realtime WebSockets and teardown checks."""
import base64
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import socket
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from sys import path as module_path
module_path.insert(0,str(Path('tests/fixtures').resolve()))
from arib_timing import inject

def run(*args,timeout=120):
    return subprocess.check_output(args,text=True,timeout=timeout).strip()

def read_exact(stream,size):
    data=b''
    while len(data)<size:
        more=stream.read(size-len(data))
        if not more:raise EOFError()
        data+=more
    return data

def ws_receive(stream):
    a,b=read_exact(stream,2);size=b&127
    if size==126:size=struct.unpack('!H',read_exact(stream,2))[0]
    elif size==127:size=struct.unpack('!Q',read_exact(stream,8))[0]
    if size>262144:raise ValueError('oversized frame')
    mask=read_exact(stream,4) if b&128 else None
    payload=read_exact(stream,size)
    if mask:payload=bytes(v^mask[i%4] for i,v in enumerate(payload))
    if a&15==8:raise EOFError()
    return json.loads(payload) if a&15==1 else None

dist=Path('dist');dist.mkdir(exist_ok=True)
device=json.loads((dist/'simulator-device.json').read_text())['udid'];bundle='io.github.nyanz00.NeoEPGStation'
run('xcrun','simctl','bootstatus',device,'-b',timeout=600)
run('xcrun','simctl','install',device,'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app',timeout=300)
documents=Path(run('xcrun','simctl','get_app_container',device,bundle,'data'))/'Documents'
if not shutil.which('ffmpeg'):subprocess.check_call(['brew','install','ffmpeg'],timeout=600)
results=[]
for codec in ['mpeg2video','libx264']:
    fixture=dist/'live-fixture.ts';captioned=dist/'live-caption-fixture.ts'
    subprocess.check_call(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=640x360:rate=24',
      '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','24','-c:v',codec,
      *(['-preset','ultrafast'] if codec=='libx264' else []),'-pix_fmt','yuv420p','-b:v','1000k','-g','24',
      '-c:a','aac','-b:a','64k','-muxrate','2000k','-output_ts_offset','3390','-f','mpegts',str(fixture)],timeout=120)
    inject(fixture,captioned);video=captioned.read_bytes()
    events=[];connections=[];fault_until=[0];active=[0];max_active=[0];lock=threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*_):pass
        def json(self,value,code=200):
            body=json.dumps(value).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def do_GET(self):
            path=urlparse(self.path).path;query=parse_qs(urlparse(self.path).query)
            if path.startswith('/ws/'):
                self.websocket(path);return
            if path.endswith('/logo'):self.json({},404);return
            if path.startswith('/api/') and self.headers.get('X-Live-Test')!='synthetic' and path!='/api/live-test-fault':
                events.append({'authMissing':path});self.json({},403);return
            if path=='/api/config':
                self.json({'encode':[],'isEnableTSLiveStream':True,'broadcast':{'GR':True,'BS':True},
                    'streamConfig':{'live':{'ts':{'m2ts':[{'name':'無変換','isUnconverted':True},{'name':'1080p','isUnconverted':False}],'m2tsll':['720p']}}}});return
            if path=='/api/schedules/broadcasting':
                now=time.time()*1000;self.json([{'channel':{'id':i,'name':name,'channelType':wave,'type':1,'hasLogoData':False},
                    'programs':[{'id':i,'name':'Synthetic live 番組 '+str(i),'startAt':now-600000,'endAt':now+1200000,'description':'現在放送中のテスト番組です。'}]}
                    for i,name,wave in [(1,'Synthetic GR','GR'),(2,'Synthetic BS','BS')]]);return
            if path=='/api/channels/jikkyo':self.json([{'channelId':1,'force':220},{'channelId':2,'force':80}]);return
            if path.endswith('/jikkyo'):
                self.json({'watchSessionUrl':f'ws://127.0.0.1:{self.server.server_port}/ws/watch','commentSessionUrl':f'ws://127.0.0.1:{self.server.server_port}/ws/comments'});return
            if path=='/api/live-test-fault':
                fault_until[0]=time.monotonic()+3;events.append({'fault':True})
                with lock:old=list(connections)
                for connection in old:
                    try:connection.shutdown(socket.SHUT_RDWR)
                    except OSError:pass
                self.json({});return
            if path.startswith('/api/streams/live/'):
                events.append({'open':path,'query':query,'range':self.headers.get('Range')})
                if time.monotonic()<fault_until[0]:events.append({'injected503':True});self.json({},503);return
                with lock:active[0]+=1;max_active[0]=max(max_active[0],active[0]);connections.append(self.connection)
                try:
                    self.send_response(200);self.send_header('Content-Type','video/mp2t');self.send_header('Transfer-Encoding','chunked');self.end_headers()
                    begin=time.monotonic();size=188*100
                    for offset in range(0,len(video),size):
                        body=video[offset:offset+size]
                        self.wfile.write(f'{len(body):x}\r\n'.encode()+body+b'\r\n');self.wfile.flush()
                        due=begin+(offset+len(body))*8/2000000
                        if due>time.monotonic():time.sleep(due-time.monotonic())
                except (OSError,ConnectionError):pass
                finally:
                    with lock:active[0]-=1;connections.remove(self.connection)
                    events.append({'release':path});self.close_connection=True
                return
            self.json({},404)
        def ws_send(self,value):
            data=json.dumps(value).encode();head=bytes([0x81,len(data)]) if len(data)<126 else bytes([0x81,126])+struct.pack('!H',len(data))
            self.wfile.write(head+data);self.wfile.flush()
        def websocket(self,path):
            if self.headers.get('X-Live-Test'):events.append({'socketAuthLeaked':True})
            key=self.headers.get('Sec-WebSocket-Key','');accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',accept);self.end_headers()
            events.append({'socketOpen':path})
            try:
                value=ws_receive(self.rfile);events.append({'handshake':path,'value':value})
                if path.endswith('watch'):
                    self.ws_send({'type':'seat','data':{'keepIntervalSec':1}});self.ws_send({'type':'ping'})
                    self.ws_send({'type':'room','data':{'threadId':'synthetic','messageServer':{'uri':f'ws://127.0.0.1:{self.server.server_port}/ws/comments'}}})
                    while True:
                        value=ws_receive(self.rfile)
                        if value:events.append({'watchCommand':value.get('type')})
                else:
                    self.ws_send({'chat':{'no':0,'content':'BACKLOG MUST NOT RENDER','date':1}})
                    self.ws_send({'ping':{'content':'rf:0'}})
                    for index in range(600):
                        # A real new chat after the historical-message fence.
                        self.ws_send({'chat':{'no':index+1,'date':int(time.time()),'user_id':'fixture','content':'Live 日本語 '+str(index),'mail':'white big'}})
                        if select.select([self.connection],[],[],0.2)[0]:ws_receive(self.rfile)
            except (OSError,EOFError,ValueError,ConnectionError):pass
            finally:events.append({'socketClosed':path});self.close_connection=True
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        subprocess.run(['xcrun','simctl','terminate',device,bundle],capture_output=True)
        for name in ['live-smoke.json','live-diagnostics.json','live-onair.png','live-dialog.png','live-player.png']:(documents/name).unlink(missing_ok=True)
        env=os.environ.copy();env['SIMCTL_CHILD_NEO_EPG_LIVE_SMOKE']=f'http://127.0.0.1:{server.server_port}'
        subprocess.check_call(['xcrun','simctl','launch',device,bundle],env=env,timeout=30)
        deadline=time.monotonic()+155
        while time.monotonic()<deadline and not (documents/'live-smoke.json').exists():time.sleep(0.5)
        report=json.loads((documents/'live-smoke.json').read_text()) if (documents/'live-smoke.json').exists() else {'success':False,'error':'live probe timeout'}
        time.sleep(1)
        checks={'streamOpened':any('open' in e for e in events),'faultInjected':any('fault' in e for e in events),
            'faultRefused':any('injected503' in e for e in events),'streamReleasedOnExit':active[0]==0,
            'noRangeOrOverride':all(not e.get('range') and set(e.get('query',{}))=={'mode','quality'} for e in events if 'open' in e),
            'noOriginAuthOnWS':not any(e.get('socketAuthLeaked') or e.get('authMissing') for e in events),
            'watchPong':any(e.get('watchCommand')=='pong' for e in events),'keepSeat':any(e.get('watchCommand')=='keepSeat' for e in events),
            'socketsReleasedOnExit':sum('socketOpen' in e for e in events)==sum('socketClosed' in e for e in events)}
        report['serverChecks']=checks;report['maximumConcurrentStreams']=max_active[0];report['success']=report.get('success',False) and all(checks.values())
        for name in ['live-diagnostics.json','live-onair.png','live-dialog.png','live-player.png']:
            if (documents/name).exists():shutil.copy2(documents/name,dist/f'live-{codec}-{name}')
        (dist/f'live-{codec}.json').write_text(json.dumps({'result':report,'events':events},indent=2))
        results.append(report);print(codec,json.dumps(report),flush=True)
    finally:
        subprocess.run(['xcrun','simctl','terminate',device,bundle],capture_output=True);server.shutdown();server.server_close()
(dist/'live-summary.json').write_text(json.dumps({'success':all(r.get('success') for r in results),'cases':results},indent=2))
assert all(r.get('success') for r in results),'Live verification failed; inspect per-codec diagnostics'
