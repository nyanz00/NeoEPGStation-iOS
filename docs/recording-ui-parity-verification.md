# 録画操作UIの再現と検証

検証済みソースは `df70025e7f63f2ef67af7f2c14a298f70e4626b0`。
Actionsの[ビルド45](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/37327009010)の2回目の実行が成功した。
この検証記録の追加ではアプリ・ビルド設定を変更していない。

## 参照と変更

- `RecordedDetailPage.tsx` とMUIのButton・createPaletteを参照した。
  PLAYは同じ中抜きの三角アイコンを使う。背景はWebのcontainedボタンを引き継ぐ。
  ファイル選択は13pt・最小幅64pt・31pt高、ダークテーマのsuccess色 `#81c784` と黒文字に修正した。
- PLAY・STREAMING・ENCODEをモバイルで一行に収める。STREAMING・ENCODEは準備中の操作。
  「THUMBボタンを表示しない」は既定でオンにし、設定から切り替えて保存する。
- `RecordedItemActions.tsx` の順序に合わせ、詳細のthumbnailはencode直後、developer mode時のsubtitleはその次に置く。
  一覧のsubtitleはprotect/unprotectの後。encodeの準備中項目は設定取得前でも表示する指定を適用した。
- `queries.ts` と同じく、設定APIのencode配列から非文字列・空のモードを除外する。
  モードの欠落・無効値によってdeveloper modeやSTREAMINGの設定まで読み込み失敗にならないようにした。
  初回設定取得に失敗した場合は録画メニューを開いたときにバックグラウンドで再取得する。
- `RecordedPage.tsx` を参照し、一覧右上は編集・クリーンアップ・アップロードの準備中メニューに修正した。
- ドロップログは `programDialogStyles.ts` と詳細ページのDialogを参照し、番組名付きタイトル・区切り線・スクロール本文・閉じるボタンを持つダイアログにした。
  別ページへ移動せず、詳細のナビゲーションスタックを増やさない。

## 結果

Swiftの型検査、無効なencode項目が混在する設定のデコード、developer modeの保持、
thumbnail/subtitleの順序と表示条件、設定APIの取得試験が成功した。
シミュレーターではTHUMB非表示の既定値と保存、一行の操作ボタン、
ファイル選択の位置・色・最小幅、一覧と詳細のメニュー、ログダイアログと戻る履歴の維持を確認した。
新しいUIの画像を目視確認し、既存のナビゲーション・フェード・サムネイル・保存・再生・コメント合成・PiPの検証も成功した。

初回は今回未変更の再生試験で、合成動画の生成中の書き込みが失敗した。
その試験は20秒の期限とappend失敗を同じエラーで扱い、個別原因の記録はない。
コードを変更せずに再実行し、全項目が成功した。成功した2回目のArtifact（ID `11353563325`）を配布対象にした。

iPadシミュレーターは省略した。画面画像と操作ハンドラーの確認であり、
実際の指での操作感・端末上の表示は実機で確認する。
STREAMING・ENCODE・THUMB・管理メニューの操作は今回プレースホルダーである。

IPA: build `45`、最低OS `18.0`、`io.github.nyanz00.NeoEPGStation`、LiveContainer用ad-hoc署名。
SHA-256: `6a0b84729e811eabfcf3785212a5122ffc98198796bf34c9faa20b734d2634cf`。
成果物のコミット・IPAの情報・チェックサム・プライバシー情報の同梱を確認し、依存ロックは変更なし。
