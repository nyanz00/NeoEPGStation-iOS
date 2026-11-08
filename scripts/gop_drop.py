"""Drag local videos/folders onto GOP測定JSON作成.cmd; no app build needed."""
import argparse
import bisect
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys

from gop_reference import references

VIDEO_SUFFIXES = {'.mkv', '.mp4', '.mov', '.m4v'}


def choose_intervals(keys, pts, duration, fps, sections=8):
    """Evenly spread GOPs; source packet PTS, never future-key distance.

    The app accepts +/-2 frames (minimum 30ms). Keep this entire acceptance
    window inside the selected GOP, including for the far sample.
    """
    if not 1 <= sections <= 16:
        raise ValueError('測定区間数は1〜16で指定してください。')
    if not math.isfinite(fps) or fps <= 0 or not math.isfinite(duration) or duration <= 60:
        raise ValueError('現在のアプリでは60秒を超える動画が必要です。')
    if len(keys) < 2 or keys != sorted(set(keys)) or not all(math.isfinite(k) and 0 <= k < duration for k in keys):
        raise ValueError('キーフレーム時刻を取得できませんでした。')
    pts = sorted(set(t for t in pts if math.isfinite(t) and 0 <= t < duration))
    tolerance = max(.03, 2 / fps)
    margin = tolerance + 1 / fps
    eligible = []
    for start, end in zip(keys, keys[1:]):
        first = bisect.bisect_left(pts, start + margin)
        last = bisect.bisect_right(pts, end - margin)
        if last - first < 3:
            continue
        near, far = pts[first], pts[last - 1]
        center = (start + end) / 2
        candidates = [t for t in pts[max(first, bisect.bisect_left(pts, center)-1):min(last, bisect.bisect_left(pts, center)+1)] if near < t < far]
        if not candidates or near < 20 or far + 15 >= duration:
            continue
        middle = min(candidates, key=lambda t: abs(t-center))
        if middle-near <= 2*tolerance or far-middle <= 2*tolerance:
            continue
        eligible.append(dict(key=start, nextKey=end, near=near, middle=middle, far=far))
    if len(eligible) < sections:
        raise ValueError(f'測定可能なキーフレーム区間が{len(eligible)}個です。必要数は{sections}個です。')
    lower, upper = (40, duration-40) if duration > 100 else (20, duration-15)
    anchors = [lower+(i+.5)*(upper-lower)/sections for i in range(sections)]
    remaining = eligible.copy()
    selected = []
    for anchor in anchors:
        interval = min(remaining, key=lambda x: abs((x['key']+x['nextKey'])/2-anchor))
        remaining.remove(interval)
        selected.append(interval)
    selected.sort(key=lambda x: x['key'])
    return selected, tolerance


def inputs(paths):
    result = []
    seen = set()
    for raw in paths:
        path = Path(raw).expanduser().resolve()
        if not path.exists():
            raise ValueError(f'ファイルがありません: {path}')
        candidates = sorted(path.iterdir()) if path.is_dir() else [path]
        for movie in candidates:
            if movie.is_file() and movie.suffix.lower() in VIDEO_SUFFIXES and movie not in seen:
                result.append(movie)
                seen.add(movie)
    if not result:
        raise ValueError('動画ファイル、または動画のあるフォルダーをドロップしてください。')
    return result


def executable(name, supplied=None):
    local = Path(__file__).resolve().parent / (name+'.exe' if os.name == 'nt' else name)
    value = supplied or (str(local) if local.exists() else shutil.which(name))
    if not value or not Path(value).is_file():
        raise ValueError(f'{name}が見つかりません。PATHに追加するか、このスクリプトと同じフォルダーへ置いてください。')
    return str(Path(value).resolve())


def probe(movie, ffprobe):
    def read(*args, timeout=300):
        output = subprocess.check_output([ffprobe, '-v', 'error', *args, '-of', 'json', str(movie)], timeout=timeout)
        return json.loads(output)
    meta = read('-show_streams', '-show_format', timeout=60)
    video = next((s for s in meta['streams'] if s['codec_type'] == 'video'), None)
    if video is None:
        raise ValueError('映像トラックがありません。')
    rate = video.get('avg_frame_rate', '0/0').split('/')
    if len(rate) != 2 or float(rate[1]) == 0:
        raise ValueError('フレームレートを取得できませんでした。')
    fps = float(rate[0])/float(rate[1])
    # Reference readback currently covers SDR BT.709/untagged sources.
    if video.get('color_transfer', 'unknown') not in ('unknown', 'unspecified', 'bt709', 'iec61966-2-1'):
        raise ValueError('この参照画像生成はSDR用です。この動画の転送特性には未対応です。')
    if video.get('color_space', 'unknown') not in ('unknown', 'unspecified', 'bt709'):
        raise ValueError('この参照画像生成はBT.709/色指定なしの動画用です。')
    origin = float(video.get('start_time', 0))
    duration = float(meta['format']['duration'])-origin
    packets = read('-select_streams', 'v:0', '-show_packets', '-show_entries', 'packet=pts_time,flags')['packets']
    pts = sorted(set(round(float(p['pts_time'])-origin, 6) for p in packets if 'pts_time' in p and float(p['pts_time']) >= origin))
    keys = sorted(set(round(float(p['pts_time'])-origin, 6) for p in packets if 'pts_time' in p and 'K' in p.get('flags', '') and float(p['pts_time']) >= origin))
    label = movie.stem.rsplit('-', 1)[-1]
    if not re.fullmatch(r'(?:default|gop\d+)', label, re.IGNORECASE):
        label = 'video'
    gaps = [b-a for a, b in zip(keys, keys[1:])]
    profile = dict(label=label, bytes=movie.stat().st_size, duration=duration, fps=fps,
                   keys=keys, sourceTimeOrigin=origin, codec=video['codec_name'], pixelFormat=video.get('pix_fmt'),
                   width=video['width'], height=video['height'], gapMedian=statistics.median(gaps) if gaps else 0,
                   gapMax=max(gaps, default=0))
    return profile, pts


def create(movie, ffprobe, ffmpeg, sections=8, check_only=False):
    print(f'解析: {movie.name}', flush=True)
    profile, pts = probe(movie, ffprobe)
    intervals, tolerance = choose_intervals(profile['keys'], pts, profile['duration'], profile['fps'], sections)
    points = []
    for index, interval in enumerate(intervals, 1):
        for group in ('near', 'middle', 'far'):
            target = interval[group]
            points.append(dict(target=target, group=group, section=index, key=interval['key'], nextKey=interval['nextKey'],
                               distanceFromKey=target-interval['key'], fraction=(target-interval['key'])/(interval['nextKey']-interval['key'])))
    targets = [point['target'] for point in points]
    print(f'  キー間隔中央値: {profile["gapMedian"]:.3f}秒 / {sections}区間×近・中央・遠×送り戻し = {len(targets)*2}回', flush=True)
    for index, interval in enumerate(intervals, 1):
        print(f'  {index}: キー {interval["key"]:.3f}〜{interval["nextKey"]:.3f}秒 / 近 {interval["near"]:.3f}・中央 {interval["middle"]:.3f}・遠 {interval["far"]:.3f}', flush=True)
    if check_only:
        return None
    positions = sorted(set(targets+[t+d for t in targets for d in (-10, 10)]))
    print('  画像照合データを作成中です。動画の長さによって数分かかります…', flush=True)
    profile['references'] = references(movie, positions, profile['fps'], ffmpeg, profile['sourceTimeOrigin'])
    if len(profile['keys']) >= 100000 or len(profile['references']) >= 20000:
        raise ValueError('現在のアプリの測定計画上限を超えています。')
    plan = dict(schema=1, targets=targets, profiles=[profile], sampling=dict(method='keyframe-position-v1', sections=sections,
                targetToleranceSeconds=tolerance, points=points))
    data = (json.dumps(plan, ensure_ascii=False, separators=(',', ':'))+'\n').encode('utf-8')
    if len(data) >= 4*1024*1024:
        raise ValueError('JSONがアプリ上限の4MiBを超えました。--sectionsを減らしてください。')
    stem = f'gop-seek-plan-{profile["label"]}'
    output = movie.with_name(stem+'.json')
    suffix = 2
    while output.exists():
        output = movie.with_name(f'{stem} ({suffix}).json')
        suffix += 1
    # Exclusive create also protects a file appearing after the existence check.
    with output.open('xb') as handle:
        handle.write(data)
    print(f'  完了: {output}\n  動画とこのJSONを同じフォルダーに置いて、アプリで2つを選択してください。', flush=True)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description='動画をドロップして、キー区間の近・中央・遠を測るJSONを動画と同じ場所へ作成します。')
    parser.add_argument('paths', nargs='*', help='動画またはフォルダー（複数可、フォルダー内のサブフォルダーは対象外）')
    parser.add_argument('--sections', type=int, default=8)
    parser.add_argument('--ffprobe')
    parser.add_argument('--ffmpeg')
    parser.add_argument('--check', action='store_true', help='解析・測定位置の確認だけ。参照画像とJSONは作成しません。')
    parser.add_argument('--pause', action='store_true', help='終了後にEnter入力を待ちます（デスクトップの起動用）。')
    args = parser.parse_args(argv)
    try:
        movies = inputs(args.paths)
        ffprobe = executable('ffprobe', args.ffprobe)
        ffmpeg = executable('ffmpeg', args.ffmpeg)
        if not 1 <= args.sections <= 16:
            raise ValueError('測定区間数は1〜16で指定してください。')
    except (ValueError, OSError) as error:
        print(f'エラー: {error}', file=sys.stderr)
        return 1
    errors = 0
    for index, movie in enumerate(movies, 1):
        print(f'\n[{index}/{len(movies)}]', flush=True)
        try:
            create(movie, ffprobe, ffmpeg, args.sections, args.check)
        except (ValueError, OSError, KeyError, StopIteration, subprocess.SubprocessError, AssertionError) as error:
            errors += 1
            if isinstance(error, subprocess.CalledProcessError):
                print('エラー: FFmpeg/ffprobeの処理に失敗しました。', file=sys.stderr)
            else:
                print(f'エラー: {error}', file=sys.stderr)
    print(f'\n終了: 成功 {len(movies)-errors}本 / 失敗 {errors}本', flush=True)
    return 1 if errors else 0


if __name__ == '__main__':
    code = 1
    try:
        code = main()
    except KeyboardInterrupt:
        print('\n中断しました。', file=sys.stderr)
    finally:
        if '--pause' in sys.argv[1:]:
            try:
                input('\nEnterキーで閉じます…')
            except (EOFError, KeyboardInterrupt):
                pass
    raise SystemExit(code)
