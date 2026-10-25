"""PC-only comparison of retained frames and lossless 10-bit packed snapshots."""
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
SOURCE=ROOT/'.local/dav1d-packed'
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
    ap.add_argument('--report',type=Path,default=ROOT/'.local/packed-checkpoint-results.json')
    args=ap.parse_args()
    if os.name!='nt':ap.error('Current timing/affinity harness targets Windows')
    env=os.environ.copy();env['PATH']=str(args.toolchain)+os.pathsep+env['PATH']
    env['CC']=str(args.toolchain/'gcc.exe')
    temp=args.toolchain.parents[1]/'tmp/neo-dav1d-checkpoint';temp.mkdir(parents=True,exist_ok=True)
    env['TMP']=env['TEMP']=str(temp)
    if not SOURCE.exists():
        run(['git','clone','--quiet','--depth','1','--branch','1.5.4','https://github.com/videolan/dav1d.git',SOURCE],env)
    assert run(['git','-C',SOURCE,'rev-parse','HEAD'],env).strip()==PIN
    for src,dst in [(ORIGINAL/'checkpoint.c','src/neo_checkpoint.c'),(ORIGINAL/'neo_checkpoint.h','include/neo_checkpoint.h'),
                    (HERE/'packed.c','src/neo_packed_checkpoint.c'),(HERE/'packed.h','include/packed.h')]:
        write(SOURCE/dst,src.read_bytes())
    meson=run(['git','-C',SOURCE,'show','HEAD:src/meson.build'],env)
    write(SOURCE/'src/meson.build',meson.replace("'cdf.c',","'cdf.c',\n    'neo_packed_checkpoint.c',",1).encode())
    picture=run(['git','-C',SOURCE,'show','HEAD:src/picture.c'],env)
    write(SOURCE/'src/picture.c',picture.encode()+b'\n'+(HERE/'picture-helper.inc').read_bytes())
    if not (BUILD/'build.ninja').exists():
        run(['meson','setup',BUILD.relative_to(ROOT).as_posix(),SOURCE.relative_to(ROOT).as_posix(),
             '--buildtype=release','--default-library=static','-Db_ndebug=false','-Denable_tools=false',
             '-Denable_tests=false','-Denable_docs=false'],env,'packed-checkpoint-setup.log')
    run(['ninja','-C',BUILD,'-j','8'],env,'packed-checkpoint-build.log')
    exe=BUILD/'packed-probe.exe'
    run(['gcc','-std=gnu11','-O2','-g','-Wall','-Wextra','-Werror',
         '-I.local/dav1d-packed/include','-I.local/dav1d-packed/build/include',
         (HERE/'probe.c').relative_to(ROOT).as_posix(),(BUILD/'src/libdav1d.a').relative_to(ROOT).as_posix(),
         '-o',exe.relative_to(ROOT).as_posix(),'-lm'],env,'packed-checkpoint-link.log')
    cases=[('fixture-8bit',ROOT/'tests/fixtures/av1-seek-8.mkv',[18]),
           ('fixture-10bit',ROOT/'tests/fixtures/av1-seek-10.mkv',[18])]
    if args.input:cases.append(('recording-10bit-long-gop',args.input.resolve(),[19.8,18,14]))
    results=[]
    for label,source,positions in cases:
        ivf=Path('.local')/('packed-'+label+'.ivf')
        run([args.ffmpeg,'-v','error','-y','-i',source,'-map','0:v:0','-c:v','copy','-t','32','-f','ivf',ivf],env)
        for cp in positions:
            print(f'Checking {label}, checkpoint={cp}, target=20',flush=True)
            row=json.loads(run([exe,ivf,cp,20,30],env));row['case']=label
            for mode in ['unpacked','packed']:
                for metric in ['saveMs','freeMs','restoreMs','restoreAndSuffixMs']:
                    row[mode][metric+'Median']=statistics.median(row[mode][metric])
                row[mode]['heldMiB']=row[mode]['heldBytes']/1048576
            row['savedMiB']=(row['unpacked']['heldBytes']-row['packed']['heldBytes'])/1048576
            row['reductionPercent']=100*(1-row['packed']['heldBytes']/row['unpacked']['heldBytes'])
            results.append(row)
            # Persist completed cases so later interruption never loses evidence.
            args.report.parent.mkdir(parents=True,exist_ok=True)
            sources=[HERE/'packed.c',HERE/'packed.h',HERE/'picture-helper.inc',HERE/'probe.c',ORIGINAL/'checkpoint.c',ORIGINAL/'probe.c']
            report={'upstreamRevision':PIN,'method':'Windows PC single-thread; first allowed logical CPU; images in RAM; no network/audio/UI in timers',
                    'compiler':run(['gcc','--version'],env).splitlines()[0],
                    'sourceSHA256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},'cases':results}
            args.report.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    print('All packed allocation bytes and subsequent decoded pixels match.',flush=True)


if __name__=='__main__':main()
