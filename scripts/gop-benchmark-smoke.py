"""Exercise the shipping foreground player and benchmark with a local AV1 clip."""
import functools,http.server,json,os,shutil,subprocess,threading,time
from pathlib import Path

def run(*args,timeout=180):return subprocess.check_output(args,text=True,timeout=timeout).strip()
device=json.loads(Path('dist/simulator-device.json').read_text())['udid'];bundle='io.github.nyanz00.NeoEPGStation'
run('xcrun','simctl','bootstatus',device,'-b',timeout=600)
run('xcrun','simctl','install',device,'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app',timeout=600)
docs=Path(run('xcrun','simctl','get_app_container',device,bundle,'data'))/'Documents';docs.mkdir(exist_ok=True)
shutil.copyfile('tests/fixtures/av1-seek-10.mkv',docs/'gop-fixture.mkv')
shutil.copyfile('tests/gop-benchmark/fixture.json',docs/'gop-fixture.json')
marker=docs/'gop-benchmark-smoke.json';marker.unlink(missing_ok=True)
os.environ['SIMCTL_CHILD_NEO_EPG_GOP_BENCHMARK']='gop-fixture.mkv'
run('xcrun','simctl','launch',f'--stdout={docs}/gop-stdout.txt',f'--stderr={docs}/gop-stderr.txt',device,bundle)
captured=False
for _ in range(180):
 if marker.exists():break
 partial=docs/'gop-seek-current.json'
 if not captured and partial.exists():
  try:
   if len(json.loads(partial.read_text()).get('rows',[]))>=2:
    run('xcrun','simctl','io',device,'screenshot','dist/gop-benchmark-running.png',timeout=30);captured=True
  except (OSError,ValueError):pass
 time.sleep(1)
for name in ['gop-benchmark-smoke.json','gop-seek-current.json','gop-benchmark-diagnostics.json','gop-stdout.txt','gop-stderr.txt']:
 if (docs/name).exists():shutil.copyfile(docs/name,Path('dist')/name)
assert marker.exists(),'Benchmark result missing; inspect preserved diagnostics'
result=json.loads(marker.read_text());rows=result.get('rows',[])
assert result['status']=='completed',result
assert result['checkpoint'] is False and result['audio'] is True and result['local'] is True,result
assert len(rows)==8 and sum(r['sampleKind']=='warmup' for r in rows)==2,result
measured=[r for r in rows if r['sampleKind']=='measured']
assert len(measured)==6 and all(r['status']=='verified' and r['displayMs']>0 and abs(r.get('picturePTS',r.get('referencePTS',-1))-r['target'])<=2/24 for r in measured),result
assert all(r['verification'] in ('displayed-surface-source-PTS','avplayer-item-display-time-buffer','displayed-picture-reference') for r in measured),result
assert sum(r['forward'] for r in measured)==3 and all('engineCompletionMs' in r and 'distanceFromKey' in r for r in measured),result
assert captured,'No running foreground image captured'
print('PASS: local AV1 normal player, 2 warmup + 6 measured seeks, displayed PTS, independent engine timing, forward/back summaries and JSON export')

# Exercise the actual file-import delegate, schema2, and three consecutive
# timestamped inputs in ONE foreground player/engine. No reference pixels are sent.
run('xcrun','simctl','terminate',device,bundle)
for source,destination in [('encoded-seek-1080.mkv','gop-batch-a.mkv'),('encoded-seek-1080.mp4','gop-batch-b.mp4'),('encoded-seek.mkv','gop-batch-c.mkv')]:
 shutil.copyfile(Path('tests/fixtures')/source,docs/destination)
shutil.copyfile('tests/gop-benchmark/batch.json',docs/'gop-batch-plan.json')
marker=docs/'gop-batch-smoke.json';marker.unlink(missing_ok=True)
os.environ.pop('SIMCTL_CHILD_NEO_EPG_GOP_BENCHMARK',None)
os.environ['SIMCTL_CHILD_NEO_EPG_GOP_BATCH']='1'
run('xcrun','simctl','launch',f'--stdout={docs}/gop-batch-stdout.txt',f'--stderr={docs}/gop-batch-stderr.txt',device,bundle)
captured_batch=False
for _ in range(180):
 if marker.exists():break
 try:
  partial=json.loads((docs/'gop-seek-benchmark.json').read_text())
  if not captured_batch and partial.get('inputLoadCount',0)>=2:
   run('xcrun','simctl','io',device,'screenshot','dist/gop-batch-running.png',timeout=30);captured_batch=True
 except (OSError,ValueError):pass
 time.sleep(1)
for name in ['gop-batch-smoke.json','gop-seek-benchmark.json','gop-seek-current.json','gop-batch-diagnostics.json','gop-batch-stdout.txt','gop-batch-stderr.txt']:
 if (docs/name).exists():shutil.copyfile(docs/name,Path('dist')/name)
assert marker.exists(),'Batch marker missing; inspect preserved diagnostics'
batch=json.loads(marker.read_text());assert batch['status']=='completed',batch
assert batch['presentationCount']==1 and batch['inputLoadCount']==3,batch
assert len(batch['runs'])==3 and captured_batch,batch
expected={p['label']:p for p in json.loads(Path('tests/gop-benchmark/batch.json').read_text())['profiles']}
for result in batch['runs']:
 assert result['status']=='completed' and result['referenceCount']==0,result
 assert result['targets']==expected[result['label']]['targets'],result
 rows=result['rows'];assert len(rows)==8 and sum(r['sampleKind']=='warmup' for r in rows)==2,result
 measured=[r for r in rows if r['sampleKind']=='measured']
 assert len(measured)==6 and all(r['status']=='verified' and r['verification'] in ('avplayer-item-display-time-buffer','displayed-surface-source-PTS') and abs(r['picturePTS']-r['target'])<=2/24 for r in measured),result
 assert set(r['group'] for r in measured)=={'near','middle','far'},result
 assert all(result['summaryByGroup'][g]['all']['count']==2 for g in ('near','middle','far')),result
print('PASS: metadata-only merged plan, actual import, three inputs with different targets, one presentation, zero reference images, per-group summaries')

# Drop exactly one preparation observation and one measured observation. The
# current video AND subsequent videos must complete; neither failure is timed
# as a successful seek. The real playback continues during these observer faults.
run('xcrun','simctl','terminate',device,bundle)
marker=docs/'gop-batch-smoke.json';marker.unlink(missing_ok=True)
os.environ['SIMCTL_CHILD_NEO_EPG_GOP_FAULTS']='1'
run('xcrun','simctl','launch',f'--stdout={docs}/gop-fault-stdout.txt',f'--stderr={docs}/gop-fault-stderr.txt',device,bundle)
for _ in range(180):
 if marker.exists():break
 time.sleep(1)
for source,destination in [('gop-batch-smoke.json','gop-fault-smoke.json'),('gop-seek-current.json','gop-fault-current.json'),('gop-batch-diagnostics.json','gop-fault-diagnostics.json')]:
 if (docs/source).exists():shutil.copyfile(docs/source,Path('dist')/destination)
assert marker.exists(),'Fault batch did not finish'
fault=json.loads(marker.read_text());assert fault['status']=='completed-with-failures' and fault['failedRunCount']==2
assert fault['presentationCount']==1 and fault['inputLoadCount']==3 and len(fault['runs'])==3
for trial in fault['runs']:
 measured=[r for r in trial['rows'] if r['sampleKind']=='measured'];assert len(measured)==6
 invalid=[r for r in measured if r['status']!='verified']
 expected_failure=trial['label']!='synthetic-native-3'
 assert len(invalid)==int(expected_failure)
 assert trial['summary']['all']['count']==6-int(expected_failure) and trial['summary']['all']['failedCount']==int(expected_failure)
 assert all('displayMs' not in r for r in invalid)
 if invalid:
  row=invalid[0];detail=row['preparation'] if row['status']=='preparation-failed' else row
  assert detail['testFault']=='omitted-picture-event' and detail['observation']['polls']>0
  assert row['status']==('preparation-failed' if trial['label']=='synthetic-native-2' else 'timeout')
 else:assert trial['status']=='completed'
print('PASS: preparation and measured observer failures saved/excluded; remaining trials and three inputs completed')

# Native AVPlayer output, including the real hasNew=false case after a second
# observer acquires a buffer. Reuse the existing public HLS fixture.
run('xcrun','simctl','terminate',device,bundle)
native=Path('tests/fixtures/aether-connected-hls')
class QuietHandler(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(QuietHandler,directory=str(native.resolve())))
threading.Thread(target=server.serve_forever,daemon=True).start()
profile=expected['synthetic-native-2']
(docs/'gop-fixture.json').write_text(json.dumps(dict(profile=profile,targets=profile['targets'],rounds=1)))
marker=docs/'gop-benchmark-smoke.json';marker.unlink(missing_ok=True)
for name in ['SIMCTL_CHILD_NEO_EPG_GOP_BATCH','SIMCTL_CHILD_NEO_EPG_GOP_FAULTS']:os.environ.pop(name,None)
os.environ['SIMCTL_CHILD_NEO_EPG_GOP_BENCHMARK']='native'
os.environ['SIMCTL_CHILD_NEO_EPG_GOP_NATIVE']=f'http://127.0.0.1:{server.server_port}/playlist.m3u8'
run('xcrun','simctl','launch',f'--stdout={docs}/gop-native-stdout.txt',f'--stderr={docs}/gop-native-stderr.txt',device,bundle)
try:
 for _ in range(180):
  if marker.exists():break
  time.sleep(1)
 for source,destination in [('gop-benchmark-smoke.json','gop-native-smoke.json'),('gop-benchmark-diagnostics.json','gop-native-diagnostics.json'),('gop-native-stdout.txt','gop-native-stdout.txt'),('gop-native-stderr.txt','gop-native-stderr.txt')]:
  if (docs/source).exists():shutil.copyfile(docs/source,Path('dist')/destination)
 assert marker.exists(),'Native display observation did not finish'
 result=json.loads(marker.read_text());assert result['status']=='completed',result.get('reason')
 rows=result['rows'];assert len(rows)==8 and result['referenceCount']==0
 assert all(r['status']=='verified' and r['verification']=='avplayer-item-display-time-buffer' and abs(r['picturePTS']-r['target'])<=2/24 for r in rows)
 assert all(r['observation']['copiedWithoutNew']>0 for r in rows)
 print('PASS: real native output, hasNew=false with acquired buffer, same strict target PTS, engine/display timing independent')
finally:server.shutdown();server.server_close()
