"""PC-only checkpoint compression and dependency-selected compressed replay."""
import argparse,hashlib,json,os,shutil,statistics,subprocess,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];HERE=Path(__file__).resolve().parent
MT=HERE.parent/'dav1d-mt-checkpoint';SOURCE=ROOT/'.local/dav1d-storage';BUILD=SOURCE/'build'
PIN='54706fc6bc0cdecab7e9593974a4039cc038fca7'


def write(path,data):
    if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)


def run(args,env,timeout=300):
    args=[str(a) for a in args];args[0]=shutil.which(args[0],path=env['PATH']) or args[0]
    p=subprocess.run(args,cwd=ROOT,env=env,capture_output=True,timeout=timeout)
    if p.returncode:raise RuntimeError((p.stdout+p.stderr).decode(errors='replace')[-9000:])
    return p.stdout


def prepare(env):
    if not SOURCE.exists():run(['git','clone','--quiet',ROOT/'.local/dav1d-mt',SOURCE],env)
    assert run(['git','-C',SOURCE,'rev-parse','HEAD'],env).decode().strip()==PIN
    for src,dst in [(MT/'core.c','src/neo_checkpoint.c'),(MT/'core.h','include/neo_checkpoint.h'),
        (MT/'packed.c','src/neo_mt_packed.c'),(MT.parent/'dav1d-packed-checkpoint/packed.h','include/packed.h'),
        (MT.parent/'dav1d-checkpoint/probe.c','include/neo_base_probe.h'),(HERE/'storage.h','include/storage.h')]:write(SOURCE/dst,src.read_bytes())
    harness=(MT.parent/'dav1d-parallel/probe.c').read_text()
    harness=harness.replace('#include "../dav1d-checkpoint/probe.c"','#include "neo_base_probe.h"').replace('int main(int argc,char **argv) {','int neo_parallel_unused(int argc,char **argv) {')
    write(SOURCE/'include/neo_parallel_harness.h',harness.encode())
    base=(MT/'probe.c').read_text().replace('int main(int argc,char **argv) {','int neo_mt_unused(int argc,char **argv) {')
    write(SOURCE/'include/neo_storage_base.h',base.encode())
    lz=ROOT/'.local/storage-lz4';lz.mkdir(exist_ok=True)
    for name in ('lz4.c','lz4.h'):
        p=lz/name
        if not p.exists():p.write_bytes(urllib.request.urlopen('https://raw.githubusercontent.com/lz4/lz4/v1.10.0/lib/'+name,timeout=30).read())
    write(SOURCE/'include/lz4.h',(lz/'lz4.h').read_bytes())
    wrapper=b'#include <windows.h>\n#include "neo_mt_packed.c"\n'+(HERE/'compress.inc').read_bytes()+b'\n'+(HERE/'recipe.inc').read_bytes()
    write(SOURCE/'src/neo_storage.c',wrapper)
    meson=run(['git','-C',SOURCE,'show','HEAD:src/meson.build'],env)
    write(SOURCE/'src/meson.build',meson.replace(b"'cdf.c',",b"'cdf.c',\n    'neo_storage.c',",1))
    picture=run(['git','-C',SOURCE,'show','HEAD:src/picture.c'],env)
    write(SOURCE/'src/picture.c',picture+b'\n'+(MT/'picture-helper.inc').read_bytes())
    obu=run(['git','-C',SOURCE,'show','HEAD:src/obu.c'],env).decode()
    obu=obu.replace('#include "src/thread_task.h"','#include "src/thread_task.h"\n#include "storage.h"')
    anchor='    // We must have read a whole number of bytes at this point'
    assert obu.count(anchor)==1
    obu=obu.replace(anchor,'''    const int storage_obu=neo_storage_obu(c,in,type,gb.ptr_start,gb.ptr_end);
    if(storage_obu<0)goto error;
    if(storage_obu>0)return gb.ptr_end-gb.ptr_start;

'''+anchor)
    anchor='        if (type != DAV1D_OBU_FRAME)\n            break;'
    assert obu.count(anchor)==1
    obu=obu.replace(anchor,'''        const int storage_header=neo_storage_header(c,in,type,gb.ptr_start,gb.ptr,gb.ptr_end);
        if(storage_header<0)goto error;
        if(storage_header>0)goto skip;

'''+anchor)
    write(SOURCE/'src/obu.c',obu.encode())
    if not (BUILD/'build.ninja').exists():run(['meson','setup',BUILD.relative_to(ROOT).as_posix(),SOURCE.relative_to(ROOT).as_posix(),
        '--buildtype=release','--default-library=static','-Db_ndebug=false','-Denable_tools=false','-Denable_tests=false','-Denable_docs=false'],env)
    run(['ninja','-C',BUILD,'-j','8'],env)
    exe=BUILD/'storage-probe.exe'
    run(['gcc','-std=gnu11','-O2','-g','-Wall','-Wextra','-Werror','-I.local/dav1d-storage/include','-I.local/dav1d-storage/build/include',
        (HERE/'probe.c').relative_to(ROOT).as_posix(),(lz/'lz4.c').relative_to(ROOT).as_posix(),
        (BUILD/'src/libdav1d.a').relative_to(ROOT).as_posix(),'-o',exe.relative_to(ROOT).as_posix(),'-lzstd','-lm'],env)
    return exe


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--long-input',type=Path);ap.add_argument('--short-input',type=Path)
    ap.add_argument('--quick',action='store_true');ap.add_argument('--report',type=Path,default=HERE/'results.json');args=ap.parse_args()
    env=os.environ.copy();env['PATH']='C:/msys64/mingw64/bin'+os.pathsep+env['PATH'];env['TMP']=env['TEMP']='C:/msys64/tmp/neo-dav1d-checkpoint'
    exe=prepare(env);ffmpeg='C:/nyanzTV/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe';ffprobe=ffmpeg.replace('ffmpeg.exe','ffprobe.exe')
    cases=[('fixture10',ROOT/'tests/fixtures/av1-seek-10.mkv',[(18,20,26)])]
    if not args.quick:
        if args.long_input:cases.append(('long-gop',args.long_input,[(14,20,25),(18,20,25),(19.8,20.1,25)]))
        if args.short_input:cases.append(('six-second-gop',args.short_input,[(12.279,14.9,17),(30.297,32.9,35),(60.327,62.9,64)]))
    report={'revision':PIN,'platform':'Windows PC; six physical cores; software dav1d; GPU performance not measured',
            'method':'exact allocation roundtrips for nine lossless methods; original compressed frame dependency closure and header-only replay; exact reference pixels and full suffix; no network/audio/UI','cases':[]}
    for label,source,points in cases:
        ivf=ROOT/'.local'/('storage-'+label+'.ivf');run([ffmpeg,'-v','error','-y','-i',source,'-map','0:v:0','-c:v','copy','-t',str(max(p[2] for p in points)+1),'-f','ivf',ivf],env)
        packets=json.loads(run([ffprobe,'-v','error','-show_packets','-select_streams','v:0','-show_entries','packet=pts_time,flags','-of','json',ivf],env))['packets']
        keys=[float(p['pts_time']) for p in packets if 'K' in p['flags']]
        for cp,target,end in points:
            key=max(k for k in keys if k<=cp);raw=ROOT/'.local/storage-current.json'
            print('Testing',label,'checkpoint',cp,flush=True)
            with raw.open('wb') as f:subprocess.run([str(exe),str(ivf),str(cp),str(target),str(end),str(key),'1'],cwd=ROOT,env=env,stdout=f,check=True,timeout=600)
            row=json.loads(raw.read_text());row['case']=label
            for m in row['compression']:
                m['saveMedianMs']=statistics.median(m['saveMs']);m['restoreMedianMs']=statistics.median(m['restoreMs']);m['heldMiB']=m['heldBytes']/1048576
            for k,v in list(row['recipe'].items()):
                if k.endswith('Ms') and isinstance(v,list):row['recipe'][k+'Median']=statistics.median(v)
            report['cases'].append(row)
            sources=[*HERE.glob('*.c'),*HERE.glob('*.inc'),HERE/'storage.h',HERE/'run.py',*MT.glob('*.c'),MT/'core.h',MT/'picture-helper.inc',
                     MT.parent/'dav1d-parallel/probe.c',MT.parent/'dav1d-checkpoint/probe.c',MT.parent/'dav1d-packed-checkpoint/packed.h']
            report['sourceSHA256']={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
            report['lz4SourceSHA256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'.local/storage-lz4').glob('lz4.*')}
            report['librarySHA256']=hashlib.sha256((BUILD/'src/libdav1d.a').read_bytes()).hexdigest()
            args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_bytes((json.dumps(report,indent=2)+'\n').encode())
            print('Case passed. Recipe frames:',row['recipe']['selectedCodedFrames'],'/',row['recipe']['originalCodedFrames'],flush=True)


if __name__=='__main__':main()
