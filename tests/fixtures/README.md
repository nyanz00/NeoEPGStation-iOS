# PLAYタップ検証用TS

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
