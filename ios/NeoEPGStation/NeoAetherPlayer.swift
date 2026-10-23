import UIKit
import AVFoundation
import Combine
import AetherEngine

// Opt-in comparison only. Normal PLAY, TS and STREAMING keep their VLC path.
enum NeoPlaybackExperiment {
  static var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: "player.experiment.aether") }
    set { UserDefaults.standard.set(newValue, forKey: "player.experiment.aether") }
  }
  static func usesAether(fileType: String, streaming: Bool, recording: Bool) -> Bool {
    enabled && fileType == "encoded" && !streaming && !recording
  }
}

@MainActor
final class NeoAetherPlayer: UIViewController {
  var onClose: (() -> Void)?
  private let source: URL, recordingTitle: String, initialPosition: Double
  private var engine: AetherEngine?
  private let surface = AetherPlayerView(frame: .zero)
  private let heading = NeoStyle.label("", size: 16, bold: true)
  private let status = NeoStyle.label("準備中…", size: 15)
  private let clockLabel = NeoStyle.label("0:00 / 0:00", size: 14)
  private let experimentLabel = NeoStyle.label("AetherEngine・比較用（コメント／字幕／PiPなし）", size: 12, muted: true)
  private let slider = UISlider()
  private let transport = UIStackView()
  private var subscriptions = Set<AnyCancellable>()
  private var loading: Task<Void, Never>?, seekTask: Task<Void, Never>?, probeTask: Task<Void, Never>?
  private var timer: Timer?, videoOutput: AVPlayerItemVideoOutput?
  private weak var outputItem: AVPlayerItem?
  private var closed = false, scrubbing = false, wantsPlayback = true, resumeAfterBackground = false
  private var landscape = false, startupReady = false
  private var openedAt = 0.0, sequence = 0, telemetryAt = -Double.infinity
  private var pending: PendingSeek?
  private var landedCount = 0, failedCount = 0
  private struct PendingSeek {
    let id: Int, target: Double, started: Double
    var engineID: UInt64?, landedTime: Double?
  }
  private lazy var closeButton = NeoStyle.iconButton("ArrowBackOutlined", label: "戻る") { [weak self] in self?.close() }
  private lazy var playButton = NeoStyle.button("一時停止") { [weak self] in self?.togglePlayback() }
  private lazy var exportButton = NeoStyle.button("診断ログ") { [weak self] in self?.exportLog() }
  private lazy var rotateButton = NeoStyle.button("横画面") { [weak self] in self?.rotate() }

  init(url: URL, title: String, initialPosition: Double) {
    source = url; recordingTitle = title
    self.initialPosition = initialPosition.isFinite ? max(0, initialPosition) : 0
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError() }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { landscape ? .landscape : .portrait }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .black; heading.text = recordingTitle
    status.textAlignment = .center; status.numberOfLines = 0
    [surface, heading, experimentLabel, status, clockLabel, slider, closeButton, exportButton, rotateButton, transport].forEach(view.addSubview)
    transport.axis = .horizontal; transport.spacing = 24; transport.distribution = .fillEqually
    transport.addArrangedSubview(NeoStyle.button("−10秒") { [weak self] in self?.skip(-10) })
    transport.addArrangedSubview(playButton)
    transport.addArrangedSubview(NeoStyle.button("＋10秒") { [weak self] in self?.skip(10) })
    slider.minimumValue = 0; slider.maximumValue = 1; slider.tintColor = NeoStyle.accent
    slider.accessibilityLabel = "再生位置"
    slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside])
    slider.addTarget(self, action: #selector(scrubCancelled), for: .touchCancel)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2; surface.addGestureRecognizer(doubleTap); surface.isUserInteractionEnabled = true
    NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    NeoPlaybackDiagnostics.begin(); openedAt = CACurrentMediaTime()
    NeoPlaybackDiagnostics.record("player.engine", fields: ["engine": "aether", "version": "7.46.0", "initialMs": initialPosition*1000])
    do {
      let engine = try AetherEngine(); self.engine = engine
      engine.backgroundPlaybackEnabled = false; engine.bind(view: surface)
      engine.$state.sink { [weak self] state in self?.stateChanged(state) }.store(in: &subscriptions)
      engine.$hasFirstFrameReadyForDisplay.sink { [weak self] ready in
        guard let self, ready, !self.startupReady, !self.closed else { return }
        self.startupReady = true
        NeoPlaybackDiagnostics.record("aether.startupReady", fields: ["durationMs": (CACurrentMediaTime()-self.openedAt)*1000])
      }.store(in: &subscriptions)
      engine.$currentAVPlayerItem.sink { [weak self] item in self?.attachOutput(item) }.store(in: &subscriptions)
      engine.seekEvents.sink { [weak self] event in self?.seekEvent(event) }.store(in: &subscriptions)
      engine.$videoRoute.removeDuplicates().sink { route in
        NeoPlaybackDiagnostics.record("aether.route", fields: ["route": route.rawValue])
      }.store(in: &subscriptions)
      engine.diagnostics.$liveTelemetry.sink { [weak self] value in
        guard let self, let value, !self.closed else { return }; self.telemetryAt = CACurrentMediaTime()
        NeoPlaybackDiagnostics.record("aether.telemetry", fields: ["sourceBytes": value.demuxerBytesFetched,
          "producerRestarts": value.producerRestartCount, "cachedBytes": value.cachedBytes ?? -1,
          "softwareCacheHits": value.softwareCacheSeekHits ?? 0, "softwareCacheMisses": value.softwareCacheSeekMisses ?? 0])
      }.store(in: &subscriptions)
      loading = Task { [weak self, engine] in
        guard let self else { return }
        do {
          // Empty subtitle preferences and no host subtitle view: the comparison
          // measures the engine without comment/subtitle preparation or history writes.
          _ = try await engine.load(url: self.source, startPosition: self.initialPosition,
            options: LoadOptions(preferredSubtitleLanguages: [], autoplay: true))
          guard !Task.isCancelled, !self.closed else { return }
          if !self.wantsPlayback { engine.pause() }
        } catch {
          guard !Task.isCancelled, !self.closed else { return }; self.showFailure(error)
        }
      }
      timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
    } catch { showFailure(error) }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets, width = view.bounds.width-safe.left-safe.right
    let top = safe.top, left = safe.left, bottom = view.bounds.height-safe.bottom
    closeButton.frame = CGRect(x: left+8, y: top+4, width: 44, height: 44)
    exportButton.frame = CGRect(x: left+width-100, y: top+4, width: 92, height: 44)
    heading.frame = CGRect(x: left+60, y: top+4, width: max(0, width-168), height: 28)
    experimentLabel.frame = CGRect(x: left+16, y: top+49, width: width-32, height: 24)
    let controlsTop = bottom-132
    let room = max(0, controlsTop-(top+78))
    let height = min(room, width*9/16)
    surface.frame = CGRect(x: left, y: top+78+max(0, (room-height)/2), width: width, height: height)
    status.frame = CGRect(x: left+20, y: surface.frame.midY-30, width: width-40, height: 60)
    clockLabel.frame = CGRect(x: left+16, y: controlsTop, width: width-128, height: 24)
    rotateButton.frame = CGRect(x: left+width-104, y: controlsTop-6, width: 96, height: 36)
    slider.frame = CGRect(x: left+16, y: controlsTop+28, width: width-32, height: 34)
    transport.frame = CGRect(x: left+16, y: controlsTop+72, width: width-32, height: 48)
  }
  private func stateChanged(_ state: PlaybackState) {
    guard !closed else { return }
    switch state {
    case .loading: status.text = "準備中…"
    case .error: status.text = "再生中にエラーが発生しました。"; failedCount += 1
    case .ended: status.text = "再生終了"; wantsPlayback = false
    default: status.text = nil
    }
    if case .error = state { NeoPlaybackDiagnostics.record("aether.failure", fields: ["stage": "playback"]) }
  }
  private func showFailure(_ error: Error) {
    failedCount += 1; status.text = "再生を開始できませんでした。"
    let value = error as NSError
    NeoPlaybackDiagnostics.record("aether.failure", fields: ["stage": "load", "code": value.code])
  }
  private func attachOutput(_ item: AVPlayerItem?) {
    if let output = videoOutput { outputItem?.remove(output) }
    outputItem = item; videoOutput = nil
    guard let item else { return }
    // No pixel conversion or image generation: only consume a buffer during a
    // measured seek, to distinguish a real target picture from an optimistic clock.
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output); videoOutput = output
  }
  private func tick() {
    guard !closed, let engine else { return }
    let duration = engine.duration, position = engine.currentTime
    if duration.isFinite, duration > 0 { slider.maximumValue = Float(duration) }
    if !scrubbing { slider.value = Float(position.isFinite ? max(0, position) : 0) }
    clockLabel.text = "\(Self.time(scrubbing ? Double(slider.value) : position)) / \(Self.time(duration))"
    playButton.setTitle(wantsPlayback ? "一時停止" : "再生", for: .normal)
    slider.isEnabled = engine.canSeek && duration.isFinite && duration > 0
    if let pending, let rendered = pending.landedTime {
      if engine.videoRoute == .software {
        if engine.clock.sourceTimeFollowsPicture { finishSeek(rendered: rendered, verification: "engineRenderedClock") }
      } else if let output = videoOutput, let item = outputItem {
        let time = item.currentTime()
        var displayed = CMTime.invalid
        if output.hasNewPixelBuffer(forItemTime: time),
          let _ = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
          displayed.isNumeric, abs(CMTimeGetSeconds(displayed-time)) < 0.5 {
          finishSeek(rendered: rendered, verification: "pixelBuffer")
        }
      }
    }
    if let pending, CACurrentMediaTime()-pending.started > 12 {
      failedCount += 1
      NeoPlaybackDiagnostics.record("seek.timeout", fields: ["targetMs": pending.target*1000, "engine": "aether"])
      self.pending = nil; status.text = "シーク先の映像を確認できませんでした。"
    }
  }
  private func seekEvent(_ event: SeekEvent) {
    guard !closed, var pending else { return }
    switch event.outcome {
    case .began:
      guard abs(event.target-pending.target) < 0.01 else { return }
      pending.engineID = event.id; self.pending = pending
    case .landed(let rendered):
      guard pending.engineID == event.id else { return }
      NeoPlaybackDiagnostics.record("aether.seekLanded", fields: ["targetMs": pending.target*1000,
        "renderedMs": rendered*1000, "durationMs": (CACurrentMediaTime()-pending.started)*1000])
      guard rendered.isFinite, abs(rendered-pending.target) < 0.5 else { return }
      pending.landedTime = rendered; self.pending = pending
    case .stalled, .rejected:
      guard pending.engineID == event.id || abs(event.target-pending.target) < 0.01 else { return }
      failedCount += 1; self.pending = nil
      NeoPlaybackDiagnostics.record("aether.seekFailed", fields: ["targetMs": pending.target*1000])
    case .superseded: break
    }
  }
  private func finishSeek(rendered: Double, verification: String) {
    guard let pending, let engine else { return }
    landedCount += 1
    NeoPlaybackDiagnostics.record("seek.videoResume", fields: ["engine": "aether", "mediaMs": rendered*1000,
      "targetMs": pending.target*1000, "durationMs": (CACurrentMediaTime()-pending.started)*1000,
      "verification": verification, "telemetryAgeMs": telemetryAt.isFinite ? (CACurrentMediaTime()-telemetryAt)*1000 : -1,
      "route": engine.videoRoute.rawValue])
    self.pending = nil
  }
  func seek(to target: Double) {
    guard !closed, let engine, engine.canSeek, target.isFinite else { return }
    let end = engine.duration.isFinite ? max(0, engine.duration-0.1) : 0
    guard end > 0 else { return }
    let target = min(end, max(0, target)), previous = engine.currentTime
    if let pending { NeoPlaybackDiagnostics.record("aether.seekSuperseded", fields: ["targetMs": pending.target*1000]) }
    seekTask?.cancel(); sequence += 1; NeoPlaybackDiagnostics.beginSeek(sequence)
    pending = PendingSeek(id: sequence, target: target, started: CACurrentMediaTime())
    status.text = nil
    NeoPlaybackDiagnostics.record("seek.start", fields: ["fromMs": previous*1000, "targetMs": target*1000, "engine": "aether"])
    seekTask = Task { await engine.seek(to: target) }
  }
  private func skip(_ seconds: Double) { seek(to: (pending?.target ?? engine?.currentTime ?? 0)+seconds) }
  private func togglePlayback() {
    guard !closed, let engine else { return }; wantsPlayback.toggle()
    if wantsPlayback { engine.play() } else { engine.pause() }
  }
  @objc private func scrubBegan() { scrubbing = true }
  @objc private func scrubEnded() { scrubbing = false; seek(to: Double(slider.value)) }
  @objc private func scrubCancelled() { scrubbing = false }
  @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
    skip(gesture.location(in: surface).x < surface.bounds.midX ? -10 : 10)
  }
  private func rotate() {
    landscape.toggle(); setNeedsUpdateOfSupportedInterfaceOrientations()
    rotateButton.setTitle(landscape ? "縦画面" : "横画面", for: .normal)
    view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations))
  }
  @objc private func background() {
    resumeAfterBackground = wantsPlayback; engine?.pause()
  }
  @objc private func foreground() {
    if resumeAfterBackground && wantsPlayback && !closed { engine?.play() }; resumeAfterBackground = false
  }
  private func exportLog() {
    guard let url = NeoPlaybackDiagnostics.exportURL() else { return }
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.popoverPresentationController?.sourceView = exportButton
    share.popoverPresentationController?.sourceRect = exportButton.bounds
    present(share, animated: true)
  }
  private func shutdown() {
    guard !closed else { return }; closed = true
    loading?.cancel(); seekTask?.cancel(); probeTask?.cancel(); timer?.invalidate(); timer = nil
    if let output = videoOutput { outputItem?.remove(output) }; outputItem = nil; videoOutput = nil
    subscriptions.removeAll(); engine?.stop(); engine = nil
    NotificationCenter.default.removeObserver(self)
    NeoPlaybackDiagnostics.record("aether.closed", fields: [:])
  }
  private func close() {
    shutdown()
    let completion = onClose; onClose = nil
    dismiss(animated: true) { completion?() }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil { shutdown() }
  }
  private static func time(_ value: Double) -> String {
    let seconds = value.isFinite ? Int(max(0, value)) : 0
    return String(format: "%d:%02d", seconds/60, seconds%60)
  }

#if targetEnvironment(simulator)
  func runComparisonProbe() {
    probeTask = Task { [weak self] in
      guard let self else { return }
      let deadline = CACurrentMediaTime()+30
      while !closed && (!startupReady || engine?.canSeek != true) && CACurrentMediaTime()<deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      var checks: [String: Bool] = ["startupVideo": startupReady, "seekable": engine?.canSeek == true,
        "initialPosition": abs((engine?.currentTime ?? 0)-initialPosition) < 3]
      for (index, target) in [20.0, 40.0, 30.0, 20.0].enumerated() {
        guard !closed else { break }
        let count = landedCount; seek(to: target)
        let end = CACurrentMediaTime()+13
        while pending != nil && CACurrentMediaTime()<end { try? await Task.sleep(for: .milliseconds(50)) }
        checks["target\(index)"] = landedCount == count+1
        try? await Task.sleep(for: .milliseconds(200))
      }
      wantsPlayback = false; engine?.pause()
      let pausedCount = landedCount; seek(to: 30)
      let pausedDeadline = CACurrentMediaTime()+13
      while pending != nil && CACurrentMediaTime()<pausedDeadline { try? await Task.sleep(for: .milliseconds(50)) }
      checks["pausedSeek"] = landedCount == pausedCount+1 && engine?.state == .paused
      checks["noFailures"] = failedCount == 0
      shutdown(); checks["closed"] = engine == nil && timer == nil
      NeoPiPSmoke.save("aether-comparison-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
      if let url = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: url) {
        try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("aether-comparison-diagnostics.json"))
      }
    }
  }
#endif
}
