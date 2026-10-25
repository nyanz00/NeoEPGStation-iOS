"""Windows PC: real keyframes vs one packed checkpoint at each GOP midpoint."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
MT=HERE.parent/'dav1d-mt-checkpoint'
SOURCE=ROOT/'.local/dav1d-mt'
BUILD=SOURCE/'build'
PIN='54706fc6bc0cdecab7e9593974a4039cc038fca7'


def write(path,data):
    if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)


def run(args,env):
    args=[str(a) for a in args];args[0]=shutil.which(args[0],path=env['PATH']) or args[0]
    p=subprocess.run(args,cwd=ROOT,env=env,capture_output=True,timeout=300)
    if p.returncode:raise RuntimeError((p.stdout+p.stderr).decode('utf-8',errors='replace')[-6000:])
    return p.stdout


def summary(values):
    return {'count':len(values),'medianMs':statistics.median(values),'meanMs':statistics.mean(values),
            'minMs':min(values),'maxMs':max(values)}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input',type=Path,required=True)
    ap.add_argument('--ffmpeg',default='C:/nyanzTV/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe')
    ap.add_argument('--ffprobe',default='C:/nyanzTV/ffmpeg-7.1.1-essentials_build/bin/ffprobe.exe')
    ap.add_argument('--report',type=Path,default=HERE/'results.json')
    args=ap.parse_args();env=os.environ.copy()
    env['PATH']='C:/msys64/mingw64/bin'+os.pathsep+env['PATH']
    env['TMP']=env['TEMP']='C:/msys64/tmp/neo-dav1d-checkpoint'
    assert SOURCE.exists(),'Run the preceding MT experiment once to prepare pinned dav1d'
    assert run(['git','-C',SOURCE,'rev-parse','HEAD'],env).decode().strip()==PIN
    for src,dst in [(MT/'core.c','src/neo_checkpoint.c'),(MT/'core.h','include/neo_checkpoint.h'),
                    (MT/'packed.c','src/neo_mt_packed.c'),(MT.parent/'dav1d-packed-checkpoint/packed.h','include/packed.h'),
                    (MT.parent/'dav1d-checkpoint/probe.c','include/neo_base_probe.h')]:
        write(SOURCE/dst,src.read_bytes())
    harness=(MT.parent/'dav1d-parallel/probe.c').read_text()
    harness=harness.replace('#include "../dav1d-checkpoint/probe.c"','#include "neo_base_probe.h"')
    harness=harness.replace('int main(int argc,char **argv) {','int neo_parallel_original_unused(int argc,char **argv) {')
    write(SOURCE/'include/neo_parallel_harness.h',harness.encode())
    base=(MT/'probe.c').read_text().replace('int main(int argc,char **argv) {','int neo_mt_original_unused(int argc,char **argv) {')
    write(SOURCE/'include/neo_midpoint_base.h',base.encode())
    meson=run(['git','-C',SOURCE,'show','HEAD:src/meson.build'],env)
    write(SOURCE/'src/meson.build',meson.replace(b"'cdf.c',",b"'cdf.c',\n    'neo_mt_packed.c',",1))
    picture=run(['git','-C',SOURCE,'show','HEAD:src/picture.c'],env)
    write(SOURCE/'src/picture.c',picture+b'\n'+(MT/'picture-helper.inc').read_bytes())
    run(['ninja','-C',BUILD,'-j','8'],env)
    exe=BUILD/'midpoint-probe.exe'
    run(['gcc','-std=gnu11','-O2','-g','-Wall','-Wextra','-Werror',
         '-I.local/dav1d-mt/include','-I.local/dav1d-mt/build/include',
         (HERE/'probe.c').relative_to(ROOT).as_posix(),(BUILD/'src/libdav1d.a').relative_to(ROOT).as_posix(),
         '-o',exe.relative_to(ROOT).as_posix(),'-lm'],env)
    metadata=json.loads(run([args.ffprobe,'-v','error','-select_streams','v:0','-show_entries',
        'stream=codec_name,profile,width,height,pix_fmt,avg_frame_rate,time_base:format=duration,size','-of','json',args.input],env))
    assert metadata['streams'][0]['codec_name']=='av1'
    packets=json.loads(run([args.ffprobe,'-v','error','-select_streams','v:0','-show_packets',
        '-show_entries','packet=pts_time,flags','-of','json',args.input],env))['packets']
    keys=[float(x['pts_time']) for x in packets if 'K' in x['flags']]
    gaps=[b-a for a,b in zip(keys,keys[1:])]
    # First full GOPs covering at least one minute, including shorter scene cuts.
    end=next(i for i,x in enumerate(keys) if x>=60)
    assert 1<=end<=20 and abs(keys[0])<.001
    sample=ROOT/'.local/midpoint-input.ivf'
    run([args.ffmpeg,'-v','error','-y','-i',args.input,'-map','0:v:0','-c:v','copy','-t',str(keys[end]+1),'-f','ivf',sample],env)
    ivf=json.loads(run([args.ffprobe,'-v','error','-select_streams','v:0','-show_packets',
        '-show_entries','packet=pts_time,flags','-of','json',sample],env))['packets']
    indices=[i for i,p in enumerate(ivf) if 'K' in p['flags']][:end+1]
    assert len(indices)==end+1
    for i,key in zip(indices,keys[:end+1]):assert abs(float(ivf[i]['pts_time'])-key)<.001
    keyfile=ROOT/'.local/midpoint-keys.txt';keyfile.write_text(' '.join(map(str,indices)))
    raw=ROOT/'.local/midpoint-raw-results.json'
    print('Comparing',end,'GOPs /',end*6,'matched target positions / 3 modes / 5 repetitions per mode',flush=True)
    with raw.open('wb') as f:
        subprocess.run([str(exe),str(sample),str(keyfile),'6'],cwd=ROOT,env=env,stdout=f,check=True,timeout=600)
    result=json.loads(raw.read_text());assert result['success']
    rows=result['rows']
    for row in rows:
        row['fromKeyframeMedianMs']=statistics.median(row['fromKeyframeMs'])
        row['withMidpointMedianMs']=statistics.median(row['withMidpointMs'])
        row['periodicSixSecondsMedianMs']=statistics.median(row['periodicSixSecondsMs'])
    result['summary']={}
    for name,predicate in [('all',lambda r:True),('beforeMidpoint',lambda r:not r['usesCheckpoint']),('afterMidpoint',lambda r:r['usesCheckpoint'])]:
        group=[r for r in rows if predicate(r)]
        result['summary'][name]={'fromKeyframe':summary([x for r in group for x in r['fromKeyframeMs']]),
            'withMidpoint':summary([x for r in group for x in r['withMidpointMs']]),
            'periodicSixSeconds':summary([x for r in group for x in r['periodicSixSecondsMs']]),
            'medianOfTargetMedians':{'fromKeyframe':statistics.median(r['fromKeyframeMedianMs'] for r in group),
                                   'withMidpoint':statistics.median(r['withMidpointMedianMs'] for r in group),
                                   'periodicSixSeconds':statistics.median(r['periodicSixSecondsMedianMs'] for r in group)}}
    sources=[HERE/'probe.c',HERE/'run.py',*MT.glob('*.c'),MT/'core.h',MT/'picture-helper.inc',
             MT.parent/'dav1d-packed-checkpoint/packed.h',MT.parent/'dav1d-parallel/probe.c',MT.parent/'dav1d-checkpoint/probe.c']
    report={'upstreamRevision':PIN,'method':'same targets / six workers / warmed reusable decoders / RAM input / five rotating ABC repetitions / no checkpoints vs packed GOP midpoints vs packed periodic six-second points / use latest key or saved point / exact pixels outside timers',
            'networkAudioUIIncluded':False,'metadata':metadata,'wholeFileKeyframes':len(keys),
            'wholeFileKeyframeGapSeconds':{'min':min(gaps),'median':statistics.median(gaps),'max':max(gaps)},
            'sampleSeconds':keys[end],'sourceSHA256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
            'librarySHA256':hashlib.sha256((BUILD/'src/libdav1d.a').read_bytes()).hexdigest(),
            'compiler':run(['gcc','--version'],env).decode().splitlines()[0],'result':result}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    print(json.dumps(result['summary'],indent=2),flush=True)
    print('All targets matched exact pixels; checkpoints held bytes:',result['totalCheckpointBytes'],flush=True)


if __name__=='__main__':main()
