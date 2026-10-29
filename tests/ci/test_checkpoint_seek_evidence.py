import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('checkpoint_seek_evidence',
    Path(__file__).parents[2]/'scripts/checkpoint_seek_evidence.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def anchor(key, audio, target):
    return {'videoKeyMs': key, 'audioStartMs': audio, 'targetMs': target, 'independent': 1}


class CheckpointSeekEvidenceTests(unittest.TestCase):
    def test_cold_boundary_and_interior_warmup(self):
        module.validate_cache_seek_anchors([anchor(18042,18042,22000), anchor(36042,35925,40000),
                                           anchor(30042,29930,34000), anchor(18042,18042,22000)])

    def test_all_interior_bookmarks(self):
        module.validate_cache_seek_anchors([anchor(42,-64,20000), anchor(24042,23936,40000)])

    def test_an_interior_key_must_keep_audio_warmup(self):
        with self.assertRaises(AssertionError):
            module.validate_cache_seek_anchors([anchor(18042,18042,22000), anchor(36042,36042,40000)])

    def test_extra_gop_audio_cursor_is_rejected(self):
        with self.assertRaises(AssertionError):
            module.validate_cache_seek_anchors([anchor(18042,18042,22000), anchor(36042,30042,40000)])

    def test_future_key_and_insufficient_boundary_audio_are_rejected(self):
        for bad in [anchor(18042,18042,18050), anchor(36042,35925,35000)]:
            with self.assertRaises(AssertionError):
                module.validate_cache_seek_anchors([bad, anchor(24042,23930,30000)])
