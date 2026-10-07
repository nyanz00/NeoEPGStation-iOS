import MetalKit
import UIKit

@objc(NeoCommentOverlay)
final class NeoCommentOverlay: UIView, MTKViewDelegate {
  @objc var timeProvider: (() -> Double)?
  @objc var runningProvider: (() -> Bool)?
  @objc var onChange: (() -> Void)?
  @objc var videoSize: CGSize = .zero
  @objc private(set) var status = "コメントを確認中…"
  @objc private(set) var ready = false
  @objc var enabled = true {
    didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); refreshRendering(); onChange?() }
  }
  private static let enabledKey = "player.comments.enabled", sizeKey = "player.comments.size", opacityKey = "player.comments.absoluteOpacity"
  private(set) var sizeMultiplier = 1.0, opacity: Float = 1
  private(set) var usesSourceOpacity = true
  private(set) var mixedOpacity = false
  private(set) var tracks: [NativeCommentTrack] = []
  private(set) var selectedIndex: Int?
  private var metal: MTKView?
  private var renderer: NeoDanmakuRenderer?
  private var loader: NeoCommentLoader?
  private var task: URLSessionDataTask?
  private var version = 0, closed = false, background = false
  private var timeline: CommentTimeline?
  @objc var panelVersion: Int { version * 2 + (ready ? 1 : 0) }
  @objc func panelComments() -> [[String: Any]] {
    (timeline?.comments ?? []).map { ["time": $0.start, "text": $0.text] }
  }
  private var clock = CommentPlaybackClock()
  private var drawn = 0, lastFrame = 0.0, frameCount = 0, fps = 0.0
  private let inFlight = DispatchSemaphore(value: 3)
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
    NotificationCenter.default.addObserver(self, selector: #selector(didBackground), name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(willForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc static func isCommentName(_ value: String) -> Bool { NeoASSComments.isCommentName(value) }

#if targetEnvironment(simulator)
  @objc func loadSmokeComments() {
    version += 1; timeline = NeoPiPSmoke.fixture; ready = true; status = "Synthetic comments · 80"
    renderer?.prepare(NeoPiPSmoke.fixture.comments); refreshRendering(); onChange?()
  }
#endif

  @objc(configureWithSource:username:password:)
  func configure(source: URL, username: String, password: String) {
    guard renderer != nil, !closed else { onChange?(); return }
    loader = NeoCommentLoader(source: source, username: username, password: password)
    reloadTracks()
  }

  func reloadTracks() {
    guard !closed, let loader = loader else { return }
    version += 1; let requestVersion = version
    task?.cancel(); task = nil
    ready = false; timeline = nil; renderer?.reset(); status = "コメントを確認中…"
    refreshRendering(); onChange?()
    task = loader.tracks { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self, !self.closed, self.version == requestVersion else { return }
        switch result {
        case .success(let tracks):
          self.tracks = tracks
          if let first = tracks.first { self.select(first) }
          else { self.status = "コメント字幕がありません"; self.onChange?() }
        case .failure(let error): self.status = error.localizedDescription; self.onChange?()
        }
      }
    }
  }

  func select(_ track: NativeCommentTrack) {
    guard !closed, let loader = loader else { return }
    version += 1; let requestVersion = version
    task?.cancel(); task = nil
    selectedIndex = track.subtitleIndex; ready = false; timeline = nil
    renderer?.reset(); status = "ASSコメントを読み込み中…"
    refreshRendering(); onChange?()
    task = loader.text(track: track) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self, !self.closed, self.version == requestVersion else { return }
        switch result {
        case .success(let timeline):
          self.timeline = timeline; self.ready = true
          if self.usesSourceOpacity {
            let values = Set(timeline.comments.map { $0.style.color.alpha })
            self.opacity = Float(timeline.comments.first?.style.color.alpha ?? 1)
            self.mixedOpacity = values.count > 1
            // Migrate an intentionally reduced old multiplier without turning
            // its default 100% into a new fully-opaque preference.
            if let old = UserDefaults.standard.object(forKey: "player.comments.opacity") as? Float, old.isFinite, old < 1 {
              self.setOpacity(self.opacity * max(0, old))
            }
            UserDefaults.standard.removeObject(forKey: "player.comments.opacity")
          }
          self.status = "専用描画 · \(timeline.comments.count)件"
          self.renderer?.prepare(timeline.visible(at: self.timeProvider?() ?? 0, lookAhead: 1), absoluteOpacity: self.usesSourceOpacity ? nil : self.opacity)
          self.renderer?.prepareLayout(timeline, size: self.sizeMultiplier)
          self.refreshRendering(); self.onChange?()
        case .failure(let error): self.status = error.localizedDescription; self.onChange?()
        }
      }
    }
  }

  func setSize(_ value: Double) {
    guard value.isFinite else { return }
    sizeMultiplier = min(2, max(0.5, value)); UserDefaults.standard.set(sizeMultiplier, forKey: Self.sizeKey); onChange?()
  }
  func setOpacity(_ value: Float) {
    guard value.isFinite else { return }
    opacity = min(1, max(0, value)); usesSourceOpacity = false; mixedOpacity = false
    UserDefaults.standard.set(opacity, forKey: Self.opacityKey); onChange?()
  }
  var diagnostics: String { String(format: "描画更新 %.0ffps · 描画 %d件 · キャッシュ %.1f / 48MiB", fps, drawn, Double(renderer?.cachedBytes ?? 0) / 1048576) }

  @objc func stop() {
    closed = true; version += 1; task?.cancel(); task = nil
    loader?.close(); loader = nil
    metal?.isPaused = true; metal?.delegate = nil
    renderer?.reset(); renderer = nil; timeline = nil
    timeProvider = nil; runningProvider = nil; onChange = nil
    NotificationCenter.default.removeObserver(self)
  }
  deinit { loader?.close(); NotificationCenter.default.removeObserver(self) }

  @objc private func didBackground() { background = true; refreshRendering() }
  @objc private func willForeground() { background = false; refreshRendering() }
  override func didMoveToWindow() { super.didMoveToWindow(); refreshRendering() }
  private func refreshRendering() {
    let show = enabled && ready && !closed
    metal?.isHidden = !show
    metal?.isPaused = !show || background || window == nil
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard enabled, ready, !background, !closed, let timeline = timeline, let renderer = renderer else { return }
    if let error = renderer.error {
      ready = false; status = error; refreshRendering(); onChange?(); return
    }
    let now = CACurrentMediaTime()
    if lastFrame == 0 { lastFrame = now }
    let time = clock.time(media: timeProvider?() ?? 0, running: runningProvider?() ?? false, now: now)
    let viewport = view.drawableSize
    let ratio = videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : CGFloat(timeline.width / timeline.height)
    let fittedWidth = min(viewport.width, viewport.height * ratio), fittedHeight = fittedWidth / ratio
    let pixelScale = max(Double(fittedWidth) / timeline.width, Double(fittedHeight) / timeline.height)
    renderer.prepare(timeline.visible(at: time, lookAhead: 1), pixelScale: pixelScale, absoluteOpacity: usesSourceOpacity ? nil : opacity)
    renderer.prepareLayout(timeline, size: sizeMultiplier)
    guard inFlight.wait(timeout: .now()) == .success else { return }
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
      let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
    drawn = renderer.encode(timeline: timeline, time: time, viewport: viewport,
      videoRect: CGRect(x: (viewport.width - fittedWidth) / 2, y: (viewport.height - fittedHeight) / 2, width: fittedWidth, height: fittedHeight),
      sizeMultiplier: sizeMultiplier, opacity: opacity, pixelScale: pixelScale, usesSourceOpacity: usesSourceOpacity, encoder: encoder)
    let completion = inFlight
    command.addCompletedHandler { _ in completion.signal() }
    encoder.endEncoding(); command.present(drawable); command.commit()
    frameCount += 1
    if now - lastFrame >= 1 { fps = Double(frameCount) / (now - lastFrame); frameCount = 0; lastFrame = now }
  }

}
