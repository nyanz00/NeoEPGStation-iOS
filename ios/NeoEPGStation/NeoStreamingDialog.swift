import UIKit

// Compact centered card, matching RecordedSelectStreamDialog. Captions use
// the native subtitle path; commentary stays in the shared comment worker.
final class NeoStreamingDialog: UIViewController {
  private let file: NeoVideoFile, qualities: [String], start: (Int, Int) -> Void
  private let card = UIView(), scroll = UIScrollView(), stack = UIStackView()
  private let quality = UIButton(type: .system), subtitle = UIButton(type: .system)
  private let subtitleStatus = NeoStyle.label(size: 12, muted: true)
  private let loader: NeoCommentLoader
  private var watchButton: UIButton?
  private var mode: Int, selectedSubtitle = -1, tracks: [NativeCommentTrack] = [], closed = false
  init(file: NeoVideoFile, qualities: [String], source: URL, start: @escaping (Int, Int) -> Void) {
    self.file = file; self.qualities = qualities; self.start = start
    loader = NeoCommentLoader(source: source, username: "", password: "")
    let saved = UserDefaults.standard.integer(forKey: "player.streaming.mode."+file.type)
    mode = qualities.indices.contains(saved) && !qualities[saved].isEmpty ? saved : (qualities.firstIndex(where: { !$0.isEmpty }) ?? 0)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    card.backgroundColor = NeoStyle.paper; card.layer.cornerRadius = 12; card.clipsToBounds = true
    card.layer.borderWidth = 1; card.layer.borderColor = NeoStyle.border.cgColor
    view.addSubview(card); card.addSubview(scroll); scroll.addSubview(stack)
    stack.axis = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)])
    let title = NeoStyle.label(file.name+" - STREAMING", size: 22, bold: true); title.numberOfLines = 0
    stack.addArrangedSubview(padded(title, top: 12, bottom: 12)); divider()
    let fields = UIStackView(); fields.axis = .vertical; fields.spacing = 12
    let row = UIStackView(); row.spacing = 12; row.distribution = .fillEqually
    let stream = UIButton(type: .system); let type = file.type == "ts" ? "HLS-TS" : "HLS"
    stream.setTitle(type, for: .normal); stream.showsMenuAsPrimaryAction = true
    stream.menu = UIMenu(children: [UIAction(title: type, state: .on) { _ in }])
    row.addArrangedSubview(field("ストリーム", button: stream)); row.addArrangedSubview(field("画質", button: quality))
    fields.addArrangedSubview(row); updateQuality()
    if file.type == "encoded" {
      fields.addArrangedSubview(field("字幕", button: subtitle)); fields.addArrangedSubview(subtitleStatus)
      subtitle.isEnabled = false; subtitle.setTitle("確認中…", for: .normal); loadSubtitles()
    }
    let content = padded(fields, top: 16, bottom: 16); content.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    stack.addArrangedSubview(content); divider()
    let actions = UIStackView(); actions.spacing = 16; actions.addArrangedSubview(UIView())
    let cancel = NeoStyle.button("キャンセル") { [weak self] in self?.cancel() }
    cancel.tintColor = .white; cancel.layer.borderWidth = 1; cancel.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
    let watch = NeoStyle.button("視聴", filled: true) { [weak self] in self?.watch() }
    watchButton = watch; watch.isEnabled = file.type != "encoded"
    for button in [cancel, watch] { button.heightAnchor.constraint(equalToConstant: 42).isActive = true; actions.addArrangedSubview(button) }
    cancel.widthAnchor.constraint(equalToConstant: 116).isActive = true; watch.widthAnchor.constraint(equalToConstant: 74).isActive = true
    stack.addArrangedSubview(padded(actions, top: 12, bottom: 12))
    let tap = UITapGestureRecognizer(target: self, action: #selector(tappedBackground(_:))); tap.cancelsTouchesInView = false; view.addGestureRecognizer(tap)
  }
  private func padded(_ child: UIView, top: CGFloat, bottom: CGFloat) -> UIView {
    let box = UIView(); box.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
      child.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20), child.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
      child.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom)])
    return box
  }
  private func divider() { let line = UIView(); line.backgroundColor = NeoStyle.border; line.heightAnchor.constraint(equalToConstant: 1).isActive = true; stack.addArrangedSubview(line) }
  private func field(_ title: String, button: UIButton) -> UIView {
    let field = UIStackView(); field.axis = .vertical; field.spacing = 3
    field.addArrangedSubview(NeoStyle.label(title, size: 14, muted: true))
    button.contentHorizontalAlignment = .left; button.tintColor = .white; button.titleLabel?.font = .systemFont(ofSize: 18)
    button.titleLabel?.lineBreakMode = .byTruncatingTail; button.showsMenuAsPrimaryAction = true
    button.heightAnchor.constraint(equalToConstant: 38).isActive = true
    let arrow = NeoStyle.label("▾", size: 18); arrow.textAlignment = .right; arrow.isUserInteractionEnabled = false
    arrow.translatesAutoresizingMaskIntoConstraints = false; button.addSubview(arrow)
    NSLayoutConstraint.activate([arrow.trailingAnchor.constraint(equalTo: button.trailingAnchor), arrow.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      arrow.widthAnchor.constraint(equalToConstant: 24), arrow.heightAnchor.constraint(equalToConstant: 24)])
    button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 28)
    field.addArrangedSubview(button)
    let line = UIView(); line.backgroundColor = NeoStyle.muted; line.heightAnchor.constraint(equalToConstant: 1).isActive = true; field.addArrangedSubview(line)
    return field
  }
  private func updateQuality() {
    quality.setTitle(qualities[mode], for: .normal)
    quality.menu = UIMenu(children: qualities.enumerated().filter { !$0.element.isEmpty }.map { index, name in
      UIAction(title: name, state: index == mode ? .on : .off) { [weak self] _ in self?.mode = index; self?.updateQuality() }
    })
  }
  private func loadSubtitles() {
    subtitleStatus.isHidden = true
    loader.ordinaryTracks { [weak self] result in
      DispatchQueue.main.async {
        guard let self, !self.closed else { return }
        if case .success(let tracks) = result {
          self.tracks = tracks
          let saved = UserDefaults.standard.object(forKey: "player.streaming.subtitleIndex") as? Int ?? -1
          self.selectedSubtitle = tracks.contains { $0.subtitleIndex == saved } ? saved : -1
        } else { self.subtitleStatus.text = "字幕を取得できません。字幕なしで視聴できます。"; self.subtitleStatus.isHidden = false }
        self.subtitle.isEnabled = true; self.watchButton?.isEnabled = true; self.updateSubtitle(); self.view.setNeedsLayout()
      }
    }
  }
  private func updateSubtitle() {
    subtitle.setTitle(tracks.first { $0.subtitleIndex == selectedSubtitle }?.displayName ?? "字幕なし", for: .normal)
    let items = [(-1, "字幕なし")]+tracks.map { ($0.subtitleIndex, $0.displayName) }
    subtitle.menu = UIMenu(children: items.map { index, name in
      UIAction(title: name, state: index == selectedSubtitle ? .on : .off) { [weak self] _ in self?.selectedSubtitle = index; self?.updateSubtitle() }
    })
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let area = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 12, dy: 12), width = min(444, area.width)
    scroll.frame = CGRect(x: 0, y: 0, width: width, height: area.height)
    let height = min(area.height, stack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
    card.frame = CGRect(x: area.midX-width/2, y: area.midY-height/2, width: width, height: height); scroll.frame = card.bounds
  }
  @objc private func tappedBackground(_ gesture: UITapGestureRecognizer) { if !card.frame.contains(gesture.location(in: view)) { cancel() } }
  private func cancel() { closed = true; loader.close(); dismiss(animated: true) }
  private func watch() {
    guard !closed else { return }; closed = true; loader.close()
    UserDefaults.standard.set(mode, forKey: "player.streaming.mode."+file.type)
    UserDefaults.standard.set(selectedSubtitle, forKey: "player.streaming.subtitleIndex")
    dismiss(animated: true) { [start, mode, selectedSubtitle] in start(mode, selectedSubtitle) }
  }
#if targetEnvironment(simulator)
  @objc(runLayoutChecksWithSource:) static func runLayoutChecks(source: URL) -> [String: Bool] {
    let file = NeoVideoFile(id: 1, name: "Synthetic recording", type: "encoded", size: 1, filename: nil)
    let dialog = NeoStreamingDialog(file: file, qualities: ["1080p", "720p"], source: source) { _, _ in }
    dialog.loadViewIfNeeded(); dialog.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); dialog.view.layoutIfNeeded()
    dialog.subtitle.setTitle("字幕なし", for: .normal)
    let screenshot = UIGraphicsImageRenderer(size: dialog.view.bounds.size).image { context in dialog.view.layer.render(in: context.cgContext) }
    try? screenshot.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent("streaming-dialog.png"))
    let checks = ["streamingDialogCentered": abs(dialog.card.center.y-dialog.view.bounds.midY) < 1,
      "streamingDialogFitsContent": dialog.card.bounds.height > 200 && dialog.card.bounds.height < 400,
      "streamingDialogNotSystemSheet": dialog.modalPresentationStyle == .overFullScreen,
      "streamingDialogSubtitleField": dialog.subtitle.superview != nil && dialog.quality.superview != dialog.subtitle.superview]
    dialog.closed = true; dialog.loader.close(); return checks
  }
#endif
}
