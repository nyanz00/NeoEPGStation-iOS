"""Apply pinned engine source patches without trusting modified cache contents."""
import hashlib
from pathlib import Path
import subprocess


def prepare_sources(checkout, patches, directory):
    checkout, directory = Path(checkout), Path(directory)
    original, final, known = {}, {}, {}
    for patch in patches:
        assert hashlib.sha256((directory/patch['file']).read_bytes()).hexdigest() == patch['sha256']
        for source in patch['sources']:
            name = source['path']
            original.setdefault(name, source['upstreamSHA256'])
            final[name] = source['patchedSHA256']
            known.setdefault(name, set()).update((source['upstreamSHA256'], source['patchedSHA256']))
    actual = {name: hashlib.sha256((checkout/name).read_bytes()).hexdigest() for name in final}
    if actual == final:
        return False  # Preserve mtimes for a fully prepared cached checkout.
    originals = {}
    for name, digest in actual.items():
        assert digest in known[name], 'Unexpected engine modifications: '+name
        data = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:'+name])
        assert hashlib.sha256(data).hexdigest() == original[name], 'Unexpected upstream: '+name
        originals[name] = data
    # A known partially prepared cache is reconstructed, not applied twice.
    for name, data in originals.items():
        if (checkout/name).read_bytes() != data:
            (checkout/name).write_bytes(data)
    for patch in patches:
        for source in patch['sources']:
            assert hashlib.sha256((checkout/source['path']).read_bytes()).hexdigest() == source['upstreamSHA256']
        subprocess.run(['git', '-C', str(checkout), 'apply', '--check', str((directory/patch['file']).resolve())], check=True)
        subprocess.run(['git', '-C', str(checkout), 'apply', str((directory/patch['file']).resolve())], check=True)
        for source in patch['sources']:
            assert hashlib.sha256((checkout/source['path']).read_bytes()).hexdigest() == source['patchedSHA256']
    assert {name: hashlib.sha256((checkout/name).read_bytes()).hexdigest() for name in final} == final
    return True
