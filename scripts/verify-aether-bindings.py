"""Reject mixed FFmpeg libraries in the linked app, before an IPA can ship."""
import argparse
import json
from pathlib import Path
import re
import struct


def bindings(data):
    if data[:4] == bytes.fromhex('cafebabe'):
        count = struct.unpack_from('>I', data, 4)[0]
        results = []
        for i in range(count):
            cpu, sub, offset, size, align = struct.unpack_from('>5I', data, 8 + i*20)
            results += bindings(data[offset:offset+size])
        return results
    magic, cpu, sub, filetype, count, size, flags, reserved = struct.unpack_from('<8I', data)
    assert magic == 0xfeedfacf and flags & 0x80, 'Expected two-level 64-bit Mach-O'
    libraries, symbol_table, offset = [], None, 32
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        if command in (0xc, 0x80000018, 0x8000001f, 0x80000023):
            start = offset + struct.unpack_from('<I', data, offset+8)[0]
            libraries.append(data[start:data.index(b'\0', start)].decode())
        if command == 2:
            symbol_table = struct.unpack_from('<4I', data, offset+8)
        offset += length
    assert symbol_table, 'Missing dynamic symbol table'
    symbols, count, strings, _ = symbol_table
    rows = []
    for i in range(count):
        string, kind, section, description, value = struct.unpack_from('<IBBHQ', data, symbols+16*i)
        if kind & 0x0e or not kind & 1:  # Only undefined external symbols.
            continue
        start = strings + string
        name = data[start:data.index(b'\0', start)].decode()
        if not re.match(r'^_(av(?:codec|format|util|filter|io|priv)?_|sws_|swr_|dav1d_|ass_)', name):
            continue
        ordinal = description >> 8
        library = libraries[ordinal-1] if 0 < ordinal <= len(libraries) else 'unresolved'
        rows.append({'symbol': name, 'library': library, 'cpu': cpu,
                     'correct': library.startswith('@rpath/VLCKit.framework/') if name.startswith('_ass_') else library.startswith('@rpath/AetherLib')})
    required = {'_av_read_frame', '_avcodec_send_packet', '_avformat_open_input', '_avcodec_find_decoder_by_name'}
    assert required <= {r['symbol'] for r in rows}, 'Core decoder imports missing'
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = bindings(args.binary.read_bytes())
    result = {'success': bool(rows) and all(r['correct'] for r in rows), 'imports': rows}
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    wrong = [r for r in rows if not r['correct']]
    assert not wrong, 'Cross-engine FFmpeg imports: '+str(wrong[:8])
    print('Verified', len(rows), 'FFmpeg/dav1d imports resolve to Aether; ASS imports resolve to bundled VLC libass')


if __name__ == '__main__':
    main()
