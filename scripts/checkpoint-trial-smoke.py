"""Run the shipped checkpoint tester on 8/10-bit long-GOP simulator inputs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=kwargs.pop('timeout',120), **kwargs).strip()


device=json.loads(Path('dist/simulator-device.json').read_text())['udid']
bundle='io.github.nyanz00.NeoEPGStation'
run('xcrun','simctl','bootstatus',device,'-b',timeout=600)
run('xcrun','simctl','install',device,'build/simulator/Build/Products/Release-iphonesimulator/NeoEPGStation.app',timeout=300)
documents=Path(run('xcrun','simctl','get_app_container',device,bundle,'data'))/'Documents'
documents.mkdir(exist_ok=True)
results=[]
for depth in (8,10):
    subprocess.run(['xcrun','simctl','terminate',device,bundle],capture_output=True)
    source=documents/'checkpoint-input.mkv'
    shutil.copyfile(Path('tests/fixtures')/f'av1-seek-{depth}.mkv',source)
    report_path=documents/'checkpoint-benchmark.json';report_path.unlink(missing_ok=True)
    env=os.environ.copy();env['SIMCTL_CHILD_NEO_EPG_CHECKPOINT_TRIAL']=source.as_uri()
    run('xcrun','simctl','launch','--terminate-running-process',device,bundle,env=env)
    deadline=time.monotonic()+360
    report={}
    while time.monotonic()<deadline:
        if report_path.exists():
            report=json.loads(report_path.read_text())
            if report.get('status') in ('complete','partial','failed','cancelled'): break
        time.sleep(1)
    assert report.get('status') in ('complete','partial','failed','cancelled'), 'Checkpoint tester did not finish'
    Path('dist',f'checkpoint-trial-{depth}.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['status']=='complete',report
    assert report['schema']==3 and report['mode']=='dav1d-checkpoint' and report['networkInDecodeTimer'] is False
    assert report['expectedConditions']==16 and report['processFootprintAfterInputReleaseBytes']>0
    assert report['sample']['gopSeconds']>=10
    rows=report['checkpoint'];assert len(rows)==16
    actual={(r['threads'],r['packed'],r['requestedDistanceSeconds']) for r in rows}
    expected={(t,p,d) for t in (1,2,4,6) for p,d in ((False,6),(True,6),(True,2),(True,.25))}
    assert actual==expected
    for row in rows:
        assert row['status']==0 and row['decoderError']==0,row
        assert row['bitDepth']==depth and row['fullPixelComparedFrames']>0
        assert row['frameContexts']=={1:1,2:2,4:2,6:3}[row['threads']]
        assert row['fullPixelComparedBytes']>0
        assert row['checkpointSeconds']<row['targetSeconds']<row['firstFollowingKeyframeSeconds']
        assert 0<row['retainedBytes']<96*1024*1024
        assert row['restoreCount']==row['temporarySaveFreeCount']==row['targetVerifiedCount']==5
        assert row['fullSuffixPasses']==2 and row['failureStage']==0
        if row['packed']:
            assert row['originalPixelsDetached'] and row['allocationVerificationPasses']==2
        assert row['sameDecoder'] and row['emptyDecoderRejected'] and row['busyDecoderRejected'] and row['wrongOwnerRejected'] and row['suffixWithoutStateRejected']
        assert row['fullPixelCheckOutsideTimer'] and row['normalPlaybackUnchanged']
        assert len(row['repeatedSaveMs'])==len(row['restoredMs'])==len(row['restoreOnlyMs'])==5
        assert all(x>0 for x in row['repeatedSaveMs']+row['restoredMs']+row['restoreOnlyMs'])
        assert len(row['sampledFootprintBytes'])==5
        assert all(x>0 for x in row['sampledFootprintBytes'])
        assert row['processFootprintAfterBytes']>0 and row['sampledProcessFootprintPeakBytes']>0
    if depth==10:
        for t in (1,2,4,6):
            raw=next(r for r in rows if r['threads']==t and not r['packed'])
            packed=next(r for r in rows if r['threads']==t and r['packed'] and r['requestedDistanceSeconds']==6)
            assert packed['retainedBytes']<raw['retainedBytes']
    serialized=json.dumps(report)
    assert 'file://' not in serialized and '/api/' not in serialized
    results.append({'bitDepth':depth,'cases':16,'success':True})
Path('dist/checkpoint-trial-verification.json').write_text(json.dumps({
    'success':True,'cases':results,'devicePerformanceVerified':False,
    'scope':'shipping lab screen; 1/2/4/6 workers; lossless packed/raw; 8/10bit full suffix twice and five exact target restores after true keyframe; memory and input cleanup; private decoder namespace'
},indent=2)+'\n')
print(json.dumps(results),flush=True)
