# NeoEPGStation iOS

NeoEPGStationのiPhone / iPad向けネイティブクライアント。iOS / iPadOS 18以降。
現在は接続設定・録画検索・一覧・詳細・ネイティブPLAY再生の初期実装です。

- [要件と開発方針](docs/requirements.md)
- [ビルドと実機確認](docs/development.md)
- [iOSビルド](../../actions/workflows/ios.yml)

Swift / UIKit、VLCKit 4系を使用します。
ActionsのArtifactにLiveContainer取り込み用のIPAを生成します。
字幕の詳細調整・コメント付きPiP・STREAMING・放映中の視聴は開発中です。
