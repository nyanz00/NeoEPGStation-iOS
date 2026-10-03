# NeoEPGStation iOS

NeoEPGStationのiPhone / iPad向けネイティブクライアント。iOS / iPadOS 18以降。
現在は接続設定・録画一覧・ファイル選択・ネイティブPLAY再生の初期試作です。

- [要件と開発方針](docs/requirements.md)
- [ビルドと実機確認](docs/development.md)
- [iOSビルド](../../actions/workflows/ios.yml)

React Native 0.87.1、Swift、VLCKit 4系を使用します。
ActionsのArtifactにLiveContainer取り込み用のIPAを生成します。
字幕の詳細調整・コメント付きPiP・STREAMING・放映中の視聴は開発中です。
