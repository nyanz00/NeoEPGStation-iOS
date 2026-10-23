# PLAYタップ検証用TS

`hevc-seek-10.mkv` / `.mp4` は72秒・1920×1080・24fps・HEVC Main 10、
24秒間隔のGOP・3 Bフレーム・440Hz音声の合成動画。
HEVCの同じ入力・同じシーク位置で、画像出力省略を両側とも有効にしたまま、
非参照フレームの復号省略のみを切り替える。H.264の結果で代用しない。

```sh
ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 72 -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -crf 38 -x265-params keyint=576:min-keyint=576:scenecut=0:bframes=3:open-gop=0:pools=4:frame-threads=2 -c:a aac -b:a 64k -map_metadata -1 hevc-seek-10.mkv
ffmpeg -i hevc-seek-10.mkv -map 0 -c copy -tag:v hvc1 -movflags +faststart -map_metadata -1 hevc-seek-10.mp4
```

`av1-seek-8.*`、`av1-seek-10.*` は下記と同じ72秒・320×180・24fpsの
合成映像と音声。AV1 Main profileの8bit/10bitをMKV/MP4で検証する。
24秒間隔のキーフレームを含み、実機アプリには同梱しない。

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 72 -c:v libaom-av1 -cpu-used 8 -row-mt 1 -threads 4 -crf 45 -b:v 0 -g 576 -pix_fmt yuv420p -c:a aac -b:a 48k av1-seek-8.mkv
# 10bit: change yuv420p to yuv420p10le and output to av1-seek-10.mkv.
ffmpeg -i av1-seek-8.mkv -map 0 -c copy -movflags +faststart av1-seek-8.mp4
ffmpeg -i av1-seek-10.mkv -map 0 -c copy -movflags +faststart av1-seek-10.mp4
```

`encoded-seek-1080.mkv` と `encoded-seek-1080.mp4` は72秒・1920×1080・24fps、
H.264、3 Bフレーム、24秒間隔のキーフレームと440Hzの音声。
同じバイナリでpreroll画像出力の有効・無効を比較する。
MKVは無効→有効、MP4は有効→無効の順で、同じ正確なシーク位置・キャッシュを使用する。
画像出力省略が実際に適用されたことも確認し、単なる試験成功を速度改善とは扱わない。

```sh
ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 72 -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 32 -g 576 -keyint_min 576 -sc_threshold 0 -bf 3 -c:a aac -b:a 64k -movflags +faststart -map_metadata -1 encoded-seek-1080.mp4
ffmpeg -i encoded-seek-1080.mp4 -map 0 -c copy -map_metadata -1 encoded-seek-1080.mkv
```

`encoded-seek.mkv` と `encoded-seek.mp4` は72秒・320×180・24fpsの合成映像と440Hzの音声。
24秒間隔のキーフレームの間への正確なシークと、30秒の途中開始位置より前への戻しを検証する。
実機アプリには同梱しない。CIで毎回FFmpegをインストール・生成する時間を省く。

生成コマンド（FFmpeg 7.1.1）:

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 72 -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 200k -g 576 -keyint_min 576 -sc_threshold 0 -bf 3 -c:a aac -b:a 64k encoded-seek.mkv
ffmpeg -i encoded-seek.mkv -map 0 -c copy -movflags +faststart encoded-seek.mp4
```

`player-seek.mkv` はFFmpegのtestsrc2と440Hzの合成音声から作った2分のMKV。
動画Cuesを含み、HTTP経由の90秒への復旧でRange位置・通信量・再生進行を検証する。
アプリのリソースには追加しない。

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=12 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 120 -c:v libx264 -preset veryfast -crf 12 -g 24 -c:a aac -b:a 64k player-seek.mkv
```

`player-tap.ts`は単色の320×180、24fps、20秒のH.264/MPEG-TS合成動画。
実サーバー・録画・音声・字幕等の私的データを含まない。
シミュレーターのDocumentsへコピーしてMP4との背景タップ挙動を比較する。
実機アプリのリソースには追加しない。

生成コマンド（FFmpeg 7.1.1）:

```sh
ffmpeg -f lavfi -i color=c=0x305060:s=320x180:r=24:d=20 -c:v libx264 -preset ultrafast -tune zerolatency -g 24 -pix_fmt yuv420p -f mpegts player-tap.ts
```
