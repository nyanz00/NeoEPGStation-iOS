import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('vlc_prepare', 'scripts/prepare-vlckit-source.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SourcePreparationTests(unittest.TestCase):
    def test_cached_added_patch_files_do_not_break_reapplication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            def git(*args):
                return subprocess.run(['git', '-C', str(source), *args], check=True, capture_output=True)
            git('init')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'user.name', 'Fixture')
            (source / 'base').write_text('base\n')
            git('add', 'base')
            git('commit', '-m', 'base')
            patches = root / 'patches'
            patches.mkdir()
            (patches / 'new.patch').write_text('diff --git a/added b/added\nnew file mode 100644\n--- /dev/null\n+++ b/added\n@@ -0,0 +1 @@\n+new\n', newline='\n')
            # Simulate an old failed build: new source is untracked; archive and
            # compiler outputs must survive both this migration and later resets.
            (source / 'added').write_text('new\n')
            (source / 'compiled.a').write_bytes(b'keep')
            for _ in range(2):
                git('reset', '--hard', 'HEAD')
                prepare.apply(source, patches)
                self.assertEqual((source / 'added').read_text(), 'new\n')
                self.assertEqual((source / 'compiled.a').read_bytes(), b'keep')

