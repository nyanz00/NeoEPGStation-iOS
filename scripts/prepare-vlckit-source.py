"""Apply upstream patches idempotently to a freshly reset dependency checkout."""
from pathlib import Path
import subprocess
import sys


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
    apply(sys.argv[1], sys.argv[2])
