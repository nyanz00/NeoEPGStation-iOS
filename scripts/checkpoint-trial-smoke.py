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
    assert report['schema']==4 and report['mode']=='dav1d-checkpoint-lossless'
    assert report['networkInDecodeTimer'] is False and report['gpuCompression'] is False
    assert report['renderingIncluded'] is False and report['audio'] is False
    assert report['expectedConditions']==10 and report['processFootprintAfterInputReleaseBytes']>0
    assert report['sample']['gopSeconds']>=10
    rows=report['checkpoint'];assert len(rows)==10
    storage=[r for r in rows if r['kind']=='storage']
    paced=[r for r in rows if r['kind']=='paced']
    assert {(r['method'],r['requestedDistanceSeconds']) for r in storage}=={(m,d) for m in (0,4,7) for d in (2,.25)}
    assert len(paced)==4 and {r['method'] for r in paced}=={-1,0,4,7}
    for row in rows:
        assert row['status']==0 and row['decoderError']==0,row
        assert row['threads']==6 and row['frameContexts']==3
        assert row['normalPlaybackUnchanged'] and row['processFootprintAfterBytes']>0
    for row in storage:
        assert row['bitDepth']==depth and row['fullPixelComparedFrames']>0
        assert row['fullPixelComparedBytes']>0
        assert row['checkpointSeconds']<row['targetSeconds']<row['firstFollowingKeyframeSeconds']
        assert 0<row['retainedBytes']<96*1024*1024
        assert row['restoreCount']==row['temporarySaveFreeCount']==row['targetVerifiedCount']==5
        assert row['fullSuffixPasses']==2 and row['failureStage']==0
        assert row['originalPixelsDetached'] and row['allocationVerificationPasses']==2
        assert row['sameDecoder'] and row['emptyDecoderRejected'] and row['busyDecoderRejected'] and row['wrongOwnerRejected']
        assert row['fullPixelCheckOutsideTimer']
        assert len(row['repeatedSaveMs'])==len(row['restoredMs'])==len(row['restoreOnlyMs'])==len(row['saveThreadCpuMs'])==5
        assert all(x>0 for x in row['repeatedSaveMs']+row['restoredMs']+row['restoreOnlyMs'])
        assert all(x>=0 for x in row['saveThreadCpuMs'])
        assert len(row['sampledFootprintBytes'])==5
        assert all(x>0 for x in row['sampledFootprintBytes'])
        assert row['sampledProcessFootprintPeakBytes']>0
    for row in paced:
        n=row['completedSaves'];method=row['method']
        assert row['frames']>0 and row['targetVerifiedCount']==3
        assert row['mediaSeconds']>2 and row['pacedWallSeconds']>1
        assert row['saveIntervalSeconds']==2 and row['compressionWorkerQoS']=='utility'
        assert row['compressionWorkers']==(0 if method<0 else 1)
        assert row['memoryBudgetBytes']==64*1024*1024
        assert 0<=row['retainedBytes']<=row['maximumRetainedBytes']<=row['memoryBudgetBytes']
        assert len(row['encodeWallMs'])==len(row['encodeThreadCpuMs'])==len(row['captureMs'])==n
        assert all(x>0 for x in row['encodeWallMs']) and all(x>=0 for x in row['encodeThreadCpuMs']+row['captureMs'])
        assert len(row['budgetSeekMs'])==len(row['budgetTargetSeconds'])==len(row['chosenCheckpointSeconds'])==len(row['usedCheckpoint'])==3
        assert all(x>0 for x in row['budgetSeekMs'])
        assert all(c<=t for c,t in zip(row['chosenCheckpointSeconds'],row['budgetTargetSeconds']))
        assert 0<=row['frameDeadlineMisses']<=row['frames']
        assert 0<=row['frameReadyLatenessMeanMs']<=row['frameReadyLatenessMaxMs']
        assert 0<=row['frameReadyLatenessP95Ms']<=row['frameReadyLatenessMaxMs']
        assert row['renderingIncluded'] is False and row['audioIncluded'] is False
        if method<0:
            assert n==row['retainedCount']==row['evictedCheckpoints']==row['retainedBytes']==0
            assert not any(row['usedCheckpoint'])
        else:
            assert n>0 and row['retainedCount']>0 and any(row['usedCheckpoint'])
    if depth==10:
        for distance in (2,.25):
            group={r['method']:r for r in storage if r['requestedDistanceSeconds']==distance}
            assert group[4]['retainedBytes']<group[0]['retainedBytes'] and group[7]['retainedBytes']<group[0]['retainedBytes']
    serialized=json.dumps(report)
    assert 'file://' not in serialized and '/api/' not in serialized
    results.append({'bitDepth':depth,'cases':10,'success':True})
Path('dist/checkpoint-trial-verification.json').write_text(json.dumps({
    'success':True,'cases':results,'devicePerformanceVerified':False,
    'scope':'shipping CPU lossless lab; packed/LZ4/Zstd; six workers; 8/10bit suffix and target pixels; paced decode with asynchronous saves under 64MiB retained-state budget; no rendering/audio; private namespace'
},indent=2)+'\n')
print(json.dumps(results),flush=True)
