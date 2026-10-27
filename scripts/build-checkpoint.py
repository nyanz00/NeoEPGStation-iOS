"""Build an isolated, private dav1d checkpoint lab for each Apple SDK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from checkpoint_compression_sources import prepare as prepare_compression

ROOT = Path(__file__).resolve().parents[1]
PIN = '54706fc6bc0cdecab7e9593974a4039cc038fca7'
BASE = ROOT / 'build/checkpoint'
SOURCE = BASE / 'source'


def run(*args, **kwargs):
    command = [str(x) for x in args]
    command[0] = shutil.which(command[0]) or command[0]
    try:
        return subprocess.check_output(command, cwd=ROOT, **kwargs).decode(errors='replace').strip()
    except subprocess.CalledProcessError as error:
        sys.stderr.buffer.write(error.output[-16000:])
        raise


def write_changed(path, data):
    if not path.exists() or path.read_bytes()!=data:
        path.write_bytes(data)


def prepare():
    if not SOURCE.exists():
        run('git', 'clone', '--depth', '1', '--branch', '1.5.4',
            'https://github.com/videolan/dav1d.git', SOURCE)
    assert run('git', '-C', SOURCE, 'rev-parse', 'HEAD') == PIN
    # Rename every public entry point and make all definitions private. This
    # prevents normal playback from binding to the diagnostic implementation.
    headers = '\n'.join(p.read_text() for p in (SOURCE/'include/dav1d').glob('*.h') if p.name != 'common.h')
    public = sorted(set(re.findall(r'DAV1D_API[^;]*?\b(dav1d_\w+)\s*\(', headers, re.S)))
    assert 'dav1d_open' in public and 'dav1d_send_data' in public and len(public) >= 15
    prefix = '\n'.join('#define '+name+' neo_lab_'+name for name in public)
    common = run('git', '-C', SOURCE, 'show', 'HEAD:include/dav1d/common.h')+'\n'
    common = common.replace('#ifndef DAV1D_API', prefix+'\n#ifdef _WIN32\n#define DAV1D_API\n#else\n#define DAV1D_API __attribute__((visibility("hidden")))\n#endif\n#ifndef DAV1D_API', 1)
    write_changed(SOURCE/'include/dav1d/common.h', common.encode())
    for src, dst in [('vendor/checkpoint/core.c','src/neo_checkpoint.c'),
                     ('vendor/checkpoint/neo_checkpoint.h','include/neo_checkpoint.h'),
                     ('vendor/checkpoint/packed.c','src/neo_packed_checkpoint.c'),
                     ('vendor/checkpoint/packed.h','include/packed.h'),
                     ('vendor/checkpoint/lossless.h','include/lossless.h'),
                     ('vendor/checkpoint/rcomp.h','include/rcomp.h'),
                     ('vendor/checkpoint/lscomp.h','include/lscomp.h'),
                     ('vendor/checkpoint/lscomp-format.c','src/neo_lscomp_format.c'),
                     ('vendor/checkpoint/rcomp-format.c','src/neo_rcomp_format.c'),
                     ('vendor/checkpoint/metal-zstd-core.h','include/metal-zstd-core.h'),
                     ('vendor/checkpoint/metal-zstd-input.h','include/metal-zstd-input.h'),
                     ('vendor/checkpoint/metal-zstd-parallel.h','include/metal-zstd-parallel.h'),
                     ('vendor/checkpoint/metal-zstd-format.c','src/neo_metal_zstd_format.c'),
                     ('vendor/checkpoint/lab.c','src/neo_checkpoint_lab.c'),
                     ('vendor/checkpoint/NeoCheckpointLab.h','include/NeoCheckpointLab.h')]:
        write_changed(SOURCE/dst, (ROOT/src).read_bytes())
    for src,dst in [('vendor/checkpoint/NeoCheckpointPlayback.h','include/NeoCheckpointPlayback.h'),
                    ('vendor/checkpoint/playback.c','src/neo_checkpoint_playback.c')]:
        write_changed(SOURCE/dst,(ROOT/src).read_bytes())
    compression=prepare_compression(ROOT,SOURCE,ROOT/'dist/notices/CheckpointCompression')
    write_changed(SOURCE/'src/neo_packed_checkpoint.c',
        (ROOT/'vendor/checkpoint/packed.c').read_bytes()+b'\n'+(ROOT/'vendor/checkpoint/lossless.inc').read_bytes())
    write_changed(SOURCE/'src/neo_checkpoint_lab.c',
        (ROOT/'vendor/checkpoint/lab.c').read_bytes()+b'\n'+(ROOT/'vendor/checkpoint/storage-profile.inc').read_bytes()+b'\n'+(ROOT/'vendor/checkpoint/realtime.inc').read_bytes())
    meson = run('git','-C',SOURCE,'show','HEAD:src/meson.build')+'\n'
    # packed.c includes core.c: compile it once, not as two translation units.
    write_changed(SOURCE/'src/meson.build', meson.replace("'cdf.c',", "'cdf.c',\n    'neo_packed_checkpoint.c',\n    'neo_checkpoint_playback.c',\n    'neo_checkpoint_lab.c',\n    'neo_lz4.c',\n    'neo_zstd.c',\n    'neo_rcomp_format.c',\n    'neo_lscomp_format.c',\n    'neo_metal_zstd_format.c',", 1).encode())
    picture = run('git','-C',SOURCE,'show','HEAD:src/picture.c')+'\n'
    write_changed(SOURCE/'src/picture.c',picture.encode()+(ROOT/'vendor/checkpoint/picture-helper.inc').read_bytes())
    return public,compression


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('sdk', choices=['iphoneos','iphonesimulator','host'])
    args=ap.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    public,compression=prepare()
    work=BASE/(args.sdk+'-work')
    output=BASE/args.sdk
    output.mkdir(exist_ok=True)
    options=[]
    if args.sdk!='host':
        sdk=run('xcrun','--sdk',args.sdk,'--show-sdk-path')
        target='arm64-apple-ios18.0'+('-simulator' if args.sdk=='iphonesimulator' else '')
        cc=run('xcrun','--sdk',args.sdk,'--find','clang')
        flags=['-arch','arm64','-isysroot',sdk,'-target',target,'-fvisibility=hidden','-fno-common','-gline-tables-only']
        cross=BASE/(args.sdk+'-cross.ini')
        write_changed(cross, ("[binaries]\nc = "+repr(cc)+"\nar = '/usr/bin/ar'\nstrip = '/usr/bin/strip'\n[built-in options]\nc_args = "+repr(flags)+"\nc_link_args = "+repr(flags)+"\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'aarch64'\nendian = 'little'\n").encode())
        options=['--cross-file',str(cross)]
    if not (work/'build.ninja').exists():
        print(run('meson','setup',work.relative_to(ROOT),SOURCE.relative_to(ROOT),
              '--buildtype=release','--default-library=static','-Db_ndebug=false',
              '-Denable_tools=false','-Denable_tests=false','-Denable_docs=false',*options)[-1500:])
    print(run('ninja','-C',work,'-j','8')[-1500:])
    library=output/'libneocheckpoint.a'
    shutil.copyfile(work/'src/libdav1d.a',library)
    ls_source=json.loads((ROOT/'vendor/lscomp/source.json').read_text())
    for name,digest in ls_source['sourceSHA256'].items():
        assert hashlib.sha256((ROOT/'vendor/lscomp'/name).read_bytes()).hexdigest()==digest
    rcomp_source=json.loads((ROOT/'vendor/rcomp-metal/source.json').read_text())
    shader=(ROOT/'vendor/rcomp-metal/lz4.metal').read_bytes()
    assert hashlib.sha256(shader).hexdigest()==rcomp_source['shaderSHA256']
    if args.sdk!='host':
        write_changed(output/'rcomp-shader.h',('static const char neo_rcomp_shader_source[] = '+json.dumps(shader.decode())+';\n').encode())
        bridge=output/'rcomp-metal.o'
        run(cc,*flags,'-fobjc-arc','-fblocks','-std=gnu11','-Wall','-Werror=implicit-function-declaration',
            '-I',ROOT/'vendor/checkpoint','-I',output,'-c',ROOT/'vendor/checkpoint/rcomp-metal.m','-o',bridge)
        run('/usr/bin/ar','r',library,bridge)
        ls_shader=(ROOT/'vendor/checkpoint/lscomp.metal').read_text()
        write_changed(output/'lscomp-shader.h',('static const char neo_lscomp_shader_source[] = '+json.dumps(ls_shader)+';\n').encode())
        ls_bridge=output/'lscomp-metal.o'
        run(cc,*flags,'-fobjc-arc','-fblocks','-std=gnu11','-Wall','-Werror=implicit-function-declaration',
            '-I',ROOT/'vendor/checkpoint','-I',output,'-c',ROOT/'vendor/checkpoint/lscomp-metal.m','-o',ls_bridge)
        run('/usr/bin/ar','r',library,ls_bridge)
        mz_shader='#include <metal_stdlib>\nusing namespace metal;\n'+(ROOT/'vendor/checkpoint/metal-zstd-core.h').read_text()+'\n'+(ROOT/'vendor/checkpoint/metal-zstd-parallel.h').read_text()+'\n'+(ROOT/'vendor/checkpoint/metal-zstd-input.h').read_text()+'\n'+(ROOT/'vendor/checkpoint/metal-zstd.metal').read_text().replace('#include "metal-zstd-core.h"','').replace('#include "metal-zstd-parallel.h"','').replace('#include "metal-zstd-input.h"','')
        write_changed(output/'metal-zstd-shader.h',('static const char neo_mzstd_shader_source[] = '+json.dumps(mz_shader)+';\n').encode())
        mz_bridge=output/'metal-zstd.o'
        run(cc,*flags,'-fobjc-arc','-fblocks','-std=gnu11','-Wall','-Werror=implicit-function-declaration',
            '-I',ROOT/'vendor/checkpoint','-I',output,'-c',ROOT/'vendor/checkpoint/metal-zstd.m','-o',mz_bridge)
        run('/usr/bin/ar','r',library,mz_bridge)
    symbols=run('nm','-g',library.relative_to(ROOT))
    assert '_neo_lab_dav1d_open' in symbols or ' neo_lab_dav1d_open' in symbols
    assert not re.search(r'\b[Tt] _?dav1d_(open|send_data|get_picture|close)\b',symbols), 'Public decoder namespace collision'
    assert 'neo_checkpoint_lab_run' in symbols
    assert not re.search(r'\b[Tt] _?(?:ZSTD|ZDICT|LZ4)_\w+\b',symbols), 'Unisolated compression function'
    metadata={'revision':PIN,'sdk':args.sdk,'publicRenames':public,
              'librarySHA256':hashlib.sha256(library.read_bytes()).hexdigest(),
              'sourceSHA256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in (
                  'scripts/build-checkpoint.py','vendor/checkpoint/core.c',
                  'vendor/checkpoint/playback.c','vendor/checkpoint/NeoCheckpointPlayback.h',
                  'vendor/checkpoint/neo_checkpoint.h','vendor/checkpoint/packed.c',
                  'vendor/checkpoint/packed.h','vendor/checkpoint/picture-helper.inc',
                  'vendor/checkpoint/lab.c','vendor/checkpoint/NeoCheckpointLab.h',
                  'vendor/checkpoint/lossless.h','vendor/checkpoint/lossless.inc',
                  'vendor/checkpoint/storage-profile.inc','vendor/checkpoint/realtime.inc',
                  'scripts/checkpoint_compression_sources.py','vendor/checkpoint/rcomp.h',
                  'vendor/checkpoint/rcomp-format.c','vendor/checkpoint/rcomp-metal.m',
                  'vendor/rcomp-metal/lz4.metal','vendor/rcomp-metal/source.json',
                  'vendor/checkpoint/lscomp.h','vendor/checkpoint/lscomp-format.c',
                  'vendor/checkpoint/lscomp-metal.m','vendor/checkpoint/lscomp.metal','vendor/lscomp/source.json',
                  'vendor/checkpoint/metal-zstd-core.h','vendor/checkpoint/metal-zstd-format.c',
                  'vendor/checkpoint/metal-zstd-parallel.h','vendor/checkpoint/metal-zstd-input.h',
                  'vendor/checkpoint/metal-zstd.m','vendor/checkpoint/metal-zstd.metal','vendor/checkpoint/MetalZstd-LICENSE')},
              'rcompMetal':rcomp_source,
              'lscomp':json.loads((ROOT/'vendor/lscomp/source.json').read_text()),
              'compression':compression,
              'normalPlaybackDecoderUnchanged':True}
    (output/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
    notice=ROOT/'dist/notices/CheckpointDav1d'
    notice.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(SOURCE/'COPYING',notice/'COPYING')
    for p in metadata['sourceSHA256']:
        shutil.copyfile(ROOT/p,notice/Path(p).name)
    (notice/'upstream.json').write_text(json.dumps({'revision':PIN,'source':'https://github.com/videolan/dav1d/tree/'+PIN,'publicRenames':public},indent=2)+'\n')
    (ROOT/'dist/notices/CheckpointCompression/provenance.json').write_text(json.dumps(compression,indent=2)+'\n')
    shutil.copytree(ROOT/'vendor/lscomp',ROOT/'dist/notices/LsCOMP',dirs_exist_ok=True)
    shutil.copytree(ROOT/'vendor/rcomp-metal',ROOT/'dist/notices/RcompMetal',dirs_exist_ok=True)
    dist=ROOT/'dist';dist.mkdir(exist_ok=True)
    shutil.copyfile(output/'provenance.json',dist/('checkpoint-'+args.sdk+'.json'))
    print('Private checkpoint library verified:',args.sdk)


if __name__=='__main__': main()
