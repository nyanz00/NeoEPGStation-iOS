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
import time

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


def build_profile(movie, ffprobe, sections=8):
    started = time.perf_counter()
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
    if len(profile['keys']) >= 100000:
        raise ValueError('現在のアプリの測定計画上限を超えています。')
    profile.update(targets=targets, points=points, samplingMethod='keyframe-position-v2', targetToleranceSeconds=tolerance)
    print(f'  解析完了: {time.perf_counter()-started:.2f}秒（参照画像なし）', flush=True)
    return profile


def write_batch(profiles, requested_output):
    if not 1 <= len(profiles) <= 12 or len({p['bytes'] for p in profiles}) != len(profiles):
        raise ValueError('1〜12本で、ファイルサイズが重複しない動画を選択してください。')
    plan = dict(schema=2, targets=[], profiles=profiles, measurement='displayed-timestamp')
    data = (json.dumps(plan, ensure_ascii=False, separators=(',', ':'))+'\n').encode('utf-8')
    if len(data) >= 4*1024*1024:
        raise ValueError('JSONがアプリ上限の4MiBを超えました。--sectionsを減らしてください。')
    output = Path(requested_output)
    stem = output.stem
    suffix = 2
    while output.exists():
        output = output.with_name(f'{stem} ({suffix}).json')
        suffix += 1
    # Exclusive create also protects a file appearing after the existence check.
    with output.open('xb') as handle:
        handle.write(data)
    print(f'\n完了: {output}\n{len(profiles)}本を1個のJSONへ保存しました。動画とこのJSONを同じフォルダーに置いて選択してください。', flush=True)
    print('この軽量形式は修正版テスター用です。ビルド355では使用できません。', flush=True)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description='動画をドロップして、参照画像なし・動画別測定位置の統合JSONを1個作成します。')
    parser.add_argument('paths', nargs='*', help='動画またはフォルダー（複数可、フォルダー内のサブフォルダーは対象外）')
    parser.add_argument('--sections', type=int, default=8)
    parser.add_argument('--ffprobe')
    parser.add_argument('--output', type=Path, help='出力先。省略時は先頭の動画と同じ場所のgop-seek-plan.json')
    parser.add_argument('--check', action='store_true', help='解析・測定位置の確認だけ。JSONは作成しません。')
    parser.add_argument('--pause', action='store_true', help='終了後にEnter入力を待ちます（デスクトップの起動用）。')
    args = parser.parse_args(argv)
    try:
        movies = inputs(args.paths)
        ffprobe = executable('ffprobe', args.ffprobe)
        if len(movies) > 12:
            raise ValueError('一度に選択できるのは12本までです。')
        if not 1 <= args.sections <= 16:
            raise ValueError('測定区間数は1〜16で指定してください。')
    except (ValueError, OSError) as error:
        print(f'エラー: {error}', file=sys.stderr)
        return 1
    errors = 0
    profiles = []
    for index, movie in enumerate(movies, 1):
        print(f'\n[{index}/{len(movies)}]', flush=True)
        try:
            profile = build_profile(movie, ffprobe, args.sections)
            if profile['bytes'] in {p['bytes'] for p in profiles}:
                raise ValueError('同じサイズの動画があり、アプリで区別できません。別々に生成してください。')
            if profile['label'] in {p['label'] for p in profiles}:
                profile['label'] += f'-{index}'
            profiles.append(profile)
        except (ValueError, OSError, KeyError, StopIteration, subprocess.SubprocessError, AssertionError) as error:
            errors += 1
            if isinstance(error, subprocess.CalledProcessError):
                print('エラー: ffprobeの処理に失敗しました。', file=sys.stderr)
            else:
                print(f'エラー: {error}', file=sys.stderr)
    print(f'\n終了: 成功 {len(movies)-errors}本 / 失敗 {errors}本', flush=True)
    if errors:
        print('失敗した動画があるため、統合JSONは保存していません。', file=sys.stderr)
        return 1
    if not args.check:
        try:
            write_batch(profiles, args.output or movies[0].with_name('gop-seek-plan.json'))
        except (ValueError, OSError) as error:
            print(f'エラー: {error}', file=sys.stderr)
            return 1
    return 0


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
