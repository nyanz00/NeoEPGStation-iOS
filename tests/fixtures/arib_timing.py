"""Synthetic ARIB A-profile PES packets with explicit replacement/clear timing.

No broadcast content. Inject into a short, ffmpeg-generated MPEG-TS fixture.
"""
from pathlib import Path


def crc32(data):
    crc = 0xffffffff
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04c11db7 if crc & 0x80000000 else 0)) & 0xffffffff
    return crc.to_bytes(4, 'big')


def stamp(pts):
    return bytes([0x21 | ((pts >> 29) & 0xe), (pts >> 22) & 255,
                  ((pts >> 14) & 0xfe) | 1, (pts >> 7) & 255, ((pts << 1) & 0xfe) | 1])


def group(body, management=False):
    data = bytes([0 if management else 4, 0, 0]) + len(body).to_bytes(2, 'big') + body
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xffff
    return b'\x80\xff\xf0' + data + crc.to_bytes(2, 'big')


def statement(text):
    unit = b'\x1f\x20' + len(text).to_bytes(3, 'big') + text
    return group(b'\x3f' + len(unit).to_bytes(3, 'big') + unit)


def packetize(data, counter):
    packets = []
    for at in range(0, len(data), 184):
        chunk = data[at:at+184]
        header = bytes([0x47, 0x01 | (0x40 if at == 0 else 0), 0x20, 0x30 | counter % 16])
        spare = 184-len(chunk)
        if spare:
            packets.append(header + bytes([spare-1]) + (b'\x00' + b'\xff'*(spare-2) if spare > 1 else b'') + chunk)
        else:
            packets.append(header[:3]+bytes([0x10 | counter % 16])+chunk)
        counter += 1
    return b''.join(packets), counter


def inject(source, target):
    raw = Path(source).read_bytes()
    # The waits below are deliberately followed/not followed by CS. Web only
    # assigns an explicit end after a delayed clear; all other cues persist.
    init = b'\x0c\x0e\x8a\x87\x9b170;400 a'
    cues = [(0, group(b'\x3f\x01\x00jpn\x70\x00\x00\x00', True)),
            (1, statement(init+b'FIRST')),
            (5, statement(init+b'SECOND\x9d\x20\x4a')),
            (9, statement(init+b'THIRD\x9d\x20\x54\x0c')),
            (13, statement(init+b'LAST')), (16, statement(b'\x0c'))]
    output, counter, next_cue = bytearray(), 0, 0
    first_pts = None
    for at in range(0, len(raw), 188):
        packet = raw[at:at+188]
        if len(packet) != 188 or packet[0] != 0x47:
            raise ValueError('Invalid transport packet')
        pid = ((packet[1] & 31) << 8) | packet[2]
        payload = 4+(1+packet[4] if packet[3] & 0x20 else 0)
        if pid == 4096 and packet[1] & 0x40:
            section = payload+1+packet[payload]
            length = ((packet[section+1]&15)<<8) | packet[section+2]
            body = bytearray(packet[section:section+3+length-4])
            body += b'\x06\xe1\x20\xf0\x08\xfd\x03\x00\x08\xff\x52\x01\x30'
            length = len(body)+4-3
            body[1:3] = (0xb000 | length).to_bytes(2, 'big')
            body += crc32(body)
            packet = packet[:payload]+b'\x00'+body
            packet += b'\xff'*(188-len(packet))
        if pid == 256 and packet[1] & 0x40 and packet[payload:payload+3] == b'\x00\x00\x01':
            p = packet[payload+9:payload+14]
            if len(p) == 5 and packet[payload+7] & 0x80:
                pts = ((p[0] >> 1 & 7)<<30) | (p[1]<<22) | ((p[2]>>1)<<15) | (p[3]<<7) | (p[4]>>1)
                if first_pts is None:
                    first_pts = pts
                while next_cue < len(cues) and pts-first_pts >= cues[next_cue][0]*90000:
                    second, caption = cues[next_cue]
                    pes = b'\x00\x00\x01\xbd'+(len(caption)+8).to_bytes(2, 'big')+b'\x80\x80\x05'+stamp(first_pts+second*90000)+caption
                    encoded, counter = packetize(pes, counter)
                    output += encoded
                    next_cue += 1
        output += packet
    if next_cue != len(cues):
        raise ValueError('Fixture was too short for all caption events')
    Path(target).write_bytes(output)
    return cues


if __name__ == '__main__':
    import sys
    inject(*sys.argv[1:])
