import MetalKit
import UIKit

@objc(NeoCommentOverlay)
final class NeoCommentOverlay: UIView, MTKViewDelegate {
  @objc var timeProvider: (() -> Double)?
  @objc var rateProvider: (() -> Double)?
  @objc var runningProvider: (() -> Bool)?
  @objc var wantsPlaybackProvider: (() -> Bool)?
  @objc var videoHostProvider: (() -> Double)?
  @objc var coveredByPiP = false { didSet { if oldValue != coveredByPiP { clock.reset(); invalidateCanvas(); refreshRendering() } } }
  @objc var onChange: (() -> Void)?
  @objc var videoSize: CGSize = .zero { didSet { if oldValue != videoSize { invalidateCanvas() } } }
  @objc var referenceVideoSize: CGSize = .zero { didSet { if oldValue != referenceVideoSize { invalidateCanvas() } } }
  @objc var expandsToViewport = false { didSet { if oldValue != expandsToViewport { invalidateCanvas() } } }
  private var canvasGeneration = 0, lastCanvasSize = CGSize.zero
  private func invalidateCanvas() { canvasGeneration += 1; lastDrawState = nil; renderer?.seekWindow() }
  override func layoutSubviews() {
    super.layoutSubviews()
    if lastCanvasSize != bounds.size { lastCanvasSize = bounds.size; invalidateCanvas() }
  }
  @objc private(set) var status = "コメントを確認中…"
  @objc private(set) var ready = false
  @objc private(set) var renderedTime = 0.0
  @objc var enabled = true {
    didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); refreshRendering(); finishPreparationIfPossible(); onChange?() }
  }
  private static let enabledKey = "player.comments.enabled", sizeKey = "player.comments.size", opacityKey = "player.comments.absoluteOpacity"
  private(set) var sizeMultiplier = 1.0, opacity: Float = 1
  private(set) var usesSourceOpacity = true
  private(set) var mixedOpacity = false
  private(set) var tracks: [NativeCommentTrack] = []
  private(set) var selectedIndex: Int?
  @objc var initialTrackSelection: NSNumber?
  private var metal: MTKView?
  private var renderer: NeoDanmakuRenderer?
  private var loader: NeoCommentLoader?
  private var usesJikkyo = false
  private var liveMode = false, nextLiveID = 0
  private var task: URLSessionDataTask?
  private var fullTask: URLSessionDataTask?
  private var rawTimeline: CommentTimeline?
  private let timelineQueue = DispatchQueue(label: "neo.comments.timeline", qos: .userInitiated)
  private var fullLoaded = false, windowRequest = 0, contentVersion = 0
  private var previewStart = 0.0, videoDuration = 0.0
  @objc private(set) var preparationStage = "コメント字幕を確認中"
  @objc func updateDuration(_ duration: Double) {
    if duration.isFinite, duration > 0, duration != videoDuration {
      videoDuration = duration
      if let rawTimeline { publish(rawTimeline) }
    }
    if !fullLoaded, ready, task == nil, let track = tracks.first(where: { $0.subtitleIndex == selectedIndex }),
       let time = timeProvider?(), time > previewStart+180 { loadWindow(track, at: time) }
  }
  private var version = 0, closed = false, background = false
  private var timeline: CommentTimeline?
  @objc var panelVersion: Int { contentVersion * 2 + (ready ? 1 : 0) }
  @objc func panelComments() -> [[String: Any]] {
    (timeline?.comments ?? []).map {
      var row: [String:Any] = ["id":$0.id,"time":$0.start,"text":$0.text]
      if let date = $0.postedAt { row["postedAt"] = date }; return row
    }
  }
  @objc static var waitBeforePlayback: Bool {
    get { UserDefaults.standard.bool(forKey: "player.comments.waitBeforePlayback") }
    set { UserDefaults.standard.set(newValue, forKey: "player.comments.waitBeforePlayback") }
  }
  private var settled = false, warming = false, seeking = false, seekVersion = 0
  private var preparationCompletion: (() -> Void)?, preparationTimer: Timer?
  private var clock = CommentPresentationClock()
  private var resumeGate: CommentSeekResumeGate?
  private var seekTarget: Double?
  private var drawn = 0, lastFrame = 0.0, frameCount = 0, fps = 0.0, metricsHost = 0.0
  private let inFlight = DispatchSemaphore(value: 3)
  private var drawDiagnosticHost = 0.0, shortGaps = 0, busyFrames = 0, gpuBackpressure = 0
  private var maxDrawMs = 0.0, maxGapMs = 0.0
  private struct DrawState: Equatable {
    let timeline: UUID, motion: Double, scheduling: Double, viewport: CGSize, fittedVideo: CGSize
    let size: Double, opacity: Float, sourceOpacity: Bool, canDraw: Bool, revision: Int
  }
  private var lastDrawState: DrawState?
  var compositionState: CommentCompositionState {
    CommentCompositionState(timeline: timeline, version: version, enabled: enabled && ready && !closed,
      size: sizeMultiplier, opacity: opacity, usesSourceOpacity: usesSourceOpacity)
  }

  @objc override init(frame: CGRect) {
    super.init(frame: frame)
    let defaults = UserDefaults.standard
    enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    let size = defaults.object(forKey: Self.sizeKey) as? Double ?? 1
    let alpha = defaults.object(forKey: Self.opacityKey) as? Float ?? 1
    sizeMultiplier = size.isFinite ? min(2, max(0.5, size)) : 1
    opacity = alpha.isFinite ? min(1, max(0, alpha)) : 1
    usesSourceOpacity = defaults.object(forKey: Self.opacityKey) == nil
    isUserInteractionEnabled = false; backgroundColor = .clear
    do {
      guard let device = MTLCreateSystemDefaultDevice() else { throw CommentParseError.invalid("Metalデバイス") }
      renderer = try NeoDanmakuRenderer(device: device)
      let view = MTKView(frame: bounds, device: device)
      view.colorPixelFormat = .bgra8Unorm; view.clearColor = MTLClearColorMake(0, 0, 0, 0)
      view.isOpaque = false; view.backgroundColor = .clear
      view.framebufferOnly = true; view.preferredFramesPerSecond = 60
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.delegate = self; view.isPaused = true
      addSubview(view); metal = view
    } catch { status = "Metal描画を開始できません。VLCの字幕表示を利用してください。" }
    // Control/Notification Center only makes the app inactive. Keep rendering
    // there; submitting Metal work must stop only on actual background entry.
    background = UIApplication.shared.applicationState == .background
    NotificationCenter.default.addObserver(self, selector: #selector(didBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(willForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc static func isCommentName(_ value: String) -> Bool { NeoASSComments.isCommentName(value) }

#if targetEnvironment(simulator)
  @objc static func runCanvasChecks() -> [String: Bool] {
    let overlay = NeoCommentOverlay(frame: CGRect(x: 0, y: 0, width: 390, height: 219.375))
    overlay.loadSmokeComments(); let source = overlay.compositionState.timeline!
    overlay.referenceVideoSize = overlay.bounds.size; overlay.layoutIfNeeded()
    let before = overlay.canvasGeneration
    overlay.frame = CGRect(x: 0, y: 0, width: 844, height: 390); overlay.referenceVideoSize = CGSize(width: 750, height: 390)
    overlay.expandsToViewport = true; overlay.layoutIfNeeded()
    let expanded = overlay.displayTimeline(source), wideGeneration = overlay.canvasGeneration
    overlay.coveredByPiP = true; overlay.coveredByPiP = false
    let checks = ["canvasChangesInvalidateOldPreparation": wideGeneration > before && overlay.canvasGeneration > wideGeneration,
      "landscapeLayoutDoesNotMutatePiPSource": overlay.compositionState.timeline?.width == source.width && expanded.width > source.width,
      "landscapeLayoutRetainsCommentIdentity": expanded.identity == source.identity && expanded.comments.map(\.id) == source.comments.map(\.id)]
    overlay.stop(); return checks
  }
  static func runJikkyoSmoke(base: String) {
    Task { @MainActor in
      let overlay = NeoCommentOverlay(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
      overlay.enabled = true; overlay.timeProvider = { 2.5 }
      overlay.configure(source: URL(string: base+"/api/videos/1")!, username: "", password: "", jikkyo: true)
      for _ in 0..<100 {
        if overlay.ready && overlay.fullLoaded { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      let comments = overlay.compositionState.timeline?.comments ?? []
      let checks = ["jsonAPISelected": overlay.tracks.first?.isJikkyo == true,
        "commentsReachSharedRenderer": overlay.ready && comments.count == 3,
        "pipUsesSameTimeline": overlay.compositionState.enabled && comments.first?.style.color.red == 1,
        "fixedAndScrolling": comments.filter { $0.motion != nil }.count == 1 && comments.filter { $0.motion == nil }.count == 2,
        "panelHasComments": overlay.panelComments().count == 3]
      NeoPiPSmoke.save("jikkyo-comments-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
      overlay.stop()
    }
  }
  static func runPreparationSmoke() {
    Task { @MainActor in
      var checks: [String: Bool] = [:]
      let overlay = NeoCommentOverlay(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
      overlay.enabled = true; overlay.loadSmokeComments()
      let testWindow = UIWindow(frame: overlay.bounds); testWindow.addSubview(overlay)
      NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
      checks["inactiveCenterKeepsCommentRendering"] = !overlay.background && overlay.metal?.isPaused == false
      overlay.didBackground()
      checks["actualBackgroundStopsMetal"] = overlay.background && overlay.metal?.isPaused == true
      overlay.willForeground()
      checks["foregroundRestoresRenderingEligibility"] = !overlay.background && overlay.metal?.isPaused == false
      var returned = false
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        overlay.prepareBeforePlayback {
          checks["waitsForLayoutAndTextures"] = returned && overlay.ready && overlay.renderer?.hasPendingImages == false
          continuation.resume()
        }
        returned = true
      }
      overlay.renderedTime = 1
      _ = overlay.clock.time(media: 0.98, running: true, now: 99.98, videoHost: 99.98)
      _ = overlay.clock.time(media: 1, running: true, now: 100, videoHost: 100)
      let preservedClock = overlay.renderedTime
      overlay.endSeek()
      checks["ordinaryPlayDoesNotStartSeekWarmup"] = !overlay.seeking && overlay.resumeGate == nil && overlay.renderedTime == preservedClock
      overlay.renderer?.waitForPreparedImages()
      let oldTimeline = overlay.timeline!, oldRaw = overlay.rawTimeline
      var added = oldTimeline.comments[0]; added.id = 100; added.start = 10; added.end = 15.25
      overlay.rawTimeline = oldTimeline
      overlay.publish(CommentTimeline(width: oldTimeline.width, height: oldTimeline.height, comments: oldTimeline.comments+[added]))
      checks["fullSwapKeepsVisibleIDsAndClock"] = overlay.timeline!.visible(at: 1).map(\.id) == oldTimeline.visible(at: 1).map(\.id) && overlay.renderedTime == preservedClock
        && abs(overlay.clock.time(media: 1, running: true, now: 100.02, videoHost: 100.02)-1.02) < 0.001
      overlay.rawTimeline = oldRaw
      overlay.stop()
      let empty = NeoCommentOverlay(frame: .zero)
      empty.settled = true; empty.timeline = nil
      empty.prepareBeforePlayback { checks["noCommentsBypassesWait"] = true }
      empty.stop()
      let disabled = NeoCommentOverlay(frame: .zero)
      let oldEnabled = disabled.enabled; disabled.enabled = false
      disabled.prepareBeforePlayback { checks["disabledCommentsBypassWait"] = true }
      disabled.enabled = oldEnabled; disabled.stop()
      let pending = NeoCommentOverlay(frame: .zero)
      pending.enabled = true
      pending.prepareBeforePlayback { checks["timeoutStartsPlayback"] = true }
      checks["timeoutIsBoundedTo15Seconds"] = abs((pending.preparationTimer?.fireDate.timeIntervalSinceNow ?? 0)-15) < 1
      pending.preparationTimer?.fire(); pending.stop()
      let cancelled = NeoCommentOverlay(frame: .zero)
      var calledAfterClose = false
      cancelled.prepareBeforePlayback { calledAfterClose = true }; cancelled.stop()
      cancelled.preparationTimer?.fire()
      checks["closingCancelsPendingStart"] = !calledAfterClose
      NeoPiPSmoke.save("comment-preparation-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
    }
  }

  @objc func loadSmokeComments() {
    version += 1; timeline = NeoPiPSmoke.fixture; ready = true; settled = true; status = "Synthetic comments · 80"
    renderer?.prepare(NeoPiPSmoke.fixture.comments); refreshRendering(); onChange?()
  }
  @objc func loadNetworkSmokeComments() {
    version += 1
    let template = NeoPiPSmoke.fixture
    let comments = (0..<180).map { index -> NativeComment in
      var comment = template.comments[index % template.comments.count]
      comment.id = index; comment.start = Double(index); comment.end = Double(index)+5.25
      return comment
    }
    timeline = CommentTimeline(width: template.width, height: template.height, comments: comments)
    ready = true; settled = true; renderer?.prepare(comments); refreshRendering(); onChange?()
  }
#endif

  @objc(configureWithSource:username:password:jikkyo:)
  func configure(source: URL, username: String, password: String, jikkyo: Bool = false) {
    liveMode = false
    guard renderer != nil, !closed else { settled = true; finishPreparationIfPossible(); onChange?(); return }
    loader = NeoCommentLoader(source: source, username: username, password: password)
    usesJikkyo = jikkyo
    loader?.onMetric = { [weak self] event, milliseconds, count in
      NeoPlaybackDiagnostics.record(event, fields: ["durationMs": milliseconds, "count": count])
      if event == "comments.previewFetch" {
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, !self.fullLoaded, self.task != nil else { return }
          self.preparationStage = "コメントを解析中"; self.onChange?()
        }
      }
    }
    reloadTracks()
  }

  @objc func configureLive() {
    version += 1; task?.cancel(); task = nil; fullTask?.cancel(); fullTask = nil; loader = nil
    liveMode = true; nextLiveID = 0; usesJikkyo = true; videoDuration = 0
    rawTimeline = nil; timeline = CommentTimeline(width:1920,height:1080,comments:[])
    tracks = []; selectedIndex = nil; clock.reset(); renderer?.reset(); resumeGate = nil; seeking = false
    ready = true; settled = true; fullLoaded = true; contentVersion += 1
    status = "実況コメントに接続中…"; preparationStage = ""; refreshRendering(); finishPreparationIfPossible(); onChange?()
  }
  @objc func updateLiveStatus(_ value: String) { guard liveMode else { return }; status = value; onChange?() }
  @objc func appendLiveComments(_ rows: [[String:Any]]) {
    guard liveMode, !closed, !rows.isEmpty else { return }
    let value: [String:Any] = ["isSuccess":true,"source":"jikkyo","timeBase":"video","comments":rows]
    guard let data = try? JSONSerialization.data(withJSONObject:value), let parsed = try? NeoCommentLoader.parseJikkyo(data) else { return }
    var comments = (rawTimeline?.comments ?? []).filter { $0.end >= renderedTime-60 }
    for var comment in parsed.comments { comment.id = nextLiveID; nextLiveID += 1; comments.append(comment) }
    if comments.count > 2000 { comments.removeFirst(comments.count-2000) }
    publish(CommentTimeline(width:1920,height:1080,comments:comments))
  }

  func reloadTracks() {
    guard !closed, let loader = loader else { return }
    if initialTrackSelection == nil && selectedIndex == -1 { initialTrackSelection = -1 }
    version += 1; let requestVersion = version
    task?.cancel(); task = nil; fullTask?.cancel(); fullTask = nil
    ready = false; settled = false; timeline = nil; rawTimeline = nil; contentVersion += 1; renderer?.reset(); status = "コメントを確認中…"
    refreshRendering(); onChange?()
    task = loader.tracks(jikkyo: usesJikkyo) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self, !self.closed, self.version == requestVersion else { return }
        switch result {
        case .success(let tracks):
          self.tracks = tracks
          if let requested = self.initialTrackSelection {
            self.initialTrackSelection = nil
            if requested.intValue < 0 { self.selectNone(); return }
            if let track = tracks.first(where: { $0.subtitleIndex == requested.intValue }) {
              NeoPlaybackDiagnostics.record("comments.initialSelection",fields:["index":track.subtitleIndex])
              self.select(track); return
            }
            self.settled = true; self.status = "選択した弾幕を取得できません。"; self.finishPreparationIfPossible(); self.onChange?(); return
          }
          if let first = NeoCommentPreference.preferred(tracks) { self.select(first, remember: false) }
          else { self.settled = true; self.status = "コメント字幕がありません"; self.finishPreparationIfPossible(); self.onChange?() }
        case .failure(let error): self.settled = true; self.status = error.localizedDescription; self.finishPreparationIfPossible(); self.onChange?()
        }
      }
    }
  }

  func select(_ track: NativeCommentTrack, remember: Bool = true) {
    guard !closed, loader != nil else { return }
    if remember { NeoCommentPreference.save(track.displayName) }
    version += 1; contentVersion += 1
    task?.cancel(); fullTask?.cancel(); fullTask = nil
    selectedIndex = track.subtitleIndex; ready = false; settled = false; fullLoaded = false
    rawTimeline = nil; timeline = nil; renderer?.reset(); clock.reset()
    resumeGate = CommentSeekResumeGate()
    loadWindow(track, at: max(0, timeProvider?() ?? 0))
  }
  private func selectNone() {
    version += 1; contentVersion += 1; task?.cancel(); task = nil; fullTask?.cancel(); fullTask = nil
    selectedIndex = -1; rawTimeline = nil; timeline = nil; renderer?.reset(); clock.reset()
    ready = true; settled = true; fullLoaded = true; status = "弾幕なし"; preparationStage = ""
    NeoPlaybackDiagnostics.record("comments.initialSelection",fields:["index":-1])
    refreshRendering(); finishPreparationIfPossible(); onChange?()
  }
  private func sourceOpacity(_ incoming: CommentTimeline) {
    guard usesSourceOpacity, !incoming.comments.isEmpty else { return }
    opacity = Float(incoming.comments.first!.style.color.alpha)
    mixedOpacity = incoming.comments.contains { $0.style.color.alpha != incoming.comments.first!.style.color.alpha }
    if let old = UserDefaults.standard.object(forKey: "player.comments.opacity") as? Float, old.isFinite, old < 1 {
      setOpacity(opacity * max(0, old))
    }
    UserDefaults.standard.removeObject(forKey: "player.comments.opacity")
  }
  private func publish(_ incoming: CommentTimeline, preserveActive: Bool = true) {
    let raw = rawTimeline.map { incoming.preservingIDs(from: $0) } ?? incoming
    var adjusted = renderer?.fittingEnd(raw, duration: videoDuration, size: sizeMultiplier, pixelScale: renderScale) ?? raw
    if preserveActive, let timeline {
      let moving = Dictionary(uniqueKeysWithValues: timeline.visible(at: renderedTime).map { ($0.id, $0) })
      adjusted = CommentTimeline(width: adjusted.width, height: adjusted.height,
        comments: adjusted.comments.map { moving[$0.id] ?? $0 })
    }
    renderer?.replaceTimeline(timeline, at: renderedTime)
    rawTimeline = raw; timeline = adjusted; contentVersion += 1
    // Do not reset clock, seek gate, texture cache or currently assigned lanes.
    refreshRendering(); onChange?()
  }
  private func publishFull(_ incoming: CommentTimeline, version requestVersion: Int) {
    // Reconciliation and rebuilding the full time index must not stall Metal's
    // main-thread draw callback after the preview has started moving.
    let previousRaw = rawTimeline, previous = timeline, revision = contentVersion
    let duration = videoDuration, size = sizeMultiplier, scale = renderScale, renderer = renderer
    let moving = Dictionary(uniqueKeysWithValues: (previous?.visible(at: renderedTime) ?? []).map { ($0.id, $0) })
    timelineQueue.async { [weak self] in
      let began = CACurrentMediaTime()
      let raw = previousRaw.map { incoming.preservingIDs(from: $0) } ?? incoming
      let fitted = renderer?.fittingEnd(raw, duration: duration, size: size, pixelScale: scale) ?? raw
      let adjusted = CommentTimeline(width: fitted.width, height: fitted.height,
        comments: fitted.comments.map { moving[$0.id] ?? $0 })
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed, self.version == requestVersion else { return }
        guard self.contentVersion == revision, self.renderScale == scale else {
          self.publishFull(incoming, version: requestVersion); return
        }
        self.renderer?.replaceTimeline(self.timeline, at: self.renderedTime)
        self.rawTimeline = raw; self.timeline = adjusted; self.contentVersion += 1
        self.sourceOpacity(incoming); self.ready = true; self.settled = true; self.preparationStage = ""
        self.status = "専用描画 · \(incoming.comments.count)件"
        self.finishPreparationIfPossible(); self.refreshRendering(); self.onChange?()
        NeoPlaybackDiagnostics.record("comments.fullSwap", fields: ["media": self.renderedTime,
          "count": incoming.comments.count, "durationMs": (CACurrentMediaTime()-began)*1000])
      }
    }
  }
  private func loadWindow(_ track: NativeCommentTrack, at time: Double) {
    guard !closed, let loader else { return }
    windowRequest += 1; let window = windowRequest, requestVersion = version
    task?.cancel()
    let range = NeoCommentLoader.previewRange(at: time); previewStart = range.startAt
    preparationStage = usesJikkyo ? "実況ログを取得中" : "コメント字幕を抽出・取得中"; status = preparationStage
    refreshRendering(); onChange?()
    task = loader.text(track: track, range: range) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, !self.closed, self.version == requestVersion, self.windowRequest == window, !self.fullLoaded else { return }
        self.task = nil
        switch result {
        case .success(let incoming):
          self.publish(incoming); self.ready = true
          self.sourceOpacity(incoming)
          self.preparationStage = "コメントの配置・文字画像を準備中"; self.status = self.preparationStage
          self.warming = true; self.refreshRendering(); self.onChange?()
          let began = CACurrentMediaTime()
          self.renderer?.warmWindow(self.timeline!, time: time, size: self.sizeMultiplier, pixelScale: self.renderScale,
            opacity: self.usesSourceOpacity ? nil : self.opacity) { [weak self] in
            guard let self, !self.closed, self.version == requestVersion, self.windowRequest == window else { return }
            NeoPlaybackDiagnostics.record("comments.previewWarm", fields: ["durationMs": (CACurrentMediaTime()-began)*1000])
            self.warming = false; self.settled = true; self.preparationStage = ""
            self.status = "専用描画 · \(self.timeline?.comments.count ?? 0)件"
            self.completePreparation(); self.refreshRendering(); self.onChange?()
            self.loadFull(track, version: requestVersion)
          }
        case .failure(let error):
          self.settled = true; self.preparationStage = ""; self.status = error.localizedDescription
          self.finishPreparationIfPossible(); self.onChange?()
          if !self.usesJikkyo { self.loadFull(track, version: requestVersion) }
        }
      }
    }
  }
  private func loadFull(_ track: NativeCommentTrack, version requestVersion: Int) {
    guard !closed, fullTask == nil, !fullLoaded, let loader else { return }
    fullTask = loader.text(track: track) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, !self.closed, self.version == requestVersion else { return }
        self.fullTask = nil
        if case .success(let incoming) = result {
          self.warming = false; self.fullLoaded = true; self.windowRequest += 1; self.task?.cancel(); self.task = nil
          self.publishFull(incoming, version: requestVersion)
        } else {
          // Keep the working preview; following windows can still be requested.
          NeoPlaybackDiagnostics.record("comments.fullFailed", fields: [:])
        }
      }
    }
  }

  private func canvas(_ timeline: CommentTimeline) -> CommentCanvasGeometry {
    let pixels = metal?.contentScaleFactor ?? UIScreen.main.scale
    let viewport = CGSize(width: bounds.width*pixels, height: bounds.height*pixels)
    let reference = CGSize(width: referenceVideoSize.width*pixels, height: referenceVideoSize.height*pixels)
    return CommentCanvasGeometry(viewport: viewport, reference: reference, video: videoSize,
      source: CGSize(width: timeline.width, height: timeline.height), expanded: expandsToViewport)
  }
  private var renderScale: Double { timeline.map { canvas($0).scale } ?? 1 }
  private func displayTimeline(_ source: CommentTimeline) -> CommentTimeline {
    var result = source
    let geometry = canvas(source)
    result.width = Double(geometry.logicalSize.width); result.height = Double(geometry.logicalSize.height)
    return result
  }
  @objc func prepareBeforePlayback(_ completion: @escaping () -> Void) {
    preparationCompletion = completion
    preparationTimer?.invalidate()
    preparationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
      guard let self, !self.closed else { return }
      self.status = "コメントの準備が間に合わないため再生を開始します。"; self.completePreparation(); self.onChange?()
    }
    finishPreparationIfPossible()
  }
  private func completePreparation() {
    preparationTimer?.invalidate(); preparationTimer = nil
    let callback = preparationCompletion; preparationCompletion = nil; warming = false
    callback?()
  }
  private func finishPreparationIfPossible() {
    guard preparationCompletion != nil, !closed, !warming else { return }
    if !enabled || (settled && timeline == nil) { completePreparation(); return }
    guard ready, let timeline, let renderer else { return }
    warming = true; let request = version, layout = canvasGeneration
    renderer.warmWindow(displayTimeline(timeline), time: max(0, timeProvider?() ?? 0), size: sizeMultiplier, pixelScale: renderScale,
      opacity: usesSourceOpacity ? nil : opacity) { [weak self] in
      guard let self, !self.closed else { return }
      self.warming = false
      if self.version == request && self.canvasGeneration == layout { self.completePreparation() } else { self.finishPreparationIfPossible() }
    }
  }
  @objc func beginSeek(_ time: Double) {
    if !fullLoaded, let track = tracks.first(where: { $0.subtitleIndex == selectedIndex }),
       time < previewStart || time > previewStart+210 { loadWindow(track, at: time) }
    seeking = true; seekVersion += 1; seekTarget = max(0, time); resumeGate = CommentSeekResumeGate(); clock.reset(); renderer?.seekWindow(); refreshRendering()
    if let timeline { renderer?.prepareAhead(displayTimeline(timeline), time: time, pixelScale: renderScale*sizeMultiplier, opacity: usesSourceOpacity ? nil : opacity) }
  }
  @objc func endSeek() {
    guard seeking else { return }
    let request = seekVersion, layout = canvasGeneration
    guard let timeline, let renderer, enabled else { seeking = false; clock.reset(); refreshRendering(); return }
    renderer.warmWindow(displayTimeline(timeline), time: seekTarget ?? max(0, timeProvider?() ?? 0), size: sizeMultiplier, pixelScale: renderScale,
      opacity: usesSourceOpacity ? nil : opacity) { [weak self] in
      guard let self, !self.closed, self.seekVersion == request, self.seeking else { return }
      guard self.canvasGeneration == layout else { self.endSeek(); return }
      NeoPlaybackDiagnostics.record("comments.seekClockReset", fields: ["media": self.seekTarget ?? 0])
      self.seeking = false; self.clock.reset(); self.refreshRendering()
    }
  }

  func setSize(_ value: Double) {
    guard value.isFinite else { return }
    sizeMultiplier = min(2, max(0.5, value)); if let rawTimeline { publish(rawTimeline, preserveActive: false) }; UserDefaults.standard.set(sizeMultiplier, forKey: Self.sizeKey); onChange?()
  }
  func setOpacity(_ value: Float) {
    guard value.isFinite else { return }
    opacity = min(1, max(0, value)); usesSourceOpacity = false; mixedOpacity = false
    UserDefaults.standard.set(opacity, forKey: Self.opacityKey); onChange?()
  }
  var diagnostics: String {
    let overflow = timeline.map { renderer?.overflow(timeline: $0, time: timeProvider?() ?? 0) ?? 0 } ?? 0
    return String(format: "描画更新 %.0ffps · 描画 %d件 · キャッシュ %.1f / 48MiB", fps, drawn, Double(renderer?.cachedBytes ?? 0) / 1048576)
      + (overflow > 0 ? " · 重なり回避のため非表示 \(overflow)件" : "")
  }

  @objc func stop() {
    closed = true; version += 1; preparationTimer?.invalidate(); preparationTimer = nil; preparationCompletion = nil; task?.cancel(); task = nil; fullTask?.cancel(); fullTask = nil
    loader?.close(); loader = nil
    metal?.isPaused = true; metal?.delegate = nil
    renderer?.reset(); renderer = nil; timeline = nil
    timeProvider = nil; runningProvider = nil; wantsPlaybackProvider = nil; rateProvider = nil; videoHostProvider = nil; onChange = nil
    NotificationCenter.default.removeObserver(self)
  }
  deinit { loader?.close(); NotificationCenter.default.removeObserver(self) }

  @objc private func didBackground() { background = true; refreshRendering() }
  @objc private func willForeground() { background = false; clock.reset(); renderer?.seekWindow(); refreshRendering() }
  override func didMoveToWindow() { super.didMoveToWindow(); refreshRendering() }
  private func refreshRendering() {
    let show = enabled && ready && !warming && !closed && !seeking
    metal?.isHidden = !show
    metal?.isPaused = !show || background || coveredByPiP || window == nil
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard enabled, ready, !background, !coveredByPiP, !closed, !seeking, let timeline = timeline, let renderer = renderer else { return }
    if let error = renderer.error {
      ready = false; status = error; refreshRendering(); onChange?(); return
    }
    let now = CACurrentMediaTime()
    defer {
      let work = (CACurrentMediaTime()-now)*1000
      maxDrawMs = max(maxDrawMs, work)
      if work > 8 { busyFrames += 1 }
      if now-drawDiagnosticHost >= 1 {
        if shortGaps > 0 || busyFrames > 0 || gpuBackpressure > 0 {
          NeoPlaybackDiagnostics.record("comments.frameWork", fields: ["maxWorkMs": maxDrawMs, "maxGapMs": maxGapMs,
            "shortGaps": shortGaps, "busyFrames": busyFrames, "gpuBackpressure": gpuBackpressure, "media": renderedTime])
        }
        drawDiagnosticHost = now; maxDrawMs = 0; maxGapMs = 0; shortGaps = 0; busyFrames = 0; gpuBackpressure = 0
      }
    }
    if lastFrame > 0, now-lastFrame > 1.8/Double(max(1, view.preferredFramesPerSecond)), runningProvider?() == true {
      shortGaps += 1; maxGapMs = max(maxGapMs, (now-lastFrame)*1000)
    }
    if lastFrame > 0, now-lastFrame > 0.08, runningProvider?() == true {
      NeoPlaybackDiagnostics.record("comments.drawGap", fields: ["durationMs": (now-lastFrame)*1000, "media": renderedTime])
    }
    lastFrame = now
    if lastFrame == 0 { lastFrame = now }
    let media = timeProvider?() ?? 0, running = runningProvider?() ?? false
    var canDraw = true
    if var gate = resumeGate {
      canDraw = gate.allows(media: media, running: running, wantsPlayback: wantsPlaybackProvider?() ?? running)
      resumeGate = canDraw ? nil : gate
      if canDraw { seekTarget = nil }
      clock.reset()
    }
    let wasAnchored = clock.ready
    let time = clock.time(media: media, running: running, now: now, rate: rateProvider?() ?? 1)
    if !wasAnchored && clock.ready {
      NeoPlaybackDiagnostics.record("comments.initialAnchor", fields: ["media": media, "motion": time])
    }
    renderedTime = time
    let viewport = view.drawableSize, geometry = canvas(timeline)
    let drawing = displayTimeline(timeline), pixelScale = geometry.scale
    canDraw = canDraw && (clock.ready || !(wantsPlaybackProvider?() ?? running))
    renderer.prepareAhead(drawing, time: canDraw ? clock.schedulingTime : seekTarget ?? media, pixelScale: pixelScale*sizeMultiplier, opacity: usesSourceOpacity ? nil : opacity)
    let state = DrawState(timeline: timeline.identity, motion: time, scheduling: clock.schedulingTime, viewport: viewport,
      fittedVideo: CGSize(width: timeline.width*pixelScale, height: timeline.height*pixelScale),
      size: sizeMultiplier, opacity: opacity, sourceOpacity: usesSourceOpacity, canDraw: canDraw, revision: renderer.visualRevision)
    // Preparation and explicit pause often yield identical frames. Keep the
    // last presented texture instead of blocking the main thread for another
    // drawable. Moving comments (also under system overlays) change motion on
    // every tick; glyph arrival, seek, size, track and opacity invalidate this.
    if lastDrawState == state { return }
    guard inFlight.wait(timeout: .now()) == .success else { gpuBackpressure += 1; return }
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
      let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
    drawn = canDraw ? renderer.encode(timeline: drawing, time: time, viewport: viewport,
      videoRect: geometry.rect,
      sizeMultiplier: sizeMultiplier, opacity: opacity, pixelScale: pixelScale, usesSourceOpacity: usesSourceOpacity,
      schedulingTime: clock.schedulingTime, sourceSize: CGSize(width: timeline.width, height: timeline.height), encoder: encoder) : 0
    let completion = inFlight
    command.addCompletedHandler { _ in completion.signal() }
    encoder.endEncoding(); command.present(drawable); command.commit()
    lastDrawState = state
    frameCount += 1
    if now - metricsHost >= 1 { fps = Double(frameCount) / (now - metricsHost); frameCount = 0; metricsHost = now }
  }

}
