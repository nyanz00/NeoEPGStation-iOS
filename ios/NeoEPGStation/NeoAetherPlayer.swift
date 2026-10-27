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
    if let prefix = line.range(of: "[NeoSeekSegment] "), NeoPlaybackDiagnostics.seekID > 0 {
      let parts = line[prefix.upperBound...].split(separator: " ")
      var values: [String: Any] = [:]
      for part in parts {
        let pair = part.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, ["index", "file", "ok", "durationMs"].contains(String(pair[0])),
              let value = Int(pair[1]), value >= 0 else { return }
        values[String(pair[0])] = value
      }
      if values.count == 4 { NeoPlaybackDiagnostics.record("aether.segmentServed", fields: values) }
      return
    }
    var token: String?
    for (match, value) in [
      ("[VTProbe] codec=av01 hwSupported=true", "av1-hardware-supported"),
      ("[VTProbe] codec=av01 hwSupported=false", "av1-hardware-unavailable"),
      ("codec=libdav1d,", "decoder-libdav1d"),
      ("checkpoint bridge opened", "decoder-checkpoint-dav1d"),
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


// The software callback proves a freshly decoded target, not physical display.
// Keep that evidence separate when the OS returns an untimed 10-bit image copy.
private final class NeoAetherDecodedFrames: @unchecked Sendable {
  struct Frame { let time: Double; let generation: UInt64 }
  private let lock = NSLock()
  private var frame: Frame?
  func accept(_ value: SoftwareVideoFrameTime) {
    let seconds = value.presentation.seconds
    guard seconds.isFinite else { return }
    lock.lock(); frame = Frame(time: seconds, generation: value.generation); lock.unlock()
  }
  func latest() -> Frame? { lock.lock(); defer { lock.unlock() }; return frame }
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
  private let checkpointPlayback: NeoCheckpointPlayback?
  private var checkpointTask: Task<Void, Never>?
  private var checkpointLastTick = -Double.infinity
  private var checkpointAxisOffset = 0.0
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
  private var diagnosticTask: Task<Void, Never>?
  private var diagnosticBusy = false
  private var queuedDiagnostic: (PendingSeek, String)?
  private var uiTicks = 0, playbackUpdates = 0, diagnosticUpdates = 0
  private var uiWorkMs = 0.0, lastTickAt = 0.0, seekTickGapMs = 0.0
  private var lastUIPosition = Int64.min, lastUIDuration = Int64.min
  private var lastUIRunning: Bool?, lastUIStatus: String?
#if targetEnvironment(simulator)
  private let uiBaseline = ProcessInfo.processInfo.environment["NEO_EPG_AETHER_UI_BASELINE"] == "1"
#else
  private let uiBaseline = false
#endif
#if targetEnvironment(simulator)
  private var startupPicture: CVPixelBuffer?
  private var probePicture: CVPixelBuffer?
  private var seekPictures: [(CVPixelBuffer, String)] = []
#endif
  private var decodeTrialActive = false
  private var decodeTrialRows: [[String: Double]] = []
  private var rendererFailureReported = false
  private let engineLog = NeoAetherLogCapture()
  private let decodedFrames = NeoAetherDecodedFrames()
  private struct Picture { let time: Double?; let generation: UInt64?; let verification: String; let buffer: CVPixelBuffer }

  private struct PendingSeek {
    let id: Int, target: Double, started: Double
    var engineID: UInt64?, landedTime: Double?
    var previousPictureGeneration: UInt64?
    var previousDecodedGeneration: UInt64?
    var waitSampleLevel = 0
    var uiWorkAtStart = 0.0
  }
  init(url: URL, title: String, initialPosition: Double, checkpointMode: Bool? = nil, context: [String: Any] = [:]) {
    self.context = context
    checkpointPlayback = checkpointMode.map { NeoCheckpointPlayback(enabled: $0) }
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
      guard let self else { return }
      let bounds = self.chrome.videoView.bounds
      if self.surface.frame != bounds { self.surface.frame = bounds }
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
      if let checkpointPlayback {
        checkpointPlayback.onRecovery { [weak self] sourceTarget in
          Task { @MainActor [weak self] in
            guard let self, !self.closed, let pending = self.pending,
                  abs(pending.target + self.checkpointAxisOffset-sourceTarget) < 0.05 else { return }
            self.seek(to: pending.target)
          }
        }
        checkpointPlayback.onFailure { [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.seek(to: self.pending?.target ?? self.engine?.currentTime ?? 0)
          }
        }
        NeoAV1PlaybackBridge.install { [checkpointPlayback] in checkpointPlayback.makeDecoder() }
        AetherEngine.setForceSoftwarePathForTesting(true)
        NeoPlaybackDiagnostics.record("checkpoint.configuration", fields: ["enabled": checkpointPlayback.enabled,
          "historySeconds": 60, "futureSeconds": 20, "budgetBytes": NeoCheckpointPlayback.budget])
      }
      let engine = try AetherEngine(); self.engine = engine
      engine.backgroundPlaybackEnabled = false; engine.bind(view: surface)
      engine.setSoftwareVideoFrameTimeObserver { [frames = decodedFrames] in frames.accept($0) }
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
          var options = LoadOptions(preferredSubtitleLanguages: [], autoplay: true)
          if self.checkpointPlayback != nil { options.forwardBufferSegments = 5 }
          _ = try await engine.load(url: self.source, startPosition: self.initialPosition, options: options)
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
    uiTicks += 1
    let now = CACurrentMediaTime()
    if let checkpoints = checkpointPlayback, now - checkpointLastTick >= 1 {
      checkpointLastTick = now
      checkpoints.updatePosition(position + checkpointAxisOffset)
      NeoPlaybackDiagnostics.record("checkpoint.cache", fields: checkpoints.report())
      if checkpointTask == nil, checkpoints.needsAheadRun, pending == nil {
        let epoch = sequence
        checkpointTask = Task { [weak self, engine, checkpoints] in
          guard let self else { return }
          defer { self.checkpointTask = nil }
          guard let run = await engine.neoCheckpointPackets(fromSession: position),
                !Task.isCancelled, !self.closed, self.sequence == epoch else { return }
          self.checkpointAxisOffset = run.sourcePosition - position
          checkpoints.offer(run)
        }
      }
    }
    if pending != nil, lastTickAt > 0 { seekTickGapMs = max(seekTickGapMs, (now-lastTickAt)*1000) }
    lastTickAt = now
    slider.isEnabled = engine.canSeek && duration > 0
    if uiBaseline { refreshChrome(position: position, duration: duration) }
    if !startupReady || pending != nil, let picture = displayedPicture() {
      if !startupReady {
        startupReady = true; chrome.updateLoading(nil); status.text = nil; scheduleHide()
#if targetEnvironment(simulator)
        // Retain only; image conversion runs after latency measurements so
        // simulator shader compilation cannot block startup or seek timing.
        startupPicture = picture.buffer
#endif
        NeoPlaybackDiagnostics.record("aether.startupReady", fields: ["durationMs": (CACurrentMediaTime()-openedAt)*1000,
          "pictureMs": picture.time.map { $0*1000 } ?? -1, "verification": picture.verification,
          "displayTimingAvailable": picture.time != nil])
      }
#if targetEnvironment(simulator)
      probePicture = picture.buffer
#endif
      if pending != nil { observedPicture = picture }
      lastPictureGeneration = picture.generation
    }
    if let pending, pending.landedTime != nil, let picture = observedPicture {
      if let time = picture.time, abs(time-pending.target) < 0.5,
         picture.generation == nil || picture.generation != pending.previousPictureGeneration {
        finishSeek(position: time, verification: picture.verification, displayed: true)
      } else if picture.time == nil, let decoded = decodedFrames.latest(),
                decoded.generation != pending.previousDecodedGeneration,
                abs(decoded.time-pending.target) < 0.5 {
        // P010 output may be copied to BGRA with all timestamp attachments
        // removed. Unblock the UI from real target decode + a displayed image,
        // but NEVER report this as measured seek-to-display latency.
        finishSeek(position: decoded.time, verification: "decodedTargetAndPicture", displayed: false)
      }
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
    if var pending {
      let elapsed = CACurrentMediaTime()-pending.started
      if pending.waitSampleLevel == 0 && elapsed > 0.2 {
        pending.waitSampleLevel = 1; self.pending = pending; sampleSeek(pending, phase: "waiting-200ms")
      } else if pending.waitSampleLevel == 1 && elapsed > 0.6 {
        pending.waitSampleLevel = 2; self.pending = pending; sampleSeek(pending, phase: "waiting-600ms")
      }
    }
    if !uiBaseline { refreshChrome(position: position, duration: duration) }
  }
  private func refreshChrome(position: Double, duration: Double) {
    let start = CACurrentMediaTime()
    let second = Int64(position), length = Int64(duration)
    if uiBaseline || lastUIPosition != second || lastUIDuration != length || lastUIRunning != wantsPlayback {
      chrome.updatePlayback(wantsPlayback, current: second, duration: length); playbackUpdates += 1
      lastUIPosition = second; lastUIDuration = length; lastUIRunning = wantsPlayback
    }
    let text = status.text ?? ""
    if uiBaseline || lastUIStatus != text {
      chrome.updateDiagnostics(); diagnosticUpdates += 1; lastUIStatus = text
    }
    uiWorkMs += (CACurrentMediaTime()-start)*1000
  }
  private func sampleSeek(_ seek: PendingSeek, phase: String) {
    guard !closed, let engine else { return }
    if diagnosticBusy { queuedDiagnostic = (seek, phase); return }
    diagnosticBusy = true
    let requested = CACurrentMediaTime()
    diagnosticTask = Task { [weak self, engine] in
      let fields = await engine.neoSeekDiagnostics(atDisplayTime: seek.target)
      guard let self else { return }
      defer {
        diagnosticBusy = false
        if let next = queuedDiagnostic {
          queuedDiagnostic = nil; sampleSeek(next.0, phase: next.1)
        }
      }
      guard !closed, self.engine === engine else { return }
      guard sequence == seek.id else { return }
      var event: [String: Any] = ["originSeek": seek.id, "phase": phase, "route": engine.videoRoute.rawValue,
        "requestedAfterSeekMs": (requested-seek.started)*1000,
        "finishedAfterSeekMs": (CACurrentMediaTime()-seek.started)*1000]
      for (key, value) in fields where value.isFinite { event[key] = value }
      NeoPlaybackDiagnostics.record("aether.seekSnapshot", fields: event)
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
              let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() else { continue }
        var pts: Double?, generation: UInt64?
        if let backing = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
          pts = (IOSurfaceCopyValue(backing, "NeoAetherSourcePTS" as CFString) as? NSNumber)?.doubleValue
          generation = (IOSurfaceCopyValue(backing, "NeoAetherPictureGeneration" as CFString) as? NSNumber)?.uint64Value
        }
        return Picture(time: pts?.isFinite == true ? pts : nil, generation: generation,
          verification: pts == nil ? "displayedPixelBufferUntimed" : "displayedPixelBuffer", buffer: buffer)
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
      pending.landedTime = rendered; self.pending = pending; sampleSeek(pending, phase: "completion")
    case .stalled, .rejected:
      guard pending.engineID == event.id || abs(event.target-pending.target) < 0.01 else { return }
      failedCount += 1; self.pending = nil; observedPicture = nil
      NeoPlaybackDiagnostics.record("aether.seekFailed", fields: ["targetMs": pending.target*1000])
    case .superseded: break
    }
  }
  private func finishSeek(position: Double, verification: String, displayed: Bool) {
    guard let pending, let engine else { return }
    landedCount += 1
    sampleSeek(pending, phase: "picture")
    NeoPlaybackDiagnostics.record("aether.seekUIWork", fields: ["uiWorkMs": uiWorkMs-pending.uiWorkAtStart,
      "maxTickGapMs": seekTickGapMs, "uiThrottled": !uiBaseline])
    if displayed {
      NeoPlaybackDiagnostics.record("seek.videoResume", fields: ["engine": "aether", "mediaMs": position*1000,
        "targetMs": pending.target*1000, "durationMs": (CACurrentMediaTime()-pending.started)*1000,
        "verification": verification, "telemetryAgeMs": telemetryAt.isFinite ? (CACurrentMediaTime()-telemetryAt)*1000 : -1,
        "route": engine.videoRoute.rawValue])
    } else {
      NeoPlaybackDiagnostics.record("aether.seekDecodedTarget", fields: ["targetMs": pending.target*1000,
        "decodedMs": position*1000, "decodeReadyMs": (CACurrentMediaTime()-pending.started)*1000,
        "displayTimeVerified": false, "verification": verification, "route": engine.videoRoute.rawValue])
    }
    if decodeTrialActive {
      decodeTrialRows.append(["targetSeconds": pending.target, "frameSeconds": position,
        "frameReadyMs": (CACurrentMediaTime()-pending.started)*1000,
        "displayTimestampVerified": displayed ? 1 : 0])
    }
    self.pending = nil; observedPicture = nil; chrome.finishSeekPreview(); scheduleHide()
  }
  // Lab-only entry: use the shipping seek and fresh-picture checks, with local
  // video-only input. A callback alone can never complete a measurement.
  func runDecodeTrialTargets(_ targets: [Double]) async throws -> [[String: Double]] {
    decodeTrialActive = true; decodeTrialRows = []
    defer { decodeTrialActive = false }
    let deadline = CACurrentMediaTime()+35
    while !startupReady && !closed && CACurrentMediaTime()<deadline {
      try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(30))
    }
    guard startupReady, !closed else { throw NSError(domain: "NeoDecodeTrial", code: 30) }
    for _ in 0..<2 {
      for target in targets.reversed() {
        try Task.checkCancellation()
        let before = decodeTrialRows.count
        seek(to: target)
        let end = CACurrentMediaTime()+13
        while pending != nil && !closed && CACurrentMediaTime()<end {
          try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        guard !closed, decodeTrialRows.count == before+1 else { throw NSError(domain: "NeoDecodeTrial", code: 31) }
      }
    }
    return decodeTrialRows
  }
  func stopDecodeTrial() { shutdown() }
  func seek(to target: Double) {
    guard !closed, let engine, engine.canSeek, target.isFinite else { return }
    let end = engine.duration.isFinite ? max(0, engine.duration-0.1) : 0
    guard end > 0 else { return }
    let target = min(end, max(0, target)), previous = engine.currentTime
    if let pending { NeoPlaybackDiagnostics.record("aether.seekSuperseded", fields: ["targetMs": pending.target*1000]) }
    seekTask?.cancel(); sequence += 1; NeoPlaybackDiagnostics.beginSeek(sequence)
    observedPicture = nil
    pending = PendingSeek(id: sequence, target: target, started: CACurrentMediaTime(),
      previousPictureGeneration: displayedPicture()?.generation ?? lastPictureGeneration,
      previousDecodedGeneration: decodedFrames.latest()?.generation, uiWorkAtStart: uiWorkMs)
    seekTickGapMs = 0; queuedDiagnostic = nil
    if let pending { sampleSeek(pending, phase: "request") }
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
    checkpointTask?.cancel(); checkpointTask = nil
    if let checkpointPlayback {
      checkpointPlayback.stop(); NeoAV1PlaybackBridge.install(nil)
      AetherEngine.setForceSoftwarePathForTesting(false)
    }
    loading?.cancel(); seekTask?.cancel(); probeTask?.cancel(); timer?.invalidate(); timer = nil
    if let output = videoOutput { outputItem?.remove(output) }; outputItem = nil; videoOutput = nil
    diagnosticTask?.cancel(); queuedDiagnostic = nil
    NeoPlaybackDiagnostics.record("aether.uiSummary", fields: ["ticks": uiTicks, "playbackUpdates": playbackUpdates,
      "diagnosticUpdates": diagnosticUpdates, "uiWorkMs": uiWorkMs, "uiThrottled": !uiBaseline])
    hideControls?.cancel(); observedPicture = nil; subscriptions.removeAll(); engine?.stop(); engine = nil; EngineLog.handler = nil
    NotificationCenter.default.removeObserver(self)
    NeoPlaybackDiagnostics.record("aether.closed", fields: [:])
  }
  private func close() {
    shutdown()
    let completion = onClose; onClose = nil
    dismiss(animated: true) { completion?() }
  }
  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning(); checkpointPlayback?.memoryWarning()
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
  private func saveComparisonPicture(_ buffer: CVPixelBuffer, name: String = "aether-comparison-picture.png") {
    guard let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent),
          let data = UIImage(cgImage: image).pngData() else { return }
    try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent(name))
  }
  private func captureSeekPicture(_ index: Int) async {
    // Let the renderer present; this is a functional image check, not a latency
    // timer. Captured buffers are converted only after all measured seeks.
    try? await Task.sleep(for: .milliseconds(80))
    if wantsPlayback { engine?.pause() }
    if let current = displayedPicture() { probePicture = current.buffer }
    if let image = probePicture { seekPictures.append((image, "aether-seek-\(index).png")) }
    if wantsPlayback { engine?.play() }
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
        if let checkpoints = checkpointPlayback, checkpoints.enabled {
          let fillDeadline = CACurrentMediaTime()+25
          while !closed, CACurrentMediaTime()<fillDeadline {
            let state = checkpoints.report()
            if (state["newestMs"] as? Double ?? 0) >= (target-6.5)*1000,
               (state["lookaheadSaved"] as? Int ?? 0) > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
        }
        let count = landedCount; seek(to: target)
        let end = CACurrentMediaTime()+13
        while pending != nil && CACurrentMediaTime()<end { try? await Task.sleep(for: .milliseconds(50)) }
        checks["target\(index)"] = landedCount == count+1
        await captureSeekPicture(index)
        try? await Task.sleep(for: .milliseconds(200))
      }
      wantsPlayback = false; engine?.pause()
      let pausedCount = landedCount; seek(to: 30)
      let pausedDeadline = CACurrentMediaTime()+13
      while pending != nil && CACurrentMediaTime()<pausedDeadline { try? await Task.sleep(for: .milliseconds(50)) }
      checks["pausedSeek"] = landedCount == pausedCount+1 && engine?.state == .paused
      await captureSeekPicture(4)
      if let checkpoints = checkpointPlayback {
        // Match repeated real-player reuse, and force one point-local failure.
        // Both on/off still traverse the same target images and software decoder.
        for (index, target) in [20.0, 40.0, 30.0, 20.0, 40.0, 30.0].enumerated() {
          if checkpoints.enabled && index == 1 { checkpoints.probeRejectNextRestore() }
          let count = landedCount; seek(to: target)
          let end = CACurrentMediaTime()+13
          while pending != nil && CACurrentMediaTime()<end { try? await Task.sleep(for: .milliseconds(50)) }
          checks["reuseTarget\(index)"] = landedCount == count+1 && engine?.state == .paused
          await captureSeekPicture(index+5)
        }
      }
      let sampleDeadline = CACurrentMediaTime()+0.5
      while diagnosticBusy && CACurrentMediaTime()<sampleDeadline { try? await Task.sleep(for: .milliseconds(20)) }
      checks["noFailures"] = failedCount == 0
      checks["targetPictures"] = seekPictures.count == (checkpointPlayback == nil ? 5 : 11)
      if let checkpoints = checkpointPlayback {
        let report = checkpoints.report()
        checks["checkpointBudget"] = (report["heldBytes"] as? Int ?? Int.max) <= NeoCheckpointPlayback.budget
        if checkpoints.enabled {
          checks["checkpointHits"] = (report["hits"] as? Int ?? 0) >= 2
          checks["lookaheadCreated"] = (report["lookaheadSaved"] as? Int ?? 0) > 0
          checks["checkpointNoFallback"] = report["fallback"] as? Bool == false
          checks["checkpointRecovery"] = report["recoveries"] as? Int == 1 && report["rejected"] as? Int == 1
          checks["checkpointHitsAfterRecovery"] = (report["hitsAfterRecovery"] as? Int ?? 0) >= 2
        } else {
          checks["disabledCreatesNothing"] = (report["saved"] as? Int ?? -1) == 0
        }
        checkpoints.updatePosition(200)
        checks["checkpointWindowEviction"] = checkpoints.report()["points"] as? Int == 0
        checkpoints.memoryWarning()
        checks["checkpointMemoryPressure"] = checkpoints.report()["heldBytes"] as? Int == 0
      }
      for (picture, name) in seekPictures { saveComparisonPicture(picture, name: name) }; seekPictures.removeAll()
      if let picture = startupPicture { saveComparisonPicture(picture) }; startupPicture = nil
      shutdown(); checks["closed"] = engine == nil && timer == nil
      NeoPiPSmoke.save("aether-comparison-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
      if let url = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: url) {
        try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("aether-comparison-diagnostics.json"))
      }
    }
  }
#endif
}
