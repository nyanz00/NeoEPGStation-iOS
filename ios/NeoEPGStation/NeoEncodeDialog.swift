import UIKit

/// Native counterpart of the recorded-page manual encode dialog.
final class NeoEncodeDialog: NeoLiveDialog {
  let records: [NeoRecording]
  let bulk: Bool
  private var configModes: [String] = []
  private var configDirectories: [String] = []
  private var busy = false
  private var locked = false
  private var completed = 0
  private var total = 0
  private var successCount = 0
  private var failures: [NeoEncodeFailure] = []
  private var messageText: String?
  private var messageError = false
  private var keyboardObservers: [NSObjectProtocol] = []
  private var layoutConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]

  private(set) var settings: NeoAddEncodeSettings
  var directory: String { directoryField.text ?? "" }
  private(set) var sourceVideoFileID: Int?
  private(set) var sourceName = ""
  var onSubmit: ((NeoEncodeDialog) -> Void)?
  var onClose: (() -> Void)?
  var onRetry: (() -> Void)? { didSet { refreshMessage() } }

#if targetEnvironment(simulator)
  var smokeSubmitEnabled: Bool { canSubmit }
  var smokeLocked: Bool { locked }
  var smokeConfigModeCount: Int { configModes.count }
  var smokeConfigDirectoryCount: Int { configDirectories.count }
  func smokeSetSource(_ id: Int?) { sourceVideoFileID = id; sourceName = commonSources.first(where: { $0.id == id })?.name ?? ""; refreshPickers(); refreshControls() }
  func smokeSetMode(_ value: String) { settings.mode = value; refreshPickers(); refreshControls() }
  func smokeSetRoot(_ value: String) { settings.parentDir = value; refreshPickers(); refreshControls() }
  func smokeSetDirectory(_ value: String) { directoryField.text = value }
  func smokeSetOptions(sameDirectory: Bool, removeOriginal: Bool, updateThumbnail: Bool) {
    settings.sameDirectory = sameDirectory; settings.removeOriginal = removeOriginal; settings.updateThumbnail = updateThumbnail; refreshControls()
  }
  func smokeTapSubmit() { submit() }
  func smokeTapCancel() { cancel() }
#endif

  override var maximumWidth: CGFloat { 600 }
  override var showsCloseButton: Bool { true }
  override var contentHorizontalInset: CGFloat { view.bounds.width < 600 ? 16 : 24 }
  override var screenHorizontalInset: CGFloat { view.bounds.width < 600 ? 12 : 32 }
  override var contentBackground: UIColor { UIColor.white.withAlphaComponent(0.04) }

  private let sourcePicker = NeoSelectButton()
  private let modePicker = NeoSelectButton()
  private let rootPicker = NeoSelectButton()
  private let directoryField = UITextField()
  private let sameDirectoryButton = UIButton(type: .system)
  private let removeOriginalButton = UIButton(type: .system)
  private let updateThumbnailButton = UIButton(type: .system)
  private let messageLabel = NeoStyle.label(size: 14)
  private let progressLabel = NeoStyle.label(size: 14, muted: true)
  private let progressBar = UIProgressView(progressViewStyle: .default)
  private let warningLabel = NeoStyle.label(size: 14)
  private let bulkDescription = NeoStyle.label("選択した録画に共通する元ファイルを選んで、一括でエンコードを追加します。", size: 14, muted: true)
  private let failureRows = UIStackView()
  private let sameDirectoryHint = NeoStyle.label("元ファイルがあるフォルダーに保存します。", size: 13, muted: true)
  private let retryButton = UIButton(type: .system)
  private var submitButton: UIButton?
  private var cancelButton: UIButton?
  private var firstRow: UIStackView?
  private var destinationRow: UIStackView?

  init(records: [NeoRecording], bulk: Bool, settings: NeoAddEncodeSettings) {
    self.records = records; self.bulk = bulk; self.settings = settings
    let title = bulk ? "エンコードを一括追加" : (records.first?.name ?? "録画")
    super.init(title: title)
    buildUI()
    refreshControls()
  }
  required init?(coder: NSCoder) { fatalError() }

  func setConfig(_ config: NeoServerConfig) {
    configModes = config.encode
    configDirectories = config.recorded
    if !configModes.contains(settings.mode) { settings.mode = configModes.first ?? "" }
    if !configDirectories.contains(settings.parentDir) { settings.parentDir = configDirectories.first ?? "" }
    if sourceVideoFileID == nil { selectDefaultSource() }
    refreshPickers(); refreshControls()
  }

  func setBusy(_ busy: Bool, completed: Int = 0, total: Int = 0) {
    self.busy = busy; self.completed = completed; self.total = total
    if busy { progressLabel.text = "\(completed) / \(total) 件完了" }
    else if total > 0 { progressLabel.text = nil }
    progressBar.isHidden = total <= 0
    progressBar.progress = total > 0 ? Float(completed) / Float(total) : 0
    refreshControls()
  }

  func setMessage(_ text: String?, error: Bool = false) {
    messageText = text; messageError = error; refreshMessage()
  }

  func setFailures(_ failures: [NeoEncodeFailure], successCount: Int) {
    self.failures = failures; self.successCount = successCount
    locked = true; busy = false
    submitButton?.setTitle(failures.isEmpty ? "完了" : "失敗した録画を再試行", for: .normal)
    renderFailures()
    if failures.isEmpty {
      setMessage("\(successCount) 件のエンコードを追加しました。")
    } else {
      setMessage("\(successCount) 件成功、\(failures.count) 件失敗しました。失敗した録画だけ再試行できます。", error: true)
    }
    refreshControls()
  }

  override func cancel() {
    guard !busy else { return }
    let callback = onClose
    super.cancel()
    callback?()
  }

  private func buildUI() {
    let fields = UIStackView(); fields.axis = .vertical; fields.spacing = 12
    bulkDescription.numberOfLines = 0; bulkDescription.isHidden = !bulk
    fields.addArrangedSubview(bulkDescription)
    let firstRow = makeRow(); self.firstRow = firstRow
    addField("元ファイル", picker: sourcePicker, to: firstRow)
    addField("エンコードプリセット", picker: modePicker, to: firstRow)
    fields.addArrangedSubview(firstRow)
    let destinationRow = makeRow(); self.destinationRow = destinationRow
    addField("保存先", picker: rootPicker, to: destinationRow)
    let directoryBox = UIStackView(); directoryBox.axis = .vertical; directoryBox.spacing = 4
    directoryBox.addArrangedSubview(NeoStyle.label("サブディレクトリ", size: 14, muted: true))
    directoryField.borderStyle = .roundedRect; directoryField.font = .systemFont(ofSize: 16)
    directoryField.autocorrectionType = .no; directoryField.autocapitalizationType = .none; directoryField.spellCheckingType = .no
    directoryField.returnKeyType = .done
    directoryField.addAction(UIAction { [weak self] _ in self?.directoryField.resignFirstResponder() },for:.editingDidEndOnExit)
    directoryField.textColor = .white; directoryField.backgroundColor = UIColor.white.withAlphaComponent(0.025)
    directoryField.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor; directoryField.layer.borderWidth = 1
    directoryField.layer.cornerRadius = 7; directoryField.heightAnchor.constraint(equalToConstant: 44).isActive = true
    directoryField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1)); directoryField.leftViewMode = .always
    directoryBox.addArrangedSubview(directoryField); destinationRow.addArrangedSubview(directoryBox)
    fields.addArrangedSubview(destinationRow)
    warningLabel.numberOfLines = 0; fields.addArrangedSubview(warningLabel)
    sameDirectoryHint.numberOfLines = 0; fields.addArrangedSubview(sameDirectoryHint)
    let options = UIStackView(); options.axis = .vertical; options.spacing = 0
    addCheck("元ファイルと同じ場所に保存", button: sameDirectoryButton, selected: settings.sameDirectory, into: options) { [weak self] in
      guard let self, !self.locked else { return }; self.settings.sameDirectory.toggle(); self.refreshControls()
    }
    addCheck("元ファイル削除", button: removeOriginalButton, selected: settings.removeOriginal, into: options) { [weak self] in
      guard let self, !self.locked else { return }; self.settings.removeOriginal.toggle(); self.refreshControls()
    }
    addCheck("サムネイル再生成", button: updateThumbnailButton, selected: settings.updateThumbnail, into: options) { [weak self] in
      guard let self, !self.locked else { return }; self.settings.updateThumbnail.toggle(); self.refreshControls()
    }
    fields.addArrangedSubview(options)
    progressLabel.numberOfLines = 0; fields.addArrangedSubview(progressLabel)
    progressBar.progressTintColor = NeoStyle.accent; progressBar.trackTintColor = UIColor.white.withAlphaComponent(0.12)
    progressBar.isHidden = true; fields.addArrangedSubview(progressBar)
    messageLabel.numberOfLines = 0; fields.addArrangedSubview(messageLabel)
    failureRows.axis = .vertical; failureRows.spacing = 6; fields.addArrangedSubview(failureRows)
    retryButton.setTitle("再試行", for: .normal); retryButton.setTitleColor(NeoStyle.accent, for: .normal)
    retryButton.contentHorizontalAlignment = .left
    retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
    fields.addArrangedSubview(retryButton)
    addView(fields)
    cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
    submitButton = addAction("追加", filled: true) { [weak self] in self?.submit() }
    directoryField.addTarget(self, action: #selector(directoryChanged), for: .editingChanged)
    observeKeyboard()
    refreshPickers()
  }

  private func makeRow() -> UIStackView {
    let row = UIStackView(); row.axis = .vertical
    row.alignment = .fill; row.spacing = 16; return row
  }
  private func addField(_ title: String, picker: NeoSelectButton, to row: UIStackView) {
    let box = UIStackView(); box.axis = .vertical; box.spacing = 4
    box.addArrangedSubview(NeoStyle.label(title, size: 14, muted: true)); box.addArrangedSubview(picker); row.addArrangedSubview(box)
  }
  private func addCheck(_ title: String, button: UIButton, selected: Bool, into stack: UIStackView, action: @escaping () -> Void) {
    button.contentHorizontalAlignment = .left; button.tintColor = NeoStyle.accent
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    button.addAction(UIAction { [weak self] _ in guard let self, !self.busy && !self.locked else { return }; action() }, for: .touchUpInside); setCheck(button, selected: selected)
    let label = NeoStyle.label(title, size: 15); label.isUserInteractionEnabled = true
    label.accessibilityIdentifier = title
    label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(optionLabelTapped(_:))))
    let row = UIStackView(arrangedSubviews: [button, label]); row.axis = .horizontal; row.alignment = .center; row.spacing = 8
    button.widthAnchor.constraint(equalToConstant: 28).isActive = true; stack.addArrangedSubview(row)
  }
  private func setCheck(_ button: UIButton, selected: Bool) {
    button.setImage(NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank"), for: .normal)
    button.accessibilityLabel = selected ? "選択済み" : "未選択"
  }
  private func refreshPickers() {
    modePicker.setTitle((settings.mode.isEmpty ? "" : settings.mode) + " ▾", for: .normal)
    modePicker.menu = UIMenu(options: [.singleSelection], children: configModes.map { value in
      UIAction(title: value, state: settings.mode == value ? .on : .off) { [weak self] _ in
        guard let self, !self.locked else { return }; self.settings.mode = value; self.refreshPickers(); self.refreshControls()
      }
    })
    rootPicker.setTitle((settings.parentDir.isEmpty ? "" : settings.parentDir) + " ▾", for: .normal)
    rootPicker.menu = UIMenu(options: [.singleSelection], children: configDirectories.map { value in
      UIAction(title: value, state: settings.parentDir == value ? .on : .off) { [weak self] _ in
        guard let self, !self.locked else { return }; self.settings.parentDir = value; self.refreshPickers(); self.refreshControls()
      }
    })
    let sources = commonSources
    if let sourceVideoFileID, let selected = sources.first(where: { $0.id == sourceVideoFileID }) { sourceName = selected.name }
    sourcePicker.setTitle((sourceName.isEmpty ? "" : sourceName) + " ▾", for: .normal)
    sourcePicker.menu = UIMenu(options: [.singleSelection], children: sources.map { source in
      UIAction(title: source.name, state: source.id == sourceVideoFileID ? .on : .off) { [weak self] _ in
        guard let self, !self.locked else { return }; self.sourceVideoFileID = source.id; self.sourceName = source.name; self.refreshPickers(); self.refreshControls()
      }
    })
  }
  private var commonSources: [NeoVideoFile] {
    guard let first = records.first?.videoFiles else { return [] }
    if !bulk { return first }
    let names = NeoEncodePlan.commonSourceNames(records)
    return names.compactMap { name in first.first(where: { $0.name == name }) }
  }
  private func selectDefaultSource() {
    guard let source = commonSources.first else { return }; sourceVideoFileID = source.id; sourceName = source.name
  }
  private var canSubmit: Bool {
    guard !busy, !records.isEmpty else { return false }
    if locked { return !failures.isEmpty }
    guard configModes.contains(settings.mode) else { return false }
    if bulk {
      guard NeoEncodePlan.commonSourceNames(records).contains(sourceName) else { return false }
    } else if sourceVideoFileID == nil { return false }
    return !records.contains(where: \.isRecording) && (settings.sameDirectory || (!settings.parentDir.isEmpty && configDirectories.contains(settings.parentDir)))
  }
  private func refreshControls() {
    guard isViewLoaded else { return }
    sourcePicker.isHidden = false
    [sourcePicker, modePicker, rootPicker].forEach { $0.isEnabled = !busy && !locked }
    let commonAvailable = bulk ? !commonSources.isEmpty : sourceVideoFileID != nil
    sourcePicker.isEnabled = !busy && !locked && commonAvailable
    rootPicker.isEnabled = !busy && !locked && !settings.sameDirectory
    directoryField.isEnabled = !busy && !locked && !settings.sameDirectory
    warningLabel.text = warningText
    warningLabel.textColor = UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1)
    warningLabel.isHidden = warningLabel.text?.isEmpty ?? true
    sameDirectoryHint.isHidden = !bulk || !settings.sameDirectory
    setCheck(sameDirectoryButton, selected: settings.sameDirectory); setCheck(removeOriginalButton, selected: settings.removeOriginal)
    setCheck(updateThumbnailButton, selected: settings.updateThumbnail)
    [sameDirectoryButton, removeOriginalButton, updateThumbnailButton].forEach { $0.isEnabled = !busy && !locked }
    submitButton?.isEnabled = canSubmit
    submitButton?.backgroundColor = canSubmit ? NeoStyle.accent : UIColor.white.withAlphaComponent(0.12)
    submitButton?.tintColor = canSubmit ? .black : UIColor.white.withAlphaComponent(0.3)
    cancelButton?.setTitle(locked && !failures.isEmpty ? "閉じる" : "キャンセル", for: .normal)
    cancelButton?.isEnabled = !busy; cancelButton?.alpha = busy ? 0.4 : 1
    setCloseEnabled(!busy)
    retryButton.isHidden = !messageError || !failures.isEmpty || onRetry == nil
    retryButton.isEnabled = !busy
    if total > 0 {
      progressLabel.text = "\(completed) / \(total) 件完了"
      progressBar.isHidden = false; progressBar.progress = Float(completed) / Float(total)
    }
    sourcePicker.setTitle((sourceName.isEmpty ? "" : sourceName) + " ▾", for: .normal)
    updateRowLayout()
    refreshMessage()
  }
  private func refreshMessage() {
    guard isViewLoaded else { return }
    messageLabel.text = messageText
    messageLabel.textColor = messageError ? UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1) : NeoStyle.muted
    messageLabel.isHidden = messageText == nil || messageText?.isEmpty == true
    retryButton.isHidden = !messageError || !failures.isEmpty || onRetry == nil
  }
  private func submit() {
    guard canSubmit else { return }
    onSubmit?(self)
  }
  @objc private func directoryChanged() { }
  private func renderFailures() {
    failureRows.arrangedSubviews.forEach { failureRows.removeArrangedSubview($0); $0.removeFromSuperview() }
    for failure in failures {
      let label = NeoStyle.label("\(failure.job.recordedName): \(failure.error)", size: 14)
      label.numberOfLines = 0; label.textColor = UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1)
      failureRows.addArrangedSubview(label)
    }
  }
  private var warningText: String? {
    if records.isEmpty { return "録画を選択してください。" }
    if records.contains(where: \.isRecording) { return "録画中の番組はエンコードに追加できません。" }
    if configModes.isEmpty { return "エンコードプリセットがありません。" }
    if bulk && NeoEncodePlan.commonSourceNames(records).isEmpty { return "選択した録画すべてに共通する元ファイルがありません。" }
    if !bulk && commonSources.isEmpty { return "元ファイルがありません。" }
    return nil
  }
  @objc private func optionLabelTapped(_ gesture: UITapGestureRecognizer) {
    guard !busy && !locked, let title = (gesture.view as? UILabel)?.accessibilityIdentifier else { return }
    switch title {
    case "元ファイルと同じ場所に保存": settings.sameDirectory.toggle()
    case "元ファイル削除": settings.removeOriginal.toggle()
    case "サムネイル再生成": settings.updateThumbnail.toggle()
    default: return
    }
    refreshControls()
  }
  private func updateRowLayout() {
    guard let firstRow, let destinationRow else { return }
    let wide = view.bounds.width >= 600
    for row in [firstRow, destinationRow] {
      row.axis = wide ? .horizontal : .vertical
      row.distribution = .fill
      guard row.arrangedSubviews.count == 2 else { continue }
      let key = ObjectIdentifier(row)
      let constraint = layoutConstraints[key] ?? row.arrangedSubviews[1].widthAnchor.constraint(equalTo: row.arrangedSubviews[0].widthAnchor, multiplier: 1.5)
      layoutConstraints[key] = constraint
      constraint.isActive = wide
    }
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); updateRowLayout() }
  private func observeKeyboard() {
    let center = NotificationCenter.default
    keyboardObservers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] in self?.updateKeyboardAvoidance($0) })
    keyboardObservers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] in self?.updateKeyboardAvoidance($0) })
  }
  private func updateKeyboardAvoidance(_ notification: Notification) {
    guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let keyboardFrame = view.convert(frame, from: nil)
    bottomAvoidance = keyboardFrame.maxY >= view.bounds.maxY-1 ? max(0, view.bounds.maxY-keyboardFrame.minY) : 0
    view.setNeedsLayout()
    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
    let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
    UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)) { self.view.layoutIfNeeded() }
  }
  deinit { keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) } }
}
