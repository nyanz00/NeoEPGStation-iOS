import UIKit

final class NeoDetailPage: NeoPage {
  private var item: NeoRecording
  private let scroll = UIScrollView(), stack = UIStackView(), thumbnail = NeoThumbnail()
  private let loading = UIActivityIndicatorView(style: .medium)
  private var wide = false
  private var thumbnailSize: [NSLayoutConstraint] = []
  private var task: Task<Void, Never>?
  private let dropStatus = NeoStyle.label(size: 14, muted: true)
  private lazy var playButton = NeoStyle.button("▶  PLAY", filled: true) { [weak self] in self?.selectFile() }
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
      let row = UIView()
      row.addSubview(playButton); playButton.frame = CGRect(x: 0, y: 0, width: 100, height: 36)
      row.heightAnchor.constraint(equalToConstant: 36).isActive = true; info.addArrangedSubview(row)
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
  @objc private func showDropLog() {
    guard let drop = item.dropLogFile, let shell else { return }
    navigationController?.pushViewController(NeoDropLogPage(id: drop.id, shell: shell), animated: true)
  }
#if targetEnvironment(simulator)
  func smokeOpenPlay() { scroll.setContentOffset(.zero, animated: false); view.layoutIfNeeded(); selectFile() }
  func smokeOpenMenu() { showRecordingMenu(item, anchor: moreButton, detail: true) }
  var smokeDropText: String { dropStatus.text ?? "" }
  var smokePlayFrame: CGRect { playButton.convert(playButton.bounds, to: shell?.view) }
#endif
  deinit { task?.cancel() }
}

final class NeoDropLogPage: NeoPage {
  private let id: Int
  private let text = UITextView(), loading = UIActivityIndicatorView(style: .medium)
  private var task: Task<Void, Never>?
  init(id: Int, shell: NeoShell) { self.id = id; super.init(title: "ドロップログ", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); text.backgroundColor = NeoStyle.background; text.textColor = .white
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isEditable = false
    text.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    body.addSubview(text); body.addSubview(loading); loading.startAnimating()
    let api = shell?.api
    task = Task { [weak self] in
      guard let self, let api else { return }
      defer { self.loading.stopAnimating() }
      do {
        let result = try await api.dropLog(self.id); try Task.checkCancellation()
        guard self.shell?.api === api else { return }; self.text.text = result
      } catch {
        guard !Task.isCancelled, self.shell?.api === api else { return }
        self.text.text = error.localizedDescription
      }
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); text.frame = body.bounds; loading.center = CGPoint(x: body.bounds.midX, y: 32)
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated); if isMovingFromParent { task?.cancel() }
  }
  deinit { task?.cancel() }
}
