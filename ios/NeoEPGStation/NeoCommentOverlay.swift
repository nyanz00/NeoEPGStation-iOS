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
    didSet { refreshRendering(); onChange?() }
  }
  private(set) var sizeMultiplier = 1.0, opacity: Float = 1
  private(set) var tracks: [NativeCommentTrack] = []
  private(set) var selectedIndex: Int?
  private var metal: MTKView?
  private var renderer: NeoDanmakuRenderer?
  private var loader: NeoCommentLoader?
  private var task: URLSessionDataTask?
  private var version = 0, closed = false, background = false
  private var timeline: CommentTimeline?
  private var clock = CommentPlaybackClock()
  private var drawn = 0, lastFrame = 0.0, frameCount = 0, fps = 0.0
  private let inFlight = DispatchSemaphore(value: 3)

  @objc override init(frame: CGRect) {
    super.init(frame: frame)
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
    NotificationCenter.default.addObserver(self, selector: #selector(didBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(willForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc static func isCommentName(_ value: String) -> Bool { NeoASSComments.isCommentName(value) }

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
          else { self.status = "NicoJKのASSコメントがありません。"; self.onChange?() }
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
          self.status = "専用描画 · \(timeline.comments.count)件"
          self.renderer?.prepare(timeline.visible(at: self.timeProvider?() ?? 0, lookAhead: 1))
          self.refreshRendering(); self.onChange?()
        case .failure(let error): self.status = error.localizedDescription; self.onChange?()
        }
      }
    }
  }

  func setSize(_ value: Double) { sizeMultiplier = min(2, max(0.5, value)) }
  func setOpacity(_ value: Float) { opacity = min(1, max(0, value)) }
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
    renderer.prepare(timeline.visible(at: time, lookAhead: 1), pixelScale: pixelScale)
    guard inFlight.wait(timeout: .now()) == .success else { return }
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
      let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
    drawn = renderer.encode(timeline: timeline, time: time, viewport: viewport,
      videoRect: CGRect(x: (viewport.width - fittedWidth) / 2, y: (viewport.height - fittedHeight) / 2, width: fittedWidth, height: fittedHeight),
      sizeMultiplier: sizeMultiplier, opacity: opacity, pixelScale: pixelScale, encoder: encoder)
    let completion = inFlight
    command.addCompletedHandler { _ in completion.signal() }
    encoder.endEncoding(); command.present(drawable); command.commit()
    frameCount += 1
    if now - lastFrame >= 1 { fps = Double(frameCount) / (now - lastFrame); frameCount = 0; lastFrame = now }
  }

  @objc func makeSettingsController() -> UIViewController {
    let controller = NeoCommentSettings(overlay: self)
    controller.modalPresentationStyle = .pageSheet
    controller.sheetPresentationController?.detents = [.medium(), .large()]
    return controller
  }
}

private final class NeoCommentSettings: UIViewController {
  private let overlay: NeoCommentOverlay
  private let status = UILabel(), diagnostics = UILabel()
  private let toggle = UISwitch(), sizeSlider = UISlider(), opacitySlider = UISlider()
  private let sizeLabel = UILabel(), opacityLabel = UILabel(), trackButtons = UIStackView()
  private var timer: Timer?
  init(overlay: NeoCommentOverlay) { self.overlay = overlay; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .systemBackground
    let title = UILabel(); title.text = "コメント描画"; title.font = .preferredFont(forTextStyle: .headline)
    let close = UIButton(type: .system); close.setTitle("閉じる", for: .normal); close.addTarget(self, action: #selector(close), for: .touchUpInside)
    let header = UIStackView(arrangedSubviews: [title, close]); header.distribution = .equalSpacing
    status.numberOfLines = 0; diagnostics.font = .preferredFont(forTextStyle: .caption1); diagnostics.numberOfLines = 0
    let label = UILabel(); label.text = "専用コメント描画"
    let toggleRow = UIStackView(arrangedSubviews: [label, toggle]); toggleRow.distribution = .equalSpacing
    toggle.isOn = overlay.enabled; toggle.addTarget(self, action: #selector(changeToggle), for: .valueChanged)
    sizeSlider.minimumValue = 0.5; sizeSlider.maximumValue = 2; sizeSlider.value = Float(overlay.sizeMultiplier)
    sizeSlider.addTarget(self, action: #selector(changeSize), for: .valueChanged)
    opacitySlider.minimumValue = 0; opacitySlider.maximumValue = 1; opacitySlider.value = overlay.opacity
    opacitySlider.addTarget(self, action: #selector(changeOpacity), for: .valueChanged)
    let retry = UIButton(type: .system); retry.setTitle("コメントを再読み込み", for: .normal); retry.addTarget(self, action: #selector(reload), for: .touchUpInside)
    let note = UILabel(); note.text = "この試作の専用コメント描画は通常画面用です。PiPのコメント合成はまだ未実装です。"; note.numberOfLines = 0; note.font = .preferredFont(forTextStyle: .footnote)
    trackButtons.axis = .vertical; trackButtons.spacing = 6
    let content = UIStackView(arrangedSubviews: [header, status, toggleRow, sizeLabel, sizeSlider, opacityLabel, opacitySlider, diagnostics, trackButtons, retry, note])
    content.axis = .vertical; content.spacing = 10; content.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll); scroll.addSubview(content)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
      content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
    ])
    changeSize(); changeOpacity(); refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
  }
  override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
  deinit { timer?.invalidate() }
  @objc private func close() { dismiss(animated: true) }
  @objc private func changeToggle() { overlay.enabled = toggle.isOn }
  @objc private func changeSize() { overlay.setSize(Double(sizeSlider.value)); sizeLabel.text = String(format: "文字サイズ %.2f倍", sizeSlider.value) }
  @objc private func changeOpacity() { overlay.setOpacity(opacitySlider.value); opacityLabel.text = "不透明度 \(Int(opacitySlider.value * 100))%" }
  @objc private func reload() { overlay.reloadTracks(); refresh() }
  private func refresh() {
    status.text = overlay.status; diagnostics.text = overlay.diagnostics; toggle.isOn = overlay.enabled
    let identifiers = overlay.tracks.map { String($0.subtitleIndex) }.joined(separator: ",")
    if trackButtons.accessibilityIdentifier != identifiers {
      trackButtons.arrangedSubviews.forEach { trackButtons.removeArrangedSubview($0); $0.removeFromSuperview() }
      for track in overlay.tracks {
        let button = UIButton(type: .system)
        button.setTitle(track.displayName, for: .normal)
        button.addAction(UIAction { [weak overlay = self.overlay] _ in overlay?.select(track) }, for: .touchUpInside)
        trackButtons.addArrangedSubview(button)
      }
      trackButtons.accessibilityIdentifier = identifiers
    }
  }
}
