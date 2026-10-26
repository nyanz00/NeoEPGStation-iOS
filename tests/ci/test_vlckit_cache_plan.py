import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('cache_plan',Path(__file__).resolve().parents[2]/'scripts/vlckit-cache-plan.py')
plan=importlib.util.module_from_spec(spec);spec.loader.exec_module(plan)


class CachePlanTests(unittest.TestCase):
    def test_both_verified_avoid_mac_jobs(self):
        self.assertEqual(plan.missing_sdks('all','true','true'),[])

    def test_partial_or_missing_cache_keeps_build_fallback(self):
        self.assertEqual(plan.missing_sdks('all','true','false'),['iphonesimulator'])
        self.assertEqual(plan.missing_sdks('all','','true'),['iphoneos'])
        self.assertEqual(plan.missing_sdks('all','false','false'),['iphoneos','iphonesimulator'])

    def test_unrequested_sdk_does_not_trigger_build(self):
        self.assertEqual(plan.missing_sdks('iphoneos','true',''),[])
        self.assertEqual(plan.missing_sdks('iphonesimulator','','false'),['iphonesimulator'])

    def test_only_explicit_verification_is_accepted(self):
        self.assertEqual(plan.missing_sdks('iphoneos','TRUE','true'),['iphoneos'])
        with self.assertRaises(ValueError):plan.missing_sdks('other','true','true')
