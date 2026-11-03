import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from settings_image import right_edge_foreground


class SettingsImageTests(unittest.TestCase):
    def bitmap(self, edge=False):
        stride = (402 * 3 + 3) // 4 * 4
        data = bytearray(54 + stride * 600)
        data[:2] = b'BM'
        struct.pack_into('<I', data, 10, 54)
        struct.pack_into('<IiiHH', data, 14, 40, 402, 600, 1, 24)
        if edge:
            index = 54 + (600 - 300 - 1) * stride + 401 * 3
            data[index:index + 3] = b'\xff\xff\xff'
        return data

    def test_clear_edge(self):
        self.assertTrue(right_edge_foreground(self.bitmap(), 402)['success'])

    def test_clipped_white_switch(self):
        result = right_edge_foreground(self.bitmap(True), 402)
        self.assertFalse(result['success'])
        self.assertEqual(result['rightEdgeForeground'], 1)

    def test_rejects_truncated_image(self):
        with self.assertRaises(ValueError):
            right_edge_foreground(self.bitmap()[:54], 402)
