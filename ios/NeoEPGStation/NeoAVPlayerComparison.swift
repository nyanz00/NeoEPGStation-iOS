import UIKit
import AVFoundation
import CoreImage
import VideoToolbox

// Encoded PLAY comparison only: the server supplies its WebKit-compatible MP4.
// No local muxer, loopback server, comment preparation or history writes.
@MainActor
final class NeoAVPlayerComparison: UIViewController {
  var onClose: (() -> Void)?
  private let source: URL, recordingTitle: String, context: [String: Any]
  private lazy var chrome = NeoPlayerChrome(title: recordingTitle)
  private var player: AVPlayer?
  private let layer = AVPlayerLayer()
  private var output: AVPlayerItemVideoOutput?
  private var timer: Timer?, hideControls: DispatchWorkItem?, probeTask: Task<Void, Never>?
  private var closed = false, startupReady = false, failed = false, scrubbing = false
  private var wantsPlayback = true, resumeAfterBackground = false, landscape = false, audioActive = false
  private var openedAt = 0.0, sequence = 0, landedCount = 0
  private var lastTransport = "", observedPicture: Picture?
  private var pending: PendingSeek?
  private struct Picture { let seconds: Double; let buffer: CVPixelBuffer }
  private struct PendingSeek { let id: Int, target: Double, started: Double; var completed = false }
#if targetEnvironment(simulator)
  private var startupPicture: CVPixelBuffer?, seekPictures: [CVPixelBuffer] = []
#endif
  init(url: URL, title: String, context: [String: Any] = [:]) {
    source = url; recordingTitle = title; self.context = context
    super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError() }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { landscape ? .landscape : .portrait }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .black
    chrome.frame = view.bounds; chrome.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(chrome); chrome.configure(context); chrome.configureEngineComparison()
    chrome.onAction = { [weak self] in self?.perform($0) }
    chrome.videoView.layer.addSublayer(layer); layer.videoGravity = .resizeAspect
    chrome.onVideoLayout = { [weak self] in self?.layoutVideo() }
    chrome.updateLoading("準備中…"); chrome.showControls(true)
    NeoPlaybackDiagnostics.begin(); openedAt = CACurrentMediaTime()
    NeoPlaybackDiagnostics.record("player.engine", fields: ["engine": "avplayer-direct", "initialMs": 0])
    NeoPlaybackDiagnostics.record("avplayer.source", fields: ["serverRemux": true,
      "av1HardwareSupported": VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)])
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback); try audio.setActive(true); audioActive = true
    } catch { fail("audio-session", code: (error as NSError).code); return }
    let item = AVPlayerItem(asset: AVURLAsset(url: source))
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output); self.output = output
    let player = AVPlayer(playerItem: item); self.player = player; layer.player = player
    // Keep Apple's default buffering policy for the initial engine comparison.
    NotificationCenter.default.addObserver(self, selector: #selector(ended), name: .AVPlayerItemDidPlayToEndTime, object: item)
    NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    player.play()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); chrome.frame = view.bounds; chrome.layoutIfNeeded(); layoutVideo()
  }
  private func layoutVideo() {
    CATransaction.begin(); CATransaction.setDisableActions(true); layer.frame = chrome.videoView.bounds; CATransaction.commit()
  }
  private var duration: Double {
    let value = player?.currentItem?.duration.seconds ?? 0; return value.isFinite ? max(0, value) : 0
  }
  private var position: Double {
    let value = player?.currentTime().seconds ?? 0; return value.isFinite ? max(0, value) : 0
  }
  private func perform(_ action: String) {
    switch action {
    case "back": close()
    case "play":
      guard !failed else { return }; wantsPlayback.toggle()
      if wantsPlayback { player?.play() } else { player?.pause() }; scheduleHide()
    case "rotate":
      landscape.toggle(); setNeedsUpdateOfSupportedInterfaceOrientations()
      view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations))
    case "toggle-controls": chrome.showControls(!chrome.controlsVisible); scheduleHide()
    case "interaction": chrome.showControls(true); scheduleHide()
    case "scrub-begin": scrubbing = true
    case "scrub-end": scrubbing = false; seek(to: Double(chrome.timeline.value)*duration)
    case "scrub-cancel": scrubbing = false
    case "export-diagnostics": exportLog()
    default:
      if action.hasPrefix("jump:"), let seconds = Double(action.dropFirst(5)) {
        seek(to: (pending?.target ?? position)+seconds)
      }
    }
  }
  private func scheduleHide() {
    hideControls?.cancel()
    let task = DispatchWorkItem { [weak self] in
      guard let self, self.wantsPlayback, self.pending == nil, !self.chrome.interactionOpen, !self.failed else { return }
      self.chrome.showControls(false)
    }
    hideControls = task; DispatchQueue.main.asyncAfter(deadline: .now()+3, execute: task)
  }
  private func picture() -> Picture? {
    guard layer.isReadyForDisplay, let player, let output else { return nil }
    let time = player.currentTime(); var shown = CMTime.invalid
    guard output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &shown), shown.isNumeric else { return nil }
    return Picture(seconds: shown.seconds, buffer: buffer)
  }
  private func transportFields() -> [String: Any] {
    guard let player, let item = player.currentItem else { return [:] }
    let ahead = item.loadedTimeRanges.map { $0.timeRangeValue }.filter {
      $0.start.seconds <= position+0.05 && $0.end.seconds >= position
    }.map { max(0, $0.end.seconds-position) }.max() ?? 0
    let reason = player.reasonForWaitingToPlay == .toMinimizeStalls ? "minimizeStalls" :
      player.reasonForWaitingToPlay == .evaluatingBufferingRate ? "evaluating" : "other"
    return ["timeControl": player.timeControlStatus.rawValue, "waitingReason": reason,
      "bufferAheadMs": ahead.isFinite ? ahead*1000 : 0, "bufferEmpty": item.isPlaybackBufferEmpty,
      "likelyToKeepUp": item.isPlaybackLikelyToKeepUp]
  }
  private func tick() {
    guard !closed, !failed, let player, let item = player.currentItem else { return }
    if item.status == .failed || player.status == .failed {
      fail("playback", code: ((item.error ?? player.error) as NSError?)?.code ?? 0); return
    }
    let size = item.presentationSize
    if size.width > 0 && size.height > 0, abs(chrome.videoAspectRatio-size.width/size.height) > 0.001 {
      chrome.videoAspectRatio = size.width/size.height; chrome.setNeedsLayout()
    }
    let fields = transportFields(), state = "\(player.timeControlStatus.rawValue):\(fields["waitingReason"] ?? "")"
    if state != lastTransport { lastTransport = state; NeoPlaybackDiagnostics.record("avplayer.transport", fields: fields) }
    if !scrubbing { chrome.timeline.value = duration > 0 ? Float(position/duration) : 0 }
    chrome.timeline.isEnabled = startupReady && duration > 0
    chrome.updatePlayback(wantsPlayback, current: Int64(position), duration: Int64(duration)); chrome.updateDiagnostics()
    if !startupReady || pending != nil, let frame = picture() {
      if !startupReady {
        startupReady = true; chrome.updateLoading(nil); scheduleHide()
        NeoPlaybackDiagnostics.record("avplayer.startupReady", fields: ["durationMs": (CACurrentMediaTime()-openedAt)*1000,
          "pictureMs": frame.seconds*1000, "verification": "nativePixelBuffer"])
#if targetEnvironment(simulator)
        startupPicture = frame.buffer
#endif
      }
      if pending != nil { observedPicture = frame }
    }
    if let pending, pending.completed, let frame = observedPicture, abs(frame.seconds-pending.target) < 0.5 {
      var resume = fields
      resume.merge(["engine": "avplayer-direct", "durationMs": (CACurrentMediaTime()-pending.started)*1000,
        "targetMs": pending.target*1000, "mediaMs": frame.seconds*1000, "verification": "nativePixelBuffer"]) { _, new in new }
      NeoPlaybackDiagnostics.record("seek.videoResume", fields: resume); landedCount += 1
#if targetEnvironment(simulator)
      seekPictures.append(frame.buffer)
#endif
      self.pending = nil; observedPicture = nil; chrome.finishSeekPreview(); scheduleHide()
    }
    if let pending, CACurrentMediaTime()-pending.started > 12 {
      NeoPlaybackDiagnostics.record("seek.timeout", fields: ["engine": "avplayer-direct", "targetMs": pending.target*1000])
      fail("seek-timeout")
    }
    if !startupReady && CACurrentMediaTime()-openedAt > 90 { fail("first-picture-timeout") }
  }
  private func seek(to requested: Double) {
    guard !closed, !failed, startupReady, duration > 0, requested.isFinite, let player else { return }
    let target = min(max(0, requested), max(0, duration-0.1)), previous = position
    if let pending { NeoPlaybackDiagnostics.record("avplayer.seekSuperseded", fields: ["targetMs": pending.target*1000]) }
    sequence += 1; let id = sequence; NeoPlaybackDiagnostics.beginSeek(id)
    observedPicture = nil
    pending = PendingSeek(id: id, target: target, started: CACurrentMediaTime())
    chrome.previewSeek(Int64(target)); chrome.showControls(true)
    var fields = transportFields(); fields.merge(["engine": "avplayer-direct", "fromMs": previous*1000, "targetMs": target*1000]) { _, new in new }
    NeoPlaybackDiagnostics.record("seek.start", fields: fields)
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard let self, !self.closed, var current = self.pending, current.id == id else { return }
        NeoPlaybackDiagnostics.record("avplayer.seekCompleted", fields: ["finished": finished,
          "targetMs": target*1000, "clockMs": self.position*1000, "durationMs": (CACurrentMediaTime()-current.started)*1000])
        guard finished else { self.fail("seek-interrupted"); return }
        current.completed = true; self.pending = current
      }
    }
  }
  private func fail(_ stage: String, code: Int = 0) {
    guard !failed, !closed else { return }; failed = true; player?.pause(); wantsPlayback = false
    pending = nil; observedPicture = nil; chrome.finishSeekPreview(); chrome.updateLoading(nil)
    chrome.statusLabel.text = "再生できませんでした。標準の再生エンジンでお試しください。"; chrome.showControls(true)
    NeoPlaybackDiagnostics.record("avplayer.failure", fields: ["stage": stage, "code": code])
  }
  @objc private func ended() { wantsPlayback = false; chrome.showControls(true) }
  @objc private func background() { resumeAfterBackground = wantsPlayback; player?.pause() }
  @objc private func foreground() {
    if resumeAfterBackground && wantsPlayback && !closed && !failed { player?.play() }; resumeAfterBackground = false
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
    timer?.invalidate(); timer = nil; hideControls?.cancel(); probeTask?.cancel()
    player?.pause(); player?.currentItem?.cancelPendingSeeks()
    if let output { player?.currentItem?.remove(output) }; output = nil
    player?.replaceCurrentItem(with: nil); layer.player = nil; player = nil; pending = nil; observedPicture = nil
    if audioActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); audioActive = false }
    NotificationCenter.default.removeObserver(self); NeoPlaybackDiagnostics.record("avplayer.closed", fields: [:])
  }
  private func close() { shutdown(); let completion = onClose; onClose = nil; dismiss(animated: true) { completion?() } }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated); if isBeingDismissed || presentingViewController == nil { shutdown() }
  }
#if targetEnvironment(simulator)
  func runComparisonProbe() {
    probeTask = Task { [weak self] in
      guard let self else { return }
      let deadline = CACurrentMediaTime()+30
      while !startupReady && !failed && CACurrentMediaTime()<deadline { try? await Task.sleep(for: .milliseconds(100)) }
      var checks = ["startupVideo": startupReady, "seekable": duration > 0, "productionChrome": chrome.comparisonControlsSealed()]
      for (index, target) in [20.0, 40.0, 30.0, 20.0, 30.0].enumerated() {
        if index == 4 { wantsPlayback = false; player?.pause() }
        let count = landedCount; seek(to: target); let end = CACurrentMediaTime()+13
        while pending != nil && CACurrentMediaTime()<end { try? await Task.sleep(for: .milliseconds(50)) }
        checks["target\(index)"] = landedCount == count+1
      }
      checks["pausedSeek"] = player?.rate == 0 && !wantsPlayback && pending == nil
      checks["noFailures"] = !failed; checks["targetPictures"] = seekPictures.count == 5
      // Convert only after all timing measurements; never compile image shaders inside a seek.
      let images = seekPictures; seekPictures.removeAll()
      for (index, image) in images.enumerated() { savePicture(image, name: "avplayer-seek-\(index).png") }
      if let image = startupPicture { savePicture(image, name: "avplayer-startup.png") }; startupPicture = nil
      shutdown(); checks["closed"] = player == nil && timer == nil
      NeoPiPSmoke.save("avplayer-comparison-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
      if let url = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: url) {
        try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("avplayer-comparison-diagnostics.json"))
      }
    }
  }
  private func savePicture(_ buffer: CVPixelBuffer, name: String) {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cg = CIContext().createCGImage(image, from: image.extent), let data = UIImage(cgImage: cg).pngData() else { return }
    try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent(name))
  }
#endif
}
