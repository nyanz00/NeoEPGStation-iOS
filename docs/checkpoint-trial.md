# AV1 状態復元診断

設定 → アプリ設定 → 再生エンジンで「診断用：AV1状態復元」を選び、
エンコード済み AV1 の PLAY を開き、「診断を開始」を押す。
以前と同じ長い GOP の動画を使う。対象は 1920×1080 以下。
通常の視聴経路、TS、STREAMING、コメント、PiP、視聴履歴は変更しない。
以前の「AV1復号比較」も別項目として残す。

## 現在の測定条件（schema 7）

現在は公式Zstandard 1.5.7のBSDライセンスを選択し、その公開形式とFSE/Huffman演算を
Metalへ適用した診断用バックエンドを比較する。gpu-zstd-compのコード・シェーダーは
移植・同梱していない。通常の再生エンジンやサーバー側の圧縮処理は変えない。

method=15がMetal Zstandard。GPUがハッシュ探索・貪欲解析・リテラルのHuffman符号化・
シーケンスのFSE符号化・標準Zstandardフレームの組み立てまで行う。
CPUは差分/zigzag/バイト分離の前処理、GPU入出力の転送、保存状態の組み立て、展開を担当する。
CPUへ符号化を戻すフォールバックはない。method=16は同じ符号化演算のCPU参照であり、
GPU失敗時に自動選択するものではない。公式CPU Zstandard level 1（method=7）と
以前のlsCOMP GPU差分方式（method=14）も比較する。

| 種類 | 保存方式 | 条件数 |
| --- | --- | --- |
| 単独の保存・復元 | 公式CPU Zstandard・lsCOMP GPU差分・新符号化器CPU参照・Metal Zstandard | 各2：目的位置まで約2秒・0.25秒 |
| 等速復号と定期保存 | 保存なし・公式CPU Zstandard・lsCOMP GPU差分・Metal Zstandard | 各1：2秒ごと、保持上限64MiB |

合計12条件。選択項目と共有ファイル名は従来どおり。
新方式は64KiBごとの独立した標準Zstandardフレームを連結して保存する。
前のブロックの辞書は参照せず、GPUの1バッチは最大16ブロック。
共有GPUバッファーは約18.02MiB、上限32MiB。CPU側の入力・保存データ・展開領域、
GPUドライバーやシェーダーの内部作業領域を含むプロセス総量とは区別する。
GPU側で圧縮が有利にならないブロックは、標準形式のrawブロックとして保存する。

クリア・ハッシュ挿入・候補探索・符号化の4dispatchをバッチごとに実行する。
ハッシュ挿入のatomic順序で候補と圧縮サイズに差が出得るため、CPU参照との
圧縮バイト列一致は要求せず、標準展開器で元allocation全体との一致を確認する。
MetalのGPU時間・commit待ち・dispatch数・バッファー量を記録し、初回準備は別計測。
GPUエラーは1009/1010/1011として残す。音声・画面描画は診断に含まない。

### 事前の正当性検証

`tests/metal-zstd-host.cpp` は配布用GPU符号化演算をホスト実行する検査。
7種類の合成パターン・11サイズと、1080p 10bitの実際の参照画像5枚を64KiB区切りで
処理した計492条件が、標準Zstandardによる展開・全バイト一致・出力番兵で成功した。
これはGPU性能の検証ではない。

CPU参照を配布用状態復元APIに接続した6条件（8/10bit合成素材、1080p長GOP素材、
各2距離）も成功。保存・復元各5回、後続区間2回とallocation余白まで一致した。
`scripts/metal-zstd-smoke.py` はApple環境で配布用Metalブリッジを先に実行し、
24条件・72画像を標準Zstandardで展開して検査する。その後にアプリをビルドし、
シミュレーターの診断画面で8/10bit各12条件を確認する。
iPhoneでの速度・消費メモリー・熱の結論は実機結果で判断する。

## 以前の測定条件（schema 6）

先頭の実キーフレームから次のキーフレームの約1秒後までの圧縮パケットを取得する。
準備上限は96MiB・3,000パケット・65メディア秒・90秒。一時MP4はcodec copyで作り、
終了時に削除する。通信・デマルチプレクス・MP4作成は復号タイマーに含めない。

現在の診断はCPU Zstandard level 1と、lsCOMPの可逆処理をCPU・Metalへ移植した方式を比較する。
lsCOMP上流を固定revisionとSHA-256で照合し、元ソース・ライセンスを `vendor/lscomp/` に保持する。
量子化・poolingは使用しない。8×8タイルの最大値から必要ビット数を求め、ビット面を詰める。
8bitは1バイト、10bitは2バイトの整数として扱い、画像のallocation余白も含めて完全保存する。
全allocationを輝度stride幅のラスタとして扱い、端の不足部分はゼロで埋める。
復元時には元のallocationサイズのみ書き戻す。

「補正なし」と「水平方向の差分・zigzagあり」の両方を比較する。
lsCOMPでは上下位バイトの分離は行わない。Zstandardは従来の差分・バイト分離を使用する。
CPU比較とGPU比較は同じ独自コンテナー `LSC1` を生成する。
同一入力の単独試験で出力バイト列一致を、診断画面で復元後の全画素一致を確認する。
上流CUDAカーネルのそのままの移植や、元のCUDA出力との互換形式ではない。
入力コピー・前処理・コンテナー組み立て・復元はCPU。GPUで行うのは圧縮部分。

復号は6ワーカー・フレーム並列度3、途中フレームスキップなし。合計14条件。

| 種類 | 保存方式 | 条件数 |
| --- | --- | --- |
| 単独の保存・復元 | Zstandard・CPU lsCOMP補正なし・GPU lsCOMP補正なし・CPU lsCOMP差分あり・GPU lsCOMP差分あり | 各2：目的位置まで約2秒・0.25秒 |
| 等速復号と定期保存 | 保存なし・Zstandard・GPU lsCOMP補正なし・GPU lsCOMP差分あり | 各1：2秒ごと、保持上限64MiB |

method=11/12がCPU/Metal補正なし、13/14がCPU/Metal差分あり。
Metalはタイル解析、256タイル単位のprefix scan、グループ先頭位置の計算、ビット面出力の
4回の順序付きdispatchで処理する。CUDA側のグループ間spin待ちは使わない。
入力48MiB・Metal作業領域128MiBの上限と明示的な失敗は従来と同じ。
従来のrcomp-metal方式はコードと過去の検証記録を残し、今回の14条件には含めない。

### 以前のrcomp-metalの比較条件（schema 5）

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
以前のschema 3の16条件とschema 4の10条件は履歴として残す。schema 5はrcomp-metal比較14条件、schema 6はlsCOMP比較14条件。
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

## lsCOMP追加時の事前検証

上流revision `d920dd9dc8ddbd2684c777d1e2ba27397212e59c`、公開アーカイブSHA-256:
`3d352066ffd612531cff4d19b88848c1df96ab6c81256df635fd915ed17de83c`。
ライセンスは上流のBSD-3-Clause形式。元コード・ライセンスを同梱し、改造箇所を明示する。

`tests/lscomp-host.cpp` は配布用Metalソースの解析・出力の整数処理をホストで実行する。
256条件で8/16bit格納、タイル端、複数scanグループ、ゼロ・最大値・乱数・段階値を比較し、
CPU参照との出力バイト一致・全allocation復元・出力番兵・短縮入力拒否を確認した。
これはGPU上のscanや速度を測る試験ではない。

配布用のprivateライブラリーを使ったネイティブ試験13条件も成功。
8/10bit合成素材と1080p・10bit長GOP素材の単独12条件では、保存・復元各5回、
全後続区間2回、allocation余白まで一致。実録画の等速保存1条件では保存10回、
保持枠内3地点の復元が一致した。PCの結果はiPhone性能の結論には使わない。

`scripts/lscomp-metal-smoke.py` はMac runnerで配布用Objective-Cブリッジと全4GPUパスを
実行し、24条件・72画像についてCPU出力とのバイト一致を確認する。
その後、シミュレーターの診断画面で8/10bit各14条件を確認する。
iPhoneでの時間・負荷・保持数は、実機の同じAV1入力によるJSON結果で比較する。

ビルド274ではGPU単独24条件と診断8bit全14条件が成功した後、試験コードの
「別々の復号器でもCPU/GPUの保存サイズが一致する」という誤ったassertで停止した。
同一入力のバイト一致はMetal単独試験が担い、診断画面では同じ映像位置・寸法と
各状態の全画素/余白復元を確認する。別々の内部allocationには未使用余白等の差があり、
保存サイズの一致を要求しない。アプリソースを変えず、保存済みバイナリーで再試験する。

## ビルド274・再検証275の確認

アプリのソース `04031385f4663a36f9d514281a2a2a2454e70bbd`、
[ビルド274](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40286940376)
でdevice/simulatorビルドに成功。Mac上の配布用Metalブリッジは24条件・72画像が
CPU参照とバイト一致し、GPU全4パスの実行と完全復元を確認した。

試験条件だけを直した `1929e433298a815d527b4462b191c2d4d878f2b7` の
[再検証275](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40289005363)
は、アプリ・privateネイティブコード・ビルドレシピ・素材の差分なしを確認し、
ビルド274の同じシミュレーターアプリを再利用した。再ビルドは行っていない。
8bit/10bit各14条件、合計28条件がschema 6・`complete`。
両GPU方式の単独・定期保存がCPU代替なしで成功し、`gpuCompressionVerified=true`。

IPA: `NeoEPGStation-build274.ipa`、SHA-256:
`6acbd991716785bfed22d8185fc6fa2f3334b59f93145b04266846cfd47b7c6d`。
artifact digest・ZIP CRC・ビルド番号・同梱ソース/ライセンス・上流ハッシュを照合。
通常経路のFFmpegインポート146件も従来のAetherフレームワークへ結び付いている。
iPhone上の保存時間・CPU負荷・GPU作業量・保持数は実機での比較待ち。
