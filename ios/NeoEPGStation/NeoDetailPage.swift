import UIKit

final class NeoDetailPage: NeoPage {
  private var item: NeoRecording
  private let scroll = UIScrollView(), stack = UIStackView(), thumbnail = NeoThumbnail()
  private let loading = UIActivityIndicatorView(style: .medium)
  private var task: Task<Void, Never>?
  init(item: NeoRecording, shell: NeoShell) { self.item = item; super.init(title: "録画詳細", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); body.addSubview(scroll); body.addSubview(loading)
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
  }
  private func render() {
    stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    thumbnail.load(item.thumbnails?.first.flatMap { shell?.api?.url("/thumbnails/\($0)") })
    stack.addArrangedSubview(thumbnail)
    if thumbnail.constraints.isEmpty { thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9/16).isActive = true }
    let title = NeoStyle.label(item.name, size: 20, bold: true); title.numberOfLines = 0; stack.addArrangedSubview(title)
    let channel = item.channelName ?? item.channelId.flatMap { shell?.channels[$0] } ?? item.channelId.map(String.init) ?? ""
    stack.addArrangedSubview(NeoStyle.label(channel, size: 16))
    stack.addArrangedSubview(NeoStyle.label(NeoProgramText.interval(start: item.startAt, end: item.endAt), size: 14, muted: true))
    let size = (item.videoFiles ?? []).reduce(0) { $0 + $1.size }
    stack.addArrangedSubview(NeoStyle.label(NeoProgramText.bytes(size), size: 14, muted: true))
    if !(item.videoFiles ?? []).isEmpty {
      let row = UIView(); let play = NeoStyle.button("▶  PLAY", filled: true) { [weak self] in self?.selectFile() }
      row.addSubview(play); play.frame = CGRect(x: 0, y: 0, width: 100, height: 36)
      row.heightAnchor.constraint(equalToConstant: 36).isActive = true; stack.addArrangedSubview(row); stack.setCustomSpacing(24, after: row)
    } else { stack.addArrangedSubview(NeoStyle.label("再生できるファイルがありません。", muted: true)) }
    for text in [item.description, item.extended].compactMap({ $0 }) {
      let label = NeoStyle.label(text); label.numberOfLines = 0; stack.addArrangedSubview(label)
    }
  }
  private func selectFile() {
    let sheet = UIAlertController(title: "PLAY", message: "録画ファイルを選択", preferredStyle: .actionSheet)
    for file in item.videoFiles ?? [] {
      sheet.addAction(UIAlertAction(title: "\(file.name) · \(NeoProgramText.bytes(file.size))", style: .default) { [weak self, weak sheet] _ in
        // Action-sheet dismissal completes before the native player is presented.
        guard let self else { return }
        sheet?.dismiss(animated: true) { [weak self] in self?.shell?.play(file, title: self?.item.name ?? "PLAY") }
      })
    }
    sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel)); sheet.popoverPresentationController?.sourceView = stack
    sheet.popoverPresentationController?.sourceRect = CGRect(x: 0, y: stack.bounds.midY, width: 100, height: 36)
    present(sheet, animated: true)
  }
  deinit { task?.cancel() }
}
