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
    if checkpointMode { status.text = "1080p以下の長いGOPのAV1動画が対象です。取得後に、状態復元の速度・全画素一致・保持メモリーを確認します。通常の再生処理は変更しません。" }
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
          report["schema"] = 2; report["mode"] = "dav1d-checkpoint"
          report["timing"] = "single-thread-same-decoder-restored-state-to-target-output; full-pixel-check-outside-timer"
          report["thermalStateStart"] = ProcessInfo.processInfo.thermalState.rawValue
        }
        status.text = "比較する映像データを準備中…"
        try await trial.prepare(url: source, clipURL: clip)
        try Task.checkCancellation()
        report["sample"] = trial.summary
        if checkpointMode {
          status.text = "状態復元・全画素照合・メモリーを計測中…\n閉じる、またはバックグラウンドへの移動で中断します。"
          let data = try await NeoCheckpointWorker.run(trial)
          try Task.checkCancellation()
          let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
          report["checkpoint"] = rows
          let passed = rows.filter { ($0["status"] as? Int) == 0 }.count
          report["status"] = passed == 2 ? "complete" : "partial"
          report["thermalStateEnd"] = ProcessInfo.processInfo.thermalState.rawValue
          status.text = "状態復元診断が完了しました。\n全画素一致・復元試験：\(passed)/2条件\n診断結果を共有してください。画面表示や音声の速度は今回の測定に含みません。"
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
  static func run(_ trial: NeoDecodeTrial) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      try trial.withCheckpointPackets { packets, gop in
        let input = packets.map { NeoCheckpointPacket(data: $0.data, size: $0.count, seconds: $0.seconds) }
        var rows: [[String: Any]] = []
        for distance in [2.0, 0.25] {
          if trial.checkpointCancelled { throw CancellationError() }
          var result = NeoCheckpointResult()
          let code = input.withUnsafeBufferPointer { buffer in
            neo_checkpoint_lab_run(buffer.baseAddress, buffer.count, gop, distance, &result, { cookie in
              guard let cookie else { return 1 }
              return Unmanaged<NeoDecodeTrial>.fromOpaque(cookie).takeUnretainedValue().checkpointCancelled ? 1 : 0
            }, Unmanaged.passUnretained(trial).toOpaque())
          }
          if code == 1006 { throw CancellationError() }
          let baseline = withUnsafeBytes(of: result.baseline_ms) { Array($0.bindMemory(to: Double.self)) }
          let restored = withUnsafeBytes(of: result.restored_ms) { Array($0.bindMemory(to: Double.self)) }
          let restoreOnly = withUnsafeBytes(of: result.restore_only_ms) { Array($0.bindMemory(to: Double.self)) }
          let footprints = withUnsafeBytes(of: result.sampled_footprint_bytes) { Array($0.bindMemory(to: UInt64.self)) }
          rows.append([
            "status": Int(code), "decoderError": Int(result.decoder_error), "threads": 1, "frameDelay": 1,
            "requestedDistanceSeconds": distance, "checkpointSeconds": result.checkpoint_seconds,
            "targetSeconds": result.target_seconds, "firstFollowingKeyframeSeconds": result.first_following_key_seconds,
            "width": result.width, "height": result.height, "bitDepth": result.bit_depth,
            "fullPixelComparedFrames": result.compared_frames, "fullPixelComparedBytes": result.compared_pixel_bytes,
            "retainedBytes": result.retained_bytes, "stateBytes": result.state_bytes,
            "pictureBytes": result.picture_bytes, "uniquePictures": result.unique_pictures,
            "saveMs": result.save_ms, "baselineMs": baseline, "restoredMs": restored, "restoreOnlyMs": restoreOnly,
            "sampledFootprintBytes": footprints, "processFootprintBeforeBytes": result.before_bytes,
            "sampledProcessFootprintPeakBytes": result.sampled_peak_bytes, "processFootprintAfterBytes": result.after_bytes,
            "emptyDecoderRejected": result.empty_rejected != 0, "wrongOwnerRejected": result.wrong_owner_rejected != 0,
            "suffixWithoutStateRejected": result.suffix_without_state_rejected != 0,
            "restoreCount": result.restore_count, "temporarySaveFreeCount": result.temporary_save_free_count,
            "sameDecoder": true, "fullPixelCheckOutsideTimer": true, "normalPlaybackUnchanged": true
          ])
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
      }
    }.value
  }
}
