import UIKit

// MUI Stack direction=row, spacing=1, flexWrap=wrap. Long names are clipped
// only when a single button exceeds the available line width.
private final class NeoInfoFileChoices: UIView {
  var buttons: [UIButton] = []
  var availableWidth: CGFloat = 1 { didSet { if oldValue != availableWidth { invalidateIntrinsicContentSize(); setNeedsLayout() } } }
  private func frames() -> [CGRect] {
    var x: CGFloat = 0, y: CGFloat = 0
    return buttons.map { button in
      let width = min(availableWidth,max(64,ceil(button.titleLabel?.intrinsicContentSize.width ?? 0)+32))
      if x > 0 && x+width > availableWidth { x = 0; y += 44 }
      let frame = CGRect(x:x,y:y,width:width,height:36); x += width+8; return frame
    }
  }
  override var intrinsicContentSize: CGSize { CGSize(width:UIView.noIntrinsicMetric,height:frames().last?.maxY ?? 0) }
  override func layoutSubviews() { super.layoutSubviews(); for (button,frame) in zip(buttons,frames()) { button.frame = frame } }
}

// RecordedItemActions.tsx / VideoInfoView, including stale results and the
// independent keyframe analysis lifecycle. The dialog appears before its GET.
final class NeoRecordedInfoDialog: NeoLiveDialog {
  override var maximumWidth: CGFloat { 900 }
  override var titleInset: CGFloat? { 12 }
  override var contentBackground: UIColor { NeoStyle.paper }
  private let api: NeoAPI, files: [NeoVideoFile], revision: Int
  private let bodyStack = UIStackView(), choices = NeoInfoFileChoices()
  private let message = NeoStyle.label(size:14,muted:true)
  private var selected: Int, latest: [Int:NeoVideoInfo] = [:]
  private var task: Task<Void,Never>?
  private var reanalyze: UIButton!
  private var bodyMinimum: NSLayoutConstraint!
  private var retainedBodyHeight: CGFloat = 24
  private var close: UIButton!
  init(item: NeoRecording, api: NeoAPI) {
    self.api = api; files = item.videoFiles ?? []; selected = files.first?.id ?? 0; revision = api.identityRevision
    super.init(title:"Info")
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); bodyStack.axis = .vertical; bodyStack.spacing = 8
    message.numberOfLines = 0; message.heightAnchor.constraint(greaterThanOrEqualToConstant:20).isActive = true
    bodyMinimum = bodyStack.heightAnchor.constraint(greaterThanOrEqualToConstant:retainedBodyHeight); bodyMinimum.isActive = true
    if files.count > 1 {
      for file in files {
        let button = NeoStyle.button(file.name) { [weak self] in self?.select(file.id) }
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityIdentifier = "recording-info-file-\(file.id)"; button.tag = file.id
        choices.buttons.append(button); choices.addSubview(button)
      }
      addView(choices)
    }
    addView(message); addView(bodyStack)
    reanalyze = addAction("Reanalyze",filled:true) { [weak self] in self?.load(force:true) }
    reanalyze.accessibilityIdentifier = "recording-info-reanalyze"
    close = addAction("閉じる") { [weak self] in self?.cancel() }
    select(selected)
  }
  private func select(_ id: Int) {
    retainedBodyHeight = max(retainedBodyHeight,bodyStack.bounds.height); bodyMinimum.constant = retainedBodyHeight
    selected = id
    for button in choices.buttons {
      button.layer.borderWidth = 1; button.layer.cornerRadius = 6; button.layer.borderColor = NeoStyle.accent.cgColor
      button.backgroundColor = button.tag == id ? NeoStyle.accent : .clear
      button.tintColor = button.tag == id ? NeoStyle.successText : NeoStyle.accent
    }
    UIView.performWithoutAnimation { render(); load(force:false); view.layoutIfNeeded() }
  }
  private func load(force: Bool) {
    task?.cancel(); guard selected > 0 else { return }
    let id = selected; reanalyze.isEnabled = false
    message.text = latest[id] == nil ? "Loading analysis information..." : nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        var force = force
        repeat {
          let value = try await api.videoInfo(id,force:force); force = false
          try Task.checkCancellation(); guard selected == id, api.identityRevision == revision else { return }
          latest[id] = value; message.text = nil; reanalyze.isEnabled = true
          UIView.performWithoutAnimation { render(); view.layoutIfNeeded() }
          if !["pending","analyzing"].contains(value.keyframes?.status ?? "") { break }
          try await Task.sleep(nanoseconds:3_000_000_000)
        } while !Task.isCancelled
      } catch {
        guard !Task.isCancelled, selected == id, api.identityRevision == revision else { return }
        message.text = (latest[id] == nil ? "Could not load analysis information: " : "Could not refresh the latest analysis information: ")+error.localizedDescription
        reanalyze.isEnabled = true; view.setNeedsLayout()
      }
    }
  }
  private func render() {
    bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let info = latest[selected] else { view.setNeedsLayout(); return }
    func row(_ pair: (String,String)) {
      let label = NeoStyle.label(pair.0,size:16,muted:true), value = NeoStyle.label(pair.1,size:16)
      label.numberOfLines = 0; value.numberOfLines = 0; value.lineBreakMode = .byCharWrapping
      label.widthAnchor.constraint(equalToConstant:110).isActive = true
      value.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
      let line = UIStackView(arrangedSubviews:[label,value]); line.spacing = 8; line.alignment = .top; bodyStack.addArrangedSubview(line)
    }
    info.rows.forEach(row)
    if info.keyframes != nil { bodyStack.addArrangedSubview(NeoStyle.label("Keyframe interval (estimated)",size:16,bold:true)); info.keyRows.forEach(row) }
    [("Analyzed",info.analyzed),("Status",info.status)].forEach(row)
    view.setNeedsLayout()
  }
  override func viewDidLayoutSubviews() {
    choices.availableWidth = max(1,min(maximumWidth,view.bounds.width-24)-48)
    super.viewDidLayoutSubviews()
  }
  override func cancel() { task?.cancel(); super.cancel() }
  override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); task?.cancel() }
#if targetEnvironment(simulator)
  var smokeRows: [(String,String)] { guard let value = latest[selected] else { return [] }; return value.rows+value.keyRows+[("Analyzed",value.analyzed),("Status",value.status)] }
  func smokeSelect(_ id: Int) { select(id) }
  func smokeReanalyze() { load(force:true) }
  var smokeMessage: String { message.text ?? "" }
  var smokeChoiceFrames: [CGRect] { choices.layoutIfNeeded(); return choices.buttons.map(\.frame) }
  var smokeBodyHeight: CGFloat { bodyStack.bounds.height }
  var smokeCloseTitle: String? { close.title(for:.normal) }
#endif
  deinit { task?.cancel() }
}
