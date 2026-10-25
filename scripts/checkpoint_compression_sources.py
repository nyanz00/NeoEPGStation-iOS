"""Pinned, isolated LZ4/Zstd sources for the device checkpoint diagnostic."""
import hashlib
import io
import re
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ZSTD_SHA='37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'
LZ4_SHA={'lz4.c':'9396f7de527bc8435de9c7569fb7998e56545a84b4f3c2d808c0235c01774539',
         'lz4.h':'26b82efc53d1570f3b54eef02e9c4764c1ad374ff03cac04e2ced5ea4d4c552f',
         'LICENSE':'8b58c446121a109ccf32edc094bba3010a3d85e4ee3702950db55e4d3e87736c'}


def changed(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)


def download(path,url,digest=None):
    if not path.exists():changed(path,urllib.request.urlopen(url,timeout=60).read())
    data=path.read_bytes()
    if digest:assert hashlib.sha256(data).hexdigest()==digest,'Unexpected compression source: '+path.name
    return data


def prepare(root,source,notice):
    cache=root/'build/checkpoint/compression-sources';cache.mkdir(parents=True,exist_ok=True)
    files={}
    for name in ('lz4.c','lz4.h','LICENSE'):
        url='https://raw.githubusercontent.com/lz4/lz4/v1.10.0/lib/'+name
        files[name]=download(cache/('lz4-'+name),url,LZ4_SHA.get(name))
    archive=download(cache/'zstd-1.5.7.tar.gz','https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7',ZSTD_SHA)
    extracted=cache/'zstd-1.5.7'
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        # Extract ordinary source files only; never trust symlinks or paths.
        for member in tar.getmembers():
            if not member.isfile():continue
            path=cache/member.name
            assert path.resolve().is_relative_to(extracted.resolve())
            changed(path,tar.extractfile(member).read())
    amalgam=cache/'zstd-single.c'
    template=extracted/'build/single_file_libs/zstd-in.c'
    data=template.read_text().replace('#ifndef __EMSCRIPTEN__\n#define ZSTD_MULTITHREAD\n#endif','/* Single-threaded compression for bounded diagnostic work. */')
    changed(template,data.encode())
    # The generated file contains relative #line markers only (no private paths).
    subprocess.run([sys.executable,'-X','utf8','combine.py','-r','../../lib','-x','legacy/zstd_legacy.h',
                    '-o','../../../zstd-single.c','zstd-in.c'],cwd=template.parent,check=True,capture_output=True)
    # Upstream temporarily aliases then undefines this public function.
    # Rename that local alias too so it cannot erase our outer namespace.
    zstd=amalgam.read_text(encoding="utf-8").replace('#define ZSTD_isError ERR_isError', '#define neo_ckpt_ZSTD_isError ERR_isError').replace('#undef ZSTD_isError', '#undef neo_ckpt_ZSTD_isError')
    files['zstd.c']=zstd.encode();files['zstd.h']=(extracted/'lib/zstd.h').read_bytes()
    files['zstd_errors.h']=(extracted/'lib/zstd_errors.h').read_bytes()
    texts='\n'.join(files[n].decode() for n in ('lz4.c','lz4.h','zstd.c','zstd.h'))
    macros=set(re.findall(r'^\s*#\s*define\s+(\w+)',texts,re.M))
    names=sorted(set(re.findall(r'\b((?:ZSTD_|ZDICT_|LZ4_|HUF_|FSE_|HIST_|ERR_|XXH)\w+)\s*\(',texts))-macros)
    namespace='/* Generated from pinned sources; keep the normal engines isolated. */\n'+'\n'.join('#define '+n+' neo_ckpt_'+n for n in names)+'\n'
    changed(source/'include/neo_compression_namespace.h',namespace.encode())
    for name,dst in (('lz4.h','include/lz4.h'),('zstd.h','include/zstd.h'),('zstd_errors.h','include/zstd_errors.h')):changed(source/dst,files[name])
    for name,dst in (('lz4.c','src/neo_lz4.c'),('zstd.c','src/neo_zstd.c')):
        # Upstream LZ4 has an internal global helper without a prototype; keep
        # dav1d's stricter rule for our code, but not this unchanged vendor TU.
        preamble=b'#include "neo_compression_namespace.h"\n#pragma GCC diagnostic ignored "-Wmissing-prototypes"\n'
        changed(source/dst,preamble+files[name])
    notice.mkdir(parents=True,exist_ok=True)
    changed(notice/'LZ4-LICENSE',files['LICENSE']);changed(notice/'Zstandard-LICENSE',(extracted/'LICENSE').read_bytes())
    return {'lz4Version':'1.10.0','zstdVersion':'1.5.7','zstdArchiveSHA256':ZSTD_SHA,
            'sourceSHA256':{k:hashlib.sha256(v).hexdigest() for k,v in files.items()},
            'namespaceSHA256':hashlib.sha256(namespace.encode()).hexdigest(),'renamedFunctions':names,
            'zstdMultithread':False,'urls':{'lz4':'https://github.com/lz4/lz4/tree/v1.10.0','zstd':'https://github.com/facebook/zstd/tree/v1.5.7'}}
