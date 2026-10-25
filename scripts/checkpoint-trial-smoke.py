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
    deadline=time.monotonic()+240
    while not report_path.exists() and time.monotonic()<deadline: time.sleep(1)
    assert report_path.exists(), 'Checkpoint tester did not finish'
    report=json.loads(report_path.read_text())
    Path('dist',f'checkpoint-trial-{depth}.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['status']=='complete',report
    assert report['mode']=='dav1d-checkpoint' and report['networkInDecodeTimer'] is False
    assert report['sample']['gopSeconds']>=10
    rows=report['checkpoint'];assert len(rows)==2
    for row in rows:
        assert row['status']==0 and row['decoderError']==0,row
        assert row['bitDepth']==depth and row['fullPixelComparedFrames']>50
        assert row['fullPixelComparedBytes']>0
        assert row['checkpointSeconds']<row['targetSeconds']<row['firstFollowingKeyframeSeconds']
        assert 0<row['retainedBytes']<96*1024*1024
        assert row['restoreCount']==row['temporarySaveFreeCount']==5
        assert row['sameDecoder'] and row['emptyDecoderRejected'] and row['wrongOwnerRejected'] and row['suffixWithoutStateRejected']
        assert row['fullPixelCheckOutsideTimer'] and row['normalPlaybackUnchanged']
        assert len(row['baselineMs'])==len(row['restoredMs'])==len(row['restoreOnlyMs'])==5
        assert all(x>0 for x in row['baselineMs']+row['restoredMs'])
        assert len(row['sampledFootprintBytes'])==5
        assert all(x>0 for x in row['sampledFootprintBytes'])
        assert row['processFootprintAfterBytes']>0 and row['sampledProcessFootprintPeakBytes']>0
    serialized=json.dumps(report)
    assert 'file://' not in serialized and '/api/' not in serialized
    results.append({'bitDepth':depth,'cases':2,'success':True})
Path('dist/checkpoint-trial-verification.json').write_text(json.dumps({
    'success':True,'cases':results,'devicePerformanceVerified':False,
    'scope':'shipping lab screen; 8/10bit full-pixel comparison; five same-decoder restores after true keyframe; memory observations; private decoder namespace'
},indent=2)+'\n')
print(json.dumps(results),flush=True)
