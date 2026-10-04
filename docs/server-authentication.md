# リバースプロキシのログイン対応

現状のアプリはURLの保存・自動接続を実装している。OAuth / SSOのログイン経路は未実装。
接続画面にはBasic認証の入力欄を置かない。

## EPGPlayerで確認した構成

参照コミット: `imxieyi/EPGPlayer` の `4fb8da5b166f51ee6e0cf9c226d47dbdffee283a`。

- `EPGClient.swift` はURLSessionのAPIリダイレクトを自動追跡しない。
  `EPGPlayerApp.swift` はリダイレクト応答を認証が必要な状態として扱う。
- `MainView.swift` は認証用のWeb画面を開く。`AuthWebView.swift` はWKWebViewで
  `/api/version` のURLを読み込み、ログイン画面への遷移をブラウザーに処理させる。
  想定URLとJSONのContent-Typeへの復帰をログイン完了の目印にする。
- 認証画面が閉じた後、APIクライアントを更新し、データを再取得する。
- `VLCPlayer.swift` は動画URLに該当するHTTPCookieStorageのCookieを
  `VLCMedia.storeCookie(_:forHost:path:)` で再生前にVLCへ渡す。

現在固定しているVLCKitの公開ヘッダーにも `storeCookie:forHost:path:` が存在する。
したがって、アプリ内ログインとVLCへのCookie受け渡しを、今の再生構成に追加する余地がある。
これはNeoEPGStation-iOSでOAuth認証を実証したという意味ではない。

## こちらの実装方針

最初はoauth2-proxyによる保護を想定する。アプリが新しいOAuthクライアントとして
プロバイダーへ登録するのではなく、既存のサーバー側ログイン経路を利用する。

1. URLへ接続し、APIの認証リダイレクトを検知する。
   HTMLをJSONとして解析して一般的な接続エラーにしない。
   サーバー障害や権限不足の401/403を、必ずログインが必要だと決めつけない。
2. 認証が必要ならログイン画面を開く。キャンセルと通信エラーから接続画面に戻れるようにする。
3. WebKitのCookieを明示的に取得し、対象サーバーの認証状態をネイティブのHTTP取得へ引き継ぐ。
   復帰先は文字列の前方一致だけで判定せず、スキーム・ホスト・ポート・APIパスで照合する。
   Cookieのドメイン・パス・Secure・有効期限を守る。
4. APIを再確認してから画面へ戻り、API・サムネイル・字幕・動画再生に同じ認証状態を適用する。
   VLCへのCookie設定は再生開始前に行う。
5. 再起動、セッション期限切れ、ログアウト、接続先変更を扱う。
   Cookieや認証ヘッダーをログ・JSの一般設定・公開テストデータへ出さない。

EPGPlayerのWebKit→HTTP Cookie同期がこのアプリでも暗黙に成立するとは扱わず、
実装とテストで明示的に確認する。認証プロバイダーによってWeb画面でのログイン条件も異なるため、
EPGPlayerで利用できる方式が全プロバイダーに対応するとは保証しない。

## 確認対象

認証なしの接続、初回ログイン、キャンセル、期限切れ後の再ログイン、アプリ再起動、
別サーバーへの切り替え、APIと画像と字幕の取得、VLC再生・シーク・PiPを確認する。
サブパス配下のサーバーとoauth2-proxyの複数Cookie構成も確認する。

## 参照

- [EPGPlayer APIクライアント](https://github.com/imxieyi/EPGPlayer/blob/4fb8da5b166f51ee6e0cf9c226d47dbdffee283a/EPGPlayer/Shared/Client/EPGClient.swift)
- [EPGPlayer認証画面](https://github.com/imxieyi/EPGPlayer/blob/4fb8da5b166f51ee6e0cf9c226d47dbdffee283a/EPGPlayer/Shared/UI/Main/AuthWebView.swift)
- [EPGPlayerプレイヤー](https://github.com/imxieyi/EPGPlayer/blob/4fb8da5b166f51ee6e0cf9c226d47dbdffee283a/EPGPlayer/Shared/UI/Player/VLCPlayer.swift)
- [固定VLCKitの公開VLCMediaヘッダー](https://github.com/videolan/vlckit/blob/2e0868f5ed40fe59cd92f377645fdcc260c6e759/Headers/Public/Media/VLCMedia.h)
- [oauth2-proxyのエンドポイント](https://oauth2-proxy.github.io/oauth2-proxy/features/endpoints/)
- [WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore)
