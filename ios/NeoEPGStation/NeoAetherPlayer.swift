import UIKit
import AVFoundation
import Combine
import AetherEngine
import AetherLibavcodec
import AetherLibavutil
import VideoToolbox
import CoreImage
import IOSurface

// Fixed tokens only: no URLs, subtitles, titles or raw engine error strings.
private final class NeoAetherLogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var seen = Set<String>()
  func receive(_ line: String) {
    var token: String?
    for (match, value) in [
      ("[VTProbe] codec=av01 hwSupported=true", "av1-hardware-supported"),
      ("[VTProbe] codec=av01 hwSupported=false", "av1-hardware-unavailable"),
      ("codec=libdav1d,", "decoder-libdav1d"),
      ("dispatch: codec=\(AV_CODEC_ID_AV1.rawValue) → software", "av1-software-route"),
      ("dispatch: codec=\(AV_CODEC_ID_AV1.rawValue) → native", "av1-native-route"),
      ("[SWDecoder] send_packet returned", "video-decode-error"),
      ("[Renderer] queue target failed", "video-render-error"),
      ("Failed to get pixel format", "video-pixel-format-error"),
      ("source is forward-only", "source-unseekable")
    ] { if line.contains(match) { token = value; break } }
    guard let token else { return }
    lock.lock(); let first = seen.insert(token).inserted; lock.unlock()
    if first { NeoPlaybackDiagnostics.record("aether.engineDecision", fields: ["decision": token]) }
  }
}


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
  private lazy var chrome = NeoPlayerChrome(title: recordingTitle)
  private var status: UILabel { chrome.statusLabel }
  private var slider: UISlider { chrome.timeline }
  private var playButton: UIButton { chrome.playButton }
  private let context: [String: Any]
  private var hideControls: DispatchWorkItem?
  private var subscriptions = Set<AnyCancellable>()
  private var loading: Task<Void, Never>?, seekTask: Task<Void, Never>?, probeTask: Task<Void, Never>?
  private var timer: Timer?, videoOutput: AVPlayerItemVideoOutput?
  private weak var outputItem: AVPlayerItem?
  private var closed = false, scrubbing = false, wantsPlayback = true, resumeAfterBackground = false
  private var landscape = false, startupReady = false
  private var openedAt = 0.0, sequence = 0, telemetryAt = -Double.infinity
  private var pending: PendingSeek?
  private var landedCount = 0, failedCount = 0
  private var lastPictureGeneration: UInt64?
  private var observedPicture: Picture?
  private var rendererFailureReported = false
  private let engineLog = NeoAetherLogCapture()
  private struct Picture { let time: Double; let generation: UInt64?; let verification: String; let buffer: CVPixelBuffer }

  private struct PendingSeek {
    let id: Int, target: Double, started: Double
    var engineID: UInt64?, landedTime: Double?
    var previousPictureGeneration: UInt64?
  }
  init(url: URL, title: String, initialPosition: Double, context: [String: Any] = [:]) {
    self.context = context
    source = url; recordingTitle = title
    self.initialPosition = initialPosition.isFinite ? max(0, initialPosition) : 0
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError() }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { landscape ? .landscape : .portrait }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .black
    chrome.frame = view.bounds; chrome.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(chrome); chrome.configure(context); chrome.configureEngineComparison()
    chrome.videoView.addSubview(surface)
    surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    chrome.onVideoLayout = { [weak self] in
      guard let self else { return }; self.surface.frame = self.chrome.videoView.bounds
    }
    chrome.onAction = { [weak self] action in self?.perform(action) }
    chrome.updateLoading("準備中…"); chrome.showControls(true)
    NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    NeoPlaybackDiagnostics.begin(); openedAt = CACurrentMediaTime()
    NeoPlaybackDiagnostics.record("player.engine", fields: ["engine": "aether", "version": "7.46.0", "initialMs": initialPosition*1000])
    do {
      // Verify imported enum values against the actual linked binary before it
      // can misclassify AV1/HEVC. A version string alone does not establish ABI.
      let av1 = avcodec_descriptor_get_by_name("av1")?.pointee.id
      let hevc = avcodec_descriptor_get_by_name("hevc")?.pointee.id
      let dav1d = avcodec_find_decoder_by_name("libdav1d")
      let compatible = av1 == AV_CODEC_ID_AV1 && hevc == AV_CODEC_ID_HEVC && dav1d?.pointee.id == av1
      NeoPlaybackDiagnostics.record("aether.binaryABI", fields: ["compatible": compatible,
        "headerAV1": AV_CODEC_ID_AV1.rawValue, "runtimeAV1": av1?.rawValue ?? 0,
        "headerHEVC": AV_CODEC_ID_HEVC.rawValue, "runtimeHEVC": hevc?.rawValue ?? 0,
        "dav1dAvailable": dav1d != nil, "avcodecVersion": avcodec_version()])
      guard compatible else { throw NSError(domain: "NeoAetherBinaryABI", code: 1) }
      NeoPlaybackDiagnostics.record("aether.hardware", fields: ["av1": VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)])
      EngineLog.handler = { [capture = engineLog] line in capture.receive(line) }
      let engine = try AetherEngine(); self.engine = engine
      engine.backgroundPlaybackEnabled = false; engine.bind(view: surface)
      engine.$state.sink { [weak self] state in self?.stateChanged(state) }.store(in: &subscriptions)
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
          if let size = engine.softwareDisplaySize, size.height > 0 { self.chrome.videoAspectRatio = size.width/size.height }
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
    chrome.frame = view.bounds; chrome.layoutIfNeeded(); surface.frame = chrome.videoView.bounds
  }
  private func perform(_ action: String) {
    switch action {
    case "back": close()
    case "play": togglePlayback()
    case "rotate": rotate()
    case "toggle-controls": chrome.showControls(!chrome.controlsVisible); scheduleHide()
    case "interaction": chrome.showControls(true); scheduleHide()
    case "scrub-begin": scrubBegan()
    case "scrub-end": scrubEnded()
    case "scrub-cancel": scrubCancelled()
    case "export-diagnostics": exportLog()
    default:
      if action.hasPrefix("jump:"), let seconds = Double(action.dropFirst(5)) { skip(seconds) }
    }
  }
  private func scheduleHide() {
    hideControls?.cancel()
    let task = DispatchWorkItem { [weak self] in
      guard let self, self.wantsPlayback, self.pending == nil, !self.chrome.interactionOpen else { return }
      self.chrome.showControls(false)
    }
    hideControls = task; DispatchQueue.main.asyncAfter(deadline: .now()+3, execute: task)
  }
  private func stateChanged(_ state: PlaybackState) {
    guard !closed else { return }
    switch state {
    case .loading: chrome.updateLoading("準備中…")
    case .error: chrome.updateLoading(nil); status.text = "再生中にエラーが発生しました。"; failedCount += 1
    case .ended: chrome.updateLoading(nil); status.text = "再生終了"; wantsPlayback = false
    default: break
    }
    if case .error = state { NeoPlaybackDiagnostics.record("aether.failure", fields: ["stage": "playback"]) }
  }
  private func showFailure(_ error: Error) {
    failedCount += 1; chrome.updateLoading(nil); status.text = "再生を開始できませんでした。"
    let value = error as NSError
    NeoPlaybackDiagnostics.record("aether.failure", fields: ["stage": "load", "code": value.code])
  }
  private func attachOutput(_ item: AVPlayerItem?) {
    if let output = videoOutput { outputItem?.remove(output) }
    outputItem = item; videoOutput = nil; observedPicture = nil
    guard let item else { return }
    // No pixel conversion or image generation: only consume a buffer during a
    // measured seek, to distinguish a real target picture from an optimistic clock.
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output); videoOutput = output
  }
  private func tick() {
    guard !closed, let engine else { return }
    let duration = engine.duration.isFinite ? max(0, engine.duration) : 0
    let position = engine.currentTime.isFinite ? max(0, engine.currentTime) : 0
    if !scrubbing { slider.value = duration > 0 ? Float(position/duration) : 0 }
    chrome.updatePlayback(wantsPlayback, current: Int64(position), duration: Int64(duration))
    slider.isEnabled = engine.canSeek && duration > 0
    chrome.updateDiagnostics()
    if !startupReady || pending != nil, let picture = displayedPicture() {
      if !startupReady {
        startupReady = true; chrome.updateLoading(nil); status.text = nil; scheduleHide()
#if targetEnvironment(simulator)
        saveComparisonPicture(picture.buffer)
#endif
        NeoPlaybackDiagnostics.record("aether.startupReady", fields: ["durationMs": (CACurrentMediaTime()-openedAt)*1000,
          "pictureMs": picture.time*1000, "verification": picture.verification])
      }
      if pending != nil { observedPicture = picture }
      lastPictureGeneration = picture.generation
    }
    if let pending, pending.landedTime != nil, let picture = observedPicture,
       abs(picture.time-pending.target) < 0.5,
       picture.generation == nil || picture.generation != pending.previousPictureGeneration {
      finishSeek(rendered: picture.time, verification: picture.verification)
    }
    if !startupReady && CACurrentMediaTime()-openedAt > 30 && !rendererFailureReported {
      rendererFailureReported = true; failedCount += 1; engine.pause(); wantsPlayback = false
      chrome.updateLoading(nil); status.text = "映像を表示できませんでした。"
      NeoPlaybackDiagnostics.record("aether.failure", fields: ["stage": "first-picture-timeout", "route": engine.videoRoute.rawValue])
    }
    if let pending, CACurrentMediaTime()-pending.started > 12 {
      failedCount += 1
      NeoPlaybackDiagnostics.record("seek.timeout", fields: ["targetMs": pending.target*1000, "engine": "aether"])
      self.pending = nil; observedPicture = nil; chrome.finishSeekPreview(); status.text = "シーク先の映像を確認できませんでした。"
    }
  }
  private func layers(in layer: CALayer) -> [CALayer] {
    [layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
  }
  private func displayedPicture() -> Picture? {
    guard let engine, !surface.bounds.isEmpty else { return nil }
    let active = layers(in: surface.layer)
    if engine.videoRoute == .software {
      for layer in active.compactMap({ $0 as? AVSampleBufferDisplayLayer }) {
        guard layer.isReadyForDisplay, layer.sampleBufferRenderer.status != .failed,
              let buffer = layer.sampleBufferRenderer.displayedPixelBuffer(),
              let backing = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
              let pts = IOSurfaceCopyValue(backing, "NeoAetherSourcePTS" as CFString) as? NSNumber,
              let generation = IOSurfaceCopyValue(backing, "NeoAetherPictureGeneration" as CFString) as? NSNumber,
              pts.doubleValue.isFinite else { continue }
        return Picture(time: pts.doubleValue, generation: generation.uint64Value,
          verification: "displayedPixelBuffer", buffer: buffer)
      }
      return nil
    }
    guard active.compactMap({ $0 as? AVPlayerLayer }).contains(where: { $0.isReadyForDisplay }),
          let output = videoOutput, let item = outputItem else { return nil }
    let time = item.currentTime(); var displayed = CMTime.invalid
    guard output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
          displayed.isNumeric, let source = engine.presentationAxisMap.sourceSeconds(forItemSeconds: displayed.seconds),
          source.isFinite else { return nil }
    return Picture(time: source, generation: nil, verification: "nativePixelBuffer", buffer: buffer)
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
      failedCount += 1; self.pending = nil; observedPicture = nil
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
    self.pending = nil; observedPicture = nil; chrome.finishSeekPreview(); scheduleHide()
  }
  func seek(to target: Double) {
    guard !closed, let engine, engine.canSeek, target.isFinite else { return }
    let end = engine.duration.isFinite ? max(0, engine.duration-0.1) : 0
    guard end > 0 else { return }
    let target = min(end, max(0, target)), previous = engine.currentTime
    if let pending { NeoPlaybackDiagnostics.record("aether.seekSuperseded", fields: ["targetMs": pending.target*1000]) }
    seekTask?.cancel(); sequence += 1; NeoPlaybackDiagnostics.beginSeek(sequence)
    observedPicture = nil
    pending = PendingSeek(id: sequence, target: target, started: CACurrentMediaTime(),
      previousPictureGeneration: displayedPicture()?.generation ?? lastPictureGeneration)
    status.text = nil; chrome.previewSeek(Int64(target)); chrome.showControls(true)
    NeoPlaybackDiagnostics.record("seek.start", fields: ["fromMs": previous*1000, "targetMs": target*1000, "engine": "aether"])
    seekTask = Task { await engine.seek(to: target) }
  }
  private func skip(_ seconds: Double) { seek(to: (pending?.target ?? engine?.currentTime ?? 0)+seconds) }
  private func togglePlayback() {
    guard !closed, let engine else { return }; wantsPlayback.toggle()
    if wantsPlayback { engine.play() } else { engine.pause() }
  }
  @objc private func scrubBegan() { scrubbing = true }
  @objc private func scrubEnded() { scrubbing = false; seek(to: Double(slider.value)*(engine?.duration ?? 0)) }
  @objc private func scrubCancelled() { scrubbing = false }
  private func rotate() {
    landscape.toggle(); setNeedsUpdateOfSupportedInterfaceOrientations()
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
    share.popoverPresentationController?.sourceView = chrome
    share.popoverPresentationController?.sourceRect = CGRect(x: chrome.bounds.midX, y: chrome.bounds.midY, width: 1, height: 1)
    present(share, animated: true)
  }
  private func shutdown() {
    guard !closed else { return }; closed = true
    loading?.cancel(); seekTask?.cancel(); probeTask?.cancel(); timer?.invalidate(); timer = nil
    if let output = videoOutput { outputItem?.remove(output) }; outputItem = nil; videoOutput = nil
    hideControls?.cancel(); observedPicture = nil; subscriptions.removeAll(); engine?.stop(); engine = nil; EngineLog.handler = nil
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
  private func saveComparisonPicture(_ buffer: CVPixelBuffer) {
    guard let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent),
          let data = UIImage(cgImage: image).pngData() else { return }
    try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("aether-comparison-picture.png"))
  }
  func runComparisonProbe() {
    probeTask = Task { [weak self] in
      guard let self else { return }
      let deadline = CACurrentMediaTime()+30
      while !closed && (!startupReady || engine?.canSeek != true) && CACurrentMediaTime()<deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      var checks: [String: Bool] = ["startupVideo": startupReady, "seekable": engine?.canSeek == true,
        "productionChrome": chrome.comparisonControlsSealed(),
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
