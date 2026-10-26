"""Repeat the relevant comparisons with host CPU SIMD enabled for both libraries.

This is a PC CPU experiment, not Metal and not an iPhone performance estimate.
"""
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import run as trial

ROOT, WORK, SOURCE, HERE = trial.ROOT, trial.WORK, trial.SOURCE, trial.HERE


def main():
    if not (WORK / 'libopenzl-portable.a').exists():
        shutil.copyfile(SOURCE / 'libopenzl.a', WORK / 'libopenzl-portable.a')
    with (WORK / 'build-native.log').open('wb') as log:
        result = subprocess.run(
            ['C:/msys64/usr/bin/bash.exe', '-c',
             "export PATH=/mingw64/bin:/usr/bin; make -j8 libopenzl.a BUILD_TYPE=OPT CC=gcc AR=ar MOREFLAGS='-march=native -pipe'"],
            cwd=SOURCE, env=trial.ENV, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    if result.returncode:
        raise RuntimeError((WORK / 'build-native.log').read_text(errors='replace')[-5000:])
    print('Native CPU OpenZL build complete', flush=True)
    trial.call(['gcc', '-pipe', '-std=gnu11', '-O3', '-march=native', '-DNDEBUG', '-DZSTD_DISABLE_ASM', '-c',
                WORK / 'zstd-single.c', '-o', WORK / 'zstd-native.o'], timeout=300)
    trial.call(['gcc', '-pipe', '-std=gnu11', '-O3', '-march=native', '-Wall', '-Wextra', '-c',
                '-I.local/openzl-trial/openzl-0.3.0/include', '-I.local/openzl-trial/openzl-0.3.0/deps/zstd/lib',
                HERE / 'bench.c', '-o', WORK / 'bench-native.o'])
    trial.call(['gcc', WORK / 'bench-native.o', SOURCE / 'libopenzl.a', WORK / 'zstd-native.o',
                SOURCE / 'deps/lz4/lib/liblz4.a', '-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free',
                '-o', WORK / 'bench-native.exe', '-lpsapi', '-lm'])
    previous = json.loads((WORK / 'results.json').read_text())
    report = {k: v for k, v in previous.items() if k not in ('cases', 'summary', 'sourceSHA256', 'librarySHA256')}
    report['cpuBuild'] = 'OpenZL, Zstandard and harness -O3 -march=native; one compression thread, affinity 1'
    report['sourceSHA256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in HERE.glob('*') if p.suffix in ('.c', '.py')}
    report['librarySHA256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in (SOURCE / 'libopenzl.a', WORK / 'zstd-native.o', WORK / 'bench-native.exe')}
    report['cases'] = []
    methods = trial.METHODS + trial.LZ_METHODS
    for index, case in enumerate(previous['cases']):
        folder = WORK / (case['case'] + '-' + str(index % 3))
        for image in case['images']:
            assert hashlib.sha256((folder / image['file']).read_bytes()).hexdigest() == image['sha256']
        row = {k: v for k, v in case.items() if k != 'methods'}
        row['methods'] = []
        order = methods[index:] + methods[:index]
        for method, level, name in order:
            result = json.loads(trial.call([WORK / 'bench-native.exe', folder, method, level, 5]))
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
        (WORK / 'native-cpu-results.json').write_text(json.dumps(report, indent=2) + '\n')
    report['summary'] = []
    for _, _, name in methods:
        rows = [next(m for m in c['methods'] if m['name'] == name) for c in report['cases']]
        report['summary'].append({'name': name, **{field: statistics.median(r[field] for r in rows)
                                  for field in ('imagePayloadMiB', 'estimatedCheckpointMiB', 'saveMsMedian', 'restoreMsMedian')},
                                  'compressionAdditionalPeakMiBMax': max(r['compressionAdditionalPeakBytesMedian'] for r in rows) / 1048576})
    (WORK / 'native-cpu-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['summary'], indent=2), flush=True)


if __name__ == '__main__':
    main()
