"""Record exact custom binary inputs and preserve corresponding library sources."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parents[1]
sdk = sys.argv[1]
assert sdk in ('iphoneos', 'iphonesimulator')
wrapper = root / f'build/vlckit-{sdk}/VLCKit'
vlc = wrapper / 'libvlc/vlc'
output = root / f'build/vlckit-output-{sdk}'
source = json.loads((root / 'vendor/vlckit/source.json').read_text())
source['patches'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted((root / 'vendor/vlckit').rglob('*')) if p.is_file()}
source['sdk'] = sdk
source['xcode'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
source['sha256'] = hashlib.sha256((output / 'VLCKit.framework/VLCKit').read_bytes()).hexdigest()
(output / 'provenance.json').write_text(json.dumps(source, indent=2) + '\n')
if sdk == 'iphoneos':
    # Full modified tracked sources plus the downloaded contrib/tool sources.
    # Library binaries and intermediate objects are deliberately excluded.
    with tarfile.open(root / 'dist/VLCKit-corresponding-source.tar.gz', 'w:gz') as archive:
        for checkout, prefix in ((wrapper, 'VLCKit'), (vlc, 'VLCKit/libvlc/vlc')):
            names = subprocess.check_output(['git', '-C', str(checkout), 'ls-files', '-z']).decode().split('\0')
            for name in filter(None, names):
                path = checkout / name
                if path.is_file():
                    archive.add(path, arcname=f'{prefix}/{name}', recursive=False)
        archive.add(vlc / 'modules/codec/videotoolbox/av1.c.inc', arcname='VLCKit/libvlc/vlc/modules/codec/videotoolbox/av1.c.inc')
        archive.add(vlc / 'modules/packetizer/neo_preroll.h', arcname='VLCKit/libvlc/vlc/modules/packetizer/neo_preroll.h')
        for directory in (vlc / 'contrib/tarballs', vlc / 'extras/tools'):
            for path in directory.iterdir():
                if path.is_file() and ('.tar.' in path.name or path.suffix in ('.zip', '.tgz')):
                    archive.add(path, arcname='VLCKit/libvlc/vlc/' + str(path.relative_to(vlc)))
        archive.add(root / 'vendor/vlckit', arcname='NeoEPGStation/vendor/vlckit')
        for script in ('build-vlckit.sh', 'prepare-vlckit-source.py', 'fetch-vlckit-tools.py', 'vlckit-provenance.py'):
            archive.add(root / 'scripts' / script, arcname='NeoEPGStation/scripts/' + script)
    print('Preserved complete modified VLC/VLCKit sources and downloaded dependency sources')
