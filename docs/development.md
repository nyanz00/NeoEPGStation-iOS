# 開発と実機確認

## ビルド

Windowsでは `npm ci` の後、`npm run typecheck`、`npm run lint`、`npm test -- --runInBand` を実行できる。
ネイティブのビルドは `.github/workflows/ios.yml` のmacOSランナーで行う。
React Nativeは0.87.1、Nodeは24.18.0、Xcodeは26.6、CocoaPodsは1.16.2に固定している。
VLCKitは `ios/VLCKit.podspec` の公式ダウンロードURLとSHA-256で固定する。

Actionsの `NeoEPGStation-iOS-<run number>` ArtifactからZIPをダウンロードし、
中の `NeoEPGStation.ipa` をLiveContainerに取り込む。
このIPAはad-hoc署名であり、LiveContainerでの取り込み用。通常の直接インストールやApp Store提出には使わない。
バンドルIDを維持して更新し、接続設定が残ることも確認する。

シミュレーターはXcodeのad-hoc署名を使う。ReleaseビルドをMetroなしで起動し、
接続設定のKeychainへの保存・読み戻し、直後に終了しないこととスクリーンショットを確認する。
これは接続・映像デコード・PiP・ASS・実機の性能の試験にはならない。
依存ロックファイルはActionsで生成した内容を検証して保存する。

## 最初の試験

1. 起動すると接続設定画面が表示される。
2. サーバーURLと、必要ならリバースプロキシのBasic認証を設定して接続する。
   URLには `/api` を指定しても除去される。サブパスは保持する。
3. 録画一覧から番組を選び、ファイルを選ぶ。
4. 元ファイルのPLAYで映像・音声、再生／一時停止、±10秒、シークバーを確認する。
   再生時にBasic認証を求められた場合は、保存した値を入力済みの認証ダイアログで確認する。
5. 字幕トラックの選択とオフを確認する。PiPボタンが有効になったら開始・復帰を確認する。
6. 閉じた後に再度再生できること、再起動・IPA更新後に接続設定が残ることを確認する。

キャッシュは最初は5秒。これはPLAYの調整の出発点であり、高ビットレート動画の停止を防ぐ完成実装ではない。
NicoJKコメント専用描画とサイズ・不透明度の試作は `docs/comment-rendering.md` を参照する。
コメント付きPiPの合成、STREAMING、放映中は後続の実装対象。
現時点のPiPはVLCKitの標準経路なので、字幕がPiPに出ることは保証しない。

## ネットワークと保存

接続情報はSwift経由でKeychainに保存する。認証情報はURLに埋め込まず、診断ログへ出力しない。
任意のユーザー指定HTTPサーバーに対応するためATSのHTTP制限を許可している。
HTTPSの証明書検証は無効化しない。App Store提出時にはこの設定の必要性とプライバシー情報を確認する。
ログ・スクリーンショットを公開する場合は、サーバーURL・番組名・認証情報等を確認してから共有する。

## 依存ライブラリ

VLCKitとlibVLCのライセンス表示・ソース提供等の配布条件を維持する。
独自改修の配布前には対応するソースとパッチを公開し、App Store配布時の構成を確認する。
公式ビルドの情報: https://github.com/videolan/vlckit/tree/2e0868f5ed40fe59cd92f377645fdcc260c6e759
