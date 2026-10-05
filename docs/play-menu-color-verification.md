# PLAYメニューの色・配置修正

検証済みソースは `08bff1c5349b90ddefc6cde29864ded9e55e0716`。
Actionsの[ビルド46](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/37340598487)が成功した。

## 参照と修正

- 本体の `RecordedDetailPage.tsx` のファイル選択Popoverと、MUIのButton・ButtonBase・createPalette・green・Paper・Popover・getOverlayAlphaを確認した。
- dark success.mainはgreen[400]の `#66BB6A`。ENCODE・THUMB・ファイル選択で共有する色を訂正した。文字色は黒、不透明度0.87を維持する。
- メニュー背景はneon-teal darkのpaper `#191E23` に、Popoverのelevation 8の白いオーバーレイ（不透明度0.119）を合成した値を使う。近似の色コードに丸めない。
- ファイル名は各ボタン内で中央揃え。最小幅64pt・左右余白10pt・13pt文字・高さ31ptを維持し、角丸はWebと同じ6ptに訂正した。
- メニューの余白と行間は8pt、最大幅220pt。ファイル名ごとの幅を使い、TS一件ではボタン64pt・メニュー80ptになる。PLAY直下の左端に揃える。

## 検証結果

Swiftの型検査と既存テスト、実機用・シミュレーター用Releaseビルドが成功した。
シミュレーターでは緑のRGB値、ボタンの中央配置、最小幅、TS一件の幅、PLAY直下の位置、角丸と繰り返し開閉を確認した。
生成されたPLAYメニュー画像でも中央揃えと配置を目視確認した。
既存の一覧・詳細・メニュー・ドロップログ・ナビゲーション・保存・再生・コメント合成の確認も成功した。
iPadシミュレーターは省略した。実機の画面表示・操作感の確認は別途必要。

IPA: build `46`、最低OS `18.0`、`io.github.nyanz00.NeoEPGStation`、LiveContainer用ad-hoc署名。
SHA-256: `ba02ec2cc4fb869f569fab9bc2f2dcbfa6a7a218157d6178fad3f6aa0fa8f37f`。
Artifact IDは `11358937136`。成果物のソース・ビルド番号・チェックサム・プライバシー情報の同梱と、依存ロックに変更がないことを確認した。
