import UIKit

final class NeoBulkActionsDialog: NeoLiveDialog {
  var onSelect: ((NeoBulkRecordingCommand) -> Void)?
  private let rows = UIStackView()

  override var showsCloseButton: Bool { true }
  override var contentHorizontalInset: CGFloat { view.bounds.width < 600 ? 16 : 24 }
  override var screenHorizontalInset: CGFloat { view.bounds.width < 600 ? 12 : 32 }

  init(onSelect: @escaping (NeoBulkRecordingCommand) -> Void) {
    self.onSelect = onSelect
    super.init(title: "一括操作")
    rows.axis = .vertical
    rows.spacing = 0
    addView(rows)
    addMenuRow("エンコードを一括追加", icon: "ControlPoint", command: .encode)
    addMenuRow("ユーザーを一括変更", icon: "AccountCircleOutlined", command: .user)
    addMenuRow("サブディレクトリへ一括移動", icon: "DriveFileMoveOutlined", command: .move)
    let close = addAction("閉じる") { [weak self] in self?.cancel() }
    close.layer.borderColor = UIColor.white.cgColor
  }

  required init?(coder: NSCoder) { fatalError() }

  override func cancel() {
    guard !isBeingDismissed else { return }
    super.cancel()
  }

  private func addMenuRow(_ title: String, icon: String, command: NeoBulkRecordingCommand) {
    let button = UIButton(type: .system)
    button.contentHorizontalAlignment = .left
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.isUserInteractionEnabled = false
    let image = UIImageView(image: NeoIcon.image(icon))
    image.tintColor = .white
    image.contentMode = .scaleAspectFit
    image.widthAnchor.constraint(equalToConstant: 24).isActive = true
    image.heightAnchor.constraint(equalToConstant: 24).isActive = true
    let iconSlot = UIView()
    iconSlot.addSubview(image)
    image.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      image.leadingAnchor.constraint(equalTo: iconSlot.leadingAnchor),
      image.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
      iconSlot.widthAnchor.constraint(equalToConstant: 36)
    ])
    let label = NeoStyle.label(title, size: 16)
    label.numberOfLines = 2
    [iconSlot, label].forEach(row.addArrangedSubview)
    button.addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
      row.topAnchor.constraint(equalTo: button.topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
    ])
    button.accessibilityLabel = title
    button.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      let callback = self.onSelect
      self.dismiss(animated: true) { callback?(command) }
    }, for: .touchUpInside)
    rows.addArrangedSubview(button)
  }
}

final class NeoBulkRecordingDialog: NeoLiveDialog {
  let command: NeoBulkRecordingCommand
  let records: [NeoRecording]

  private var users: [NeoViewer] = []
  private var directories: [String] = []
  private var filteredDirectories: [String] = []
  private var busy = false
  private var messageText: String?
  private var messageIsError = false
  private var didSetUsers = false
  private var keyboardObservers: [NSObjectProtocol] = []

  private(set) var selectedUser: Int?
  private(set) var subDirectory = ""
  private(set) var deleteOption: NeoBulkDeleteOption = .all
  private(set) var deleteFileNames: Set<String> = []

  var onSubmit: ((NeoBulkRecordingDialog) -> Void)?
  var onClose: (() -> Void)?
  var onRetry: (() -> Void)? { didSet { refreshMessage() } }

  override var maximumWidth: CGFloat { command == .move ? 600 : 444 }
  override var showsCloseButton: Bool { command == .user || command == .move }
  override var contentHorizontalInset: CGFloat { view.bounds.width < 600 ? 16 : 24 }
  override var screenHorizontalInset: CGFloat { view.bounds.width < 600 ? 12 : 32 }

  private let userPicker = NeoSelectButton()
  private let directoryField = UITextField()
  private let directorySuggestions = UIStackView()
  private let directoryScroll = UIScrollView()
  private var directoryHeight: NSLayoutConstraint?
  private let deleteOptionPicker = NeoSelectButton()
  private let deleteRows = UIStackView()
  private let messageLabel = NeoStyle.label(size: 14)
  private let retryButton = UIButton(type: .system)
  private var deleteNameButtons: [String: UIButton] = [:]
  private var submitButton: UIButton?
  private var cancelButton: UIButton?

  init(command: NeoBulkRecordingCommand, records: [NeoRecording]) {
    self.command = command
    self.records = records
    let title: String
    switch command {
    case .user: title = "ユーザーを一括変更"
    case .move: title = "サブディレクトリへ一括移動"
    case .delete: title = "録画を削除"
    case .encode: title = "エンコードを一括追加"
    }
    super.init(title: title)
    buildContent()
  }

  required init?(coder: NSCoder) { fatalError() }

  func setUsers(_ users: [NeoViewer], preferred: Int? = nil) {
    self.users = users.filter { $0.id > 0 }
    didSetUsers = true
    if let selectedUser, !self.users.contains(where: { $0.id == selectedUser }) {
      self.selectedUser = nil
    }
    if selectedUser == nil { selectedUser = self.users.first(where:{$0.id == preferred})?.id ?? self.users.first?.id }
    refreshUserPicker()
    updateControls()
  }

  func setDirectories(_ directories: [String]) {
    var seen = Set<String>()
    self.directories = directories.filter { seen.insert($0).inserted }
    refreshDirectorySuggestions()
  }

  func setBusy(_ busy: Bool, message: String? = nil) {
    self.busy = busy
    messageText = message
    messageIsError = false
    updateControls()
    refreshMessage()
  }

  func setMessage(_ text: String?, error: Bool = false) {
    messageText = text
    messageIsError = error
    refreshMessage()
  }

  override func cancel() {
    guard !isBeingDismissed, !busy else { return }
    super.cancel()
    onClose?()
  }

#if targetEnvironment(simulator)
  var smokeSelectedUser: Int? { selectedUser }
  var smokeSubDirectory: String { directoryField.text ?? subDirectory }
  var smokeDeleteOption: NeoBulkDeleteOption { deleteOption }
  var smokeDeleteFileNames: Set<String> { deleteFileNames }
  var smokeSubmitEnabled: Bool { submitButton?.isEnabled ?? false }
  var smokeBusy: Bool { busy }
  func smokeSelectUser(_ id: Int) { if let user = users.first(where: { $0.id == id }) { selectUser(user) } }
  func smokeSelectDeleteOption(_ option: NeoBulkDeleteOption) { selectDeleteOption(option) }
  func smokeToggleDeleteName(_ name: String) { deleteNameButtons[name]?.sendActions(for: .touchUpInside) }
  func smokeSetSubDirectory(_ value: String) { directoryField.text = value; textDidChange() }
  func smokeChooseDirectory(_ value: String) { if directories.contains(value) { chooseDirectory(value) } }
  func smokeTapSubmit() { submitButton?.sendActions(for: .touchUpInside) }
  func smokeTapCancel() { cancelButton?.sendActions(for: .touchUpInside) }
#endif

  private var hasEncodingSelection: Bool { records.contains { $0.isEncoding == true } }
  private var fileNameOptions: [(name: String, count: Int)] { NeoRecordedBulk.fileNames(records) }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    observeKeyboard()
    if command == .move { directoryField.becomeFirstResponder(); refreshDirectorySuggestions() }
  }

  private func buildContent() {
    switch command {
    case .user:
      addText("選択した \(records.count) 件の録画を別のユーザーへ変更します。")
      addField(label: "変更先ユーザー", picker: userPicker)
      let empty = NeoStyle.label("通常ユーザーを作成してください", size: 13, muted: true)
      empty.numberOfLines = 0
      empty.tag = 410
      addView(empty)
      cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
      submitButton = addAction("変更", filled: true) { [weak self] in self?.submit() }
      refreshUserPicker()
    case .move:
      addText("選択した \(records.count) 件に紐づく、元録画とエンコード済みを含むすべての動画ファイルを移動します。")
      if hasEncodingSelection {
        let warning = NeoStyle.label("エンコード中の録画が含まれています。エンコード完了または停止後に移動してください。", size: 14)
        warning.numberOfLines = 0
        warning.textColor = UIColor(red:255/255,green:226/255,blue:183/255,alpha:1)
        let image = UIImageView(image:NeoIcon.image("ReportProblemOutlined"))
        image.tintColor = UIColor(red:255/255,green:183/255,blue:77/255,alpha:1)
        image.widthAnchor.constraint(equalToConstant:22).isActive = true; image.heightAnchor.constraint(equalToConstant:22).isActive = true
        let alert = UIStackView(arrangedSubviews:[image,warning]); alert.spacing = 12; alert.alignment = .top
        alert.isLayoutMarginsRelativeArrangement = true; alert.directionalLayoutMargins = NSDirectionalEdgeInsets(top:8,leading:16,bottom:8,trailing:16)
        alert.layer.cornerRadius = 4; alert.backgroundColor = UIColor(red:25/255,green:18/255,blue:7/255,alpha:1)
        addView(alert)
      }
      let field = UIStackView(); field.axis = .vertical; field.spacing = 6
      field.addArrangedSubview(NeoStyle.label("移動先サブディレクトリ", size: 14, muted: true))
      directoryField.borderStyle = .none
      directoryField.layer.cornerRadius = 7; directoryField.layer.borderWidth = 1
      directoryField.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
      directoryField.leftView = UIView(frame:CGRect(x:0,y:0,width:14,height:1)); directoryField.leftViewMode = .always
      directoryField.backgroundColor = UIColor.white.withAlphaComponent(0.025)
      directoryField.textColor = .white
      directoryField.tintColor = NeoStyle.accent
      directoryField.font = .systemFont(ofSize: 16)
      directoryField.placeholder = "既存の保存先を選択、または新しい名前を入力"
      directoryField.autocorrectionType = .no
      directoryField.autocapitalizationType = .none
      directoryField.clearButtonMode = .whileEditing
      directoryField.returnKeyType = .done
      directoryField.delegate = self
      directoryField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      directoryField.addTarget(self, action: #selector(directoryChanged), for: .editingChanged)
      field.addArrangedSubview(directoryField)
      directorySuggestions.axis = .vertical
      directorySuggestions.spacing = 0
      directorySuggestions.translatesAutoresizingMaskIntoConstraints = false
      directoryScroll.delaysContentTouches = false; directoryScroll.addSubview(directorySuggestions)
      NSLayoutConstraint.activate([
        directorySuggestions.leadingAnchor.constraint(equalTo:directoryScroll.contentLayoutGuide.leadingAnchor),
        directorySuggestions.trailingAnchor.constraint(equalTo:directoryScroll.contentLayoutGuide.trailingAnchor),
        directorySuggestions.topAnchor.constraint(equalTo:directoryScroll.contentLayoutGuide.topAnchor),
        directorySuggestions.bottomAnchor.constraint(equalTo:directoryScroll.contentLayoutGuide.bottomAnchor),
        directorySuggestions.widthAnchor.constraint(equalTo:directoryScroll.frameLayoutGuide.widthAnchor)
      ])
      directoryHeight = directoryScroll.heightAnchor.constraint(equalToConstant:0); directoryHeight?.isActive = true
      field.addArrangedSubview(directoryScroll)
      addView(field)
      addText("存在しない名前は新しく作成します。空欄のまま実行すると録画ルート直下へ移動します。")
      let roots = NeoStyle.label("複数の録画保存ルートにファイルがある場合は、それぞれのルート内に同じサブディレクトリを作成して移動します。", size: 12, muted: true)
      roots.numberOfLines = 0
      addView(roots)
      cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
      submitButton = addAction("移動", filled: true) { [weak self] in self?.submit() }
    case .delete:
      addText("選択した \(records.count) 件から削除するファイルを選択してください。")
      addField(label: "削除対象", picker: deleteOptionPicker)
      refreshDeletePicker()
      deleteRows.axis = .vertical
      deleteRows.spacing = 0
      addView(deleteRows)
      renderDeleteNames()
      cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
      submitButton = addAction("削除", filled: true) { [weak self] in self?.submit() }
      submitButton?.backgroundColor = UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1)
      submitButton?.tintColor = .white
    case .encode:
      let close = addAction("閉じる") { [weak self] in self?.cancel() }
      close.layer.borderColor = UIColor.white.cgColor
      break
    }
    messageLabel.numberOfLines = 0
    messageLabel.isHidden = true
    retryButton.setTitle("再試行", for: .normal)
    retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    retryButton.addAction(UIAction { [weak self] _ in
      guard let self, !self.busy else { return }
      self.onRetry?()
    }, for: .touchUpInside)
    retryButton.isHidden = true
    let messages = UIStackView(arrangedSubviews: [messageLabel, retryButton])
    messages.axis = .vertical
    messages.spacing = 6
    addView(messages)
    refreshMessage()
    updateControls()
    cancelButton?.layer.borderColor = UIColor.white.cgColor
  }

  private func addField(label: String, picker: NeoSelectButton) {
    let field = UIStackView(); field.axis = .vertical; field.spacing = 6
    field.addArrangedSubview(NeoStyle.label(label, size: 14, muted: true))
    field.addArrangedSubview(picker)
    addView(field)
  }

  private func refreshUserPicker() {
    let selected = users.first { $0.id == selectedUser }
    userPicker.setTitle((selected?.name ?? "ユーザーを選択") + " ▾", for: .normal)
    userPicker.menu = UIMenu(options: [.singleSelection], children: users.map { user in
      UIAction(title: user.name, state: user.id == selectedUser ? .on : .off) { [weak self] _ in
        guard let self, !self.busy else { return }
        self.selectUser(user)
      }
    })
    if let empty = view.viewWithTag(410) { empty.isHidden = !didSetUsers || !users.isEmpty || messageIsError }
    updateControls()
  }

  fileprivate func refreshDirectorySuggestions() {
    for child in directorySuggestions.arrangedSubviews {
      directorySuggestions.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    let query = (directoryField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    filteredDirectories = directoryField.isFirstResponder
      ? directories.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
      : []
    for directory in filteredDirectories {
      let suggestion = UIButton(type: .system)
      suggestion.contentHorizontalAlignment = .left
      suggestion.setTitle(directory, for: .normal)
      suggestion.setTitleColor(.white, for: .normal)
      suggestion.titleLabel?.numberOfLines = 1
      suggestion.titleLabel?.lineBreakMode = .byTruncatingMiddle
      suggestion.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
      suggestion.backgroundColor = NeoStyle.paper
      suggestion.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
      suggestion.addAction(UIAction { [weak self] _ in self?.chooseDirectory(directory) }, for: .touchUpInside)
      directorySuggestions.addArrangedSubview(suggestion)
    }
    directoryHeight?.constant = min(220,CGFloat(filteredDirectories.count)*40)
    directoryScroll.isHidden = filteredDirectories.isEmpty
    view.setNeedsLayout()
  }

  private func chooseDirectory(_ directory: String) {
    guard !busy else { return }
    directoryField.text = directory
    subDirectory = directory
    directoryField.resignFirstResponder()
    refreshDirectorySuggestions()
    updateControls()
  }

  private func renderDeleteNames() {
    for child in deleteRows.arrangedSubviews { deleteRows.removeArrangedSubview(child); child.removeFromSuperview() }
    deleteNameButtons.removeAll()
    guard deleteOption == .names else { return }
    if fileNameOptions.isEmpty {
      let empty = NeoStyle.label("削除できる動画ファイルがありません。", size: 14, muted: true)
      deleteRows.addArrangedSubview(empty)
      return
    }
    for option in fileNameOptions {
      let button = UIButton(type: .system)
      button.contentHorizontalAlignment = .left
      button.titleLabel?.numberOfLines = 2
      button.setTitleColor(.white, for: .normal)
      button.tintColor = deleteFileNames.contains(option.name) ? NeoStyle.accent : NeoStyle.muted
      button.setImage(NeoIcon.image(deleteFileNames.contains(option.name) ? "CheckBox" : "CheckBoxOutlineBlank"), for: .normal)
      button.setTitle("  \(option.name.isEmpty ? "（名前なし）" : option.name) (\(option.count))", for: .normal)
      button.imageView?.contentMode = .scaleAspectFit
      button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      button.accessibilityLabel = "\(option.name.isEmpty ? "名前なし" : option.name) (\(option.count))"
      button.addAction(UIAction { [weak self] _ in
        guard let self, !self.busy else { return }
        if self.deleteFileNames.contains(option.name) { self.deleteFileNames.remove(option.name) }
        else { self.deleteFileNames.insert(option.name) }
        self.renderDeleteNames()
        self.updateControls()
      }, for: .touchUpInside)
      deleteRows.addArrangedSubview(button)
      deleteNameButtons[option.name] = button
    }
  }

  private func refreshDeletePicker() {
    let options: [(NeoBulkDeleteOption, String)] = [(.all, "すべて"), (.original, "オリジナルファイルだけ"), (.encoded, "エンコードファイルだけ"), (.names, "ファイル名を指定")]
    deleteOptionPicker.setTitle((options.first { $0.0 == deleteOption }?.1 ?? "すべて") + " ▾", for: .normal)
    deleteOptionPicker.menu = UIMenu(options: [.singleSelection], children: options.map { option, title in
      UIAction(title: title, state: option == deleteOption ? .on : .off) { [weak self] _ in self?.selectDeleteOption(option) }
    })
  }

  private func selectUser(_ user: NeoViewer) {
    guard !busy else { return }
    selectedUser = user.id
    refreshUserPicker()
  }

  private func selectDeleteOption(_ option: NeoBulkDeleteOption) {
    guard !busy else { return }
    deleteOption = option
    renderDeleteNames()
    refreshDeletePicker()
    updateControls()
  }

  @objc private func directoryChanged() { textDidChange() }

  fileprivate func textDidChange() {
    subDirectory = directoryField.text ?? ""
    refreshDirectorySuggestions()
    updateControls()
  }

  private func observeKeyboard() {
    guard command == .move, keyboardObservers.isEmpty else { return }
    let center = NotificationCenter.default
    keyboardObservers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
      self?.updateKeyboardAvoidance(note)
    })
    keyboardObservers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
      self?.updateKeyboardAvoidance(note)
    })
  }

  private func updateKeyboardAvoidance(_ notification: Notification) {
    guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let keyboardFrame = view.convert(frame, from: nil)
    let overlap = keyboardFrame.maxY >= view.bounds.maxY-1 ? max(0,view.bounds.maxY-keyboardFrame.minY) : 0
    bottomAvoidance = overlap
    view.setNeedsLayout()
    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
    let curveValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
    let options = UIView.AnimationOptions(rawValue: curveValue << 16).union(.beginFromCurrentState)
    UIView.animate(withDuration: duration, delay: 0, options: options) { self.view.layoutIfNeeded() }
  }

  private var canSubmit: Bool {
    guard !busy else { return false }
    switch command {
    case .user: return selectedUser != nil && users.contains { $0.id == selectedUser }
    case .move: return !hasEncodingSelection
    case .delete:
      switch deleteOption {
      default: return !NeoRecordedBulk.targets(records, option: deleteOption, names: deleteFileNames).isEmpty
      }
    case .encode: return false
    }
  }

  private func updateControls() {
    userPicker.isEnabled = !busy && !users.isEmpty
    directoryField.isEnabled = !busy
    directorySuggestions.arrangedSubviews.compactMap { $0 as? UIButton }.forEach { $0.isEnabled = !busy }
    deleteOptionPicker.isEnabled = !busy
    deleteNameButtons.values.forEach { $0.isEnabled = !busy }
    submitButton?.isEnabled = canSubmit
    submitButton?.backgroundColor = canSubmit
      ? (command == .delete ? UIColor(red:244/255,green:67/255,blue:54/255,alpha:1) : NeoStyle.accent)
      : UIColor.white.withAlphaComponent(0.12)
    submitButton?.tintColor = canSubmit ? (command == .delete ? .white : .black) : .white.withAlphaComponent(0.3)
    cancelButton?.isEnabled = !busy
    cancelButton?.layer.borderColor = UIColor.white.withAlphaComponent(busy ? 0.12 : 1).cgColor
    setCloseEnabled(!busy)
    retryButton.isEnabled = !busy
  }

  private func submit() {
    guard canSubmit else { return }
    if command == .move { subDirectory = directoryField.text ?? "" }
    onSubmit?(self)
  }

  private func refreshMessage() {
    guard isViewLoaded else { return }
    messageLabel.text = messageText
    messageLabel.textColor = messageIsError ? UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1) : NeoStyle.muted
    messageLabel.isHidden = messageText == nil || messageText?.isEmpty == true
    retryButton.isHidden = !messageIsError || onRetry == nil || messageText == nil
    updateControls()
  }

  deinit {
    keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }
}

extension NeoBulkRecordingDialog: UITextFieldDelegate {
  func textFieldDidBeginEditing(_ textField: UITextField) { refreshDirectorySuggestions() }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    guard textField.markedTextRange == nil else { return false }
    textDidChange(); textField.resignFirstResponder(); refreshDirectorySuggestions()
    return true
  }
}
