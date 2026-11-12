import UIKit

final class NeoRecordingActionDialog: NeoLiveDialog {
  let command: NeoRecordingCommand
  private let item: NeoRecording
  private var files: [NeoVideoFile]
  private var users: [NeoViewer] = []
  private var didSetUsers = false
  private var busy = false
  private var closeRequested = false
  private var messageText: String?
  private var messageIsError = false

  private(set) var selectedUser: Int?
  private(set) var selectedFile: Int?
  private(set) var selectedFiles: Set<Int> = []

  var onSubmit: ((NeoRecordingActionDialog) -> Void)?
  var onDownload: ((NeoVideoFile, Bool) -> Void)?
  var onClose: (() -> Void)?
  var onRetry: (() -> Void)? { didSet { refreshMessage() } }

  override var maximumWidth: CGFloat { command == .download ? 600 : 444 }
  override var showsCloseButton: Bool { command == .user || command == .download }
  override var titleInset: CGFloat? { command == .download ? 16 : nil }
  override var titleVerticalInset: CGFloat? { command == .thumbnail ? 6 : nil }

  private let userPicker = NeoSelectButton()
  private let thumbnailPicker = NeoSelectButton()
  private let emptyUsersLabel = NeoStyle.label("通常ユーザーを作成してください", size: 13, muted: true)
  private let messageLabel = NeoStyle.label(size: 14)
  private let retryButton = UIButton(type: .system)
  private let deleteRows = UIStackView()
  private let videoFileButtons = UIStackView()
  private let playlistButtons = UIStackView()
  private var deleteRowButtons: [Int: UIButton] = [:]
  private var downloadButtons: [UIButton] = []
  private var submitButton: UIButton?
  private var cancelButton: UIButton?

  init(command: NeoRecordingCommand, item: NeoRecording, selectAll: Bool = false) {
    precondition([.download, .user, .thumbnail, .delete].contains(command))
    self.command = command
    self.item = item
    files = item.videoFiles ?? []
    selectedFile = files.first?.id
    if command == .delete && selectAll { selectedFiles = Set(files.map(\.id)) }
    let title: String
    switch command {
    case .download: title = item.name
    case .user: title = "ユーザー変更"
    case .thumbnail: title = "サムネイル再生成"
    case .delete: title = "録画を削除"
    default: title = item.name
    }
    super.init(title: title)
    buildContent()
  }

  required init?(coder: NSCoder) { fatalError() }

  func setUsers(_ users: [NeoViewer], selected: Int?) {
    self.users = users
    didSetUsers = true
    if let selected, users.contains(where: { $0.id == selected }) {
      selectedUser = selected
    } else if let selectedUser, users.contains(where: { $0.id == selectedUser }) {
      self.selectedUser = selectedUser
    } else {
      selectedUser = users.first?.id
    }
    refreshUserPicker()
    updateControls()
  }

  func setFiles(_ files: [NeoVideoFile], selected: Set<Int>? = nil) {
    self.files = files
    let available = Set(files.map(\.id))
    if let selected {
      selectedFiles = selected.intersection(available)
      selectedFile = selected.sorted().first(where: available.contains)
    } else {
      selectedFiles.formIntersection(available)
      if selectedFile.map(available.contains) != true { selectedFile = files.first?.id }
    }
    renderFileRows()
    refreshThumbnailPicker()
    updateControls()
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
    guard !isBeingDismissed, !closeRequested, !(busy && isMutation) else { return }
    closeRequested = true
    super.cancel()
    onClose?()
  }

#if targetEnvironment(simulator)
  var smokeBusy: Bool { busy }
  var smokeMessage: String? { messageText }
  var smokeSubmitEnabled: Bool { submitButton?.isEnabled ?? false }
  var smokeCancelEnabled: Bool { cancelButton?.isEnabled ?? false }
  func smokeSelectUser(_ id: Int) { if let user = users.first(where: { $0.id == id }) { selectUser(user) } }
  func smokeSelectFile(_ id: Int) { if let file = files.first(where: { $0.id == id }) { selectFile(file) } }
  func smokeToggleFile(_ id: Int) { deleteRowButtons[id]?.sendActions(for: .touchUpInside) }
  func smokeTapSubmit() { submitButton?.sendActions(for: .touchUpInside) }
  func smokeTapCancel() { cancelButton?.sendActions(for: .touchUpInside) }
#endif

  private var isMutation: Bool { command != .download }

  private func buildContent() {
    messageLabel.numberOfLines = 0
    messageLabel.isHidden = true
    retryButton.setTitle("再試行", for: .normal)
    retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    retryButton.addAction(UIAction { [weak self] _ in
      guard let self, !self.busy else { return }
      self.onRetry?()
    }, for: .touchUpInside)
    retryButton.isHidden = true
    switch command {
    case .user:
      addText("\(item.name) のユーザーを変更")
      let field = UIStackView(); field.axis = .vertical; field.spacing = 6
      field.addArrangedSubview(NeoStyle.label("ユーザー", size: 14, muted: true))
      stylePicker(userPicker)
      field.addArrangedSubview(userPicker)
      addView(field)
      emptyUsersLabel.numberOfLines = 0
      addView(emptyUsersLabel)
      cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
      submitButton = addAction("変更", filled: true) { [weak self] in self?.submit() }
      refreshUserPicker()
    case .delete:
      addText("\(item.name) から削除するファイルを選択してください。")
      deleteRows.axis = .vertical; deleteRows.spacing = 0
      addView(deleteRows)
      renderFileRows()
      cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
      submitButton = addAction("削除", filled: true) { [weak self] in self?.submit() }
      submitButton?.backgroundColor = Self.errorColor
      submitButton?.tintColor = .white
    case .thumbnail:
      addText("選んだ録画ファイルタイプを元にサムネイルを再生成します。")
      let field = UIStackView(); field.axis = .vertical; field.spacing = 6
      field.addArrangedSubview(NeoStyle.label("録画ファイル", size: 14, muted: true))
      stylePicker(thumbnailPicker)
      field.addArrangedSubview(thumbnailPicker)
      addView(field)
      refreshThumbnailPicker()
      cancelButton = addAction("キャンセル") { [weak self] in self?.cancel() }
      submitButton = addAction("再生成", filled: true) { [weak self] in self?.submit() }
    case .download:
      let videoTitle = NeoStyle.label("video files", size: 16, bold: true)
      addView(videoTitle)
      videoFileButtons.axis = .vertical; videoFileButtons.spacing = 8
      addView(videoFileButtons)
      let playlistTitle = NeoStyle.label("play lists", size: 16, bold: true)
      addView(playlistTitle)
      playlistButtons.axis = .vertical; playlistButtons.spacing = 8
      addView(playlistButtons)
      renderFileRows()
      cancelButton = addAction("閉じる") { [weak self] in self?.cancel() }
      cancelButton?.layer.borderWidth = 0
      cancelButton?.tintColor = NeoStyle.accent
    default:
      break
    }
    addView(messageLabel)
    addView(retryButton)
    refreshMessage()
    updateControls()
  }

  private func refreshUserPicker() {
    let current = users.first { $0.id == selectedUser }
    userPicker.setTitle((current?.name ?? "ユーザーを選択") + " ▾", for: .normal)
    userPicker.menu = UIMenu(options: [.singleSelection], children: users.map { user in
      UIAction(title: user.name, state: user.id == selectedUser ? .on : .off) { [weak self] _ in
        guard let self, !self.busy else { return }
        self.selectUser(user)
      }
    })
    emptyUsersLabel.isHidden = !didSetUsers || !users.isEmpty || messageIsError
  }

  private func refreshThumbnailPicker() {
    let current = files.first { $0.id == selectedFile }
    thumbnailPicker.setTitle((current?.name ?? "録画ファイルを選択") + " ▾", for: .normal)
    thumbnailPicker.menu = UIMenu(options: [.singleSelection], children: files.map { file in
      UIAction(title: file.name, state: file.id == selectedFile ? .on : .off) { [weak self] _ in
        guard let self, !self.busy else { return }
        self.selectFile(file)
      }
    })
  }

  private func renderFileRows() {
    clear(deleteRows); clear(videoFileButtons); clear(playlistButtons)
    deleteRowButtons.removeAll()
    downloadButtons.removeAll()
    for file in files {
      let row = makeDeleteRow(file)
      deleteRowButtons[file.id] = row
      deleteRows.addArrangedSubview(row)

      let videoButton = makeDownloadButton("\(file.name) (\(Self.formatBytes(file.size)))") { [weak self] in
        guard let self, !self.busy else { return }
        self.onDownload?(file, false)
      }
      videoFileButtons.addArrangedSubview(videoButton)
      downloadButtons.append(videoButton)

      let playlistButton = makeDownloadButton(file.name) { [weak self] in
        guard let self, !self.busy else { return }
        self.onDownload?(file, true)
      }
      playlistButtons.addArrangedSubview(playlistButton)
      downloadButtons.append(playlistButton)
    }
    updateDeleteRows()
    updateControls()
  }

  private func selectUser(_ user: NeoViewer) {
    guard !busy else { return }
    selectedUser = user.id
    refreshUserPicker()
    updateControls()
  }

  private func selectFile(_ file: NeoVideoFile) {
    guard !busy else { return }
    selectedFile = file.id
    refreshThumbnailPicker()
    updateControls()
  }

  private func stylePicker(_ picker: NeoSelectButton) {
    picker.layer.cornerRadius = 7
    picker.layer.masksToBounds = true
    picker.backgroundColor = UIColor.white.withAlphaComponent(0.025)
  }

  private func makeDeleteRow(_ file: NeoVideoFile) -> UIButton {
    let button = UIButton(type: .system)
    button.contentHorizontalAlignment = .left
    button.titleLabel?.numberOfLines = 0
    button.titleLabel?.lineBreakMode = .byWordWrapping
    button.titleLabel?.textAlignment = .left
    button.setTitle("\(file.name) (\(Self.formatBytes(file.size)))", for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.tintColor = NeoStyle.accent
    button.setImage(UIImage(systemName: "square"), for: .normal)
    button.imageView?.contentMode = .scaleAspectFit
    button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
    button.titleEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 0)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    button.accessibilityLabel = "\(file.name), \(Self.formatBytes(file.size))"
    button.addAction(UIAction { [weak self, weak button] _ in
      guard let self, !self.busy else { return }
      if self.selectedFiles.contains(file.id) { self.selectedFiles.remove(file.id) }
      else { self.selectedFiles.insert(file.id) }
      if let button { self.updateDeleteRow(button, id: file.id) }
      self.updateControls()
    }, for: .touchUpInside)
    return button
  }

  private func makeDownloadButton(_ title: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    var style = UIButton.Configuration.filled()
    style.title = title
    style.baseBackgroundColor = NeoStyle.accent
    style.baseForegroundColor = NeoStyle.successText
    style.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    style.cornerStyle = .medium
    button.configuration = style
    button.contentHorizontalAlignment = .leading
    button.titleLabel?.numberOfLines = 0
    button.titleLabel?.lineBreakMode = .byWordWrapping
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  private func updateDeleteRows() {
    for (id, button) in deleteRowButtons { updateDeleteRow(button, id: id) }
  }

  private func updateDeleteRow(_ button: UIButton, id: Int) {
    let checked = selectedFiles.contains(id)
    button.setImage(UIImage(systemName: checked ? "checkmark.square.fill" : "square"), for: .normal)
    button.accessibilityValue = checked ? "選択済み" : "未選択"
    button.accessibilityTraits = checked ? [.button, .selected] : [.button]
  }

  private func updateControls() {
    userPicker.isEnabled = !busy && !users.isEmpty
    thumbnailPicker.isEnabled = !busy && files.contains { $0.id == selectedFile }
    deleteRowButtons.values.forEach { $0.isEnabled = !busy }
    downloadButtons.forEach { $0.isEnabled = !busy }
    submitButton?.isEnabled = !busy && canSubmit
    cancelButton?.isEnabled = !(busy && isMutation)
    setCloseEnabled(!(busy && isMutation))
    retryButton.isEnabled = !busy
  }

  private var canSubmit: Bool {
    switch command {
    case .user: return selectedUser != nil
    case .thumbnail: return selectedFile != nil && files.contains { $0.id == selectedFile }
    case .delete: return !selectedFiles.isEmpty
    case .download: return false
    default: return false
    }
  }

  private func submit() {
    guard !busy, canSubmit else { return }
    onSubmit?(self)
  }

  private func refreshMessage() {
    guard isViewLoaded else { return }
    messageLabel.text = messageText
    messageLabel.textColor = messageIsError ? Self.errorColor : NeoStyle.muted
    messageLabel.isHidden = messageText == nil || messageText?.isEmpty == true
    retryButton.isHidden = !messageIsError || onRetry == nil || messageText == nil
    emptyUsersLabel.isHidden = !didSetUsers || !users.isEmpty || messageIsError
    updateControls()
  }

  private func clear(_ stack: UIStackView) {
    for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
  }

  private static let errorColor = UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1)

  private static func formatBytes(_ size: Double) -> String {
    if size >= 1024 * 1024 * 1024 { return String(format: "%.2f GB", size / (1024 * 1024 * 1024)) }
    if size >= 1024 * 1024 { return String(format: "%.1f MB", size / (1024 * 1024)) }
    return "\(max(0, Int((size / 1024).rounded()))) KB"
  }
}
