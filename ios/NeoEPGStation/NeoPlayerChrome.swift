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
  private let settingsSubtitles = UIButton(type: .system)
  private var isWide: Bool { bounds.width > bounds.height }
  private var panelVisible: Bool { !isWide || panelOpen }
  private let menuButton = UIButton(type: .system), backButton = UIButton(type: .system)
  private let infoButton = UIButton(type: .system), settingsButton = UIButton(type: .system)
  private let rotationButton = UIButton(type: .system), reloadButton = UIButton(type: .system), ruleButton = UIButton(type: .system)
  private let timeButton = UIButton(type: .custom)
  private var jumps: [UIButton] = []
  private let panel = UIView(), panelHeader = UIView(), panelTitle = NeoStyle.label(size: 16, bold: true)
  private let panelClose = UIButton(type: .system), panelTabs = UIView(), panelTabDivider = UIView()
  private let scroll = UIScrollView(), stack = UIStackView()
  private let commentList = UITableView(frame: .zero, style: .plain), followButton = UIButton(type: .system)
  private var tabButtons: [UIButton] = [], tab = "program", followsComments = true, lastCommentIndex = -1
  private var comments: [(time: Double, text: String)] = []
  private var context: [String: Any] = [:], api: NeoAPI?, recording: NeoRecording?
  private var records: [NeoRecording] = [], rulesLoaded = false, ruleHeading = "関連する録画", ruleError: String?
  private var task: Task<Void, Never>?, relatedTask: Task<Void, Never>?, logoTask: URLSessionDataTask?
  private var popup: NeoAnchoredMenu?, remainingTime = false, current: Int64 = 0, duration: Int64 = 0
  private var cacheSeconds = 5, speed: Float = 1
  private let drawer = UIView(), drawerDim = UIButton(type: .custom), drawerTable = UITableView(frame: .zero, style: .plain)
  private let brand = NeoStyle.label("NeoEPGStation", size: 18, bold: true), brandLogo = UIImageView(image: UIImage(named: "Brand"))
  private var drawerOpen = false, drawerStart: CGFloat = 0
  private var diagnostic = "", commentDiagnostic = ""

  @objc(initWithTitle:)
  init(title: String) {
    super.init(frame: .zero); backgroundColor = .black; videoView.backgroundColor = .black
    self.title.text = title; self.title.lineBreakMode = .byTruncatingTail
    channel.textColor = NeoStyle.muted; logo.contentMode = .scaleAspectFit
    [videoView, videoDim, header, controls, centerControls, panel, statusLabel, drawerDim, drawer].forEach(addSubview)
    header.addSubview(leftHeader); header.addSubview(rightHeader)
    [menuButton, backButton, logo, channel, self.title].forEach(leftHeader.addSubview)
    [infoButton, pipButton, commentButton, settingsButton].forEach(rightHeader.addSubview)
    [timeButton, timeline, rotationButton, reloadButton, ruleButton, subtitleButton].forEach(controls.addSubview)
    timeButton.addSubview(timeLabel); timeButton.accessibilityLabel = "再生時間表示を切り替える"
    timeButton.addAction(UIAction { [weak self] _ in self?.remainingTime.toggle(); self?.updateTime() }, for: .touchUpInside)
    configure(menuButton, icon: "Menu", label: "サイドメニュー", action: "menu")
    configure(backButton, icon: "ArrowBack", label: "録画詳細へ戻る", action: "back")
    configure(infoButton, icon: "InfoOutlined", label: "番組情報", action: "program")
    configure(pipButton, icon: "PictureInPictureAltOutlined", label: "コメント付きPiP", action: "pip")
    configure(commentButton, icon: "ChatBubbleOutlineOutlined", label: "コメント設定", action: "comments-settings")
    configure(settingsButton, icon: "SettingsOutlined", label: "プレイヤー設定", action: "settings")
    configure(rotationButton, icon: "ScreenRotation", label: "画面の向きを切り替えて固定", action: "rotate")
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
    ([playButton] + jumps).forEach { button in
      button.backgroundColor = .black.withAlphaComponent(0.55)
      button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.25
      button.layer.shadowRadius = 2; button.layer.shadowOffset = .zero
    }
    timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    timeLabel.textAlignment = .center; timeButton.backgroundColor = .black.withAlphaComponent(0.6)
    timeButton.layer.cornerRadius = 12
    videoDim.backgroundColor = .black.withAlphaComponent(0.18); videoDim.isUserInteractionEnabled = false
    configure(settingsSubtitles, icon: "SubtitlesOutlined", label: "字幕", action: "subtitles")
    centerControls.addSubview(playButton)
    timeline.minimumTrackTintColor = NeoStyle.accent; timeline.maximumTrackTintColor = .white.withAlphaComponent(0.35)
    timeline.thumbTintColor = .white; timeline.accessibilityLabel = "再生位置"
    timeline.addAction(UIAction { [weak self] _ in self?.onAction?("scrub-begin") }, for: .touchDown)
    timeline.addAction(UIAction { [weak self] _ in self?.onAction?("scrub-end") }, for: [.touchUpInside, .touchUpOutside])
    timeline.addAction(UIAction { [weak self] _ in self?.onAction?("scrub-cancel") }, for: .touchCancel)
    panel.backgroundColor = NeoStyle.paper; panel.clipsToBounds = true; panel.isHidden = true
    [panelHeader, scroll, commentList, panelTabs, followButton].forEach(panel.addSubview)
    panelTabDivider.backgroundColor = NeoStyle.border; panelTabs.addSubview(panelTabDivider)
    panelHeader.addSubview(panelTitle); panelHeader.addSubview(panelClose)
    configure(panelClose, icon: "Close", label: "パネルを閉じる", action: "panel-close")
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
      ("comments", "コメント", "ChatBubbleOutlineOutlined"), ("twitter", "Twitter", "Twitter")] {
      let b = UIButton(type: .system); b.accessibilityLabel = label
      var config = UIButton.Configuration.plain(); config.title = label
      config.image = NeoIcon.image(icon)
      config.imagePlacement = .top; config.imagePadding = 4; config.contentInsets = .zero
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = .systemFont(ofSize: 12); return a }
      b.configuration = config; b.addAction(UIAction { [weak self] _ in self?.selectPanel(id, toggle: false) }, for: .touchUpInside)
      panelTabs.addSubview(b); tabButtons.append(b)
    }
    drawer.backgroundColor = NeoStyle.paper; drawerDim.backgroundColor = .black.withAlphaComponent(0.5)
    drawerDim.addAction(UIAction { [weak self] _ in self?.setDrawer(false) }, for: .touchUpInside)
    drawer.addSubview(brand); drawer.addSubview(brandLogo); drawer.addSubview(drawerTable)
    drawerTable.backgroundColor = NeoStyle.paper; drawerTable.separatorStyle = .none
    drawerTable.dataSource = self; drawerTable.delegate = self; drawerTable.rowHeight = 40
    drawerTable.register(UITableViewCell.self, forCellReuseIdentifier: "navigation")
    drawer.isHidden = true; drawerDim.isHidden = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(dragDrawer)); pan.delegate = self
    drawer.addGestureRecognizer(pan)
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
  private func perform(_ action: String) {
    onAction?("interaction")
    switch action {
    case "program", "rules", "settings": selectPanel(action, toggle: true)
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
    videoView.frame = wide ? CGRect(x: 0, y: 0, width: videoWidth, height: bounds.height)
      : CGRect(x: 0, y: safe.top, width: videoWidth, height: videoWidth * 9 / 16)
    videoDim.frame = videoView.frame
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
    let controlsHeight: CGFloat = wide ? 88 : 50
    let bottom = wide ? bounds.height - safe.bottom - 6 : videoView.frame.maxY
    controls.frame = CGRect(x: safe.left + 8, y: bottom - controlsHeight, width: header.bounds.width, height: controlsHeight)
    let timeWidth = min(controls.bounds.width - 48, max(90, timeLabel.intrinsicContentSize.width + 16))
    timeButton.frame = CGRect(x: 4, y: 0, width: max(0, timeWidth), height: 26); timeLabel.frame = timeButton.bounds
    rotationButton.frame = CGRect(x: controls.bounds.width - 44, y: -6, width: 44, height: 40)
    // A small visual thumb with a generous 32pt tracking area, independent of iOS's glass slider styling.
    timeline.frame = CGRect(x: 0, y: 26, width: controls.bounds.width, height: 32)
    for (index, button) in [reloadButton, ruleButton, subtitleButton].enumerated() {
      button.isHidden = !wide
      button.frame = CGRect(x: controls.bounds.width - CGFloat(3 - index) * 44, y: 50, width: 44, height: 38)
    }
    let centerWidth = min(wide ? 400 : 340, max(0, videoWidth - safe.left - rightInset - 16))
    let centerHeight: CGFloat = 64
    centerControls.frame = CGRect(x: (videoWidth - centerWidth) / 2, y: videoView.frame.midY - centerHeight / 2, width: centerWidth, height: centerHeight)
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
    panelTitle.frame = CGRect(x: 14, y: 0, width: max(0, panel.bounds.width - 62), height: 44)
    panelClose.frame = CGRect(x: panel.bounds.width - 44, y: 0, width: 44, height: 44)
    let tabsHeight: CGFloat = tab == "settings" ? 0 : 72
    panelTabs.isHidden = tab == "settings"
    panelTabs.frame = CGRect(x: 0, y: panel.bounds.height - panelBottom - tabsHeight, width: panel.bounds.width, height: tabsHeight)
    panelTabDivider.frame = CGRect(x: 0, y: 0, width: panel.bounds.width, height: 1)
    for (i, b) in tabButtons.enumerated() { b.frame = CGRect(x: CGFloat(i) * panel.bounds.width / 4, y: 0, width: panel.bounds.width / 4, height: tabsHeight) }
    let contentFrame = CGRect(x: 0, y: panelHeader.frame.maxY, width: panel.bounds.width, height: max(0, panelTabs.frame.minY - panelHeader.frame.maxY))
    scroll.frame = contentFrame; commentList.frame = contentFrame
    if tab == "comments" { commentList.frame.size.height = max(0, contentFrame.height - 36) }
    followButton.frame = CGRect(x: 0, y: commentList.frame.maxY, width: panel.bounds.width, height: 36)
    statusLabel.frame = CGRect(x: safe.left + 16, y: header.frame.maxY + 4,
      width: max(0, videoWidth - safe.left - rightInset - 24), height: 32)
    drawerDim.frame = bounds
    let drawerWidth = min(280, bounds.width * 0.8)
    drawer.frame = CGRect(x: drawerOpen ? 0 : -drawerWidth, y: 0, width: drawerWidth, height: bounds.height)
    brand.frame = CGRect(x: 16, y: safe.top + 16, width: 194, height: 40); brandLogo.frame = CGRect(x: 217, y: safe.top + 19, width: 32, height: 32)
    drawerTable.frame = CGRect(x: 0, y: brand.frame.maxY + 12, width: drawerWidth, height: max(0, bounds.height - brand.frame.maxY - safe.bottom - 12))
  }
  @objc func showControls(_ visible: Bool) {
    videoDim.alpha = visible ? 1 : 0
    [header, controls, centerControls].forEach { $0.alpha = visible ? 1 : 0; $0.isUserInteractionEnabled = visible }
  }
  @objc var controlsVisible: Bool { controls.alpha > 0 }
  @objc var interactionOpen: Bool { (isWide && panelOpen) || drawerOpen || popup != nil }
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
  private func selectPanel(_ id: String, toggle: Bool) {
    if toggle && isWide && panelOpen && tab == id { setPanel(false); return }
    tab = id; renderPanel(); setPanel(true)
    if id == "rules" { loadRelated() }
  }
  private func setPanel(_ open: Bool) {
    popup?.dismiss(); panelOpen = open; panel.isHidden = false
    if !open && !isWide { tab = "program"; renderPanel() }
    infoButton.tintColor = open && tab == "program" ? NeoStyle.accent : .white
    ruleButton.tintColor = open && tab == "rules" ? NeoStyle.accent : .white
    settingsButton.tintColor = open && tab == "settings" ? NeoStyle.accent : .white
    setNeedsLayout()
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.16, animations: { self.layoutIfNeeded(); self.panel.alpha = self.panelVisible ? 1 : 0 }) { _ in self.panel.isHidden = !self.panelVisible }
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
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }; scroll.setContentOffset(.zero, animated: false)
    scroll.isHidden = tab == "comments"; commentList.isHidden = tab != "comments"; followButton.isHidden = tab != "comments"
    panelTitle.text = ["program":"番組情報", "rules":"ルール", "comments":"コメント", "twitter":"Twitter", "settings":"プレイヤー設定"][tab]
    for (i, b) in tabButtons.enumerated() {
      let selected = ["program", "rules", "comments", "twitter"][i] == tab
      b.tintColor = selected ? NeoStyle.accent : NeoStyle.muted
      b.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
        var a = a; a.font = .systemFont(ofSize: selected ? 14 : 12); return a
      }
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
    case "twitter": append("Twitter連携は準備中です。", muted: true)
    case "settings":
      let playbackActions = UIStackView(); playbackActions.spacing = 12; playbackActions.distribution = .fillEqually
      let reload = NeoStyle.button("再読み込み") { [weak self] in self?.onAction?("reload") }
      settingsSubtitles.setTitle("字幕", for: .normal); settingsSubtitles.tintColor = NeoStyle.accent
      playbackActions.addArrangedSubview(reload); playbackActions.addArrangedSubview(settingsSubtitles)
      playbackActions.heightAnchor.constraint(equalToConstant: 44).isActive = true; stack.addArrangedSubview(playbackActions)
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
      let row = UIStackView(); row.addArrangedSubview(NeoStyle.label("操作ボタンを自動で隠す")); let toggle = UISwitch(); toggle.isOn = autoHide; toggle.onTintColor = NeoStyle.accent
      toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.autoHide = toggle?.isOn == true }, for: .valueChanged); row.addArrangedSubview(toggle); stack.addArrangedSubview(row)
      append("画面の向き", bold: true)
      for (id, text) in [("auto", "端末の向きに合わせる"), ("portrait", "縦に固定"), ("landscape", "横に固定")] {
        stack.addArrangedSubview(NeoStyle.button(text) { [weak self] in self?.onAction?("orientation:\(id)") })
      }
      append(diagnostic, size: 12, muted: true); append(commentDiagnostic, size: 12, muted: true)
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
  @objc func showSubtitleChoices(_ names: [String]) {
    popup?.dismiss()
    let menu = NeoAnchoredMenu(anchor: isWide ? subtitleButton : settingsSubtitles, entries: (["オフ"] + names).enumerated().map { i, name in
      NeoMenuEntry(title: name) { [weak self] in self?.onAction?("subtitle:\(i - 1)") }
    }, appearance: .actions)
    menu.onDismiss = { [weak self] in self?.popup = nil }; popup = menu; menu.show(in: self)
  }
  private func setDrawer(_ open: Bool) {
    drawerOpen = open; drawer.isHidden = false; drawerDim.isHidden = false; setNeedsLayout()
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, animations: { self.layoutIfNeeded(); self.drawerDim.alpha = open ? 1 : 0 }) { _ in
      self.drawer.isHidden = !self.drawerOpen; self.drawerDim.isHidden = !self.drawerOpen
    }
  }
  @objc private func dragDrawer(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: self).x
    if gesture.state == .began { drawerStart = drawer.frame.minX }
    if gesture.state == .changed { drawer.frame.origin.x = min(0, max(-drawer.bounds.width, drawerStart + translation)); drawerDim.alpha = 1 + drawer.frame.minX / drawer.bounds.width }
    if [.ended, .cancelled].contains(gesture.state) { setDrawer(gesture.state == .cancelled || (translation > -drawer.bounds.width * 0.25 && gesture.velocity(in: self).x > -350)) }
  }
  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard let pan = gesture as? UIPanGestureRecognizer else { return true }; let v = pan.velocity(in: self); return v.x < 0 && abs(v.x) >= abs(v.y)
  }
  func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tableView === drawerTable ? NeoDestination.all.count : comments.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let navigation = tableView === drawerTable
    let cell = tableView.dequeueReusableCell(withIdentifier: navigation ? "navigation" : "comment", for: indexPath)
    var config = cell.defaultContentConfiguration(); config.textProperties.color = .white
    if navigation {
      let item = NeoDestination.all[indexPath.row]; config.text = item.title; config.image = NeoIcon.image(item.icon)
      config.imageProperties.tintColor = NeoStyle.muted; config.textProperties.font = .systemFont(ofSize: 14)
    } else {
      let item = comments[indexPath.row]; config.text = item.text; config.textProperties.font = .systemFont(ofSize: 13)
      config.secondaryText = String(format: "%d:%02d", Int(item.time) / 60, Int(item.time) % 60); config.secondaryTextProperties.color = NeoStyle.muted
    }
    cell.contentConfiguration = config; cell.backgroundColor = NeoStyle.paper; return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if tableView === drawerTable { onAction?("navigate:\(NeoDestination.all[indexPath.row].id)") }
    else { onAction?("seekto:\(comments[indexPath.row].time)") }
  }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { if scrollView === commentList { followsComments = false } }
  @objc func shutdown() { task?.cancel(); relatedTask?.cancel(); logoTask?.cancel(); popup?.dismiss(); onAction = nil }
  deinit { task?.cancel(); relatedTask?.cancel(); logoTask?.cancel() }

#if targetEnvironment(simulator)
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
    let full = videoView.frame == bounds
    let noBands = header.backgroundColor == UIColor.clear && controls.backgroundColor == UIColor.clear && statusLabel.backgroundColor == UIColor.clear
    let smallThumb = timeline.thumbImage(for: .normal)?.size.width == 12
    let filledPlay = playerIcon("PlayArrow", side: 60).size.width == 60
    let centered = centerControls.frame.midX == videoView.frame.midX && centerControls.frame.midY == videoView.frame.midY

    tab = "program"; panelOpen = true; panel.isHidden = false; panel.alpha = 1; renderPanel(); setNeedsLayout(); layoutIfNeeded()
    let side = abs(panel.frame.width / bounds.width - 1/3) < 0.01 && panel.frame.minX == videoView.frame.maxX

    frame = CGRect(x: 0, y: 0, width: 390, height: 844); setNeedsLayout(); layoutIfNeeded()
    let below = panel.frame.minY >= videoView.frame.maxY && panel.frame.maxY == bounds.maxY && rightHeader.frame.minY == 0 && title.isHidden && reloadButton.isHidden

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
    panelOpen = false; tab = "program"; rulesLoaded = false; records = []; renderPanel()

    frame = original; autoHide = originalHide; setNeedsLayout(); layoutIfNeeded()
    return ["success": full && centered && side && below && routing && time && noBands && smallThumb && filledPlay, "noBands": noBands, "smallThumb": smallThumb, "fullVideo": full, "centerControls": centered, "landscapePanel": side, "portraitPanel": below, "buttonRouting": routing, "timeToggle": time]
  }
  @objc func showSmokePanel(_ id: String) {
    tab = id == "controls" ? "program" : id; panelOpen = id != "controls"; panel.isHidden = !panelOpen; panel.alpha = 1
    if id == "rules" {
      rulesLoaded = true; ruleHeading = "サンプルルール"
      records = (1...3).map { i in NeoRecording(id: i, name: "サンプル番組 #\(i)", startAt: 1791042600000, endAt: 1791044400000, isRecording: false, description: "関連する番組の説明", extended: nil, channelId: nil, channelName: nil, thumbnails: nil, videoFiles: nil) }
    }
    renderPanel(); showControls(true); setNeedsLayout(); layoutIfNeeded()
  }
  @objc func snapshot(_ name: String) {
    layoutIfNeeded(); let image = UIGraphicsImageRenderer(size: bounds.size).image { _ in drawHierarchy(in: bounds, afterScreenUpdates: true) }
    if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png")) }
  }
#endif
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
