"""Generate tiny, synthetic clock fixtures; requires FFmpeg with NVIDIA support.

These files contain only a solid color and silence. Generating them here keeps
the investigation runner independent of Homebrew and tests FFmpeg 7.1.1 media.
"""
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile
import zipfile

ff = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y']


def run(args):
    subprocess.run(args, check=True, timeout=120)


with tempfile.TemporaryDirectory(prefix='hls-clock-') as temporary:
    root = Path(temporary)
    movie = root / 'source.mp4'
    run(ff + ['-f', 'lavfi', '-i', 'color=c=navy:size=320x180:rate=25', '-f', 'lavfi', '-i',
              'anullsrc=sample_rate=48000:channel_layout=stereo', '-t', '70', '-c:v', 'libx264',
              '-preset', 'ultrafast', '-g', '100', '-c:a', 'aac', str(movie)])
    variants = [('full', 0, 0, 'libx264', 'ultrafast', 0),
                ('full-default-mux', 0, 0, 'libx264', 'ultrafast', None),
                ('rebased-absolute', 48, 48, 'libx264', 'ultrafast', 0),
                ('rebased-relative', 48, 0, 'libx264', 'ultrafast', 0),
                ('nvenc-absolute', 48, 48, 'h264_nvenc', 'p4', 0),
                ('nvenc-default-mux', 48, 48, 'h264_nvenc', 'p4', None),
                ('x264-bframes-absolute', 48, 48, 'libx264', 'medium', 0),
                ('x264-bframes-default-mux', 48, 48, 'libx264', 'medium', None)]
    for name, start, offset, codec, preset, delay in variants:
        out = root / name
        out.mkdir()
        args = ff + ['-ss', str(start), '-i', str(movie), '-c:v', codec, '-preset', preset]
        if codec == 'libx264':
            args += ['-g', '100', '-sc_threshold', '0']
        else:
            args += ['-profile:v', 'high', '-b:v', '1000k', '-maxrate', '1000k']
        args += ['-force_key_frames', 'expr:gte(t,n_forced*4)', '-c:a', 'aac']
        if delay is not None:
            args += ['-muxdelay', str(delay), '-muxpreload', str(delay)]
        args += ['-f', 'hls', '-hls_time', '4', '-hls_list_size', '0', '-hls_playlist_type', 'vod',
                 '-hls_segment_type', 'mpegts', '-hls_flags', 'independent_segments', '-start_number', str(start//4),
                 '-output_ts_offset', str(offset), '-hls_segment_filename', str(out / '%d.ts'), str(out / 'playlist.m3u8')]
        run(args)
    for name, copyts, delay in [('remux-absolute', False, None), ('remux-copyts', True, None),
                                ('remux-copyts-zero', True, 0)]:
        out = root / name
        out.mkdir()
        args = ff + (['-copyts'] if copyts else []) + ['-i', str(root / 'rebased-absolute/playlist.m3u8'),
                                                      '-map', '0', '-c', 'copy']
        if delay is not None:
            args += ['-muxdelay', str(delay), '-muxpreload', str(delay)]
        run(args + ['-hls_time', '4', '-hls_list_size', '0', '-hls_playlist_type', 'vod', '-hls_segment_type',
                    'mpegts', '-hls_flags', 'independent_segments', '-start_number', '12',
                    '-hls_segment_filename', str(out / '%d.ts'), str(out / 'playlist.m3u8')])
    origins = {}
    for out in sorted(root.iterdir()):
        if not out.is_dir():
            continue
        index = 0 if out.name.startswith('full') else 12
        media = out / f'{index}.ts'
        origins[out.name] = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
                        'format=start_time,duration', '-of', 'json', str(media)], text=True))
        origins[out.name]['video'] = json.loads(subprocess.check_output(['ffprobe', '-v', 'error',
                        '-select_streams', 'v:0', '-read_intervals', '%+#1', '-show_entries',
                        'packet=pts_time,dts_time', '-of', 'json', str(media)], text=True))
    archive = Path(__file__).with_name('fixtures.zip')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        output.writestr('origins.json', json.dumps(origins, indent=2))
        for out in sorted(root.iterdir()):
            if out.is_dir():
                for file in sorted(out.iterdir()):
                    output.write(file, file.relative_to(root).as_posix())
    archive.with_suffix('.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  fixtures.zip\n')
    print(archive, archive.stat().st_size)
