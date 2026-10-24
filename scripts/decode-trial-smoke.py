"""Exercise the shipping, opt-in diagnostic screen; no simulator HW speed claims."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def run(*args, timeout=120, env=None):
    return subprocess.check_output(args, text=True, timeout=timeout, env=env).strip()


device = json.loads(Path('dist/simulator-device.json').read_text())['udid']
bundle = 'io.github.nyanz00.NeoEPGStation'
run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=600)
run('xcrun', 'simctl', 'install', device, 'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app', timeout=300)
documents = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data'))/'Documents'
documents.mkdir(exist_ok=True)
results = []
for fixture in ('av1-seek-8.mkv', 'av1-seek-10.mkv'):
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
    source = documents/'decode-trial-input.mkv'
    shutil.copyfile(Path('tests/fixtures')/fixture, source)
    report_path = documents/'decode-benchmark.json'
    report_path.unlink(missing_ok=True)
    env = os.environ.copy()
    env['SIMCTL_CHILD_NEO_EPG_DECODE_TRIAL'] = source.as_uri()
    run('xcrun', 'simctl', 'launch', '--terminate-running-process', device, bundle, env=env)
    deadline = time.monotonic()+180
    while not report_path.exists() and time.monotonic()<deadline:
        time.sleep(1)
    assert report_path.exists(), 'Diagnostic screen did not finish: '+fixture
    report = json.loads(report_path.read_text())
    Path('dist', 'decode-trial-'+fixture+'.json').write_text(json.dumps(report, indent=2)+'\n')
    assert report['status'] in ('complete', 'partial'), report
    assert report['sample']['gopSeconds'] >= 10, 'Not a long-GOP test'
    assert report['sample']['packetBytes'] <= 96*1024*1024
    software = [x for x in report['direct'] if x['backend']=='dav1d']
    hardware = [x for x in report['direct'] if x['backend']=='videotoolbox']
    assert len(software)==len(hardware)==6
    assert all(x['status']=='ok' and x['decodeMs']>0 and
               0 <= x['frameSeconds']-x['targetSeconds'] < .1 for x in software)
    assert all(x['status'] in ('ok', 'hardware-unavailable') for x in hardware), hardware
    assert all(x['hardware'] and x.get('imageMeanError',999)<=2 for x in hardware if x['status']=='ok')
    assert report['networkInDecodeTimer'] is False and report['audio'] is False
    # Same actual decoded image/time must be reproducible across fresh decoders.
    for first, second in zip(software[:3], software[3:]):
        assert first['frameSeconds']==second['frameSeconds']
        assert first.get('lumaSHA256') and first['lumaSHA256']==second['lumaSHA256']
    # The timed output is never renamed to on-screen latency. Baseline failures
    # remain explicit, while unavailable hardware does not erase dav1d results.
    assert len(report.get('aether',[]))==6, report
    assert all(x['frameReadyMs']>0 and abs(x['frameSeconds']-x['targetSeconds'])<.5 for x in report['aether'])
    serialized = json.dumps(report)
    assert 'file://' not in serialized and '/api/' not in serialized
    results.append({'fixture':fixture, 'softwareRows':len(software),
                    'hardwareMeasured':sum(x['status']=='ok' for x in hardware),
                    'aetherRows':len(report.get('aether',[])), 'success':True})
Path('dist/decode-trial-verification.json').write_text(json.dumps({
    'success':True, 'cases':results,
    'deviceHardwarePerformanceVerified':False,
    'scope':'AV1 lab preparation, real 8/10-bit software output, target PTS, repeat fingerprints, explicit hardware availability'}, indent=2)+'\n')
print(json.dumps(results), flush=True)
