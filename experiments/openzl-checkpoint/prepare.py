"""Build the unmodified, pinned OpenZL CPU library for a local PC experiment."""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.local/openzl-trial'
SOURCE = WORK / 'openzl-0.3.0'
ARCHIVES = (
    ('v0.3.0.tar.gz', 'https://codeload.github.com/facebook/openzl/tar.gz/refs/tags/v0.3.0',
     '6e105e5c49187ebf63e0bf62fb3ecb22b628248c0bf55bd40ace434721f394f5', SOURCE),
    ('zstd-1.5.7.tar.gz', 'https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7',
     '37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3', SOURCE / 'deps/zstd'),
    ('lz4-1.10.0.tar.gz', 'https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz',
     '537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b', SOURCE / 'deps/lz4'),
)


def extract(archive, destination):
    """Extract ordinary files only, strip the archive's top directory."""
    destination = destination.resolve()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts[1:]
            if not parts:
                continue
            target = destination.joinpath(*parts).resolve()
            if not target.is_relative_to(destination):
                raise ValueError(member.name)
            if member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(member).read())


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    for name, url, digest, destination in ARCHIVES:
        archive = WORK / name
        if not archive.exists():
            cached = ROOT / '.local/checkpoint-compression-deps' / name
            archive.write_bytes(cached.read_bytes() if cached.exists()
                               else urllib.request.urlopen(url, timeout=60).read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise ValueError('Archive hash mismatch: ' + name)
        if not (destination / '.neo-extracted').exists():
            extract(archive, destination)
            (destination / '.neo-extracted').write_text(digest)
        print('Verified', name, digest, flush=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/mingw64/bin;C:/msys64/usr/bin;' + env['PATH']
    with (WORK / 'build.log').open('wb') as log:
        result = subprocess.run(
            ['C:/msys64/usr/bin/bash.exe', '-c',
             'export PATH=/mingw64/bin:/usr/bin; make -j8 libopenzl.a BUILD_TYPE=OPT CC=gcc AR=ar'],
            cwd=SOURCE, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    if result.returncode:
        raise RuntimeError((WORK / 'build.log').read_text(errors='replace')[-6000:])
    print('Built OpenZL v0.3.0 CPU static library', flush=True)


if __name__ == '__main__':
    main()
