"""Rendered switch clipping check; macOS sips supplies a standard BGR bitmap."""
import struct


def right_edge_foreground(data, logical_width):
    if data[:2] != b'BM' or len(data) < 54:
        raise ValueError('Not a BMP image')
    offset, = struct.unpack_from('<I', data, 10)
    width, height = struct.unpack_from('<ii', data, 18)
    bits, = struct.unpack_from('<H', data, 28)
    compression, = struct.unpack_from('<I', data, 30)
    if not 0 < width < 10000 or not 0 < abs(height) < 10000 or bits not in (24, 32) or compression not in (0, 3):
        raise ValueError('Unsupported BMP image')
    if compression == 3 and struct.unpack_from('<III', data, 54) != (0xff0000, 0xff00, 0xff):
        raise ValueError('Unexpected channel masks')
    stride = (width * bits + 31) // 32 * 4
    if len(data) < offset + stride * abs(height):
        raise ValueError('Incomplete BMP image')
    margin = max(1, round(width / logical_width * 8))
    count = 0
    for y in range(round(abs(height) * .2), round(abs(height) * .88)):
        row = y if height < 0 else height - y - 1
        for x in range(width - margin, width):
            pixel = offset + row * stride + x * (bits // 8)
            b, g, r = data[pixel:pixel + 3]
            if min(r, g, b) >= 220 or (g > 100 and b > 80 and r < g * .8 and b < g * 1.2):
                count += 1
    return {'success': count == 0, 'rightEdgeForeground': count,
            'width': width, 'height': abs(height), 'marginPoints': 8}
