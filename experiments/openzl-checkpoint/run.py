"""Compare pinned CPU OpenZL with the checkpoint's existing CPU Zstd transform.

Requires the existing PC dav1d-storage experiment and its local IVF samples.
Actual reference pixels and source names stay in ignored .local/ only.
"""
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import shutil
import sys
import argparse

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORK = ROOT / '.local/openzl-trial'
SOURCE = WORK / 'openzl-0.3.0'
ENV = os.environ.copy()
ENV['PATH'] = 'C:/msys64/mingw64/bin;C:/msys64/usr/bin;' + ENV['PATH']
ENV['TMP'] = ENV['TEMP'] = ENV['TMPDIR'] = '.local/openzl-trial/tmp'
METHODS = (
    (0, 1, 'raw-zstd1'),
    (1, 1, 'row-delta-shuffle-zstd1'),
    (2, 1, 'openzl-generic1'),
    (2, 6, 'openzl-generic6'),
    (3, 1, 'openzl-numeric16-1'),
    (3, 6, 'openzl-numeric16-6'),
    (4, 1, 'openzl-delta-zigzag-numeric16-1'),
    (4, 6, 'openzl-delta-zigzag-numeric16-6'),
    (5, 1, 'row-delta-shuffle-openzl-generic1'),
)
LZ_METHODS = ((6, 1, 'openzl-native-lz1'), (6, 6, 'openzl-native-lz6'),
              (7, 1, 'row-delta-shuffle-openzl-native-lz1'),
              (7, 6, 'row-delta-shuffle-openzl-native-lz6'))


def call(args, timeout=180):
    args = [a.relative_to(ROOT).as_posix() if isinstance(a, Path) and a.is_relative_to(ROOT) else str(a) for a in args]
    args[0] = shutil.which(args[0], path=ENV['PATH']) or args[0]
    result = subprocess.run(args, cwd=ROOT, env=ENV,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stdout + result.stderr).decode(errors='replace')[-7000:])
    return result.stdout


def build():
    (WORK / 'tmp').mkdir(exist_ok=True)
    # Upstream Zstd's makefile does not handle this workspace's space in its
    # absolute directory: it can report success with an empty archive. Generate
    # its official single-file library instead, with single-threaded compression.
    zstd = SOURCE / 'deps/zstd'
    single = zstd / 'build/single_file_libs'
    template = (single / 'zstd-in.c').read_text(encoding='utf-8')
    template = template.replace('#ifndef __EMSCRIPTEN__\n#define ZSTD_MULTITHREAD\n#endif',
                                '/* Single-threaded CPU diagnostic. */')
    (single / 'neo-zstd-in.c').write_text(template, encoding='utf-8')
    combined = subprocess.run([sys.executable, '-X', 'utf8', 'combine.py', '-r', '../../lib',
                               '-x', 'legacy/zstd_legacy.h', '-o', 'neo-zstd.c', 'neo-zstd-in.c'],
                              cwd=single, capture_output=True, check=True)
    data = (single / 'neo-zstd.c').read_bytes()
    generated = WORK / 'zstd-single.c'
    changed = not generated.exists() or generated.read_bytes() != data
    if changed or not (WORK / 'zstd-single.a').exists():
        generated.write_bytes(data)
        call(['gcc', '-pipe', '-std=gnu11', '-O3', '-DNDEBUG', '-DZSTD_DISABLE_ASM', '-c',
              WORK / 'zstd-single.c', '-o', WORK / 'zstd-single.o'], timeout=300)
        call(['ar', 'rcs', WORK / 'zstd-single.a', WORK / 'zstd-single.o'])
    call(['gcc', '-pipe', '-std=gnu11', '-O3', '-c',
          '-I.local/dav1d-storage', '-I.local/dav1d-storage/build',
          '-I.local/dav1d-storage/include', '-I.local/dav1d-storage/build/include',
          HERE / 'export.c', '-o', WORK / 'export.o'])
    call(['gcc', WORK / 'export.o', '.local/dav1d-storage/build/src/libdav1d.a',
          WORK / 'zstd-single.a', SOURCE / 'deps/lz4/lib/liblz4.a',
          '-o', WORK / 'export.exe', '-lm'])
    call(['gcc', '-pipe', '-std=gnu11', '-O3', '-Wall', '-Wextra', '-c',
          '-I.local/openzl-trial/openzl-0.3.0/include', '-I.local/openzl-trial/openzl-0.3.0/deps/zstd/lib',
          HERE / 'bench.c', '-o', WORK / 'bench.o'])
    call(['gcc', WORK / 'bench.o', SOURCE / 'libopenzl.a',
          WORK / 'zstd-single.a', SOURCE / 'deps/lz4/lib/liblz4.a',
          '-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free',
          '-o', WORK / 'bench.exe', '-lpsapi', '-lm'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extend-native-lz', action='store_true',
                        help='Reuse exact exported allocations and add native LZ cases to a separate report')
    args = parser.parse_args()
    build()
    if args.extend_native_lz:
        extend_native_lz()
        return
    cases = [('long-gop', '.local/mt-recording-10bit-long-gop.ivf', [14, 18, 19.8]),
             ('six-second-gop', '.local/storage-six-second-gop.ivf', [12.279, 30.297, 60.327])]
    report = {
        'platform': 'Windows x86-64 CPU, one compression thread, affinity mask 1; no audio/render/network',
        'openzlVersion': '0.3.0', 'zstdVersion': '1.5.7',
        'allocationMeasurement': 'GNU ld wraps malloc/calloc/realloc/free of the static libraries and harness; requested live bytes, excludes allocator overhead and non-malloc allocations',
        'timing': 'one full unique-reference set per round; context creation, transform, compression, output allocation/shrink included; restoration includes output allocation and inverse transform; I/O and byte comparison excluded; first round warmup',
        'scope': 'reference-image compression only, not full decoder-state save/restore or seek latency; no training or custom OpenZL codec; numeric graph is contiguous LE16 including allocation padding, delta graph is one-dimensional',
        'cases': [],
    }
    for label, file, positions in cases:
        if not (ROOT / file).exists():
            raise FileNotFoundError('Local sample required: ' + label)
        for ordinal, position in enumerate(positions):
            folder = WORK / (label + '-' + str(ordinal))
            folder.mkdir(exist_ok=True)
            manifest = json.loads(call([WORK / 'export.exe', file, position, folder]))
            manifest['case'] = label
            rows = [str(len(manifest['images']))]
            for image in manifest['images']:
                image['sha256'] = hashlib.sha256((folder / image['file']).read_bytes()).hexdigest()
                rows.append(' '.join(str(v) for v in [image['bytes'], image['width'], image['height'],
                                                     *image['stride'], *image['offset']]))
            (folder / 'geometry.txt').write_text('\n'.join(rows) + '\n')
            manifest['methods'] = []
            # Rotate method order between points to reduce systematic order bias.
            methods = METHODS[ordinal:] + METHODS[:ordinal]
            for method, level, name in methods:
                result = json.loads(call([WORK / 'bench.exe', folder, method, level, 5]))
                result['name'] = name
                measured = [r for r in result['rounds'] if not r['warmup']]
                for field in ('saveMs', 'restoreMs', 'saveThreadCpuMs', 'restoreThreadCpuMs',
                              'compressedBytes', 'compressionAdditionalPeakBytes', 'restorationAdditionalPeakBytes'):
                    result[field + 'Median'] = statistics.median(r[field] for r in measured)
                result['imagePayloadMiB'] = result['compressedBytesMedian'] / 1048576
                result['estimatedCheckpointMiB'] = (result['compressedBytesMedian'] + manifest['otherCheckpointBytes']) / 1048576
                manifest['methods'].append(result)
                print(label, round(manifest['checkpointSeconds'], 3), name,
                      'MiB', round(result['imagePayloadMiB'], 3),
                      'save/restore ms', round(result['saveMsMedian'], 3), round(result['restoreMsMedian'], 3), flush=True)
            report['cases'].append(manifest)
            report['sourceSHA256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in HERE.glob('*') if p.suffix in ('.c', '.py')}
            report['librarySHA256'] = {str(p.relative_to(WORK)): hashlib.sha256(p.read_bytes()).hexdigest()
                                       for p in (SOURCE / 'libopenzl.a', WORK / 'zstd-single.a',
                                                 SOURCE / 'deps/lz4/lib/liblz4.a')}
            (WORK / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = []
    for _, _, name in METHODS:
        rows = [next(m for m in c['methods'] if m['name'] == name) for c in report['cases']]
        summary.append({'name': name, **{field: statistics.median(r[field] for r in rows)
                        for field in ('imagePayloadMiB', 'estimatedCheckpointMiB', 'saveMsMedian', 'restoreMsMedian')},
                        'compressionAdditionalPeakMiBMax': max(r['compressionAdditionalPeakBytesMedian'] for r in rows) / 1048576})
    report['summary'] = summary
    (WORK / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


def extend_native_lz():
    previous = json.loads((WORK / 'results.json').read_text())
    report = {k: v for k, v in previous.items() if k not in ('cases', 'summary', 'sourceSHA256', 'librarySHA256')}
    report['baselineReportSHA256'] = hashlib.sha256((WORK / 'results.json').read_bytes()).hexdigest()
    report['cases'] = []
    report['sourceSHA256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in HERE.glob('*') if p.suffix in ('.c', '.py')}
    report['executableSHA256'] = hashlib.sha256((WORK / 'bench.exe').read_bytes()).hexdigest()
    for index, case in enumerate(previous['cases']):
        folder = WORK / (case['case'] + '-' + str(index % 3))
        for image in case['images']:
            assert hashlib.sha256((folder / image['file']).read_bytes()).hexdigest() == image['sha256']
        row = {k: v for k, v in case.items() if k != 'methods'}
        row['methods'] = []
        for method, level, name in LZ_METHODS:
            result = json.loads(call([WORK / 'bench.exe', folder, method, level, 5]))
            result['name'] = name
            measured = [r for r in result['rounds'] if not r['warmup']]
            for field in ('saveMs', 'restoreMs', 'saveThreadCpuMs', 'restoreThreadCpuMs',
                          'compressedBytes', 'compressionAdditionalPeakBytes', 'restorationAdditionalPeakBytes'):
                result[field + 'Median'] = statistics.median(r[field] for r in measured)
            result['imagePayloadMiB'] = result['compressedBytesMedian'] / 1048576
            result['estimatedCheckpointMiB'] = (result['compressedBytesMedian'] + case['otherCheckpointBytes']) / 1048576
            row['methods'].append(result)
            print(case['case'], case['checkpointSeconds'], name, round(result['imagePayloadMiB'], 3),
                  round(result['saveMsMedian'], 3), round(result['restoreMsMedian'], 3), flush=True)
        report['cases'].append(row)
        (WORK / 'native-lz-results.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = []
    for _, _, name in LZ_METHODS:
        rows = [next(m for m in c['methods'] if m['name'] == name) for c in report['cases']]
        summary.append({'name': name, **{field: statistics.median(r[field] for r in rows)
                        for field in ('imagePayloadMiB', 'estimatedCheckpointMiB', 'saveMsMedian', 'restoreMsMedian')},
                        'compressionAdditionalPeakMiBMax': max(r['compressionAdditionalPeakBytesMedian'] for r in rows) / 1048576})
    report['summary'] = summary
    (WORK / 'native-lz-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
