# 放映中

放映中タブは本体 `client/src/pages/OnAirPage.tsx`、`components/OnAirSelectStreamDialog.tsx`、`core/media/live.ts`、`core/player/LiveJikkyoCommentCore.ts` を基準に移植する。

- 放送種別タブ、局カード、番組情報、進行率、ピン留め、実況の勢い（コメ/分）。番組・勢いは30秒、進行率は10秒で更新する。
- サーバー設定の live.ts.m2ts / m2tsll を使う。無変換も変換も同じライブAPIを使い、encoder / hevc の独自上書きは送らない。
- 共通VLCプレイヤーを使い、ARIB字幕と実況を既存コメント描画・合成PiPへ渡す。初回にコメント投稿欄は含めない。
- ライブTS専用の有界な逐次中継を使用し、録画用のRangeキャッシュ・リジューム・視聴履歴・シーク処理へ入れない。停止・切り替え・終了で上流HTTPを閉じ、サーバーの配信利用を解放する。
- 一時停止後の再開、ライブへ戻る、再接続は最新位置で開き直す。HTTPエラー・EOF・25秒の開始待ち・5秒の映像停止を検出し、再接続は1〜15秒、最大8回。音声は映像確認までミュートする。
- 実況はサーバーAPIからセッションを取得し、watch/commentの2つのWebSocketへ接続する。初期の過去ログを除外し、PCRから求めた映像の遅延を加える。サーバーの認証ヘッダーを外部の実況WebSocketへ送らない。
- 共通プレイヤーの一般設定でライブの配信・画質・バッファを変更できる。下部の放送局パネルから局を切り替える。

## 対象検証

Actionsの `check_scope=live` は、API設定・PCR/ラップ・コメントコマンドの単体試験、両SDKビルド、MPEG-2/H.264の実映像と音声を使った逐次TS配信、WebSocket接続、局/画質切り替え、HTTP切断と503からの回復、終了時の接続解放、録画PLAYの回帰試験を行う。
実機の放送受信環境、iOSによるアプリ外PiP、触覚はシミュレーター試験と区別する。試験結果はビルド成果物の `live-*.json` と画面画像に保存する。

## 確認済みビルド

- ビルド303、ソース `953edba1c829d0df1669204e8dcc154da33f0ef4`。
- Actions: https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/41064833249
- iPhone用・シミュレーター用の両SDKビルドとFFmpeg import isolation確認が成功。
- ライブのAPI/PCR/コマンド14チェックが成功。MPEG-2とH.264それぞれで再生17・UI6・サーバー9、計64チェックが成功。
- 合成映像フレーム、ARIBの表示領域、実況の初期過去ログ除外、局/画質切り替え、停止/再開、通信切断と503後の復帰、HTTP/WebSocket解放を確認。ARIB字幕と実況が映った画面画像も確認した。
- 録画PLAYのMKV・MP4は各48チェックが成功。
- IPA: `NeoEPGStation-build303.ipa`。SHA-256: `51c159ef8724c1a36305a50c4109a587f42267a2a0d617ea026e583bbcf2d8c2`。
- IPA内のビルド番号・ソース情報・配布ハッシュを照合済み。実際の放送受信環境とアプリ外PiPのOS動作は実機未確認。
