import UIKit

final class NeoDetailPage: NeoPage {
  private var item: NeoRecording
  private let scroll = UIScrollView(), stack = UIStackView(), thumbnail = NeoThumbnail()
  private let loading = UIActivityIndicatorView(style: .medium)
  private var wide = false
  private var thumbnailSize: [NSLayoutConstraint] = []
  private var task: Task<Void, Never>?
  private let dropStatus = NeoStyle.label(size: 14, muted: true)
  private lazy var playButton = NeoStyle.recordingButton("PLAY", icon: "PlayArrowOutlined") { [weak self] in self?.selectFile() }
  private lazy var streamingButton = NeoStyle.recordingButton("STREAMING", icon: "PlayCircleOutlineOutlined") { [weak self] in self?.selectStreamingFile() }
  private lazy var encodeButton = NeoStyle.recordingButton("ENCODE", icon: "ControlPoint", success: true) { [weak self] in self?.alert("ENCODE の操作は準備中です。") }
  private lazy var thumbButton = NeoStyle.recordingButton("THUMB", icon: "ImageOutlined", success: true) { [weak self] in self?.alert("thumbnail の操作は準備中です。") }
  private let buttonRow = NeoRecordingButtonRow()
  private lazy var moreButton: UIButton = NeoStyle.iconButton("MoreVert", label: "詳細メニューを開く") { [weak self] in
    guard let self else { return }; self.showRecordingMenu(self.item, anchor: self.moreButton, detail: true)
  }
  init(item: NeoRecording, shell: NeoShell) { self.item = item; super.init(title: "録画詳細", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); body.addSubview(scroll); body.addSubview(loading)
    actions = [moreButton]
    dropStatus.numberOfLines = 0
    dropStatus.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showDropLog)))
    stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)])
    render(); loading.startAnimating()
    let api = shell?.api, id = item.id
    task = Task { [weak self] in
      guard let self else { return }
      do {
#if targetEnvironment(simulator)
        if self.shell?.smokeStage.isEmpty == false { self.loading.stopAnimating(); return }
#endif
        guard let api else { return }
        let item = try await api.recording(id); try Task.checkCancellation()
        self.item = item; self.render()
      } catch { if !Task.isCancelled { self.alert(error.localizedDescription) } }
      self.loading.stopAnimating()
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); scroll.frame = body.bounds; loading.center = CGPoint(x: body.bounds.midX, y: 30)
    let isWide = body.bounds.width >= 900
    if wide != isWide { wide = isWide; render() }
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if isViewLoaded { refreshCapabilities() } }
  func refreshCapabilities() {
    guard isViewLoaded else { return }
    var buttons = [playButton, streamingButton]
    if shell?.storage.hideRecordedThumbnailButton == false { buttons.append(thumbButton) }
    buttons.append(encodeButton); buttonRow.setButtons(buttons)
  }
  private func render() {
    stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    NSLayoutConstraint.deactivate(thumbnailSize)
    thumbnail.removeFromSuperview()
    let top = UIStackView(), info = UIStackView()
    top.axis = wide ? .horizontal : .vertical; top.spacing = 8; top.alignment = wide ? .center : .fill
    info.axis = .vertical; info.spacing = 4
    thumbnail.load(item.thumbnails?.first.flatMap { shell?.api?.url("/thumbnails/\($0)") })
#if targetEnvironment(simulator)
    if shell?.smokeStage.isEmpty == false { thumbnail.showFixture(item.id) }
#endif
    top.addArrangedSubview(thumbnail); top.addArrangedSubview(info); stack.addArrangedSubview(top)
    thumbnailSize = [thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9/16)]
    if wide { thumbnailSize.append(thumbnail.widthAnchor.constraint(equalToConstant: 400)) }
    NSLayoutConstraint.activate(thumbnailSize)
    let title = NeoStyle.label(item.name, size: 20, bold: true); title.numberOfLines = 0; info.addArrangedSubview(title)
    let channel = item.channelName ?? item.channelId.flatMap { shell?.channels[$0] } ?? item.channelId.map(String.init) ?? ""
    info.addArrangedSubview(NeoStyle.label(channel, size: 16))
    info.addArrangedSubview(NeoStyle.label(NeoProgramText.interval(start: item.startAt, end: item.endAt), size: 14, muted: true))
    dropStatus.text = NeoProgramText.dropSummary(item)
    let hasErrors = item.dropLogFile?.hasErrors == true
    dropStatus.textColor = hasErrors ? .systemRed : NeoStyle.muted
    dropStatus.font = .systemFont(ofSize: 14, weight: hasErrors ? .bold : .regular)
    dropStatus.isUserInteractionEnabled = item.dropLogFile != nil
    dropStatus.accessibilityTraits = item.dropLogFile == nil ? .staticText : .button
    info.addArrangedSubview(dropStatus)
    moreButton.isEnabled = !(item.videoFiles ?? []).isEmpty
    if !(item.videoFiles ?? []).isEmpty {
      refreshCapabilities()
      info.setCustomSpacing(12, after: dropStatus)
      info.addArrangedSubview(buttonRow)
    } else { info.addArrangedSubview(NeoStyle.label("再生できるファイルがありません。", muted: true)) }
    stack.setCustomSpacing(24, after: top)
    for text in [item.description, item.extended].compactMap({ $0 }) {
      let label = NeoStyle.label(text); label.numberOfLines = 0; stack.addArrangedSubview(label)
    }
  }
  private func selectFile() {
    shell?.showPopup(anchor: playButton, entries: (item.videoFiles ?? []).map { file in
      NeoMenuEntry(title: file.name) { [weak self] in
        guard let self else { return }; self.shell?.play(file, title: self.item.name)
      }
    }, appearance: .files)
  }
  private func selectStreamingFile() {
    let config = shell?.serverConfig
    let files = (item.videoFiles ?? []).filter {
      ($0.type == "ts" && config?.isEnableTSRecordedStream == true) || ($0.type == "encoded" && config?.isEnableEncodedRecordedStream == true)
    }
    guard !files.isEmpty else { alert("STREAMING の操作は準備中です。"); return }
    shell?.showPopup(anchor: streamingButton, entries: files.map { file in
      NeoMenuEntry(title: file.name) { [weak self] in self?.alert("STREAMING の操作は準備中です。") }
    }, appearance: .files)
  }
  @objc private func showDropLog() {
    guard let drop = item.dropLogFile, let shell else { return }
    shell.dismissPopup()
    let dialog = NeoDropLogDialog(id: drop.id, name: item.name, shell: shell)
    dialog.modalPresentationStyle = .overFullScreen; dialog.modalTransitionStyle = .crossDissolve
    present(dialog, animated: shell.smokeStage.isEmpty)
  }
#if targetEnvironment(simulator)
  func smokeOpenPlay() { scroll.setContentOffset(.zero, animated: false); view.layoutIfNeeded(); selectFile() }
  func smokeOpenMenu() { showRecordingMenu(item, anchor: moreButton, detail: true) }
  var smokeDropText: String { dropStatus.text ?? "" }
  var smokePlayFrame: CGRect { playButton.convert(playButton.bounds, to: shell?.view) }
  var smokeButtonsInOneRow: Bool { buttonRow.buttons.count == 3 && buttonRow.buttons.allSatisfy { $0.frame.minY == 0 && $0.frame.maxX <= buttonRow.bounds.width + 0.5 } }
  var smokeButtonTitles: [String] { buttonRow.buttons.compactMap { $0.configuration?.title } }
  func smokeOpenDropLog() { showDropLog() }
  var smokeDropDialogVisible: Bool { (presentedViewController as? NeoDropLogDialog)?.smokeReady == true }
#endif
  deinit { task?.cancel() }
}

// Web RecordedDetailPage action row: spacing=8, height=36. The requested
// three mobile actions fit one row; THUMB can be restored in settings.
final class NeoRecordingButtonRow: UIView {
  private(set) var buttons: [UIButton] = []
  private var height: NSLayoutConstraint!
  init() { super.init(frame: .zero); height = heightAnchor.constraint(equalToConstant: 36); height.isActive = true }
  required init?(coder: NSCoder) { fatalError() }
  func setButtons(_ buttons: [UIButton]) {
    self.buttons.forEach { $0.removeFromSuperview() }; self.buttons = buttons; buttons.forEach(addSubview); setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews(); guard !buttons.isEmpty else { return }
    let widths = buttons.map { max(64, $0.intrinsicContentSize.width) }
    let total = widths.reduce(0, +) + CGFloat(buttons.count - 1) * 8
    let scale = buttons.count <= 3 ? min(1, max(0, bounds.width - CGFloat(buttons.count - 1) * 8) / widths.reduce(0, +)) : 1
    var x: CGFloat = 0, y: CGFloat = 0
    for (button, width) in zip(buttons, widths) {
      let width = min(bounds.width, width * scale)
      if buttons.count > 3 && x > 0 && x + width > bounds.width { x = 0; y += 44 }
      button.frame = CGRect(x: x, y: y, width: width, height: 36); x += width + 8
    }
    let wanted = buttons.count <= 3 || total <= bounds.width ? 36 : y + 36
    if height.constant != wanted { height.constant = wanted }
  }
}

final class NeoDropLogDialog: UIViewController {
  private let id: Int
  private weak var shell: NeoShell?
  private let surface = UIView(), heading: UILabel, closeButton: UIButton
  private let topLine = UIView(), bottomLine = UIView(), backdrop = UIButton(type: .custom)
  private let text = UITextView(), loading = UIActivityIndicatorView(style: .medium)
  private var task: Task<Void, Never>?
  init(id: Int, name: String, shell: NeoShell) {
    self.id = id; self.shell = shell; heading = NeoStyle.label("\(name) - ドロップログ", size: 20, bold: true)
    closeButton = NeoStyle.button("閉じる") { }
    super.init(nibName: nil, bundle: nil)
    closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .clear
    backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.5); backdrop.accessibilityLabel = "ドロップログを閉じる"
    backdrop.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    view.addSubview(backdrop); view.addSubview(surface)
    surface.backgroundColor = NeoStyle.paper; surface.layer.cornerRadius = 12; surface.layer.borderWidth = 1
    surface.layer.borderColor = NeoStyle.border.cgColor; surface.accessibilityViewIsModal = true
    heading.numberOfLines = 0; heading.lineBreakMode = .byCharWrapping
    topLine.backgroundColor = NeoStyle.border; bottomLine.backgroundColor = NeoStyle.border
    text.backgroundColor = .clear; text.textColor = .white
    text.font = .monospacedSystemFont(ofSize: 13, weight: .regular); text.isEditable = false
    text.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16); text.textContainer.lineFragmentPadding = 0
    [heading, text, closeButton, topLine, bottomLine, loading].forEach(surface.addSubview)
    loading.startAnimating()
#if targetEnvironment(simulator)
    if shell?.smokeStage.isEmpty == false {
      text.text = String(repeating: "pid: 0x0000, error: 0, drop: 2, scrambling: 0, packet: 18073, name: PAT\n", count: 32)
      loading.stopAnimating(); return
    }
#endif
    let api = shell?.api
    task = Task { [weak self] in
      guard let self, let api else { return }
      defer { self.loading.stopAnimating() }
      do {
        let result = try await api.dropLog(self.id); try Task.checkCancellation()
        guard self.shell?.api === api else { return }; self.text.text = result; self.view.setNeedsLayout()
      } catch {
        guard !Task.isCancelled, self.shell?.api === api else { return }
        self.text.text = error.localizedDescription; self.view.setNeedsLayout()
      }
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); backdrop.frame = view.bounds
    let safe = view.safeAreaInsets, width = min(900, view.bounds.width - 24)
    let availableHeight = view.bounds.height - safe.top - safe.bottom - 24
    let titleHeight = min(availableHeight * 0.35, ceil(heading.sizeThatFits(CGSize(width: width - 32, height: .greatestFiniteMagnitude)).height))
    let headerHeight = titleHeight + 24, footerHeight: CGFloat = 60
    let contentHeight = max(160, text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    let height = min(availableHeight, headerHeight + footerHeight + contentHeight)
    surface.frame = CGRect(x: (view.bounds.width - width) / 2, y: safe.top + 12 + (availableHeight - height) / 2, width: width, height: height)
    heading.frame = CGRect(x: 16, y: 12, width: width - 32, height: titleHeight)
    topLine.frame = CGRect(x: 0, y: headerHeight, width: width, height: 1)
    bottomLine.frame = CGRect(x: 0, y: height - footerHeight, width: width, height: 1)
    text.frame = CGRect(x: 0, y: headerHeight + 1, width: width, height: max(0, height - headerHeight - footerHeight - 2))
    closeButton.frame = CGRect(x: width - 80, y: height - footerHeight + 9, width: 64, height: 42)
    loading.center = CGPoint(x: width / 2, y: headerHeight + 64)
  }
  private func close() { task?.cancel(); dismiss(animated: shell?.smokeStage.isEmpty != false) }
  override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); task?.cancel() }
#if targetEnvironment(simulator)
  var smokeReady: Bool { isViewLoaded && presentingViewController != nil && text.text.contains("pid:") && surface.bounds.height > 0 }
#endif
  deinit { task?.cancel() }
}
