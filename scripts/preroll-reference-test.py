"""Compile the production classifiers; verify retained pictures against FFmpeg.

No Apple decoder is needed for reference-dependency correctness. This does not
measure iPhone hardware speed. Inputs are public synthetic test fixtures only.
"""
import ctypes as C
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')
FFPROBE = os.environ.get('FFPROBE', 'ffprobe')


def run(*args):
    result = subprocess.run(list(map(str, args)), capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return result


class Config(C.Structure):
    _fields_ = [('reduced_still', C.c_bool), ('decoder_model', C.c_bool),
                ('frame_ids', C.c_bool), ('operating_points_minus1', C.c_uint),
                ('screen_tools', C.c_uint), ('integer_mv', C.c_uint),
                ('order_hint_bits', C.c_uint)]


class State(C.Structure):
    _fields_ = [('types', C.c_uint8 * 8), ('known', C.c_uint8)]


def bytes_arg(data):
    return (C.c_uint8 * len(data)).from_buffer_copy(data)


def trace_values(path):
    p = run(FFMPEG, '-hide_banner', '-i', path, '-map', '0:v:0', '-frames:v', '1',
            '-c:v', 'copy', '-bsf:v', 'trace_headers', '-f', 'null', '-')
    return {key: int(value) for key, value in re.findall(
        r'\]\s+\d+\s+(\w+)\s+[01]+\s+=\s+(\d+)', p.stderr.decode())}


def hashes(path):
    data = run(FFMPEG, '-v', 'error', '-i', path, '-map', '0:v:0',
               '-fps_mode', 'passthrough', '-f', 'framemd5', '-').stdout.decode()
    return [line.rsplit(',', 1)[1].strip() for line in data.splitlines() if line and not line.startswith('#')]


def av1_check(lib, path, tmp):
    values = trace_values(path)
    config = Config(bool(values['reduced_still_picture_header']),
                    bool(values.get('decoder_model_info_present_flag', 0)),
                    bool(values['frame_id_numbers_present_flag']),
                    values['operating_points_cnt_minus_1'],
                    2 if values.get('seq_choose_screen_content_tools') else values['seq_force_screen_content_tools'],
                    2 if values.get('seq_choose_integer_mv') else values.get('seq_force_integer_mv', 0),
                    1 + values['order_hint_bits_minus_1'] if values['enable_order_hint'] else 0)
    original = tmp / (path.stem + '.ivf')
    filtered = tmp / (path.stem + '-filtered.ivf')
    run(FFMPEG, '-v', 'error', '-i', path, '-map', '0:v:0', '-c:v', 'copy', '-f', 'ivf', original)
    data = original.read_bytes()
    header = bytearray(data[:32])
    rate, scale = struct.unpack_from('<II', header, 16)
    body = bytearray(); offset = 32; removed = 0; count = 0; state = State()
    while offset < len(data):
        size, timestamp = struct.unpack_from('<IQ', data, offset)
        packet = data[offset + 12:offset + 12 + size]
        assert len(packet) == size
        droppable = lib.test_av1(bytes_arg(packet), size, C.byref(config), C.byref(state))
        drop = timestamp * scale / rate < 30 and droppable
        if drop:
            removed += 1
        else:
            body += data[offset:offset + 12 + size]; count += 1
        offset += 12 + size
    struct.pack_into('<I', header, 24, count)
    filtered.write_bytes(header + body)
    before, after = hashes(original), hashes(filtered)
    # IVF rate/scale is the timestamp timebase, not necessarily the picture
    # rate (the MKV demuxer may preserve a 1/1000 clock). Fixtures are 24fps.
    tail = 42 * 24
    assert removed > 100, (path.name, 'classifier never exercised', removed)
    assert len(before) > tail and len(after) > tail
    assert before[-tail:] == after[-tail:], (path.name, 'reference/output corruption after target')
    return {'fixture': path.name, 'skippedBefore30s': removed, 'matchingPicturesAfterTarget': tail}


def unhex(text):
    return bytes.fromhex(''.join(line.split(':', 1)[1].split('  ')[0].replace(' ', '')
                                 for line in text.splitlines() if ':' in line))


def hevc_check(lib, path, tmp):
    values = trace_values(path)
    highest = values['sps_max_sub_layers_minus1']
    probe = json.loads(run(FFPROBE, '-v', 'error', '-select_streams', 'v:0',
                          '-show_streams', '-show_packets', '-show_data', '-of', 'json', path).stdout)
    extra = unhex(probe['streams'][0]['extradata'])
    assert extra[0] == 1
    length_size = (extra[21] & 3) + 1
    prefix = bytearray(); offset = 23
    for _ in range(extra[22]):
        nals = int.from_bytes(extra[offset + 1:offset + 3], 'big'); offset += 3
        for _ in range(nals):
            size = int.from_bytes(extra[offset:offset + 2], 'big'); offset += 2
            prefix += b'\0\0\0\1' + extra[offset:offset + size]; offset += size
    originals = bytearray(prefix); filtered = bytearray(prefix); removed = 0
    for packet in probe['packets']:
        data = unhex(packet['data']); offset = 0; annex = bytearray(); slices = []; safe = True
        while offset < len(data):
            size = int.from_bytes(data[offset:offset + length_size], 'big'); offset += length_size
            nal = data[offset:offset + size]; offset += size
            assert len(nal) == size and size >= 2
            annex += b'\0\0\0\1' + nal
            if (nal[0] >> 1) & 63 < 32:
                slices.append(nal)
                safe = safe and lib.test_hevc(bytes_arg(nal), size, highest)
        originals += annex
        if float(packet['pts_time']) < 30 and slices and safe:
            removed += 1
        else:
            filtered += annex
    original = tmp / 'original.hevc'; output = tmp / 'filtered.hevc'
    original.write_bytes(originals); output.write_bytes(filtered)
    before, after = hashes(original), hashes(output)
    assert removed > 100, ('HEVC classifier never exercised', removed)
    assert before[-1008:] == after[-1008:], 'HEVC reference/output corruption after target'
    return {'fixture': path.name, 'skippedBefore30s': removed, 'matchingPicturesAfterTarget': 1008}


def guards(lib):
    config = Config(False, False, False, 0, 2, 2, 8)
    good = bytes([0x12, 0, 0x32, 4, 0x30, 0, 0, 0])
    def av1(data, c=config, state=None):
        return lib.test_av1(bytes_arg(data), len(data), C.byref(c), C.byref(state or State()))
    assert av1(good)
    bad = [b'', good[:-1], good + good, good + bytes([0x2a, 0]),
           bytes([0x36, 1, 4, 0x30, 0, 0, 0]),
           bytes([0x32, 1, 0x80]),  # show-existing: not a new non-reference frame
           bytes([0x32, 4, 0x30, 0, 0, 0x20]),  # refresh a reference slot
           bytes([0x32, 4, 0x38, 0, 0, 0])]  # error-resilient
    for data in bad:
        assert not av1(data), data.hex()
    for field in ('decoder_model', 'frame_ids', 'reduced_still', 'operating_points_minus1'):
        clone = Config.from_buffer_copy(config); setattr(clone, field, 1)
        assert not av1(good, clone), field
    existing = bytes([0x32, 1, 0x80])  # slot 0
    state = State(); state.known = 1; state.types[0] = 1
    assert av1(existing, state=state), 'known INTER show-existing should not require decoding'
    state.types[0] = 0
    assert not av1(existing, state=state), 'KEY show-existing updates every reference slot'
    assert state.known == 255
    state.known = 0
    assert not av1(existing, state=state), 'unknown/flush state must not skip show-existing'
    for layer in range(7):
        nal = bytes([0, layer + 1, 0x80])
        assert lib.test_hevc(bytes_arg(nal), len(nal), layer)
        assert not lib.test_hevc(bytes_arg(nal), len(nal), 7)
        assert not lib.test_hevc(bytes_arg(bytes([2, layer + 1, 0x80])), 3, layer)
    # Prefixes/truncation and reference, unknown and multilayer NALs stay intact.
    for data in (b'', b'\0', b'\0\1', b'\0\0\x80', b'\1\1\x80', b'\0\x09\x80', b'\x20\1\x80'):
        assert not lib.test_hevc(bytes_arg(data), len(data), 0), data.hex()


def main():
    with tempfile.TemporaryDirectory(prefix='neo-preroll-', ignore_cleanup_errors=True) as directory:
        tmp = Path(directory)
        library = tmp / ('classifiers.dll' if sys.platform == 'win32' else 'classifiers.dylib' if sys.platform == 'darwin' else 'classifiers.so')
        cc = os.environ.get('CC', 'clang' if sys.platform == 'darwin' else 'gcc')
        run(cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
            '-dynamiclib' if sys.platform == 'darwin' else '-shared',
            *([] if sys.platform == 'win32' else ['-fPIC']),
            ROOT / 'tests/preroll-reference.c', '-o', library)
        lib = C.CDLL(str(library))
        lib.test_av1.argtypes = [C.POINTER(C.c_uint8), C.c_size_t, C.POINTER(Config), C.POINTER(State)]
        lib.test_hevc.argtypes = [C.POINTER(C.c_uint8), C.c_size_t, C.c_uint]
        lib.test_av1.restype = lib.test_hevc.restype = C.c_bool
        guards(lib)
        results = [av1_check(lib, ROOT / f'tests/fixtures/av1-seek-{depth}.mkv', tmp) for depth in (8, 10)]
        results.append(hevc_check(lib, ROOT / 'tests/fixtures/hevc-seek-10.mkv', tmp))
        print(json.dumps({'guards': 'passed', 'results': results}, indent=2))
        if 'GITHUB_ACTIONS' in os.environ:
            (ROOT / 'dist').mkdir(exist_ok=True)
            (ROOT / 'dist/preroll-reference-test.json').write_text(json.dumps(results, indent=2))
        if sys.platform == 'win32':
            import _ctypes
            _ctypes.FreeLibrary(lib._handle)


if __name__ == '__main__':
    main()
