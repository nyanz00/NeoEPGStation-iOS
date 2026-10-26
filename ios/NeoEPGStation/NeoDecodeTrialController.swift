import UIKit
import AetherEngine

/// A disposable lab screen, reached only by the explicit AV1 diagnostic setting.
/// It never replaces an existing player or writes viewing history.
@MainActor
final class NeoDecodeTrialController: UIViewController {
  var onClose: (() -> Void)?
  private let source: URL
  private let checkpointMode: Bool
  private let trial = NeoDecodeTrial()
  private var work: Task<Void, Never>?
  private var player: NeoAetherPlayer?
  private var directory: URL?
  private var closed = false
  private var report: [String: Any] = ["schema": 1, "status": "not-started"]
  private let stack = UIStackView(), surface = UIView()
  private let status = NeoStyle.label("長いGOPのAV1動画を選んでください。取得・準備時間は復号時間に含めません。", size: 15)
  private let start = UIButton(type: .system), share = UIButton(type: .system)
  init(source: URL, checkpoint: Bool = false) { self.source = source; checkpointMode = checkpoint; super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = NeoStyle.background
    stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    let close = UIButton(type: .system); close.setTitle("閉じる", for: .normal)
    close.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    let title = NeoStyle.label(checkpointMode ? "AV1 状態復元診断" : "AV1 シーク診断", size: 21, bold: true)
    if checkpointMode { status.text = "1080p以下のAV1動画で、CPU Zstandard・lsCOMP GPU・Metal Zstandardで容量と保存負荷を比較します。等速復号と定期保存を重ねる試験も行います。" }
    status.numberOfLines = 0
    start.setTitle("診断を開始", for: .normal); start.accessibilityIdentifier = "decode-trial-start"
    start.addAction(UIAction { [weak self] _ in self?.run() }, for: .touchUpInside)
    share.setTitle("診断結果を共有", for: .normal); share.isEnabled = false
    share.addAction(UIAction { [weak self] _ in self?.export() }, for: .touchUpInside)
    for v in [close, title, status, start, share, surface] { stack.addArrangedSubview(v) }
    surface.heightAnchor.constraint(equalToConstant: 160).isActive = true
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)])
    NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); player?.view.frame = surface.bounds }
  func run() {
    guard work == nil, !closed else { return }
    start.isEnabled = false; UIApplication.shared.isIdleTimerDisabled = true
    work = Task { [weak self] in
      guard let self else { return }
      defer { UIApplication.shared.isIdleTimerDisabled = false; work = nil }
      do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("neo-decode-trial-"+UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        let clip = folder.appendingPathComponent("sample.mp4")
        report = ["schema": 1, "status": "preparing", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
          "os": UIDevice.current.systemVersion, "cpuCount": ProcessInfo.processInfo.activeProcessorCount,
          "timing": "fresh-decoder-feed-to-target-output; initialization-separate; luma-check-after-timer",
          "audio": false, "networkInDecodeTimer": false]
        if checkpointMode {
          report["schema"] = 9; report["mode"] = "metal-zstd-pipelined-checkpoint"
          report["metalZstdParseBytes"] = 4096; report["metalZstdWindowBytes"] = 65536
          report["gpuStageNames"] = ["match", "parse", "histogram", "huffman", "fse", "packing", "assembly", "preprocessing"]
          report["hostStageNames"] = ["inputPreparation", "rawUpload", "commandEncodingSubmission", "completionBlocking", "outputCopyAndResize"]
          report["gpuWaitMeaning"] = "CPU blocking only; overlaps GPU execution; not additional GPU cost"
          report["metalZstdInputSlots"] = 2
          report["expectedConditions"] = 15
          report["gpuCompressionRequested"] = true; report["renderingIncluded"] = false
          report["lscompRevision"] = "d920dd9dc8ddbd2684c777d1e2ba27397212e59c"
          report["lscompMetalAdaptation"] = true; report["quantization"] = false; report["pooling"] = false
          report["metalZstdCompressionStages"] = ["match finding", "parse", "Huffman/FSE", "frame assembly"]
          report["metalZstdCpuEntropyCoding"] = false
          report["restoreBackend"] = "CPU"; report["preprocessingBackend"] = "CPU-direct/GPU comparison"
          report["timing"] = "Official-Zstandard-based Metal full encoder; CPU reference; CPU-direct/GPU preprocessing and CPU restore; six decode workers; pixel checks outside timers"
          report["thermalStateStart"] = ProcessInfo.processInfo.thermalState.rawValue
        }
        status.text = "比較する映像データを準備中…"
        try await trial.prepare(url: source, clipURL: clip)
        try Task.checkCancellation()
        report["sample"] = trial.summary
        if checkpointMode {
          status.text = "状態復元・全画素照合・メモリーを計測中…\n閉じる、またはバックグラウンドへの移動で中断します。"
          let data = try await NeoCheckpointWorker.run(trial) { [weak self] data, completed, total, phase in
            guard let self else { return }
            if let rows = try? JSONSerialization.jsonObject(with: data) { report["checkpoint"] = rows }
            report["status"] = "running"; save()
            status.text = "\(phase)\n\(completed)/\(total)条件完了。閉じる、またはバックグラウンドへの移動で中断します。"
          }
          try Task.checkCancellation()
          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
          let rows = result["rows"] as? [[String: Any]] ?? []
          report["checkpoint"] = rows
          report["processFootprintAfterInputReleaseBytes"] = result["processFootprintAfterInputReleaseBytes"]
          let passed = rows.filter { ($0["status"] as? Int) == 0 }.count
          report["status"] = passed == 15 ? "complete" : "partial"
          let gpuRows = rows.filter { [14, 15, 17].contains(($0["method"] as? Int) ?? -1) }
          report["gpuCompressionVerified"] = gpuRows.count == 9 && gpuRows.allSatisfy { ($0["status"] as? Int) == 0 }
          report["thermalStateEnd"] = ProcessInfo.processInfo.thermalState.rawValue
          status.text = "状態復元診断が完了しました。\n全画素一致・復元試験：\(passed)/15条件\n診断結果を共有してください。等速復号の出力遅れも記録しました。画面表示・音声は測定に含みません。"
        } else {
          let origin = trial.summary["originSeconds"] ?? 0
          let points = trial.targets.map { $0-origin }
          status.text = "AetherEngineの映像再開を計測中…"
          let child = NeoAetherPlayer(url: clip, title: "AV1 シーク診断", initialPosition: 0)
          player = child; addChild(child); surface.addSubview(child.view)
          child.view.frame = surface.bounds; child.view.isUserInteractionEnabled = false; child.didMove(toParent: self)
          do { report["aether"] = try await child.runDecodeTrialTargets(points) }
          catch { report["aetherErrorCode"] = (error as NSError).code }
          removePlayer()
          try Task.checkCancellation()
          status.text = "VideoToolbox・dav1dを比較中…"
          let rows = try await trial.runDirect()
          try Task.checkCancellation()
          let data = try JSONEncoder().encode(rows)
          report["direct"] = try JSONSerialization.jsonObject(with: data)
          let sw = rows.filter { $0.backend == "dav1d" && $0.status == "ok" }.compactMap(\.decodeMs)
          let hw = rows.filter { $0.backend == "videotoolbox" && $0.status == "ok" }.compactMap(\.decodeMs)
          let baseline = report["aether"] as? [[String: Double]] ?? []
          report["status"] = sw.count == 6 && hw.count == 6 && baseline.count == 6 && baseline.allSatisfy { $0["displayTimestampVerified"] == 1 } ? "complete" : "partial"
          status.text = "診断が完了しました。\ndav1d：\(sw.count)/6回\nVideoToolbox：\(hw.count)/6回\n結果を共有してください。未対応・不一致も結果に記録しています。"
        }
        save(); share.isEnabled = true
      } catch {
        removePlayer()
        report["status"] = Task.isCancelled || trial.checkpointCancelled ? "cancelled" : "failed"
        report["errorCode"] = (error as NSError).code
        if checkpointMode {
          trial.releaseCheckpointPackets()
          report["processFootprintAfterInputReleaseBytes"] = neo_checkpoint_lab_footprint()
        }
        // Never export raw URL-bearing engine error descriptions.
        status.text = Task.isCancelled || trial.checkpointCancelled ? "診断を中断しました。" : "診断を完了できませんでした。対象動画か確認し、診断結果を共有してください。"
        save(); share.isEnabled = true
      }
      if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
    }
  }
  private var resultURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(checkpointMode ? "checkpoint-benchmark.json" : "decode-benchmark.json")
  }
  private func save() {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: resultURL, options: .atomic)
  }
  private func export() {
    save()
    let activity = UIActivityViewController(activityItems: [resultURL], applicationActivities: nil)
    activity.popoverPresentationController?.sourceView = share
    activity.popoverPresentationController?.sourceRect = share.bounds
    present(activity, animated: true)
  }
  private func removePlayer() {
    guard let player else { return }
    player.stopDecodeTrial(); player.willMove(toParent: nil); player.view.removeFromSuperview(); player.removeFromParent()
    self.player = nil
  }
  @objc private func background() { trial.cancel(); work?.cancel(); removePlayer() }
  override func didReceiveMemoryWarning() { super.didReceiveMemoryWarning(); if checkpointMode { background() } }
  private func close() {
    closed = true; background(); UIApplication.shared.isIdleTimerDisabled = false
    let completion = onClose; onClose = nil; dismiss(animated: true) { completion?() }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed { closed = true; background() }
  }
  deinit { NotificationCenter.default.removeObserver(self) }
}

/// A borrowed packet view is consumed synchronously inside a worker task. The
/// dedicated static library owns every decoder/checkpoint and releases them on
/// success, mismatch, cancellation or timeout. It never touches a player engine.
private enum NeoCheckpointWorker {
  static func run(_ trial: NeoDecodeTrial,
    progress: @escaping @MainActor @Sendable (Data, Int, Int, String) -> Void) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      defer { trial.releaseCheckpointPackets() }
      var rows: [[String: Any]] = []
      let profiles: [(Int32, Double)] = [(7, 2), (14, 2), (16, 2), (15, 2), (17, 2), (17, 0.25), (15, 0.25), (16, 0.25), (14, 0.25), (7, 0.25)]
      func name(_ method: Int32) -> String {
        switch method { case -1: return "保存なし"; case 0: return "現在方式"; case 4: return "LZ4"; case 9: return "CPU LZ4・64KiB"; case 10: return "rcomp-metal・GPU LZ4"; case 11: return "lsCOMP CPU・補正なし"; case 12: return "lsCOMP GPU・補正なし"; case 13: return "lsCOMP CPU・差分あり"; case 14: return "lsCOMP GPU・差分あり"; case 15: return "Metal Zstandard・CPU直接前処理"; case 16: return "Metal Zstandard・CPU参照"; case 17: return "Metal Zstandard・GPU前処理"; default: return "Zstandard" }
      }
      for (method, distance) in profiles {
        if Task.isCancelled || trial.checkpointCancelled { throw CancellationError() }
        let snapshot = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        await progress(snapshot, rows.count, 15, "単独の保存・復元測定：" + name(method))
        let rowData = try trial.withCheckpointPackets { packets, gop in
          let input = packets.map { NeoCheckpointPacket(data: $0.data, size: $0.count, seconds: $0.seconds) }
          var output = NeoStorageResult()
          let code = input.withUnsafeBufferPointer { buffer in
            neo_checkpoint_storage_run(buffer.baseAddress, buffer.count, gop, distance, method, &output, { cookie in
              guard let cookie else { return 1 }
              return Unmanaged<NeoDecodeTrial>.fromOpaque(cookie).takeUnretainedValue().checkpointCancelled ? 1 : 0
            }, Unmanaged.passUnretained(trial).toOpaque())
          }
          if code == 1006 { throw CancellationError() }
          var result = output.checkpoint
          let saves = withUnsafeBytes(of: result.repeated_save_ms) { Array($0.bindMemory(to: Double.self)) }
          let cpu = withUnsafeBytes(of: output.save_cpu_ms) { Array($0.bindMemory(to: Double.self)) }
          let gpu = withUnsafeBytes(of: output.gpu_ms) { Array($0.bindMemory(to: Double.self)) }
          let gpuWait = withUnsafeBytes(of: output.gpu_wait_ms) { Array($0.bindMemory(to: Double.self)) }
          let restored = withUnsafeBytes(of: result.restored_ms) { Array($0.bindMemory(to: Double.self)) }
          let restoreOnly = withUnsafeBytes(of: result.restore_only_ms) { Array($0.bindMemory(to: Double.self)) }
          let footprints = withUnsafeBytes(of: result.sampled_footprint_bytes) { Array($0.bindMemory(to: UInt64.self)) }
          let row: [String: Any] = [
            "kind": "storage", "method": Int(method), "status": Int(code),
            "methodName": name(method), "preprocessing": method == 17 ? "GPU horizontal delta and byte shuffle" : method == 15 ? "CPU direct SIMD horizontal delta and byte shuffle" : method == -1 || method == 11 || method == 12 ? "none" : ([7, 16].contains(method) ? "CPU horizontal delta and byte shuffle" : "CPU horizontal delta"), "gpuCompression": [14, 15, 17].contains(method), "restoreBackend": "CPU",
            "entropyBackend": [15, 17].contains(method) ? "GPU" : "CPU/control",
            "gpuSetupMs": output.gpu_setup_ms, "gpuCommandMs": gpu, "gpuWaitMs": gpuWait,
            "gpuStagingBytes": output.gpu_staging_bytes, "gpuDispatches": Int(output.gpu_dispatches),
            "gpuStageTotalMs": withUnsafeBytes(of: output.gpu_stage_total_ms) { Array($0.bindMemory(to: Double.self)) },
            "gpuStageTimedBatches": Int(output.gpu_stage_timed_batches),
            "hostStageTotalMs": withUnsafeBytes(of: output.gpu_host_total_ms) { Array($0.bindMemory(to: Double.self)) },
            "gpuInputBytes": output.gpu_input_bytes, "gpuOutputBytes": output.gpu_output_bytes,
            "gpuWaitCount": Int(output.gpu_wait_count), "gpuBatchCount": Int(output.gpu_batch_count), "gpuMaxInFlight": Int(output.gpu_max_in_flight),
            "decoderError": Int(result.decoder_error), "failureStage": Int(result.failure_stage),
            "threads": Int(result.threads), "frameContexts": Int(result.frame_contexts),
            "requestedDistanceSeconds": distance, "checkpointSeconds": result.checkpoint_seconds,
            "targetSeconds": result.target_seconds, "firstFollowingKeyframeSeconds": result.first_following_key_seconds,
            "width": result.width, "height": result.height, "bitDepth": result.bit_depth,
            "fullPixelComparedFrames": result.compared_frames, "fullPixelComparedBytes": result.compared_pixel_bytes,
            "retainedBytes": result.retained_bytes, "stateBytes": result.state_bytes,
            "pictureBytes": result.picture_bytes, "uniquePictures": result.unique_pictures,
            "saveMs": result.save_ms, "repeatedSaveMs": saves, "saveThreadCpuMs": cpu,
            "restoredMs": restored, "restoreOnlyMs": restoreOnly, "drainBeforeSaveMs": result.drain_before_save_ms,
            "sampledFootprintBytes": footprints, "processFootprintBeforeBytes": result.before_bytes,
            "sampledProcessFootprintPeakBytes": result.sampled_peak_bytes, "processFootprintAfterBytes": result.after_bytes,
            "emptyDecoderRejected": result.empty_rejected != 0, "wrongOwnerRejected": result.wrong_owner_rejected != 0,
            "busyDecoderRejected": result.busy_rejected != 0, "originalPixelsDetached": result.original_pixels_detached != 0,
            "restoreCount": result.restore_count, "temporarySaveFreeCount": result.temporary_save_free_count,
            "targetVerifiedCount": result.target_verified_count, "fullSuffixPasses": result.full_suffix_passes,
            "allocationVerificationPasses": result.allocation_verification_passes,
            "sameDecoder": true, "fullPixelCheckOutsideTimer": true, "normalPlaybackUnchanged": true]
          return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        }
        if let row = try JSONSerialization.jsonObject(with: rowData) as? [String: Any] { rows.append(row) }
      }
      for method in [Int32(-1), 7, 14, 15, 17] {
        if Task.isCancelled || trial.checkpointCancelled { throw CancellationError() }
        let snapshot = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        await progress(snapshot, rows.count, 15, "等速復号＋2秒ごとの保存：" + name(method))
        let rowData = try trial.withCheckpointPackets { packets, gop in
          let input = packets.map { NeoCheckpointPacket(data: $0.data, size: $0.count, seconds: $0.seconds) }
          var result = NeoRealtimeResult()
          let code = input.withUnsafeBufferPointer { buffer in
            neo_checkpoint_realtime_run(buffer.baseAddress, buffer.count, gop, method, &result, { cookie in
              guard let cookie else { return 1 }
              return Unmanaged<NeoDecodeTrial>.fromOpaque(cookie).takeUnretainedValue().checkpointCancelled ? 1 : 0
            }, Unmanaged.passUnretained(trial).toOpaque())
          }
          if code == 1006 { throw CancellationError() }
          let n = max(0, min(32, Int(result.completed_saves)))
          let saves = withUnsafeBytes(of: result.save_ms) { Array($0.bindMemory(to: Double.self).prefix(n)) }
          let cpu = withUnsafeBytes(of: result.save_cpu_ms) { Array($0.bindMemory(to: Double.self).prefix(n)) }
          let capture = withUnsafeBytes(of: result.capture_ms) { Array($0.bindMemory(to: Double.self).prefix(n)) }
          let gpu = withUnsafeBytes(of: result.gpu_ms) { Array($0.bindMemory(to: Double.self).prefix(n)) }
          let gpuWait = withUnsafeBytes(of: result.gpu_wait_ms) { Array($0.bindMemory(to: Double.self).prefix(n)) }
          let target = withUnsafeBytes(of: result.target_ms) { Array($0.bindMemory(to: Double.self)) }
          let seconds = withUnsafeBytes(of: result.target_seconds) { Array($0.bindMemory(to: Double.self)) }
          let chosen = withUnsafeBytes(of: result.chosen_seconds) { Array($0.bindMemory(to: Double.self)) }
          let used = withUnsafeBytes(of: result.used_checkpoint) { Array($0.bindMemory(to: Int32.self)).map { $0 != 0 } }
          let row: [String: Any] = [
            "kind": "paced", "method": Int(method), "status": Int(code), "decoderError": Int(result.decoder_error),
            "methodName": name(method), "preprocessing": method == 17 ? "GPU horizontal delta and byte shuffle" : method == 15 ? "CPU direct SIMD horizontal delta and byte shuffle" : method == -1 || method == 11 || method == 12 ? "none" : ([7, 16].contains(method) ? "CPU horizontal delta and byte shuffle" : "CPU horizontal delta"), "gpuCompression": [14, 15, 17].contains(method), "restoreBackend": "CPU",
            "entropyBackend": [15, 17].contains(method) ? "GPU" : "CPU/control",
            "gpuSetupMs": result.gpu_setup_ms, "gpuCommandMs": gpu, "gpuWaitMs": gpuWait,
            "gpuStagingBytes": result.gpu_staging_bytes, "gpuDispatches": Int(result.gpu_dispatches),
            "gpuStageTotalMs": withUnsafeBytes(of: result.gpu_stage_total_ms) { Array($0.bindMemory(to: Double.self)) },
            "gpuStageTimedBatches": Int(result.gpu_stage_timed_batches),
            "hostStageTotalMs": withUnsafeBytes(of: result.gpu_host_total_ms) { Array($0.bindMemory(to: Double.self)) },
            "gpuInputBytes": result.gpu_input_bytes, "gpuOutputBytes": result.gpu_output_bytes,
            "gpuWaitCount": Int(result.gpu_wait_count), "gpuBatchCount": Int(result.gpu_batch_count), "gpuMaxInFlight": Int(result.gpu_max_in_flight),
            "threads": 6, "frameContexts": 3, "saveIntervalSeconds": 2,
            "compressionWorkerQoS": "utility", "compressionWorkers": method < 0 ? 0 : 1,
            "frames": Int(result.frames), "frameDeadlineMisses": Int(result.late_frames),
            "frameReadyLatenessMeanMs": result.late_mean_ms, "frameReadyLatenessP95Ms": result.late_p95_ms,
            "frameReadyLatenessMaxMs": result.late_max_ms, "mediaSeconds": result.media_seconds,
            "pacedWallSeconds": result.wall_seconds, "completedSaves": n, "skippedBusySaves": Int(result.skipped_busy),
            "evictedCheckpoints": Int(result.evicted), "retainedCount": Int(result.retained_count),
            "retainedBytes": result.retained_bytes, "maximumRetainedBytes": result.maximum_retained_bytes,
            "memoryBudgetBytes": result.memory_budget_bytes,
            "encodeWallMs": saves, "encodeThreadCpuMs": cpu, "captureMs": capture,
            "budgetSeekMs": target, "budgetTargetSeconds": seconds, "chosenCheckpointSeconds": chosen,
            "usedCheckpoint": used, "targetVerifiedCount": Int(result.target_verified_count),
            "processFootprintBeforeBytes": result.before_bytes, "sampledProcessFootprintPeakBytes": result.sampled_peak_bytes,
            "processFootprintAfterBytes": result.after_bytes, "renderingIncluded": false, "audioIncluded": false,
            "normalPlaybackUnchanged": true]
          return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        }
        if let row = try JSONSerialization.jsonObject(with: rowData) as? [String: Any] { rows.append(row) }
      }
      let snapshot = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
      await progress(snapshot, rows.count, 15, "結果を保存中…")
      trial.releaseCheckpointPackets()
      return try JSONSerialization.data(withJSONObject: ["rows": rows,
        "processFootprintAfterInputReleaseBytes": neo_checkpoint_lab_footprint()], options: [.sortedKeys])
    }.value
  }
}
