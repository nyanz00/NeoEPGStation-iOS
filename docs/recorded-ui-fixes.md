# 録画済み・放映中の入力と表示条件

## 今回の範囲

録画操作の新規移植は含めない。対象は次の5点のみ。

| 対象 | Webの根拠・仕様 | アプリの変更と確認 |
| --- | --- | --- |
| 放映波切り替え | ネイティブ既存の横スライド0.22秒を維持し、新しい放映波は先頭から表示 | `NeoOnAirPage`のスクロール一覧と移動用外枠を分離。再配置・先頭移動はアニメーション外で確定。下方スクロールからの左右切り替えと途中反転について、表示レイヤーのY座標・高さとスクロール位置を途中フレームで確認 |
| 検索のフォーカス | `RecordedPage.tsx`のキーワード`autoFocus` | 初回表示でフォーカス。検索候補を取得して再配置しても同じ入力欄を保持し、入力・カーソル・キーボードを維持 |
| 日付の補正 | `DateTimeInput.tsx`と`core/dateTimeInput.ts` | NFKC、8桁の数字、表示YYYY/MM/DD・内部YYYY-MM-DD。削除時は区切りを再挿入せず、不完全な入力を保持。存在しない日付や途中入力は検索前に拒否。JSTの開始・終了境界は既存モデルを維持 |
| subtitleの場所 | `RecordedItemActions.tsx`のdeveloperModeかつonSubtitle指定。Web一覧はonSubtitleを渡さない | 一覧から削除。詳細のdeveloperMode条件は維持 |
| THUMBの設定反映 | `SettingsPage.tsx`の「THUMBボタンを表示しない」、`RecordedDetailPage.tsx`のボタン／詳細メニュー配置 | 既存設定と保存値を維持。別タブから保持済みの詳細へ戻った時にも配置を再評価。実際の設定スイッチを変更し、同じ詳細インスタンスで両方向を確認 |

## 検証

Actionsは`check_scope=player-feedback`、`ui_stage=recorded-fixes`を指定。日付補正のFoundationテスト、メニューを含むUIモデルテスト、iPhone/iPadの対象UI試験、両SDKのアプリビルドとFFmpegインポート分離を実行する。再生・通信復旧・PiP・Annictの試験は追加しない。

Windows上ではCI補助27項目、Python構文、ワークフローYAML、差分の空白検査を確認。Swift/UIKitとアニメーションの実行結果はActions完了後に記録する。実機の操作感はシミュレーター結果とは区別する。
