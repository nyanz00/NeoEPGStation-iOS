"""Fetch the GNU m4 source missing from VideoLAN's mirror, with bounded TLS fallbacks."""
import hashlib
from pathlib import Path
import sys
from urllib.request import urlopen

tools = Path(sys.argv[1])
line = next(line for line in (tools / 'packages.mak').read_text().splitlines() if line.startswith('M4_VERSION='))
version = line.split('=', 1)[1]
name = f'm4-{version}.tar.gz'
expected = next(line.split()[0] for line in (tools / 'SHA512SUMS').read_text().splitlines() if line.split()[-1] == name)
archive = tools / name
valid = archive.is_file() and hashlib.sha512(archive.read_bytes()).hexdigest() == expected
if not valid:
    errors = []
    for host in ('https://mirrors.kernel.org/gnu', 'https://mirror.csclub.uwaterloo.ca/gnu', 'https://ftp.gnu.org/gnu'):
        try:
            with urlopen(f'{host}/m4/{name}', timeout=15) as response:
                data = response.read()
            if hashlib.sha512(data).hexdigest() != expected:
                raise ValueError('Upstream source checksum mismatch')
            archive.write_bytes(data)
            valid = True
            break
        except Exception as error:
            errors.append(f'{host}: {type(error).__name__}')
    if not valid:
        raise RuntimeError('; '.join(errors))
print(f'{name}: pinned upstream SHA-512 verified')
