import UIKit

// UIKit controls stay independent of VLC's drawable and native playback clock.
@objc(NeoPlayerChrome)
final class NeoPlayerChrome: UIView, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
  @objc let videoView = UIView()
  @objc let header = UIView(), controls = UIView(), centerControls = UIView()
  @objc let statusLabel = NeoStyle.label(size: 12), commentLabel = NeoStyle.label(size: 12)
  @objc let timeLabel = NeoStyle.label(size: 13)
  @objc let timeline: UISlider = NeoPlayerSeekSlider()
  @objc let playButton = UIButton(type: .system), pipButton = UIButton(type: .system)
  @objc let subtitleButton = UIButton(type: .system), commentButton = UIButton(type: .system)
  @objc var onAction: ((String) -> Void)?
  @objc private(set) var commentVersion = -1
  @objc private(set) var panelOpen = false
  @objc var autoHide = true
  private let logo = UIImageView(), channel = NeoStyle.label(size: 11), title = NeoStyle.label(size: 15, bold: true)
  private let leftHeader = UIView(), rightHeader = UIView(), videoDim = UIView()
  private let videoTap = UITapGestureRecognizer()
  private let navigationPan = UIPanGestureRecognizer()
  private var navigationStart = CGPoint.zero, navigationAction: NeoSwipeAction?
  private weak var navigationScroll: UIScrollView?
  private var navigationScrollEnabled = false
  private var settingsCategory = "general"
  private weak var commentOverlay: NeoCommentOverlay?
  private var subtitleTracks: [[String: Any]] = []
  private let commentToggle = UISwitch(), commentSize = UISlider(), commentOpacity = UISlider()
  private let commentSizeLabel = NeoStyle.label(), commentOpacityLabel = NeoStyle.label()
  private let commentStatus = NeoStyle.label(size: 12, muted: true), commentStats = NeoStyle.label(size: 12, muted: true)
  private let commentTracks = UIStackView()
  private var commentTrackKey = "", subtitleKey = ""
  private var hudVisible = true
  private let pipCover = UIView(), pipMessage = NeoStyle.label("ピクチャインピクチャで視聴中", size: 16)
  private var isWide: Bool { bounds.width > bounds.height }
  private var panelVisible: Bool { !isWide || panelOpen }
  private let menuButton = UIButton(type: .system), backButton = UIButton(type: .system)
  private let infoButton = UIButton(type: .system), settingsButton = UIButton(type: .system)
  private let rotationButton = UIButton(type: .system), reloadButton = UIButton(type: .system), ruleButton = UIButton(type: .system)
  private let timeButton = UIButton(type: .custom)
  private var jumps: [UIButton] = []
  private let panel = UIView(), panelHeader = UIView(), panelTitle = NeoStyle.label(size: 16, bold: true)
  private let panelClose = UIButton(type: .system), panelTabs = UIView(), panelTabDivider = UIView()
  private let settingsTabs = UIView(), settingsTabDivider = UIView()
  private var categoryButtons: [UIButton] = [], categoryDividers: [UIView] = []
  private let scroll = UIScrollView(), stack = UIStackView()
  private let commentList = UITableView(frame: .zero, style: .plain), followButton = UIButton(type: .system)
  private var tabButtons: [NeoPlayerPanelTab] = [], tab = "program", followsComments = true, lastCommentIndex = -1
  private var comments: [(time: Double, text: String)] = []
  private var context: [String: Any] = [:], api: NeoAPI?, recording: NeoRecording?
  private var records: [NeoRecording] = [], rulesLoaded = false, ruleHeading = "関連する録画", ruleError: String?
  private var task: Task<Void, Never>?, relatedTask: Task<Void, Never>?, logoTask: URLSessionDataTask?
  private var popup: NeoAnchoredMenu?, remainingTime = false, current: Int64 = 0, duration: Int64 = 0
  private var cacheSeconds = 5, speed: Float = 1
  private let drawer = NeoSidebar(), drawerDim = UIButton(type: .custom)
  private var drawerOpen = false, drawerDragging = false, drawerStart: CGFloat = 0
  private var diagnostic = "", commentDiagnostic = ""

  @objc(initWithTitle:)
  init(title: String) {
    super.init(frame: .zero); backgroundColor = .black; videoView.backgroundColor = .black
    videoView.clipsToBounds = true
    self.title.text = title; self.title.lineBreakMode = .byTruncatingTail
    channel.textColor = NeoStyle.muted; logo.contentMode = .scaleAspectFit
    [videoView, pipCover, videoDim, header, controls, centerControls, panel, statusLabel, drawerDim, drawer].forEach(addSubview)
    header.addSubview(leftHeader); header.addSubview(rightHeader)
    [menuButton, backButton, logo, channel, self.title].forEach(leftHeader.addSubview)
    [infoButton, pipButton, commentButton, settingsButton].forEach(rightHeader.addSubview)
    [timeButton, timeline, rotationButton, reloadButton, ruleButton, subtitleButton].forEach(controls.addSubview)
    timeButton.addSubview(timeLabel); timeButton.accessibilityLabel = "再生時間表示を切り替える"
    timeButton.addAction(UIAction { [weak self] _ in self?.onAction?("interaction"); self?.remainingTime.toggle(); self?.updateTime() }, for: .touchUpInside)
    configure(menuButton, icon: "Menu", label: "サイドメニュー", action: "menu")
    configure(backButton, icon: "ArrowBack", label: "録画詳細へ戻る", action: "back")
    configure(infoButton, icon: "InfoOutlined", label: "番組情報", action: "program")
    configure(pipButton, symbol: "pip.enter", label: "コメント付きPiP", action: "pip")
    pipButton.setImage(fittedSymbol("pip.enter"), for: .normal)
    configure(commentButton, icon: "ChatBubbleOutlineOutlined", label: "コメント設定", action: "comments-settings")
    configure(settingsButton, icon: "SettingsOutlined", label: "プレイヤー設定", action: "settings")
    configure(rotationButton, icon: "ScreenRotationRounded", label: "画面の向きを切り替えて固定", action: "rotate")
    rotationButton.setImage(playerIcon("ScreenRotationRounded", side: 32), for: .normal)
    configure(reloadButton, icon: "Refresh", label: "再読み込み", action: "reload")
    configure(ruleButton, icon: "RuleOutlined", label: "ルール・関連録画", action: "rules")
    configure(subtitleButton, icon: "SubtitlesOutlined", label: "字幕", action: "subtitles")
    for offset in [-30, -10, 10, 30] {
      let button = UIButton(type: .system)
      configure(button, symbol: "\(offset < 0 ? "gobackward" : "goforward").\(abs(offset))",
        label: "\(abs(offset))秒\(offset < 0 ? "戻す" : "送る")", action: "jump:\(offset)")
      jumps.append(button); centerControls.addSubview(button)
    }
    configure(playButton, icon: "Pause", label: "再生・一時停止", action: "play")
    playButton.setImage(playerIcon("Pause", side: 60), for: .normal)
    ([playButton, menuButton, backButton, infoButton, pipButton, commentButton, settingsButton,
      rotationButton, reloadButton, ruleButton, subtitleButton] + jumps).forEach { button in
      button.backgroundColor = .clear
      button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.7
      button.layer.shadowRadius = 2; button.layer.shadowOffset = .zero
    }
    timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    timeLabel.textAlignment = .center; timeButton.backgroundColor = UIColor(white: 0.32, alpha: 0.8)
    timeButton.layer.cornerRadius = 12
    videoDim.backgroundColor = .black.withAlphaComponent(0.18); videoDim.isUserInteractionEnabled = false
    pipCover.backgroundColor = .black; pipCover.isHidden = true; pipCover.isUserInteractionEnabled = false
    pipMessage.textAlignment = .center; pipMessage.numberOfLines = 0; pipCover.addSubview(pipMessage)
    commentTracks.axis = .vertical; commentTracks.spacing = 6
    commentSize.minimumValue = 0.5; commentSize.maximumValue = 2
    commentOpacity.minimumValue = 0; commentOpacity.maximumValue = 1
    commentToggle.onTintColor = NeoStyle.accent
    [commentSize, commentOpacity].forEach { $0.tintColor = NeoStyle.accent }
    commentToggle.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onAction?("interaction"); self.commentOverlay?.enabled = self.commentToggle.isOn }, for: .valueChanged)
    commentSize.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onAction?("interaction"); self.commentOverlay?.setSize(Double(self.commentSize.value)) }, for: .valueChanged)
    commentOpacity.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onAction?("interaction"); self.commentOverlay?.setOpacity(self.commentOpacity.value) }, for: .valueChanged)
    centerControls.addSubview(playButton)
    timeline.minimumTrackTintColor = NeoStyle.accent; timeline.maximumTrackTintColor = .white.withAlphaComponent(0.35)
    timeline.thumbTintColor = .white; timeline.accessibilityLabel = "再生位置"
    timeline.addAction(UIAction { [weak self] _ in self?.onAction?("scrub-begin") }, for: .touchDown)
    timeline.addAction(UIAction { [weak self] _ in self?.onAction?("scrub-end") }, for: [.touchUpInside, .touchUpOutside])
    timeline.addAction(UIAction { [weak self] _ in self?.onAction?("scrub-cancel") }, for: .touchCancel)
    panel.backgroundColor = NeoStyle.paper; panel.clipsToBounds = true; panel.isHidden = true
    [panelHeader, settingsTabs, scroll, commentList, panelTabs, followButton].forEach(panel.addSubview)
    panelTabDivider.backgroundColor = NeoStyle.border; panelTabs.addSubview(panelTabDivider)
    panelHeader.addSubview(panelTitle); panelHeader.addSubview(panelClose)
    configure(panelClose, icon: "Close", label: "パネルを閉じる", action: "panel-close")
    settingsTabDivider.backgroundColor = NeoStyle.border; settingsTabs.addSubview(settingsTabDivider)
    for (id, label) in [("general", "全般"), ("comments", "コメント"), ("subtitles", "字幕")] {
      let button = NeoStyle.button(label) { [weak self] in self?.showSettings(id) }
      button.accessibilityIdentifier = "player-settings-" + id
      settingsTabs.addSubview(button); categoryButtons.append(button)
    }
    for _ in 0..<2 { let divider = UIView(); divider.backgroundColor = NeoStyle.border; settingsTabs.addSubview(divider); categoryDividers.append(divider) }
    stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -14),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -28)])
    commentList.backgroundColor = NeoStyle.paper; commentList.separatorColor = NeoStyle.border
    commentList.dataSource = self; commentList.delegate = self; commentList.rowHeight = UITableView.automaticDimension
    commentList.estimatedRowHeight = 52; commentList.register(UITableViewCell.self, forCellReuseIdentifier: "comment")
    followButton.setTitle("現在のコメントへ戻る", for: .normal); followButton.tintColor = NeoStyle.accent
    followButton.addAction(UIAction { [weak self] _ in self?.followsComments = true; self?.lastCommentIndex = -1; self?.followCurrentComment() }, for: .touchUpInside)
    for (id, label, icon) in [("program", "番組情報", "InfoOutlined"), ("rules", "ルール", "RuleOutlined"),
      ("comments", "コメント", "ChatBubbleOutlineOutlined"), ("settings", "設定", "SettingsOutlined")] {
      let b = NeoPlayerPanelTab(label: label, icon: icon)
      b.addAction(UIAction { [weak self] _ in
        if id == "settings" { self?.showSettings("general") } else { self?.selectPanel(id, toggle: false) }
      }, for: .touchUpInside)
      panelTabs.addSubview(b); tabButtons.append(b)
    }
    drawer.backgroundColor = NeoStyle.paper; drawerDim.backgroundColor = .black.withAlphaComponent(0.5)
    drawerDim.addAction(UIAction { [weak self] _ in self?.setDrawer(false) }, for: .touchUpInside)
    drawer.onSelect = { [weak self] in self?.onAction?("navigate:\($0)") }
    drawer.isHidden = true; drawerDim.isHidden = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(dragDrawer)); pan.delegate = self
    drawer.addGestureRecognizer(pan)
    // The HUD and VLC drawable are siblings. Observe their common ancestor so
    // empty HUD regions and VLC/Metal subviews receive the same background tap.
    videoTap.addTarget(self, action: #selector(tapVideo)); videoTap.delegate = self
    videoTap.cancelsTouchesInView = true; addGestureRecognizer(videoTap)
    navigationPan.addTarget(self, action: #selector(dragNavigation)); navigationPan.delegate = self
    addGestureRecognizer(navigationPan); videoTap.require(toFail: navigationPan)
    header.backgroundColor = .clear; controls.backgroundColor = .clear
    renderPanel()
    statusLabel.backgroundColor = .clear; statusLabel.numberOfLines = 2; statusLabel.isHidden = true
    statusLabel.layer.shadowColor = UIColor.black.cgColor; statusLabel.layer.shadowOpacity = 1
    statusLabel.layer.shadowRadius = 2; statusLabel.layer.shadowOffset = .zero
  }
  required init?(coder: NSCoder) { fatalError() }
  private func configure(_ button: UIButton, icon: String? = nil, symbol: String? = nil, label: String, action: String) {
    button.setImage(icon.map { NeoIcon.image($0) } ?? symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)) }, for: .normal)
    button.tintColor = .white; button.accessibilityLabel = label; button.accessibilityIdentifier = "player-\(action)"
    button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
  }
  private func playerIcon(_ name: String, side: CGFloat) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      NeoIcon.image(name).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }.withRenderingMode(.alwaysTemplate)
  }
  private func fittedSymbol(_ name: String) -> UIImage? {
    guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)) else { return nil }
    let scale = 24 / max(symbol.size.width, symbol.size.height)
    let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
      symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in:
        CGRect(x: (24 - size.width) / 2, y: (24 - size.height) / 2, width: size.width, height: size.height))
    }.withRenderingMode(.alwaysTemplate)
  }
  private func perform(_ action: String) {
    onAction?("interaction")
    switch action {
    case "program", "rules": selectPanel(action, toggle: true)
    case "settings": showSettings("general")
    case "panel-close": setPanel(false)
    case "menu": setDrawer(!drawerOpen)
    default: onAction?(action)
    }
  }
  @objc func configure(_ context: [String: Any]) {
    self.context = context; channel.text = context["channelName"] as? String; renderPanel()
    guard let base = (context["baseURL"] as? String).flatMap(URL.init(string:)), let id = context["id"] as? Int else { return }
    let api = NeoAPI(base: base); self.api = api
    loadLogo(context["channelId"] as? Int ?? 0, api: api)
    task = Task { [weak self] in
      do {
        let recording = try await api.recording(id); try Task.checkCancellation()
        guard let self else { return }; self.recording = recording
        if self.tab == "program" { self.renderPanel() }
      } catch { /* The detail context is still available if metadata refresh fails. */ }
    }
  }
  private func loadLogo(_ id: Int, api: NeoAPI) {
    guard id > 0 else { return }; logoTask?.cancel()
    logoTask = api.session.dataTask(with: api.url("/channels/\(id)/logo")) { [weak self] data, response, _ in
      guard let data, (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async { self?.logo.image = image; self?.setNeedsLayout(); if self?.tab == "program" { self?.renderPanel() } }
    }; logoTask?.resume()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let wide = isWide, safe = safeAreaInsets
    let panelWidth: CGFloat = wide && panelOpen ? min(420, max(230, bounds.width / 3)) : 0
    let videoWidth = bounds.width - panelWidth
    // Keep HUD hit targets inside the safe area, but let the video continue
    // underneath the home indicator instead of reserving a black bottom strip.
    videoView.frame = wide ? CGRect(x: safe.left, y: safe.top, width: max(0, videoWidth - safe.left - (panelOpen ? 0 : safe.right)), height: max(0, bounds.height - safe.top))
      : CGRect(x: 0, y: safe.top, width: videoWidth, height: videoWidth * 9 / 16)
    videoDim.frame = videoView.frame; pipCover.frame = videoView.frame
    pipMessage.frame = pipCover.bounds.insetBy(dx: 20, dy: 20)
    let rightInset = panelOpen && wide ? 8 : safe.right + 8
    header.frame = CGRect(x: safe.left + 8, y: wide ? safe.top + 4 : videoView.frame.minY + 2,
      width: max(0, videoWidth - safe.left - rightInset - 8), height: 44)
    let rightWidth: CGFloat = 160
    rightHeader.frame = CGRect(x: max(0, header.bounds.width - rightWidth), y: 0, width: rightWidth, height: 44)
    leftHeader.frame = CGRect(x: 0, y: 0, width: wide ? max(0, header.bounds.width - rightWidth - 4) : 80, height: 44)
    menuButton.frame = CGRect(x: 0, y: 0, width: 40, height: 44); backButton.frame = CGRect(x: 40, y: 0, width: 40, height: 44)
    [logo, channel, title].forEach { $0.isHidden = !wide }
    logo.frame = CGRect(x: 84, y: 6, width: 42, height: 32)
    let labelX: CGFloat = logo.image == nil ? 84 : 132
    channel.frame = CGRect(x: labelX, y: 5, width: max(0, leftHeader.bounds.width - labelX - 4), height: 14)
    title.frame = CGRect(x: labelX, y: 19, width: channel.bounds.width, height: 22)
    for (index, button) in [infoButton, pipButton, commentButton, settingsButton].enumerated() {
      button.frame = CGRect(x: CGFloat(index) * 40, y: 0, width: 40, height: 44)
    }
    let controlsHeight: CGFloat = wide ? 80 : 50
    let bottom = wide ? bounds.height - safe.bottom : videoView.frame.maxY
    let controlsOffset: CGFloat = wide ? min(10, max(0, safe.bottom - 4)) : 2
    controls.frame = CGRect(x: safe.left + 8, y: bottom - controlsHeight + controlsOffset, width: header.bounds.width, height: controlsHeight)
    let timeWidth = min(controls.bounds.width - 48, max(90, timeLabel.intrinsicContentSize.width + 16))
    timeButton.frame = CGRect(x: 4, y: 0, width: max(0, timeWidth), height: 26); timeLabel.frame = timeButton.bounds
    rotationButton.frame = CGRect(x: controls.bounds.width - 44, y: -6, width: 44, height: 40)
    // A small visual thumb with a generous 32pt tracking area, independent of iOS's glass slider styling.
    timeline.frame = CGRect(x: 0, y: 26, width: controls.bounds.width, height: 32)
    for (index, button) in [reloadButton, ruleButton, subtitleButton].enumerated() {
      button.isHidden = !wide
      button.frame = CGRect(x: controls.bounds.width - CGFloat(3 - index) * 44, y: 44, width: 44, height: 36)
    }
    let centerWidth = min(wide ? 400 : 340, max(0, videoWidth - safe.left - rightInset - 16))
    let centerHeight: CGFloat = 64
    let centerY = wide ? (safe.top + bounds.height - safe.bottom) / 2 + 11 : videoView.frame.midY + 5
    centerControls.frame = CGRect(x: videoView.frame.midX - centerWidth / 2, y: centerY - centerHeight / 2, width: centerWidth, height: centerHeight)
    for (index, button) in [jumps[0], jumps[1], playButton, jumps[2], jumps[3]].enumerated() {
      let side: CGFloat = button === playButton ? 64 : 46
      button.frame = CGRect(x: (CGFloat(index) + 0.5) * centerWidth / 5 - side / 2, y: (centerHeight - side) / 2, width: side, height: side)
      button.layer.cornerRadius = side / 2
    }
    panel.frame = wide ? CGRect(x: videoWidth, y: 0, width: panelWidth, height: bounds.height)
      : CGRect(x: 0, y: videoView.frame.maxY, width: bounds.width, height: max(0, bounds.height - videoView.frame.maxY))
    panel.isHidden = !panelVisible; panel.alpha = panelVisible ? 1 : 0
    let panelTop: CGFloat = wide ? safe.top : 0, panelBottom = safe.bottom
    let panelHeaderHeight: CGFloat = wide || tab == "settings" ? 44 : 0
    panelHeader.isHidden = panelHeaderHeight == 0
    panelHeader.frame = CGRect(x: 0, y: panelTop, width: panel.bounds.width, height: panelHeaderHeight)
    // Align the close glyph with the subtitle tab, rather than subtracting
    // landscape safe-area insets twice inside the already separate panel.
    panelClose.frame = CGRect(x: panel.bounds.width * 5 / 6 - 22, y: 0, width: 44, height: 44)
    panelClose.isHidden = !wide
    panelTitle.frame = CGRect(x: 14, y: 0, width: max(0, (wide ? panelClose.frame.minX : panel.bounds.width) - 18), height: 44)
    let tabsHeight: CGFloat = 72
    panelTabs.isHidden = false
    panelTabs.frame = CGRect(x: 0, y: panel.bounds.height - panelBottom - tabsHeight, width: panel.bounds.width, height: tabsHeight)
    panelTabDivider.frame = CGRect(x: 0, y: 0, width: panel.bounds.width, height: 1)
    for (i, b) in tabButtons.enumerated() { b.frame = CGRect(x: CGFloat(i) * panel.bounds.width / 4, y: 0, width: panel.bounds.width / 4, height: tabsHeight) }
    settingsTabs.isHidden = tab != "settings"
    settingsTabs.frame = CGRect(x: 0, y: panelHeader.frame.maxY, width: panel.bounds.width, height: tab == "settings" ? 44 : 0)
    for (i, button) in categoryButtons.enumerated() { button.frame = CGRect(x: CGFloat(i) * settingsTabs.bounds.width / 3, y: 0, width: settingsTabs.bounds.width / 3, height: 44) }
    for (i, divider) in categoryDividers.enumerated() { divider.frame = CGRect(x: CGFloat(i + 1) * settingsTabs.bounds.width / 3, y: 8, width: 1, height: 28) }
    settingsTabDivider.frame = CGRect(x: 0, y: settingsTabs.bounds.height - 1, width: settingsTabs.bounds.width, height: 1)
    let contentTop = settingsTabs.frame.maxY
    let contentFrame = CGRect(x: 0, y: contentTop, width: panel.bounds.width, height: max(0, panelTabs.frame.minY - contentTop))
    scroll.frame = contentFrame; commentList.frame = contentFrame
    if tab == "comments" { commentList.frame.size.height = max(0, contentFrame.height - 36) }
    followButton.frame = CGRect(x: 0, y: commentList.frame.maxY, width: panel.bounds.width, height: 36)
    statusLabel.frame = CGRect(x: safe.left + 16, y: header.frame.maxY + 4,
      width: max(0, videoWidth - safe.left - rightInset - 24), height: 32)
    drawerDim.frame = bounds
    let drawerWidth = min(240 + safe.left, bounds.width * 0.8)
    drawer.frame = CGRect(x: drawerDragging ? drawer.frame.minX : drawerOpen ? 0 : -drawerWidth, y: 0, width: drawerWidth, height: bounds.height)
    drawer.contentSafeArea = safe

  }
  @objc func showControls(_ visible: Bool) {
    guard hudVisible != visible else { return }; hudVisible = visible
    [header, controls, centerControls].forEach { $0.isUserInteractionEnabled = visible }
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
      [self.videoDim, self.header, self.controls, self.centerControls].forEach { $0.alpha = visible ? 1 : 0 }
    }
  }
  @objc var controlsVisible: Bool { hudVisible }
  @objc func updatePiP(_ active: Bool) {
    // Cover the drawable rather than hiding it: VLC must keep supplying frames
    // for the PiP compositor, including while the app remains in foreground.
    pipCover.isHidden = !active
    centerControls.isHidden = active
  }
  @objc var interactionOpen: Bool { drawerOpen || drawerDragging || navigationAction != nil || popup != nil }
  @objc var controlTracking: Bool {
    func tracking(_ view: UIView) -> Bool {
      (view as? UIControl)?.isTracking == true || view.subviews.contains(where: tracking)
    }
    return tracking(self)
  }
  @objc private func tapVideo() { onAction?("toggle-controls") }
  private func acceptsVideoTap(_ point: CGPoint, target: UIView?) -> Bool {
    guard videoView.frame.contains(point), !interactionOpen, let target else { return false }
    var ancestor: UIView? = target
    while let view = ancestor, view !== self {
      if view is UIControl || view === panel || view === drawer { return false }
      ancestor = view.superview
    }
    return ancestor === self
  }
  func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if gesture === videoTap { return acceptsVideoTap(touch.location(in: self), target: touch.view) }
    guard gesture === navigationPan else { return true }
    navigationStart = touch.location(in: self); navigationScroll = nil
    var candidate = touch.view
    while let current = candidate, current !== self {
      if current === drawer || current === drawerDim || current is UISlider || current is UISwitch || current is UITextField || current is UITextView { return false }
      if let scroll = current as? UIScrollView {
        if scroll.contentSize.width > scroll.bounds.width + 1 { return false }
        if navigationScroll == nil { navigationScroll = scroll }
      }
      candidate = current.superview
    }
    return true
  }
  @objc func updatePlayback(_ running: Bool, current: Int64, duration: Int64) {
    self.current = current; self.duration = duration
    playButton.setImage(playerIcon(running ? "Pause" : "PlayArrow", side: 60), for: .normal)
    playButton.accessibilityLabel = running ? "一時停止" : "再生"
    updateTime(); followCurrentComment(); setNeedsLayout()
  }
  private func updateTime() {
    func format(_ seconds: Int64) -> String { seconds >= 3600 ? String(format: "%lld:%02lld:%02lld", seconds/3600, seconds/60%60, seconds%60) : String(format: "%lld:%02lld", seconds/60, seconds%60) }
    timeLabel.text = remainingTime ? "−\(format(max(0, duration - current))) / \(format(duration))" : "\(format(current)) / \(format(duration))"
  }
  @objc func updateDiagnostics() {
    let status = statusLabel.text ?? ""
    statusLabel.isHidden = !status.contains("エラー") && !status.contains("できません") && !status.contains("バッファリング") && !status.contains("再読み込み")
    diagnostic = status; commentDiagnostic = commentLabel.text ?? ""
  }
  @objc func setCommentRows(_ rows: [[String: Any]], version: Int) {
    commentVersion = version; comments = rows.compactMap { row in
      guard let time = row["time"] as? Double, let text = row["text"] as? String else { return nil }; return (time, text)
    }; lastCommentIndex = -1; commentList.reloadData()
  }
  @objc func updateCommentMessage(_ message: String) {
    guard comments.isEmpty else { commentList.backgroundView = nil; return }
    let label = (commentList.backgroundView as? UILabel) ?? NeoStyle.label(message, size: 14, muted: true)
    label.text = message
    label.textAlignment = .center; label.numberOfLines = 0
    commentList.backgroundView = label
  }
  private func selectPanel(_ id: String, toggle: Bool) {
    if toggle && isWide && panelOpen && tab == id { setPanel(false); return }
    tab = id; renderPanel(); setPanel(true)
    if id == "rules" { loadRelated() }
  }
  private func setPanel(_ open: Bool) {
    let changesVideoWidth = isWide && panelOpen != open
    popup?.dismiss(); panelOpen = open; panel.isHidden = false
    if !open && !isWide { tab = "program"; renderPanel() }
    infoButton.tintColor = open && tab == "program" ? NeoStyle.accent : .white
    ruleButton.tintColor = open && tab == "rules" ? NeoStyle.accent : .white
    settingsButton.tintColor = open && tab == "settings" ? NeoStyle.accent : .white
    setNeedsLayout()
    if changesVideoWidth {
      UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.16, animations: { self.layoutIfNeeded(); self.panel.alpha = self.panelVisible ? 1 : 0 }) { _ in self.panel.isHidden = !self.panelVisible }
    } else {
      // Switching tabs replaces content immediately; only opening/closing the
      // landscape panel changes the video layout with an animation.
      UIView.performWithoutAnimation { self.layoutIfNeeded() }
    }
  }
  private func append(_ text: String, size: CGFloat = 14, bold: Bool = false, muted: Bool = false, lineHeight: CGFloat = 1) {
    let label = NeoStyle.label(text, size: size, bold: bold, muted: muted); label.numberOfLines = 0; label.lineBreakMode = .byWordWrapping
    if lineHeight != 1 {
      let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = size * lineHeight; paragraph.maximumLineHeight = size * lineHeight
      label.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
    }
    stack.addArrangedSubview(label)
  }
  private func programDate(_ start: Double, _ end: Double) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy/MM/dd(E) HH:mm"; let first = formatter.string(from: Date(timeIntervalSince1970: start / 1000))
    formatter.dateFormat = "HH:mm"
    return "\(first) - \(formatter.string(from: Date(timeIntervalSince1970: end / 1000)))（\(Int((end - start) / 60000))分）"
  }
  private func renderPanel() {
    UIView.performWithoutAnimation {
      self.buildPanelContents(); self.setNeedsLayout(); self.layoutIfNeeded()
    }
  }
  private func buildPanelContents() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }; scroll.setContentOffset(.zero, animated: false)
    scroll.isHidden = tab == "comments"; commentList.isHidden = tab != "comments"; followButton.isHidden = tab != "comments"
    panelTitle.text = ["program":"番組情報", "rules":"ルール", "comments":"コメント", "settings":"プレイヤー設定"][tab]
    for (i, button) in categoryButtons.enumerated() {
      let selected = ["general", "comments", "subtitles"][i] == settingsCategory
      button.tintColor = selected ? NeoStyle.accent : NeoStyle.muted
      button.accessibilityTraits = selected ? [.button, .selected] : .button
    }
    for (i, b) in tabButtons.enumerated() {
      let selected = ["program", "rules", "comments", "settings"][i] == tab
      b.setActive(selected)
    }
    switch tab {
    case "program":
      let identity = UIStackView(); identity.spacing = 10; identity.alignment = .center
      if let image = logo.image { let icon = UIImageView(image: image); icon.contentMode = .scaleAspectFit; icon.widthAnchor.constraint(equalToConstant: 62).isActive = true; icon.heightAnchor.constraint(equalToConstant: 38).isActive = true; identity.addArrangedSubview(icon) }
      let captions = UIStackView(arrangedSubviews: [NeoStyle.label(channel.text ?? "", size: 16, bold: true), NeoStyle.label("録画済み", size: 12, muted: true)])
      captions.axis = .vertical; captions.spacing = 3; identity.addArrangedSubview(captions); stack.addArrangedSubview(identity)
      append(title.text ?? "", size: 20, bold: true, lineHeight: 1.45)
      let start = recording?.startAt ?? (context["startAt"] as? Double) ?? 0, end = recording?.endAt ?? (context["endAt"] as? Double) ?? 0
      if start > 0 { append(programDate(start, end), muted: true) }
      append(recording?.description ?? (context["description"] as? String) ?? "", lineHeight: 1.75)
      if let recording {
        let genres = NeoPlayerGenres.labels(recording)
        if !genres.isEmpty { stack.addArrangedSubview(NeoPlayerGenreBadges(genres)) }
      }
      let extended = recording?.extended ?? context["extended"] as? String ?? ""
      if !extended.isEmpty { append("番組内容", size: 16, bold: true); append(extended, muted: true, lineHeight: 1.75) }
    case "rules":
      append(ruleHeading, size: 16, bold: true)
      if let ruleError { append(ruleError, muted: true) }
      else if !rulesLoaded { append("関連する録画を取得中…", muted: true) }
      else if records.isEmpty { append("searchと同じ条件に一致する録画は見つかりませんでした。", muted: true) }
      else {
        append("\(records.count) 件", size: 12, muted: true)
        for item in records {
          let row = NeoPlayerRecordRow(item: item, date: programDate(item.startAt, item.endAt), current: item.id == context["id"] as? Int, api: api)
          row.addAction(UIAction { [weak self] _ in self?.onAction?("recording:\(item.id)") }, for: .touchUpInside)
          stack.addArrangedSubview(row)
        }
      }
    case "settings":
      if settingsCategory == "comments" { buildCommentSettings(); break }
      if settingsCategory == "subtitles" { buildSubtitleSettings(); break }
      append("再生速度", bold: true)
      let speeds = UIStackView(); speeds.spacing = 4; speeds.distribution = .fillEqually
      for rate in [Float(0.5), 0.75, 1, 1.25, 1.5, 2] {
        let b = NeoStyle.button("\(rate)×") { [weak self] in self?.speed = rate; self?.onAction?("rate:\(rate)"); self?.renderPanel() }
        b.tintColor = rate == speed ? NeoStyle.accent : .white; b.titleLabel?.font = .systemFont(ofSize: 11); speeds.addArrangedSubview(b)
      }; speeds.heightAnchor.constraint(equalToConstant: 40).isActive = true; stack.addArrangedSubview(speeds)
      append("PLAYのネットワークキャッシュ：\(cacheSeconds) 秒", bold: true)
      let cache = UIStepper(); cache.minimumValue = 1; cache.maximumValue = 30; cache.value = Double(cacheSeconds)
      cache.addAction(UIAction { [weak self, weak cache] _ in guard let self, let cache else { return }; self.cacheSeconds = Int(cache.value); self.onAction?("cache:\(self.cacheSeconds)"); self.renderPanel() }, for: .valueChanged)
      stack.addArrangedSubview(cache); append("次のリロードから適用します。", size: 12, muted: true)
      append("巻き戻し用キャッシュ", bold: true)
      let retained = NeoPlaybackCache.savedSeconds
      for value in NeoPlaybackCache.presets {
        let text = value == 0 ? "オフ" : value == 30 ? "30秒" : "\(value/60)分"
        let choice = NeoStyle.button(text) { [weak self] in self?.onAction?("retention:\(value)"); self?.renderPanel() }
        choice.tintColor = value == retained ? NeoStyle.accent : NeoStyle.muted
        stack.addArrangedSubview(choice)
      }
      let row = UIStackView(); row.addArrangedSubview(NeoStyle.label("操作ボタンを自動で隠す")); let toggle = UISwitch(); toggle.isOn = autoHide; toggle.onTintColor = NeoStyle.accent
      toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.autoHide = toggle?.isOn == true; self?.onAction?("interaction") }, for: .valueChanged); row.addArrangedSubview(toggle); stack.addArrangedSubview(row)
      append("画面の向き", bold: true)
      for (id, text) in [("auto", "端末の向きに合わせる"), ("portrait", "縦に固定"), ("landscape", "横に固定")] {
        stack.addArrangedSubview(NeoStyle.button(text) { [weak self] in self?.onAction?("orientation:\(id)") })
      }
      append(diagnostic, size: 12, muted: true); append(commentDiagnostic, size: 12, muted: true)
      let reload = NeoStyle.button("再読み込み") { [weak self] in self?.onAction?("reload") }
      reload.accessibilityIdentifier = "player-settings-reload"; stack.addArrangedSubview(reload)
    default: break
    }; setNeedsLayout()
  }
  private func loadRelated() {
    guard !rulesLoaded, relatedTask == nil, let api else { return }
    let ruleId = recording?.ruleId ?? (context["ruleId"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    let keyword = NeoRelatedSearch.keyword(title.text ?? "")
    relatedTask = Task { [weak self] in
      guard let self else { return }
      do {
        if let ruleId {
          // Related recordings remain usable if only the rule metadata is unavailable.
          let rule = try? await api.rule(ruleId)
          let name = rule?.searchOption.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          self.ruleHeading = name.isEmpty ? "ルール #\(ruleId)" : name
        }
        else { self.ruleHeading = keyword.isEmpty ? "関連する録画" : "検索ワード「\(keyword)」" }
        let result = try await api.relatedRecordings(ruleId: ruleId, keyword: keyword); try Task.checkCancellation()
        self.records = result.records; self.rulesLoaded = true
      } catch { if !Task.isCancelled { self.ruleError = error.localizedDescription } }
      self.relatedTask = nil; if self.tab == "rules" { self.renderPanel() }
    }
  }
  private func followCurrentComment() {
    guard panelVisible, tab == "comments", followsComments, !comments.isEmpty else { return }
    var low = 0, high = comments.count
    while low < high { let mid = (low + high) / 2; if comments[mid].time <= Double(current) { low = mid + 1 } else { high = mid } }
    let index = max(0, low - 1); guard index != lastCommentIndex else { return }; lastCommentIndex = index
    commentList.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
  }
  @objc func showSettings(_ category: String) {
    onAction?("interaction"); settingsCategory = category; selectPanel("settings", toggle: false)
  }
  @objc func bindCommentSettings(_ overlay: NeoCommentOverlay) { commentOverlay = overlay; refreshCommentSettings() }
  @objc func refreshCommentSettings() {
    guard let overlay = commentOverlay else { return }
    if !commentToggle.isTracking { commentToggle.isOn = overlay.enabled }
    if !commentSize.isTracking { commentSize.value = Float(overlay.sizeMultiplier) }
    if !commentOpacity.isTracking { commentOpacity.value = overlay.opacity }
    commentSizeLabel.text = String(format: "文字サイズ %.2f倍", overlay.sizeMultiplier)
    commentOpacityLabel.text = overlay.usesSourceOpacity && overlay.mixedOpacity ? "不透明度：ASS準拠（混在）" : "不透明度 \(Int((overlay.opacity * 100).rounded()))%"
    commentStatus.text = overlay.status; commentStats.text = overlay.diagnostics
    let key = overlay.tracks.map { "\($0.subtitleIndex):\($0.displayName)" }.joined(separator: "|") + "#\(overlay.selectedIndex ?? -1)"
    guard key != commentTrackKey else { return }; commentTrackKey = key
    commentTracks.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for track in overlay.tracks {
      commentTracks.addArrangedSubview(settingChoice(track.displayName, selected: track.subtitleIndex == overlay.selectedIndex) { [weak self, weak overlay] in
        self?.onAction?("interaction"); overlay?.select(track)
      })
    }
  }
  private func buildCommentSettings() {
    append("コメント", size: 16, bold: true)
    commentStatus.numberOfLines = 0; commentStats.numberOfLines = 0
    stack.addArrangedSubview(commentStatus)
    let row = UIStackView(arrangedSubviews: [NeoStyle.label("コメントを表示"), commentToggle]); row.distribution = .equalSpacing
    [row, commentSizeLabel, commentSize, commentOpacityLabel, commentOpacity, commentTracks, commentStats].forEach(stack.addArrangedSubview)
    stack.addArrangedSubview(NeoStyle.button("コメントを再読み込み") { [weak self] in self?.onAction?("interaction"); self?.commentOverlay?.reloadTracks() })
    append("表示・文字サイズ・不透明度の設定はPiPにも反映します。", size: 12, muted: true)
    refreshCommentSettings()
  }
  static func ordinarySubtitles(_ tracks: [[String: Any]]) -> [[String: Any]] {
    tracks.filter { !NeoCommentOverlay.isCommentName($0["name"] as? String ?? "") && !NeoCommentOverlay.isCommentName($0["detail"] as? String ?? "") }
  }
  @objc func updateSubtitleTracks(_ tracks: [[String: Any]]) {
    subtitleTracks = Self.ordinarySubtitles(tracks)
    let key = subtitleTracks.map { "\($0["index"] ?? ""): \($0["name"] ?? ""): \($0["selected"] ?? false)" }.joined(separator: "|")
    guard key != subtitleKey else { return }; subtitleKey = key
    if tab == "settings" && settingsCategory == "subtitles" { renderPanel() }
  }
  private func settingChoice(_ name: String, selected: Bool, action: @escaping () -> Void) -> UIButton {
    let button = NeoStyle.button(name, action: action)
    button.contentHorizontalAlignment = .leading
    var config = UIButton.Configuration.plain(); config.title = name
    config.image = selected ? UIImage(systemName: "checkmark.circle") : NeoIcon.image("SubtitlesOutlined"); config.imagePadding = 10
    config.baseForegroundColor = selected ? NeoStyle.accent : .white
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = .systemFont(ofSize: 14); return a }
    config.background.backgroundColor = selected ? NeoStyle.accent.withAlphaComponent(0.16) : NeoStyle.background
    config.background.strokeColor = selected ? NeoStyle.accent : NeoStyle.border; config.background.strokeWidth = 1; config.background.cornerRadius = 6
    button.configuration = config; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    return button
  }
  private func buildSubtitleSettings() {
    append("字幕", size: 16, bold: true)
    stack.addArrangedSubview(settingChoice("字幕なし", selected: !subtitleTracks.contains { $0["selected"] as? Bool == true }) { [weak self] in self?.onAction?("subtitle:-1") })
    if subtitleTracks.isEmpty { append("この録画ファイルには切り替え可能な字幕がありません。", muted: true) }
    for track in subtitleTracks {
      guard let index = track["index"] as? Int else { continue }
      stack.addArrangedSubview(settingChoice(track["name"] as? String ?? "字幕", selected: track["selected"] as? Bool == true) { [weak self] in self?.onAction?("subtitle:\(index)") })
    }
  }
  private func setDrawer(_ open: Bool) {
    drawerOpen = open; drawer.isHidden = false; drawerDim.isHidden = false; setNeedsLayout()
    drawer.accessibilityViewIsModal = open
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: { self.layoutIfNeeded(); self.drawerDim.alpha = open ? 1 : 0 }) { _ in
      self.drawer.isHidden = !self.drawerOpen; self.drawerDim.isHidden = !self.drawerOpen
    }
  }
  @objc private func dragDrawer(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: self).x
    if gesture.state == .began {
      drawerDragging = true; drawerStart = drawer.layer.presentation()?.frame.minX ?? drawer.frame.minX
      drawer.layer.removeAllAnimations(); drawerDim.layer.removeAllAnimations(); drawer.frame.origin.x = drawerStart
    }
    if gesture.state == .changed { drawer.frame.origin.x = min(0, max(-drawer.bounds.width, drawerStart + translation)); drawerDim.alpha = 1 + drawer.frame.minX / drawer.bounds.width }
    if [.ended, .cancelled, .failed].contains(gesture.state) {
      drawerDragging = false
      setDrawer(gesture.state != .ended || (translation > -drawer.bounds.width * 0.25 && gesture.velocity(in: self).x > -350))
    }
  }
  private func navigationTarget(start: CGPoint, velocity: CGPoint) -> NeoSwipeAction? {
    guard !drawerOpen, !drawerDragging, popup == nil else { return nil }
    return NeoNavigationGesture.action(startY: Double(start.y), height: Double(bounds.height),
      canGoBack: !isWide, tablet: false, horizontal: Double(velocity.x), vertical: Double(velocity.y))
  }
  @objc private func dragNavigation(_ gesture: UIPanGestureRecognizer) {
    updateNavigation(state: gesture.state, translation: gesture.translation(in: self).x, velocity: gesture.velocity(in: self).x)
  }
  private func updateNavigation(state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat) {
    guard let action = navigationAction else { return }
    if state == .began {
      onAction?("interaction"); navigationScrollEnabled = navigationScroll?.isScrollEnabled == true
      navigationScroll?.isScrollEnabled = false
      if action == .menu {
        drawerDragging = true; drawerStart = -drawer.bounds.width
        drawer.isHidden = false; drawerDim.isHidden = false; drawer.frame.origin.x = drawerStart
      }
    }
    if action == .menu && (state == .changed || state == .began) {
      drawer.frame.origin.x = min(0, max(-drawer.bounds.width, drawerStart + translation))
      drawerDim.alpha = 1 + drawer.frame.minX / max(1, drawer.bounds.width)
    }
    if [.ended, .cancelled, .failed].contains(state) {
      let threshold = action == .menu ? drawer.bounds.width * 0.5 : bounds.width * 0.28
      let finish = state == .ended && (translation > threshold || velocity > 450)
      if navigationScrollEnabled { navigationScroll?.isScrollEnabled = true }
      navigationScroll = nil; navigationAction = nil; drawerDragging = false
      if action == .menu { setDrawer(finish) }
      else if finish { perform("back") }
      onAction?("interaction")
    }
  }
  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard let pan = gesture as? UIPanGestureRecognizer else { return true }
    let v = pan.velocity(in: self)
    if gesture === navigationPan { navigationAction = navigationTarget(start: navigationStart, velocity: v); return navigationAction != nil }
    return v.x < 0 && abs(v.x) >= abs(v.y)
  }
  func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    gesture === navigationPan && other === navigationScroll?.panGestureRecognizer
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { comments.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "comment", for: indexPath), item = comments[indexPath.row]
    var config = cell.defaultContentConfiguration(); config.textProperties.color = .white
    config.text = item.text; config.textProperties.font = .systemFont(ofSize: 13)
    config.secondaryText = String(format: "%d:%02d", Int(item.time) / 60, Int(item.time) % 60); config.secondaryTextProperties.color = NeoStyle.muted
    cell.contentConfiguration = config; cell.backgroundColor = NeoStyle.paper; return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true); onAction?("seekto:\(comments[indexPath.row].time)")
  }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { if scrollView === commentList { followsComments = false } }
  @objc func shutdown() { task?.cancel(); relatedTask?.cancel(); logoTask?.cancel(); popup?.dismiss(); onAction = nil }
  deinit { task?.cancel(); relatedTask?.cancel(); logoTask?.cancel() }

#if targetEnvironment(simulator)
  private func runSettingsChecks() -> [String: Bool] {
    let oldTracks = subtitleTracks, oldCategory = settingsCategory, handler = onAction
    let oldEnabled = commentOverlay?.enabled, oldSize = commentOverlay?.sizeMultiplier, oldOpacity = commentOverlay?.opacity
    var actions: [String] = []; onAction = { actions.append($0) }
    showSettings("comments")
    let before = stack.arrangedSubviews
    commentSize.value = 1.5; commentSize.sendActions(for: .valueChanged)
    commentOpacity.value = 0.4; commentOpacity.sendActions(for: .valueChanged)
    commentToggle.isOn = false; commentToggle.sendActions(for: .valueChanged)
    let applied = commentOverlay?.sizeMultiplier == 1.5 && commentOverlay?.opacity == 0.4 && commentOverlay?.enabled == false
      && commentOverlay?.compositionState.size == 1.5 && commentOverlay?.compositionState.opacity == 0.4 && commentOverlay?.compositionState.enabled == false
    let stable = zip(before, stack.arrangedSubviews).allSatisfy { $0 === $1 } && before.count == stack.arrangedSubviews.count
    let reopenedOverlay = NeoCommentOverlay(frame: .zero)
    let persisted = reopenedOverlay.sizeMultiplier == 1.5 && reopenedOverlay.opacity == 0.4 && !reopenedOverlay.enabled
    reopenedOverlay.stop()
    showSettings("general"); showSettings("comments")
    let panelRetained = commentSize.value == 1.5 && commentOpacity.value == 0.4 && !commentToggle.isOn
    if let oldEnabled, let oldSize, let oldOpacity {
      commentOverlay?.enabled = oldEnabled; commentOverlay?.setSize(oldSize); commentOverlay?.setOpacity(oldOpacity)
    }
    updateSubtitleTracks([["index": 0, "name": "NicoJK ASS", "selected": true],
      ["index": 1, "name": "ASS", "detail": "弾幕"], ["index": 3, "name": "日本語 ASS", "selected": false]])
    showSettings("subtitles")
    let filtered = subtitleTracks.count == 1 && subtitleTracks.first?["index"] as? Int == 3
    (stack.arrangedSubviews.last as? UIButton)?.sendActions(for: .touchUpInside)
    let routed = actions.contains("subtitle:3") && !actions.contains("subtitle:0") && !actions.contains("subtitle:1")
    let categories = categoryButtons.map(\.accessibilityIdentifier) == ["player-settings-general", "player-settings-comments", "player-settings-subtitles"]
      && categoryButtons[2].tintColor == NeoStyle.accent && categoryButtons.prefix(2).allSatisfy { $0.tintColor == NeoStyle.muted }
      && categoryButtons[0].frame.maxX == categoryButtons[1].frame.minX && categoryButtons[1].frame.maxX == categoryButtons[2].frame.minX
    categoryButtons[0].sendActions(for: .touchUpInside)
    let returns = tab == "settings" && settingsCategory == "general" && panelOpen
    let generalReload = stack.arrangedSubviews.last as? UIButton
    let reloadAtBottom = generalReload?.accessibilityIdentifier == "player-settings-reload"
    generalReload?.sendActions(for: .touchUpInside)
    let reloadRouted = actions.contains("reload")
    showSettings("comments")
    let commentsNoReload = !stack.arrangedSubviews.contains { $0.accessibilityIdentifier == "player-settings-reload" }
    showSettings("subtitles")
    let subtitlesNoReload = !stack.arrangedSubviews.contains { $0.accessibilityIdentifier == "player-settings-reload" }
    showSettings("general")
    tabButtons[0].sendActions(for: .touchUpInside); tabButtons[3].sendActions(for: .touchUpInside)
    let settingsTab = tab == "settings" && settingsCategory == "general" && !panelTabs.isHidden && panelTabs.bounds.height == 72
      && tabButtons[3].accessibilityLabel == "設定" && !settingsTabs.isHidden
    let frameBefore = videoView.frame; updatePiP(true)
    let covered = !pipCover.isHidden && pipCover.frame == videoView.frame && pipCover.backgroundColor == UIColor.black && !videoView.isHidden && videoView.frame == frameBefore && centerControls.isHidden
    updatePiP(false); let restored = pipCover.isHidden && !videoView.isHidden && !centerControls.isHidden
    let cell = drawer.tableView(drawer.list, cellForRowAt: IndexPath(row: 0, section: 0))
    let config = cell.contentConfiguration as? UIListContentConfiguration
    let shared = drawer.brand.frame.minX == drawer.contentSafeArea.left + 16 && drawer.logo.frame.minX - drawer.brand.frame.maxX == 7
      && config?.imageProperties.reservedLayoutSize == CGSize(width: 24, height: 27)
    onAction = handler; subtitleTracks = oldTracks; subtitleKey = ""; settingsCategory = oldCategory
    return ["settingsStayInPanel": returns, "fixedSettingsCategoryTabs": categories, "settingsBottomTab": settingsTab,
      "videoReloadOnlyAtGeneralBottom": reloadAtBottom && reloadRouted && commentsNoReload && subtitlesNoReload,
      "commentPreferencesRestoredInNewPlayer": persisted, "commentPreferencesRetainedAcrossPanels": panelRetained,
      "commentSettingsApplyToComposition": applied, "slidersRetainedDuringUpdates": stable,
      "danmakuExcludedFromSubtitles": filtered, "filteredSubtitleKeepsOriginalIndex": routed,
      "pipCoversVideoWithoutStoppingDrawable": covered, "pipRestoresVideo": restored, "sharedDrawerAlignmentAndIconSize": shared]
  }
  // Exercise the same hit-test/ancestor filter used by the real recognizer.
  @objc func smokeTapVideoBackground() -> Bool {
    layoutIfNeeded()
    let point = CGPoint(x: videoView.frame.midX, y: videoView.frame.minY + 56)
    guard let target = hitTest(point, with: nil), acceptsVideoTap(point, target: target),
      videoTap.view === self else { return false }
    tapVideo(); return true
  }
  @objc func runInteractionChecks() -> [String: Any] {
    layoutIfNeeded()
    let initiallyAligned = panelTabRowsAligned()
    func accepted(_ view: UIView) -> Bool {
      let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: self)
      return acceptsVideoTap(point, target: hitTest(point, with: nil))
    }
    showControls(false)
    let hiddenPlayIsBackground = accepted(playButton)
    showControls(true)
    let buttonsExcluded = !accepted(playButton) && !accepted(timeButton) && !accepted(timeline)
    let blankHeader = CGPoint(x: header.frame.minX + 100, y: header.frame.midY)
    let hudBackground = acceptsVideoTap(blankHeader, target: hitTest(blankHeader, with: nil))
    let panelExcluded = !accepted(panelTabs)
    func animatedGeometry(_ view: UIView) -> Bool {
      let keys = view.layer.animationKeys() ?? []
      return keys.contains { $0.contains("position") || $0.contains("bounds") || $0.contains("transform") } ||
        view.subviews.contains(where: animatedGeometry)
    }
    var immediate = true, tabsAligned = true
    for button in tabButtons {
      button.sendActions(for: .touchUpInside)
      if tab != "comments" {
        immediate = immediate && stack.arrangedSubviews.first.map { $0.bounds.width > 0 && $0.bounds.height > 0 } == true
      }
      immediate = immediate && !animatedGeometry(panel)
      tabsAligned = tabsAligned && panelTabRowsAligned()
    }
    panelOpen = false; tab = "program"; renderPanel()
    let gestures = runNavigationChecks()
    let checks = ["rootTapRecognizer": videoTap.view === self, "hiddenButtonRevealsOnly": hiddenPlayIsBackground,
      "buttonsAndSliderExcluded": buttonsExcluded, "emptyHUDTap": hudBackground,
      "panelTapExcluded": panelExcluded, "tabsImmediateWithoutGeometryAnimation": immediate,
      "panelTabsAlignedInitially": initiallyAligned, "panelTabsStayAlignedAfterSelection": tabsAligned]
    let all = checks.merging(gestures) { _, new in new }
    return all.merging(["success": all.values.allSatisfy { $0 }]) { _, new in new }
  }
  private func runNavigationChecks() -> [String: Bool] {
    let savedFrame = frame, handler = onAction
    var actions: [String] = []; onAction = { actions.append($0) }
    frame = CGRect(x: 0, y: 0, width: 390, height: 844); setNeedsLayout(); layoutIfNeeded()
    let forward = CGPoint(x: 600, y: 400)
    let top = navigationTarget(start: CGPoint(x: 200, y: 844 * 0.39), velocity: forward) == .menu
    let lower = navigationTarget(start: CGPoint(x: 200, y: 844 * 0.4), velocity: forward) == .back
    let vertical = navigationTarget(start: .zero, velocity: CGPoint(x: 100, y: 300)) == nil
    navigationAction = .back; updateNavigation(state: .began, translation: 0, velocity: 0)
    updateNavigation(state: .cancelled, translation: 300, velocity: 800)
    let cancelled = !actions.contains("back")
    navigationAction = .back; updateNavigation(state: .began, translation: 0, velocity: 0)
    updateNavigation(state: .ended, translation: 200, velocity: 600)
    let completed = actions.contains("back")
    navigationAction = .menu; updateNavigation(state: .began, translation: 0, velocity: 0)
    updateNavigation(state: .changed, translation: 160, velocity: 600)
    let dragging = drawer.frame.minX > -drawer.bounds.width && drawerDim.alpha > 0
    updateNavigation(state: .ended, translation: 200, velocity: 600)
    let opened = drawerOpen; setDrawer(false)
    frame = CGRect(x: 0, y: 0, width: 844, height: 390); setNeedsLayout(); layoutIfNeeded()
    let wide = [0.1, 0.8].allSatisfy { navigationTarget(start: CGPoint(x: 300, y: 390 * $0), velocity: forward) == .menu }
    frame = savedFrame; onAction = handler; setNeedsLayout(); layoutIfNeeded()
    drawer.layer.removeAllAnimations(); drawerDim.layer.removeAllAnimations(); drawer.isHidden = true; drawerDim.isHidden = true
    return ["portraitSwipe40Menu60Back": top && lower, "landscapeSwipeOnlyMenu": wide,
      "swipeBackCompletesAndCancels": completed && cancelled, "swipeDrawerOpens": dragging && opened,
      "verticalSwipeLeavesScrolling": vertical, "rootNavigationGesture": navigationPan.view === self]
  }
  private func panelTabRowsAligned() -> Bool {
    tabButtons.forEach { $0.layoutIfNeeded() }
    guard let first = tabButtons.first else { return false }
    return tabButtons.allSatisfy {
      $0.bounds.width > 0 && $0.glyph.frame.size == CGSize(width: 24, height: 24) &&
      $0.glyph.frame.midY == first.glyph.frame.midY && $0.caption.frame.midY == first.caption.frame.midY &&
      $0.caption.frame.width == $0.bounds.width && $0.configuration == nil
    }
  }
  @objc func checkInitialPortrait() -> Bool {
    layoutIfNeeded()
    let buttons = [jumps[0], jumps[1], playButton, jumps[2], jumps[3]]
    let nonOverlapping = zip(buttons, buttons.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX }
    return !isWide && !panelOpen && !panel.isHidden && !stack.arrangedSubviews.isEmpty && title.isHidden &&
      reloadButton.isHidden && subtitleButton.isHidden && panel.frame.minY == videoView.frame.maxY &&
      videoView.frame.minY == safeAreaInsets.top && nonOverlapping && !interactionOpen
  }
  @objc func runLayoutChecks() -> [String: Any] {
    let original = frame, originalHide = autoHide; autoHide = false; showControls(true)
    frame = CGRect(x: 0, y: 0, width: 844, height: 390); setNeedsLayout(); layoutIfNeeded()
    let full = videoView.frame.minX >= safeAreaInsets.left && videoView.frame.maxX <= bounds.maxX - safeAreaInsets.right && videoView.frame.maxY == bounds.maxY
    let noBands = header.backgroundColor == UIColor.clear && controls.backgroundColor == UIColor.clear && statusLabel.backgroundColor == UIColor.clear
    let smallThumb = timeline.thumbImage(for: .normal)?.size.width == 12
    let filledPlay = playerIcon("PlayArrow", side: 60).size.width == 60
    let centered = centerControls.frame.midX == videoView.frame.midX && centerControls.frame.midY == (safeAreaInsets.top + bounds.height - safeAreaInsets.bottom) / 2 + 11
    let lowerHUD = controls.frame.minY >= bounds.height - safeAreaInsets.bottom - 80 &&
      controls.frame.maxY <= bounds.maxY && videoView.frame.maxY == bounds.maxY
    let hudShadows = [menuButton, backButton, infoButton, pipButton, commentButton, settingsButton, rotationButton, reloadButton, ruleButton, subtitleButton].allSatisfy { $0.layer.shadowOpacity > 0 && $0.backgroundColor == UIColor.clear }

    showSettings("general"); setNeedsLayout(); layoutIfNeeded()
    let side = abs(panel.frame.width / bounds.width - 1/3) < 0.01 && panel.frame.minX == videoView.frame.maxX
    let closeAligned = abs(panelClose.frame.midX - categoryButtons[2].frame.midX) < 0.5
    let landscapeTabs = panelTabRowsAligned()

    frame = CGRect(x: 0, y: 0, width: 390, height: 844); setNeedsLayout(); layoutIfNeeded()
    let below = panel.frame.minY >= videoView.frame.maxY && panel.frame.maxY == bounds.maxY && rightHeader.frame.minY == 0 && title.isHidden && reloadButton.isHidden
    let portraitTabs = panelTabRowsAligned()
    let portraitCloseHidden = panelClose.isHidden
    let portraitThumbFits = controls.frame.minY + timeline.frame.midY + 6 <= videoView.frame.maxY

    tab = "rules"; rulesLoaded = true; ruleHeading = "サンプルルール"
    records = (1...3).map { i in NeoRecording(id: i, name: "サンプル番組 #\(i)", startAt: 1791042600000, endAt: 1791044400000, isRecording: false, description: "関連する番組の説明", extended: nil, channelId: nil, channelName: nil, thumbnails: nil, videoFiles: nil) }
    renderPanel()
    tab = "settings"; renderPanel()
    var actions: [String] = []; let handler = onAction; onAction = { actions.append($0) }
    jumps.forEach { $0.sendActions(for: .touchUpInside) }; playButton.sendActions(for: .touchUpInside)
    reloadButton.sendActions(for: .touchUpInside); rotationButton.sendActions(for: .touchUpInside)
    onAction = handler
    let routing = ["jump:-30", "jump:-10", "jump:10", "jump:30", "play", "reload", "rotate"].allSatisfy { actions.contains($0) }
    let before = remainingTime; timeButton.sendActions(for: .touchUpInside); let time = remainingTime != before; remainingTime = before; updateTime()
    let settings = runSettingsChecks()
    NeoNative.writeSmoke("player-settings-smoke", settings.merging(["success": settings.values.allSatisfy { $0 }]) { _, new in new })
    panelOpen = false; tab = "program"; rulesLoaded = false; records = []; renderPanel()

    frame = original; autoHide = originalHide; setNeedsLayout(); layoutIfNeeded()
    let noCircles = ([playButton] + jumps).allSatisfy { $0.backgroundColor == UIColor.clear && $0.layer.shadowOpacity > 0 }
    return ["success": full && centered && lowerHUD && side && closeAligned && landscapeTabs && portraitTabs && portraitCloseHidden && portraitThumbFits && hudShadows && below && routing && time && noBands && smallThumb && filledPlay && noCircles && settings.values.allSatisfy { $0 }, "portraitSettingsCloseHidden": portraitCloseHidden, "noBands": noBands, "noCentralBackgrounds": noCircles, "hudIconShadows": hudShadows, "panelCloseAlignedWithSubtitle": closeAligned, "panelTabsAlignedAcrossOrientations": landscapeTabs && portraitTabs, "lowerHUDWithoutMovingVideo": lowerHUD, "portraitSeekThumbFits": portraitThumbFits, "smallThumb": smallThumb, "fullVideo": full, "centerControls": centered, "landscapePanel": side, "portraitPanel": below, "buttonRouting": routing, "timeToggle": time]
  }
  @objc func showSmokePanel(_ id: String) {
    if id == "settings" { settingsCategory = "general" }
    tab = id == "controls" ? "program" : id; panelOpen = id != "controls"; panel.isHidden = !panelOpen; panel.alpha = 1
    if id == "rules" {
      rulesLoaded = true; ruleHeading = "サンプルルール"
      records = (1...3).map { i in NeoRecording(id: i, name: "サンプル番組 #\(i)", startAt: 1791042600000, endAt: 1791044400000, isRecording: false, description: "関連する番組の説明", extended: nil, channelId: nil, channelName: nil, thumbnails: nil, videoFiles: nil) }
    }
    renderPanel(); showControls(true); setNeedsLayout(); layoutIfNeeded()
  }
  @objc func snapshotSettings(_ category: String, name: String) {
    showSettings(category); layoutIfNeeded(); snapshot(name)
  }
  @objc func snapshotDrawer(_ name: String) {
    UIView.performWithoutAnimation { setDrawer(true); layoutIfNeeded() }; snapshot(name)
    UIView.performWithoutAnimation { setDrawer(false); layoutIfNeeded() }
  }
  @objc func snapshotPiPNotice(_ name: String) {
    updatePiP(true); snapshot(name); updatePiP(false)
  }
  @objc func snapshot(_ name: String) {
    // Capture the settled layout, independently of the fade/resize phase.
    // Interaction tests above exercise the actual animated presentation.
    layoutIfNeeded()
    func settle(_ view: UIView) { view.layer.removeAllAnimations(); view.subviews.forEach(settle) }
    settle(self)
    let image = UIGraphicsImageRenderer(size: bounds.size).image { _ in drawHierarchy(in: bounds, afterScreenUpdates: true) }
    if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png")) }
  }
#endif
}

// Fixed icon and caption slots keep the four tabs aligned on their first
// appearance, independent of UIKit's deferred configuration/font updates.
private final class NeoPlayerPanelTab: UIButton {
  let glyph = UIImageView(), caption = NeoStyle.label(size: 12)
  init(label: String, icon: String) {
    super.init(frame: .zero)
    accessibilityLabel = label; caption.text = label; caption.textAlignment = .center
    glyph.image = NeoIcon.image(icon); glyph.contentMode = .scaleAspectFit
    [glyph, caption].forEach { $0.isUserInteractionEnabled = false; $0.isAccessibilityElement = false; addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError() }
  func setActive(_ active: Bool) {
    tintColor = active ? NeoStyle.accent : NeoStyle.muted
    glyph.tintColor = tintColor; caption.textColor = tintColor
    caption.font = .systemFont(ofSize: active ? 14 : 12)
    accessibilityTraits = active ? [.button, .selected] : .button
    setNeedsLayout()
  }
  override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
  override func layoutSubviews() {
    super.layoutSubviews()
    glyph.frame = CGRect(x: bounds.midX - 12, y: 8, width: 24, height: 24)
    caption.frame = CGRect(x: 0, y: 36, width: bounds.width, height: 24)
  }
}

private final class NeoPlayerGenreBadges: UIView {
  private var badges: [UILabel] = []
  private var measuredHeight: CGFloat = 24
  init(_ genres: [String]) {
    super.init(frame: .zero)
    for genre in genres {
      let label = NeoStyle.label(genre, size: 12, bold: true); label.textAlignment = .center
      label.backgroundColor = .white.withAlphaComponent(0.16); label.layer.cornerRadius = 4; label.clipsToBounds = true
      addSubview(label); badges.append(label)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight) }
  override func layoutSubviews() {
    super.layoutSubviews(); guard bounds.width > 0 else { return }
    var x: CGFloat = 0, y: CGFloat = 0
    for badge in badges {
      let width = min(bounds.width, ceil(badge.intrinsicContentSize.width) + 16)
      if x > 0 && x + width > bounds.width { x = 0; y += 28 }
      badge.frame = CGRect(x: x, y: y, width: width, height: 24); x += width + 6
    }
    if measuredHeight != y + 24 { measuredHeight = y + 24; invalidateIntrinsicContentSize() }
  }
}

private final class NeoPlayerRecordRow: UIControl {
  private let thumbnail = NeoThumbnail(), title = NeoStyle.label(size: 14, bold: true)
  private let date = NeoStyle.label(size: 12, muted: true), summary = NeoStyle.label(size: 12, muted: true)
  private let hasThumbnail: Bool
  init(item: NeoRecording, date: String, current: Bool, api: NeoAPI?) {
    hasThumbnail = item.thumbnails?.first != nil
    super.init(frame: .zero)
    backgroundColor = current ? .white.withAlphaComponent(0.16) : NeoStyle.background
    layer.cornerRadius = 4; clipsToBounds = true; layer.borderWidth = 1; layer.borderColor = (current ? NeoStyle.accent : NeoStyle.border).cgColor
    title.text = item.name; self.date.text = date; summary.text = item.description
    [thumbnail, title, self.date, summary].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
    thumbnail.isHidden = !hasThumbnail; thumbnail.load(item.thumbnails?.first.flatMap { api?.url("/thumbnails/\($0)") })
    heightAnchor.constraint(equalToConstant: 78).isActive = true; accessibilityLabel = item.name
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews(); thumbnail.frame = CGRect(x: 0, y: 0, width: 112, height: bounds.height)
    let x: CGFloat = hasThumbnail ? 122 : 10, width = max(0, bounds.width - x - 10)
    title.frame = CGRect(x: x, y: 7, width: width, height: 22)
    date.frame = CGRect(x: x, y: 31, width: width, height: 18)
    summary.frame = CGRect(x: x, y: 51, width: width, height: 18)
  }
}

// Labels copied from core/program.ts, including the reserved and extended genres.
enum NeoPlayerGenres {
  static let major = ["ニュース・報道", "スポーツ", "情報・ワイドショー", "ドラマ", "音楽", "バラエティ", "映画", "アニメ・特撮", "ドキュメンタリー・教養", "劇場・公演", "趣味・教育", "福祉", "予備", "予備", "拡張", "その他"]
  static let minor: [[String]] = [["定時・総合", "天気", "特集・ドキュメント", "政治・国会", "経済・市況", "海外・国際", "解説", "討論・会談", "報道特番", "ローカル・地域", "交通", "", "", "", "", "その他"], ["スポーツニュース", "野球", "サッカー", "ゴルフ", "その他の球技", "相撲・格闘技", "オリンピック・国際大会", "マラソン・陸上・水泳", "モータースポーツ", "マリン・ウィンタースポーツ", "競馬・公営競技", "", "", "", "", "その他"], ["芸能・ワイドショー", "ファッション", "暮らし・住まい", "健康・医療", "ショッピング・通販", "グルメ・料理", "イベント", "番組紹介・お知らせ", "", "", "", "", "", "", "", "その他"], ["国内ドラマ", "海外ドラマ", "時代劇", "", "", "", "", "", "", "", "", "", "", "", "", "その他"], ["国内ロック・ポップス", "海外ロック・ポップス", "クラシック・オペラ", "ジャズ・フュージョン", "歌謡曲・演歌", "ライブ・コンサート", "ランキング・リクエスト", "カラオケ・のど自慢", "民謡・邦楽", "童謡・キッズ", "民族音楽・ワールドミュージック", "", "", "", "", "その他"], ["クイズ", "ゲーム", "トークバラエティ", "お笑い・コメディ", "音楽バラエティ", "旅バラエティ", "料理バラエティ", "", "", "", "", "", "", "", "", "その他"], ["洋画", "邦画", "アニメ", "", "", "", "", "", "", "", "", "", "", "", "", "その他"], ["国内アニメ", "海外アニメ", "特撮", "", "", "", "", "", "", "", "", "", "", "", "", "その他"], ["社会・時事", "歴史・紀行", "自然・動物・環境", "宇宙・科学・医学", "カルチャー・伝統文化", "文学・文芸", "スポーツ", "ドキュメンタリー全般", "インタビュー・討論", "", "", "", "", "", "", "その他"], ["現代劇・新劇", "ミュージカル", "ダンス・バレエ", "落語・演芸", "歌舞伎・古典", "", "", "", "", "", "", "", "", "", "", "その他"], ["旅・釣り・アウトドア", "園芸・ペット・手芸", "音楽・美術・工芸", "囲碁・将棋", "麻雀・パチンコ", "車・オートバイ", "コンピュータ・ＴＶゲーム", "会話・語学", "幼児・小学生", "中学生・高校生", "大学生・受験", "生涯教育・資格", "教育問題", "", "", "その他"], ["高齢者", "障害者", "社会福祉", "ボランティア", "手話", "文字（字幕）", "音声解説", "", "", "", "", "", "", "", "", "その他"], [], [], ["BS／地上デジタル放送用番組付属情報", "広帯域CSデジタル放送用拡張", "", "サーバー型番組付属情報", "IP放送用番組付属情報"], ["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "その他"]]
  static func labels(_ item: NeoRecording) -> [String] {
    [(item.genre1, item.subGenre1), (item.genre2, item.subGenre2), (item.genre3, item.subGenre3)].compactMap { genre, sub in
      guard let genre else { return nil }
      let name = major.indices.contains(genre) ? major[genre] : "ジャンル \(genre)"
      guard let sub, minor.indices.contains(genre), minor[genre].indices.contains(sub), !minor[genre][sub].isEmpty else { return name }
      return name + " / " + minor[genre][sub]
    }
  }
}

// Explicit artwork prevents iOS 26 from substituting a large Liquid Glass thumb.
private final class NeoPlayerSeekSlider: UISlider {
  override init(frame: CGRect) {
    super.init(frame: frame)
    for (state, side) in [(UIControl.State.normal, CGFloat(12)), (.highlighted, CGFloat(16)), (.disabled, CGFloat(12))] {
      let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
        NeoStyle.accent.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
      }
      setThumbImage(image, for: state)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    CGRect(x: 6, y: bounds.midY - 1.5, width: max(0, bounds.width - 12), height: 3)
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { bounds.insetBy(dx: 0, dy: -6).contains(point) }
}
