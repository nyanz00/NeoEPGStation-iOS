"""PC raw dav1d parallelism comparison. No checkpoint API is invoked."""
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
ORIGINAL=HERE.parent/'dav1d-checkpoint'
SOURCE=ROOT/'.local/dav1d-checkpoint'
BUILD=SOURCE/'build'
PIN='54706fc6bc0cdecab7e9593974a4039cc038fca7'


def run(args,env,log=None):
    args=[str(a) for a in args];args[0]=shutil.which(args[0],path=env['PATH']) or args[0]
    p=subprocess.run(args,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if log:(ROOT/'.local'/log).write_bytes(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError((p.stderr+p.stdout).decode('utf-8',errors='replace')[-6000:])
    return p.stdout.decode('utf-8')


def write(path,data):
    if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input',type=Path)
    ap.add_argument('--toolchain',type=Path,default=Path('C:/msys64/mingw64/bin'))
    ap.add_argument('--ffmpeg',default=shutil.which('ffmpeg') or 'C:/nyanzTV/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe')
    ap.add_argument('--report',type=Path,default=ROOT/'.local/parallel-results.json')
    args=ap.parse_args()
    if os.name!='nt':ap.error('Windows timing and physical-core selection harness')
    env=os.environ.copy();env['PATH']=str(args.toolchain)+os.pathsep+env['PATH'];env['CC']=str(args.toolchain/'gcc.exe')
    temp=args.toolchain.parents[1]/'tmp/neo-dav1d-checkpoint';temp.mkdir(parents=True,exist_ok=True)
    env['TMP']=env['TEMP']=str(temp)
    if not SOURCE.exists():
        run(['git','clone','--depth','1','--branch','1.5.4','https://github.com/videolan/dav1d.git',SOURCE],env)
    assert run(['git','-C',SOURCE,'rev-parse','HEAD'],env).strip()==PIN
    for src,dst in [(ORIGINAL/'checkpoint.c','src/neo_checkpoint.c'),(ORIGINAL/'neo_checkpoint.h','include/neo_checkpoint.h')]:
        write(SOURCE/dst,src.read_bytes())
    meson=run(['git','-C',SOURCE,'show','HEAD:src/meson.build'],env)
    write(SOURCE/'src/meson.build',meson.replace("'cdf.c',","'cdf.c',\n    'neo_checkpoint.c',",1).encode())
    if not (BUILD/'build.ninja').exists():
        run(['meson','setup',BUILD.relative_to(ROOT).as_posix(),SOURCE.relative_to(ROOT).as_posix(),
             '--buildtype=release','--default-library=static','-Db_ndebug=false','-Denable_tools=false',
             '-Denable_tests=false','-Denable_docs=false'],env,'parallel-setup.log')
    run(['ninja','-C',BUILD,'-j','8'],env,'parallel-build.log')
    exe=BUILD/'parallel-probe.exe'
    run(['gcc','-std=gnu11','-O2','-g','-Wall','-Wextra','-Werror',
         '-I.local/dav1d-checkpoint/include','-I.local/dav1d-checkpoint/build/include',
         (HERE/'probe.c').relative_to(ROOT).as_posix(),(BUILD/'src/libdav1d.a').relative_to(ROOT).as_posix(),
         '-o',exe.relative_to(ROOT).as_posix(),'-lm'],env,'parallel-link.log')
    cases=[('fixture-8bit',ROOT/'tests/fixtures/av1-seek-8.mkv'),('fixture-10bit',ROOT/'tests/fixtures/av1-seek-10.mkv')]
    if args.input:cases.append(('recording-10bit-long-gop',args.input.resolve()))
    results=[]
    for label,source in cases:
        ivf=Path('.local')/('parallel-'+label+'.ivf')
        run([args.ffmpeg,'-v','error','-y','-i',source,'-map','0:v:0','-c:v','copy','-t','25','-f','ivf',ivf],env)
        print('Checking '+label+' (1/2/4/6 threads, one/auto frame delay)',flush=True)
        row=json.loads(run([exe,ivf,14,20],env));row['case']=label
        for setting in row['rows']:
            for key in ['targetMs','processCpuMs','prefixMs','initializeMs']:
                setting[key+'Median']=statistics.median(setting[key])
            setting['averageCpuParallelismMedian']=statistics.median(c/w for c,w in zip(setting['processCpuMs'],setting['targetMs']))
        results.append(row)
        sources=[HERE/'probe.c',HERE/'run.py',ORIGINAL/'probe.c',ORIGINAL/'checkpoint.c',ORIGINAL/'neo_checkpoint.h']
        report={'upstreamRevision':PIN,'compiler':run(['gcc','--version'],env).splitlines()[0],
                'method':'fresh decoder; prefix 0..14 fully decoded/drained outside timer; RAM packets 14..20 to actual target image; no checkpoints/skips/audio/network/UI; 5 rotated repetitions',
                'sourceSHA256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                'librarySHA256':hashlib.sha256((BUILD/'src/libdav1d.a').read_bytes()).hexdigest(),'cases':results}
        args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    print('All threaded output frames match the single-thread full-pixel oracle.',flush=True)


if __name__=='__main__':main()
