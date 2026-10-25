"""Parallel checkpoint restoration, including packed pictures and worker progress."""
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
SOURCE=ROOT/'.local/dav1d-mt'
BUILD=SOURCE/'build'
PIN='54706fc6bc0cdecab7e9593974a4039cc038fca7'


def run(args,env,log=None,timeout=240):
    args=[str(a) for a in args];args[0]=shutil.which(args[0],path=env['PATH']) or args[0]
    p=subprocess.run(args,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
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
    ap.add_argument('--report',type=Path,default=ROOT/'.local/mt-checkpoint-results.json')
    args=ap.parse_args()
    if os.name!='nt':ap.error('Windows timing/core-selection harness')
    env=os.environ.copy();env['PATH']=str(args.toolchain)+os.pathsep+env['PATH'];env['CC']=str(args.toolchain/'gcc.exe')
    temp=args.toolchain.parents[1]/'tmp/neo-dav1d-checkpoint';temp.mkdir(parents=True,exist_ok=True);env['TMP']=env['TEMP']=str(temp)
    if not SOURCE.exists():run(['git','clone','--quiet','--depth','1','--branch','1.5.4','https://github.com/videolan/dav1d.git',SOURCE],env)
    assert run(['git','-C',SOURCE,'rev-parse','HEAD'],env).strip()==PIN
    packed=HERE.parent/'dav1d-packed-checkpoint';single=HERE.parent/'dav1d-checkpoint'
    for src,dst in [(HERE/'core.c','src/neo_checkpoint.c'),(HERE/'core.h','include/neo_checkpoint.h'),
                    (HERE/'packed.c','src/neo_mt_packed.c'),(packed/'packed.h','include/packed.h'),
                    (single/'probe.c','include/neo_base_probe.h')]:write(SOURCE/dst,src.read_bytes())
    harness=(HERE.parent/'dav1d-parallel/probe.c').read_text(encoding='utf-8')
    harness=harness.replace('#include "../dav1d-checkpoint/probe.c"','#include "neo_base_probe.h"')
    harness=harness.replace('int main(int argc,char **argv) {','int neo_parallel_original_unused(int argc,char **argv) {')
    write(SOURCE/'include/neo_parallel_harness.h',harness.encode())
    meson=run(['git','-C',SOURCE,'show','HEAD:src/meson.build'],env)
    write(SOURCE/'src/meson.build',meson.replace("'cdf.c',","'cdf.c',\n    'neo_mt_packed.c',",1).encode())
    picture=run(['git','-C',SOURCE,'show','HEAD:src/picture.c'],env)
    write(SOURCE/'src/picture.c',picture.encode()+b'\n'+(HERE/'picture-helper.inc').read_bytes())
    if not (BUILD/'build.ninja').exists():
        run(['meson','setup',BUILD.relative_to(ROOT).as_posix(),SOURCE.relative_to(ROOT).as_posix(),
             '--buildtype=release','--default-library=static','-Db_ndebug=false','-Denable_tools=false',
             '-Denable_tests=false','-Denable_docs=false'],env,'mt-checkpoint-setup.log')
    run(['ninja','-C',BUILD,'-j','8'],env,'mt-checkpoint-build.log')
    exe=BUILD/'mt-probe.exe'
    run(['gcc','-std=gnu11','-O2','-g','-Wall','-Wextra','-Werror','-I.local/dav1d-mt/include','-I.local/dav1d-mt/build/include',
         (HERE/'probe.c').relative_to(ROOT).as_posix(),(BUILD/'src/libdav1d.a').relative_to(ROOT).as_posix(),
         '-o',exe.relative_to(ROOT).as_posix(),'-lm'],env,'mt-checkpoint-link.log')
    cases=[('fixture-8bit',ROOT/'tests/fixtures/av1-seek-8.mkv'),('fixture-10bit',ROOT/'tests/fixtures/av1-seek-10.mkv')]
    if args.input:cases.append(('recording-10bit-long-gop',args.input.resolve()))
    results=[]
    for label,source in cases:
        ivf=Path('.local')/('mt-'+label+'.ivf')
        run([args.ffmpeg,'-v','error','-y','-i',source,'-map','0:v:0','-c:v','copy','-t','32','-f','ivf',ivf],env)
        settings=[(1,1,14),(2,0,14),(4,0,14),(6,0,14),(6,0,18),(6,0,19.8)] if label.startswith('recording') else [(1,1,18),(2,0,18),(4,0,18),(6,0,19.8)]
        for threads,delay,point in settings:
            print(f'Checking {label}: threads={threads}, delay={delay}, checkpoint={point}',flush=True)
            row=json.loads(run([exe,ivf,threads,delay,point,20,30],env));row['case']=label
            for mode in ['unpacked','packed']:
                for key in ['saveMs','restoreMs','restoreAndSuffixMs']:row[mode][key+'Median']=statistics.median(row[mode][key])
                row[mode]['heldMiB']=row[mode]['heldBytes']/1048576
            results.append(row)
            sources=[*HERE.glob('*.c'),HERE/'core.h',HERE/'picture-helper.inc',HERE/'run.py',packed/'packed.h',single/'probe.c',HERE.parent/'dav1d-parallel/probe.c']
            report={'upstreamRevision':PIN,'method':'drained immutable checkpoints; worker idle synchronization; 5 repeated cross-keyframe full-pixel restores; timing excludes verification/network/UI',
                    'sourceSHA256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                    'compiler':run(['gcc','--version'],env).splitlines()[0],'cases':results}
            args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    print('All parallel raw/packed checkpoint validations passed.',flush=True)


if __name__=='__main__':main()
