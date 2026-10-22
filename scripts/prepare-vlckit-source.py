"""Apply upstream patches idempotently to a freshly reset dependency checkout."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys


def capture_times(vlc, snapshot):
    vlc = Path(vlc).resolve()
    names = []
    if (vlc / '.git').is_dir():
        names = subprocess.check_output(['git', '-C', str(vlc), 'diff', '--name-only', '-z', 'HEAD']).decode().split('\0')
    names.append('modules/codec/videotoolbox/av1.c.inc')
    saved = {}
    for name in filter(None, names):
        path = vlc / name
        if path.is_file():
            stat = path.stat()
            saved[name] = [hashlib.sha256(path.read_bytes()).hexdigest(), stat.st_atime_ns, stat.st_mtime_ns]
    Path(snapshot).write_text(json.dumps(saved))


def restore_times(vlc, snapshot):
    vlc = Path(vlc).resolve()
    restored = 0
    for name, (digest, atime, mtime) in json.loads(Path(snapshot).read_text()).items():
        path = (vlc / name).resolve()
        if not path.is_relative_to(vlc):
            raise ValueError('Cached source path outside dependency checkout')
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
            os.utime(path, ns=(atime, mtime))
            restored += 1
    print(f'Preserved timestamps of {restored} unchanged source files for incremental compilation')


def apply(vlc, patches):
    vlc = Path(vlc).resolve()
    patches = sorted(Path(patches).glob('*.patch'))
    for patch in patches:
        previous = ''
        for line in patch.read_text().splitlines():
            if previous == '--- /dev/null' and line.startswith('+++ b/'):
                name = line[6:]
                target = (vlc / name).resolve()
                if not target.is_relative_to(vlc):
                    raise ValueError('Patch path outside dependency checkout')
                # Migrate a cache created by the older unstaged-patch recipe.
                # Remove only known patch additions absent from the reset base;
                # leave all contrib/tool archives and compiled objects alone.
                tracked = subprocess.run(['git', '-C', str(vlc), 'ls-files', '--error-unmatch', '--', name], capture_output=True)
                if tracked.returncode and target.is_file():
                    target.unlink()
            previous = line
    # Staging additions makes the next reset remove them as well. A build that
    # fails halfway can safely reuse this same source/cache on its next attempt.
    subprocess.run(['git', '-C', str(vlc), 'apply', '--index', *map(str, patches)], check=True)


if __name__ == '__main__':
    if sys.argv[1] == 'capture-times':
        capture_times(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'restore-times':
        restore_times(sys.argv[2], sys.argv[3])
    else:
        apply(sys.argv[1], sys.argv[2])
