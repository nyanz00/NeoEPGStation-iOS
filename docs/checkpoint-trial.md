# AV1 状態復元診断

設定 → アプリ設定 → 再生エンジンで「診断用：AV1状態復元」を選び、
エンコード済み AV1 の PLAY を開き、「診断を開始」を押す。
以前と同じ長い GOP の動画を使う。対象は 1920×1080 以下。
通常の視聴経路、TS、STREAMING、コメント、PiP、視聴履歴は変更しない。
以前の「AV1復号比較」も別項目として残す。

## 測定条件（schema 5）

先頭の実キーフレームから次のキーフレームの約1秒後までの圧縮パケットを取得する。
準備上限は96MiB・3,000パケット・65メディア秒・90秒。一時MP4はcodec copyで作り、
終了時に削除する。通信・デマルチプレクス・MP4作成は復号タイマーに含めない。

CPUによる現在方式・LZ4・Zstandard level 1と、rcomp-metalのGPU LZ4圧縮を比較する。
rcomp-metal 0.4.0の公開crateをSHA-256で照合し、Metalカーネルは変更せず収録する。
macOS専用Rustラッパーと同梱macOS用metallibは使わず、iOS Objective-Cブリッジから
同じMetalソースを実行時コンパイルする。ライセンスは上流のApache-2.0選択肢を採用。
入力の差分・バイト整形、保存コンテナー組み立て、復元・展開はCPUで行う。
現在方式は10bit画素を16bit格納から10bit格納へ無損失で詰める方式（8bitは詰めない）。
LZ4/Zstandardは水平方向の差分・zigzag変換、10bitではさらに行ごとの上下位バイト分離を行う。
有効画素とアロケーション余白をすべて保存し、元画像への参照を圧縮完了時に解放する。

復号は6ワーカー・フレーム並列度3、途中フレームスキップなし。合計14条件。

| 種類 | 保存方式 | 条件数 |
| --- | --- | --- |
| 単独の保存・復元 | 現在方式・LZ4・Zstandard・CPU LZ4 64KiB・rcomp-metal | 各2：目的位置まで約2秒・0.25秒 |
| 等速復号と定期保存 | 保存なし・Zstandard・CPU LZ4 64KiB・rcomp-metal | 各1：2秒ごと、保持上限64MiB |

### rcomp-metalの比較条件

method=9はliblz4による独立64KiBブロック、method=10はrcomp-metalの同じ64KiB区切り。
現在のmethod=4は画像全体でLZ4圧縮するため、そのままGPU差の比較対象にはしない。
method=9と10も検索実装は異なり、圧縮バイト列・保持量の一致までは要求しない。
両方とも同じCPU前処理と`RCM1`診断用コンテナーを使用し、CPUのLZ4で復元する。
各画像の末尾をゼロで64KiBへ揃え、1地点の参照画像全体を1回のGPU dispatchで処理する。
復元では末尾を一時領域へ展開し、有効な元allocationサイズだけを書き戻す。
元の余白も元どおり復元する。圧縮されないブロックは可逆な生バイトとして保存する。

`gpuSetupMs`は端末・ライブラリー・パイプライン・キューの準備で、保存タイマーの外。
GPUバッファーは条件の間再利用し、条件終了時に解放する。
`gpuCommandMs`はMetalのGPU開始/終了時刻の差（取得できない場合0）、
`gpuWaitMs`はcommitから完了待ちまでの実時間。保存時間は前処理・入力コピー・
GPU待機・出力組み立ても含む。`gpuStagingBytes`は再利用するMetalバッファーの合計で、
64MiBの保持枠とは別。入力48MiB・Metal作業バッファー合計128MiBに上限を設ける。
GPU実行失敗をCPU成功へ置き換えない。1009はMetalデバイスなし、1010は不正なブロック、
1011はMetalコンパイル/キュー/実行エラー。`gpuCompressionVerified`でGPU条件の成功を区別する。

### 単独の保存・復元（kind=storage）

目的位置は最初のGOPの90%。短いGOPでは距離を縮め、実際のパケット境界を記録する。
保存前に出力をすべて受け取り、ワーカーの待機を確認する。
各条件で保存5回・復元5回。`repeatedSaveMs` は保持参照の取得から圧縮完了までの実時間、
`saveThreadCpuMs` は同じ保存を行ったスレッドのuser+system CPU時間。
`restoredMs` は復元開始から目的画像取得まで、`restoreOnlyMs` は復元のみ、
`drainBeforeSaveMs` は保存前の残り出力待ち。CPU時間は全復号ワーカーの合計ではない。

通常復号と全Y/U/V画素・時刻・出力数を比較する。全後続区間を2回照合し、
真の次キーフレームを越えてから戻す5回も目的画像を全画素比較する。比較はタイマーの外。
復元後のアロケーション全体（余白含む）も2回一致を確認する。
空・未処理出力ありの保存と、別所有者への復元を拒否する。

### 等速復号と定期保存（kind=paced）

先頭0.5秒を準備後、最初のGOPの90%または24秒までを、入力の表示時刻に合わせて復号する。
2秒ごとに出力をドレインし、短い排他区間で状態と画像参照を確保する。
圧縮はutility優先度の専用1ワーカーで行い、その間も6ワーカーで復号を続ける。
保存が終わっていない場合は次の保存を飛ばし、未処理ジョブを積み上げない。
終了・中断時は処理中の保存を待って、保持状態・画像・復号器を解放する。

`captureMs` は状態と参照の確保、`encodeWallMs` と `encodeThreadCpuMs` はその後の圧縮。
保存前ドレインはこれらに含まないが、出力遅れの計測には影響する。
`frameReadyLateness*Ms` は入力PTSから決めた期限に対する画像取得の遅れ。
`frameDeadlineMisses` は遅れがそのフレーム間隔を超えた回数で、画面のコマ落ち数ではない。
音声・画面描画・通常プレイヤーの操作は含まず、実際の再生品質を断定する試験ではない。
`pacedWallSeconds` は準備後の等速区間で、最後の圧縮完了待ちと後続照合は含まない。

圧縮完了した状態の合計を64MiBまで保持し、超える場合は古い地点から解放する。
この上限は入力・復号器・圧縮中の元画像・作業領域を含む総RAMの上限ではない。
`completedSaves`、`skippedBusySaves`、`evictedCheckpoints`、`retainedCount` と保持量を記録する。
等速区間終了後に3地点（区間の10%・50%・99%）へ戻し、残っている直前の状態を利用する。
利用できなければ実キーフレームから復号する。`budgetSeekMs` は復元開始から画像取得まで。
3地点は別の基準復号の全画素と一致を確認し、`usedCheckpoint` と選択した地点も記録する。
等速区間の全出力画像を逐一画素比較する試験ではない。

## 結果と制限

「診断結果を共有」で `checkpoint-benchmark.json` を共有する。
14条件すべて成功なら `status=complete`、不一致・未対応・上限到達は `partial`。
準備失敗は `failed`。各条件終了時にも結果を保存し、中断時は完了した行を残す。
ソースURL・タイトル・画像・認証情報は結果に入れない。

各行の `status=0` が成功。1001入力、1002境界、1003不一致、1004目的画像/後続キーなし、
1005保持上限、1006中断、1007条件ごとの180秒上限、1008復号失敗（`decoderError`）。
単独測定の `failureStage` は1入力、2準備復号、3保存、4全区間照合、5復元測定、6拒否検査。
成功時は0。閉じる、バックグラウンド移動、メモリー警告で中断する。

`retainedBytes` は保持データ量で、復号器の作業領域やプロセス全体とは異なる。
`sampledFootprintBytes` は単独測定の5回復元時、`processFootprintAfterBytes` は各条件の後、
`processFootprintAfterInputReleaseBytes` は全条件と圧縮入力解放後のプロセスphys_footprint。
アロケーターのキャッシュを含み、増加だけでリークとは判断しない。標本最大は厳密なピーク
ではない。開始/終了時のthermalStateも記録するが、消費電力は測定していない。

同一プロセス・同一復号器・既定アロケーター限定。HDRメタデータ等の境界は未対応。
以前のschema 3の16条件とschema 4の10条件は履歴として残す。schema 5はGPU比較の14条件。
複数地点を通常プレイヤーへ保持する機能は今回追加しない。

## ビルドと分離

`scripts/build-checkpoint.py` はdav1d 1.5.4の
`54706fc6bc0cdecab7e9593974a4039cc038fca7` を固定する。
`vendor/checkpoint/` に並列・パック・可逆圧縮方式を収録し、アプリとの境界は
`NeoCheckpointLab.h` の単純なC型だけとする。PC実験は `experiments/dav1d-checkpoint-storage/`。
LZ4 1.10.0・Zstandard 1.5.7は固定ハッシュで取得し、単一スレッド版を静的ビルドする。
圧縮ライブラリの関数も専用接頭辞へ変更し、既存のエンジンから分離する。
全public dav1d APIを `neo_lab_` 接頭辞へ変更し、Apple側ではシンボルを非公開にする。
ライセンス・固定ソース情報・追加ソースをIPAへ収録する。

Actionsの `checkpoint-trial` はdevice/simulatorビルドと診断画面の8bit/10bit各14条件に絞る。
シミュレーター成功はiPhoneの速度・熱・電力を保証しない。実機結果で次の採用判断を行う。

## ビルド269の確認

ソース `050477c45f17c5d9a56888abb02d765c1c1825de`、
[Actions 40172537801](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40172537801)
で device / simulator のビルドと診断画面の試験に成功。
8bit / 10bit の長 GOP 素材で各 2 条件が `complete`。
各条件の全画素照合を伴う 5 回復元・5 回の一時保存解放・入力/所有者の拒否検査、
phys_footprint と共有用 JSON の出力を確認した。
通常経路の FFmpeg インポート先も Aether フレームワークへ結び付いている。

IPA: `NeoEPGStation-build269.ipa`、SHA-256:
`d2b041dd6d661fac22081dd6612760c71991d8527729a0bf3fd748d3a89111fa`。
GitHub が記録するファイルの digest、ZIP CRC、埋め込みビルド番号、
収録した checkpoint のソース/ライセンスと Aether のパッチレシピを照合済み。
iPhone での速度・熱・電力の測定は未実施であり、シミュレーター試験と区別する。

## ビルド270の確認

ソース `f53126b3172d281204056ae4bc3856a640473c1d`、
[Actions 40190633901](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40190633901)
でdevice/simulatorのビルドに成功。診断画面を経由した8bit/10bit各16条件がcomplete。
1/2/4/6スレッド、元の参照保持/無損失パック、約6/2/0.25秒の残り復号を確認した。
各条件で全後続区間2回・復元目的画像5回の全画素一致、パックのアロケーション全体一致、
拒否検査、phys_footprint、入力解放後の観測値、schema 3の共有JSONが揃うことを確認。
手元でも同じアプリ用C APIの8bit/10bit各16条件と、1080p長GOP入力の6スレッドパックが成功。

IPA: `NeoEPGStation-build270.ipa`、SHA-256:
`ca7d5d9f121aeb0a0e867d58fb51b74fc839d5d73005cee5bfcd76f75cadbd81`。
GitHub artifact digest、ZIP CRC、埋め込みビルド番号、checkpointソース/ライセンス、
Aetherパッチレシピを照合済み。通常経路のFFmpeg/dav1dインポート146個が既存の
Aetherフレームワークへ結び付くことも確認した。
実機の速度・熱・電力や通常プレイヤーへの採用判断は、このビルドの実機結果で行う。

## CPU可逆圧縮版のホスト確認

配布用と同じC APIを `tests/checkpoint-lossless.c` で呼び出した。
8/10bit合成入力で単独測定12条件、1080p・10bit長GOPの実録画で単独6条件と
等速4条件を確認。全条件が成功し、保存5回・復元5回・後続区間2回・全画素と余白の
一致、即時中断時の解放経路を確認した。既存APIの6ワーカー・パック方式も1条件成功。

実録画の等速区間は約20秒、保存10回。同じ64MiB枠に現在方式3地点、LZ4は8地点、
Zstandardは10地点が残った。3地点の予算内シークも全画素一致。
このPCではフレーム間隔を超える出力遅れは観測しなかったが、iPhone性能の結論には使わない。

## ビルド272の確認

ソース `b47df4aa2d700753c693b4cf4e5724c932707baa`、
[Actions 40221461845](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40221461845)
でdevice/simulatorビルドと診断画面の試験に成功。8bit/10bit各10条件、合計20条件が
schema 4・`complete`。CPU保存時間、非同期定期圧縮、保持枠内シーク、全画素一致とJSON出力を確認。
通常経路のFFmpegインポート146件もAetherフレームワークへの結び付きを確認した。

初回ビルド271はZstandardの補助ヘッダー欠落で停止。固定ソースから `zstd_errors.h` を
同梱するよう修正し、ホストの依存参照も同梱ヘッダーへ向くことを確認してから再実行した。

IPA: `NeoEPGStation-build272.ipa`、SHA-256:
`abf30e18a5111ead400fccd89bc28351c4435989a7b5313b99e03243bd943b29`。
配布物のCRC・artifact digest・ソースハッシュ・ライセンス同梱を照合済み。
iPhone上の速度・同時復号負荷・発熱の結論は実機結果待ち。

## rcomp-metal追加時の事前検証

公開crate `rcomp-metal-0.4.0.crate` のSHA-256は
`90fbc70a09c15c871d0cd0fc5f1f74ccc6461b7d2e31bc37b1f4ccb3dd254609`。
元ソース・ベンチマーク条件・ライセンス宣言・カーネルハッシュは `vendor/rcomp-metal/`。
上流のM3 Max・数百MiB入力での速度は、iPhoneの参照画像にそのまま当てはめない。

`tests/rcomp-shader-host.cpp` はカーネルの整数処理をC++として実行する正当性検査。
48条件のゼロ・繰り返し・疑似乱数・段階値、64KiB前後と末尾を試し、配布用LZ4復元との
バイト一致、出力番兵、不正な短縮コンテナーの拒否を確認する。GPU性能測定ではない。
`python scripts/rcomp-host-kernel.py` で`.local/rcomp-host-kernel.inc`を生成して実行する。
CPU比較方式も8/10bit合成素材と1080p長GOP素材で、全画素・allocation・後続区間を確認する。

## ビルド273の確認

ソース `50c1b669fdda272dd1f2c68d43535f968a1653b1`、
[Actions 40277090848](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40277090848)
でdevice/simulatorビルドに成功。8bit/10bit各14条件、合計28条件がschema 5・`complete`。
各入力でGPU単独測定2条件・GPU定期保存1条件が実際にdispatchされ、CPU代替なしで
復元・画素照合まで成功。`gpuCompressionVerified=true`。これはシミュレーターの
GPU実行・正当性確認であり、iPhoneの速度や消費電力の結論ではない。

事前のCPU比較方式7条件（8/10bit合成素材、1080p長GOPの単独・定期保存）も成功。
Metalカーネル整数処理をホスト実行した48条件は、LZ4の全バイト復元・出力番兵・
短縮コンテナー拒否が成功。こちらはGPU性能試験ではない。

IPA: `NeoEPGStation-build273.ipa`、SHA-256:
`040bfbd1eb688cbef8ce9f165cbdf35596ad00b180e0f146300c73f28b34b4d2`。
artifact digest・ZIP CRC・ビルド番号・同梱ソース/ライセンス・元Metalコードのハッシュを照合。
通常経路のFFmpegインポート146件も従来のAetherフレームワークへの結び付きを確認した。
実機では以前と同じ診断項目とAV1入力を使い、`checkpoint-benchmark.json`を比較する。
