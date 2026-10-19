"""Fail before provisioning macOS when a native source is outside the target."""
from pathlib import Path
import re
import unittest


class ProjectSourcesTests(unittest.TestCase):
    def test_all_native_sources_are_in_application_target(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / 'ios/NeoEPGStation.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        refs = dict(re.findall(r'(\w{24})\s*(?:/\*.*?\*/)?\s*=\s*\{isa = PBXFileReference;[^\n]*?path = "?([^;"\n]+)', project))
        builds = dict(re.findall(r'(\w{24})\s*(?:/\*.*?\*/)?\s*=\s*\{isa = PBXBuildFile; fileRef = (\w{24})', project))
        section = project.split('/* Begin PBXSourcesBuildPhase section */')[1].split('/* End PBXSourcesBuildPhase section */')[0]
        members = {refs.get(ref) for build, ref in builds.items() if build in section}
        for source in (root / 'ios/NeoEPGStation').iterdir():
            if source.suffix in ('.swift', '.m', '.metal'):
                self.assertIn('NeoEPGStation/'+source.name, members, source.name)
