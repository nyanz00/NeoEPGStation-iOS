"""Verify resolved source pins and retain upstream license/source recipes."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

lock = Path('ios/NeoEPGStation.xcworkspace/xcshareddata/swiftpm/Package.resolved')
pins = json.loads(lock.read_text())['pins']
expected = {
    'aetherengine': '40193cefa7244c097519d219f84af1b9028c181c',
    'ffmpegbuild': '3b398c8f6340fe5fb4a7cb9a2a211a16677171e0',
    'libdovi': '0d7cce1d6836a30d13a3a2326e50a153af53f014',
    'smbclient': 'e636c2b2458930770932a36d311ec9d478575b90',
}
assert {p['identity']: p['state']['revision'] for p in pins} == expected, 'Unexpected dependency resolution'
root = Path('build/SourcePackages/checkouts')
notice = Path('dist/notices/AetherEngine'); notice.mkdir(parents=True, exist_ok=True)
rows = []
with tarfile.open('dist/AetherEngine-source-recipes.tar.gz', 'w:gz') as archive:
    for pin in pins:
        directory = next(p for p in root.iterdir() if p.name.lower() == pin['identity'])
        revision = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()
        assert revision == expected[pin['identity']], (directory.name, revision)
        rows.append({'name': pin['identity'], 'revision': revision,
                     'source': pin['location']+'/tree/'+revision})
        count = 0
        for path in directory.rglob('*'):
            if not path.is_file():
                continue
            relative = path.relative_to(directory)
            if any(part in ('.git', '.build') or part.endswith(('.xcframework', '.framework', '.dSYM')) for part in relative.parts):
                continue
            archive.add(path, arcname=str(Path(directory.name)/relative))
            if path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')) or 'LICENSES' in relative.parts:
                destination = notice/directory.name/relative
                destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, destination); count += 1
        assert count, 'No license notices for '+directory.name
report = {'success': True, 'aetherVersion': '7.46.0', 'dependencies': rows,
          'sourceRecipeArchiveSHA256': hashlib.sha256(Path('dist/AetherEngine-source-recipes.tar.gz').read_bytes()).hexdigest()}
(notice/'source-pins.json').write_text(json.dumps(report, indent=2)+'\n')
Path('dist/aether-provenance.json').write_text(json.dumps(report, indent=2)+'\n')
