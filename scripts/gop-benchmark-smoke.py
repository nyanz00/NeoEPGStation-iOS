"""Exercise the shipping foreground player and benchmark with a local AV1 clip."""
import json,os,shutil,subprocess,time
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
assert len(measured)==6 and all(r['status']=='verified' and r['displayMs']>0 and abs(r['picturePTS']-r['target'])<=2/24 for r in measured),result
assert sum(r['forward'] for r in measured)==3 and all('engineCompletionMs' in r and 'distanceFromKey' in r for r in measured),result
assert captured,'No running foreground image captured'
print('PASS: local AV1 normal player, 2 warmup + 6 measured seeks, displayed PTS, independent engine timing, forward/back summaries and JSON export')
