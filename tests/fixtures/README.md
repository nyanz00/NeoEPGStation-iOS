# PLAYタップ検証用TS

`player-tap.ts`は単色の320×180、24fps、20秒のH.264/MPEG-TS合成動画。
実サーバー・録画・音声・字幕等の私的データを含まない。
シミュレーターのDocumentsへコピーしてMP4との背景タップ挙動を比較する。
実機アプリのリソースには追加しない。

生成コマンド（FFmpeg 7.1.1）:

```sh
ffmpeg -f lavfi -i color=c=0x305060:s=320x180:r=24:d=20 -c:v libx264 -preset ultrafast -tune zerolatency -g 24 -pix_fmt yuv420p -f mpegts player-tap.ts
```
