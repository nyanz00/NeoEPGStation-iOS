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

## 検証結果（Build 229）

- ソース `28dfed82e06f9ffe7a8eceb5610df4655e2796b6`、
  [Actions 39808827922](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/39808827922)。
  実機・シミュレーターのVLCKit、アプリの両ビルド、Foundation試験・型検査が成功。
- AV1 Main 4:2:0の8/10bit、MKV/MP4の4条件で計192項目が成功。
  途中開始、キーフレーム間への正確な連続シーク、キャッシュ再利用、停止中の音声ゲートを確認。
  OSの対応判定はfalseで、各条件でdav1d/softwareを選択した。
  通常シーク1～7でネイティブ選択をやり直さず、明示的な入力再作成時だけ再選択した。
- 同じアプリを再利用した
  [Actions 39812607221](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/39812607221)
  で、既存H.264のMKV/MP4の計96項目も成功。
  VideoToolbox経路の再生・途中開始・精密シーク・一時停止中の復旧を確認した。
- 配布IPAのSHA-256:
  `582a8790fbf1d3e1d1c795ccfc5c49c8d77bef257cb7ebebf2978939b979f649`。
  IPA内のVLCKitのSHA-256は実機用ビルド来歴と一致し、AV1選択マーカー、変更ソースとライセンスも同梱済み。
- AV1対応実機でのVTセッション作成・実ハードウェア利用・シーク速度は未確認。
  実機の診断ログで `vlc.av1Preflight.hardwareSupported`、`decoderDecisions`、
  `decoders` を照合する。OS対応trueでも、構成やセッションが拒否された場合は
  `fallback` とdav1d/softwareが残るので、対応判定だけで利用済みと判断しない。
