# AV1の再生前デコーダー選択

アプリは `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` の結果を保持する。
非対応ならVLCのAV1 VideoToolbox初期化を省略し、dav1dを選ぶ。
対応時は追加したAV1 VideoToolbox経路を使い、ハードウェア必須で作成した
セッションの実利用プロパティも確認する。初期化・構成が受け付けられなければ、
入力を開き直さず通常のVLCモジュール選択でソフトウェアへ進む。
キャッシュ内のシークで対応判定やモジュール選択を繰り返さない。

固定版VLCのMKVとMP4のdemuxは、AV1の構成情報が4バイト以下の場合に
`b_packetized = false` とし、既存のAV1 packetizerで完全なextradataを補う。
追加decoderは、この経路が生成するav1C・sequence headerも利用できる。
AV1 Main profileの4:2:0・8/10bitを対象とし、対応外の構成はdav1dへ渡す。

元の配布済みフレームワークではVideoToolbox decoderの入口にAV1分岐がなく、
設定の優先順位を変えるだけではハードウェアへ渡せなかった。
同じVLCKit/VLCの固定ソースにAV1の入口・構成情報・色形式・フレーム情報を追加する。
demux、音声同期、精密シーク、出力・PiPは既存経路を維持する。
ソース・パッチ・配布条件は `vendor/vlckit/README.md` を参照する。

診断ログはOSの対応判定、native側の選択判断、実際のモジュールを分ける。
`decoderDecisions` の `hardware=1` は、作成したVTセッションの実利用確認を表す。
VideoToolboxという名前だけでハードウェア利用済みとは判定しない。
決定情報はイベントリングとは別に保持し、長時間視聴でも失わない。

対象試験は `av1-decoder`。実データのAV1 8/10bit・MKV/MP4について、途中開始、
24秒間隔のキーフレームの間への連続シーク、キャッシュ再利用、一時停止中の復旧を確認する。
非対応シミュレーターでは、VTセッションを作らずdav1dで再生できることを検証する。
この結果を、対応実機でのAV1ハードウェア再生・シーク速度の証明には使わない。

初回のソースビルドでは、GNU配布先のTLS／接続、macOSの古いmakeのjobserver、
外部pkg-configのマクロ検索が障害となった。HTTPSミラーと検証済み取得経路、
GNU make 4.4のFIFO、ACLOCAL_PATHの明示で扱う。
途中キャッシュに残る追加パッチの二重適用も再現試験を追加して修正した。
取得済み・コンパイル済みの内容と検証済みフレームワークを保存し、以後の繰り返しを減らす。
