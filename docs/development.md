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
加えて合成動画のVLC再生、コメントのMetal/CPU合成、横画面レイアウトを検証する。
基礎UIは実際のReleaseバンドルをiPhone・iPadシミュレーターで起動し、
架空の録画データを使った一覧・サイドメニュー・設定の画像を生成する。
下部ナビの項目・順番はUserDefaultsに保存する。実装範囲は `ui-foundation.md` を参照する。
これは実サーバー接続・実機のAV1性能・バックグラウンドPiPの試験にはならない。
依存ロックファイルはActionsで生成した内容を検証して保存する。

## 最初の試験

1. 初回は接続設定画面が表示される。保存済みなら同じ接続先から録画一覧を自動で取得する。
   接続失敗時は保存URLを残した接続画面へ戻り、再試行・変更できる。
2. サーバーURLだけを入力して保存・接続する。
   URLには `/api` を指定しても除去される。サブパスは保持する。
3. 録画一覧から番組を選び、ファイルを選ぶ。
4. 元ファイルのPLAYで映像・音声、再生／一時停止、±10秒、シークバーを確認する。
5. 字幕トラックの選択とオフを確認する。PiPボタンが有効になったら開始・復帰を確認する。
6. 閉じた後に再度再生できること、再起動・IPA更新後に接続ボタンを押さずに録画一覧が開くことを確認する。

キャッシュは最初は5秒。これはPLAYの調整の出発点であり、高ビットレート動画の停止を防ぐ完成実装ではない。
NicoJKコメント専用描画とサイズ・不透明度の試作は `docs/comment-rendering.md` を参照する。
横画面では映像を画面全体にフィットし、操作欄は映像に重ねる。
映像をタップすると操作欄が切り替わり、再生中は4秒で隠れる。
PiPボタンは専用コメントを合成する経路を使う。通常のVLC字幕はまだ合成対象ではない。
STREAMING、放映中は後続の実装対象。

## ネットワークと保存

接続情報はSwift経由でKeychainに保存する。認証情報はURLに埋め込まず、診断ログへ出力しない。
旧試作のBasic認証情報は読み戻さない。URLの再保存で旧情報も置き換わる。
リバースプロキシのOAuthログインと認証セッションの引き継ぎは将来対応であり、現在は未実装。
oauth2-proxyはセッションCookieを使うため、ブラウザーへの遷移だけでAPI・VLCの認証が成立したとは扱わない。
参考: https://oauth2-proxy.github.io/oauth2-proxy/features/endpoints/
任意のユーザー指定HTTPサーバーに対応するためATSのHTTP制限を許可している。
HTTPSの証明書検証は無効化しない。App Store提出時にはこの設定の必要性とプライバシー情報を確認する。
ログ・スクリーンショットを公開する場合は、サーバーURL・番組名・認証情報等を確認してから共有する。

## 依存ライブラリ

VLCKitとlibVLCのライセンス表示・ソース提供等の配布条件を維持する。
独自改修の配布前には対応するソースとパッチを公開し、App Store配布時の構成を確認する。
公式ビルドの情報: https://github.com/videolan/vlckit/tree/2e0868f5ed40fe59cd92f377645fdcc260c6e759
