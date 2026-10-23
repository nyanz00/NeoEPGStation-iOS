import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from http_byte_range import byte_range


class ByteRangeTests(unittest.TestCase):
    def test_bounded_open_and_suffix_ranges(self):
        for header, expected in [(None, (0, 99)), ('bytes=10-19', (10, 19)),
                                 ('bytes=80-', (80, 99)), ('bytes=90-200', (90, 99)),
                                 ('bytes=-20', (80, 99)), ('bytes=-200', (0, 99))]:
            with self.subTest(header=header):
                self.assertEqual(byte_range(header, 100), expected)

    def test_rejects_unsatisfiable_or_malformed_ranges(self):
        for header in ['bytes=100-', 'bytes=20-10', 'bytes=-0', 'bytes=-',
                       'bytes=1-2,3-4', 'items=1-2', 'bytes=a-b']:
            with self.subTest(header=header), self.assertRaises(ValueError):
                byte_range(header, 100)
