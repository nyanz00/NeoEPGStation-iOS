import UIKit

/// Native, single-rule counterpart of the Web RuleEditorDialog.
///
/// This controller deliberately owns only the editable presentation state. The
/// presenter validates and persists the returned draft, and calls setSaving(_:)
/// or showSaveError(_:) while that work is in progress.
final class NeoProgramRuleEditor: UIViewController, UITextFieldDelegate {
  private var draft: NeoProgramRuleDraft
  private let editingRule: Bool
  private let users: [NeoViewer]
  private let channels: [NeoLiveChannel]
  private let encodeModes: [String]
  private let directories: [String]
  private let onSave: (NeoProgramRuleDraft) -> Void

  private var saving = false
  private var activeTab = 0
  private var encodeRowCount = 1
  private var bottomAvoidance: CGFloat = 0
  private var keyboardObservers: [NSObjectProtocol] = []
  private var responsiveStacks: [UIStackView] = []
  private var timePrevious: [String: String] = [:]
  private weak var timeStartField: UITextField?
  private weak var timeEndField: UITextField?

  private let backdrop = UIControl()
  private let card = UIView()
  private let titleLabel = NeoStyle.dialogTitle("")
  private lazy var closeButton: UIButton = {
    let value = NeoStyle.iconButton("Close", label: "閉じる") { [weak self] in self?.close() }
    value.accessibilityIdentifier = "ruleEditor.close"
    return value
  }()
  private let userStrip = UIView()
  private let userLabel = NeoStyle.label("予約ユーザー", size: 14, muted: true)
  private let userPicker = NeoSelectButton()
  private let enabledButton = UIButton(type: .system)
  private let tabs = UIView()
  private let recordingTab = UIButton(type: .system)
  private let encodeTab = UIButton(type: .system)
  private let tabIndicator = UIView()
  private let scroll = UIScrollView()
  private let contentStack = UIStackView()
  private let footer = UIView()
  private lazy var cancelButton: UIButton = {
    let value = NeoStyle.button("キャンセル", action: { [weak self] in self?.close() })
    value.accessibilityIdentifier = "ruleEditor.cancel"
    return value
  }()
  private lazy var saveButton: UIButton = {
    let value = NeoStyle.button("追加", filled: true, action: { [weak self] in self?.save() })
    value.accessibilityIdentifier = "ruleEditor.save"
    return value
  }()
  private let errorLabel = NeoStyle.label(size: 14)

  init(
    draft: NeoProgramRuleDraft,
    editing: Bool,
    users: [NeoViewer],
    channels: [NeoLiveChannel],
    encodeModes: [String],
    directories: [String],
    onSave: @escaping (NeoProgramRuleDraft) -> Void
  ) {
    var normalized = draft
    if normalized.encodes.isEmpty {
      normalized.encodes = [NeoProgramRuleEncodeDraft()]
    }
    while normalized.encodes.count < 3 {
      normalized.encodes.append(NeoProgramRuleEncodeDraft())
    }
    if normalized.encodes.count > 3 {
      normalized.encodes = Array(normalized.encodes.prefix(3))
    }

    self.draft = normalized
    self.editingRule = editing
    self.users = users
    self.channels = channels
    self.encodeModes = encodeModes
    self.directories = directories
    self.onSave = onSave

    var lastUsed = 0
    for index in 0..<min(3, normalized.encodes.count) {
      let value = normalized.encodes[index]
      if !value.mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !value.channelIDs.isEmpty
        || !value.parentDirectoryName.isEmpty
        || !value.directory.isEmpty {
        lastUsed = index + 1
      }
    }
    encodeRowCount = max(1, lastUsed)

    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
    view.accessibilityIdentifier = "ruleEditor"
    view.isAccessibilityElement = false

    backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.56)
    backdrop.accessibilityLabel = "閉じる"
    backdrop.accessibilityHint = "背景をタップして閉じます"
    backdrop.accessibilityIdentifier = "ruleEditor.backdrop"
    backdrop.addTarget(self, action: #selector(backdropTapped), for: .touchUpInside)
    view.addSubview(backdrop)

    card.backgroundColor = NeoStyle.paper
    card.layer.cornerRadius = 12
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor
    card.clipsToBounds = true
    card.accessibilityIdentifier = "ruleEditor.card"
    view.addSubview(card)

    titleLabel.attributedText = NeoStyle.dialogTitle(editingRule ? "ルール編集" : "ルール追加").attributedText
    titleLabel.numberOfLines = 0
    titleLabel.accessibilityTraits = .header
    titleLabel.accessibilityIdentifier = "ruleEditor.title"
    card.addSubview(titleLabel)
    card.addSubview(closeButton)

    userStrip.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    userStrip.accessibilityIdentifier = "ruleEditor.userStrip"
    card.addSubview(userStrip)
    userStrip.addSubview(userLabel)
    userStrip.addSubview(userPicker)
    configureUserPicker()
    configureCheckbox(
      enabledButton,
      title: "有効",
      selected: draft.enabled,
      identifier: "ruleEditor.enabled"
    ) { [weak self] in
      guard let self else { return }
      self.draft.enabled.toggle()
      self.refreshCheckbox(self.enabledButton, selected: self.draft.enabled)
    }
    userStrip.addSubview(enabledButton)

    tabs.backgroundColor = UIColor.white.withAlphaComponent(0.04)
    tabs.accessibilityIdentifier = "ruleEditor.tabs"
    card.addSubview(tabs)
    configureTab(recordingTab, title: "録画・保存", identifier: "ruleEditor.tab.recording") { [weak self] in
      self?.selectTab(0)
    }
    configureTab(encodeTab, title: "エンコード", identifier: "ruleEditor.tab.encode") { [weak self] in
      self?.selectTab(1)
    }
    tabs.addSubview(recordingTab)
    tabs.addSubview(encodeTab)
    tabIndicator.backgroundColor = NeoStyle.accent
    tabs.addSubview(tabIndicator)

    scroll.backgroundColor = UIColor.white.withAlphaComponent(0.025)
    scroll.alwaysBounceVertical = true
    scroll.showsVerticalScrollIndicator = true
    scroll.keyboardDismissMode = .interactive
    scroll.accessibilityIdentifier = "ruleEditor.content"
    card.addSubview(scroll)

    contentStack.axis = .vertical
    contentStack.spacing = 16
    contentStack.isLayoutMarginsRelativeArrangement = true
    contentStack.accessibilityIdentifier = "ruleEditor.form"
    scroll.addSubview(contentStack)

    footer.backgroundColor = NeoStyle.paper
    footer.accessibilityIdentifier = "ruleEditor.footer"
    card.addSubview(footer)
    footer.addSubview(cancelButton)
    footer.addSubview(saveButton)
    cancelButton.layer.borderWidth = 1
    cancelButton.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
    cancelButton.tintColor = .white
    saveButton.accessibilityLabel = editingRule ? "更新" : "追加"

    errorLabel.numberOfLines = 0
    errorLabel.textColor = UIColor(red: 244 / 255, green: 67 / 255, blue: 54 / 255, alpha: 1)
    errorLabel.accessibilityIdentifier = "ruleEditor.error"
    errorLabel.isHidden = true

    rebuildContent()
    observeKeyboard()
    // Keep the first frame consistent if the presenter requested a saving
    // state before presenting the editor (for example after a retry).
    setSaving(saving)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    layoutDialog()
  }

  deinit {
    keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  /// The parent calls this around its asynchronous add/update request.
  func setSaving(_ saving: Bool) {
    self.saving = saving
    if isViewLoaded {
      card.isUserInteractionEnabled = !saving
      closeButton.isEnabled = !saving
      cancelButton.isEnabled = !saving
      saveButton.isEnabled = !saving
      saveButton.alpha = saving ? 0.45 : 1
      saveButton.setTitle(saving ? (editingRule ? "更新中…" : "追加中…") : (editingRule ? "更新" : "追加"), for: .normal)
      view.setNeedsLayout()
    }
  }

  /// Leaves the current draft intact so the user can correct a failed request.
  func showSaveError(_ message: String) {
    errorLabel.text = message
    errorLabel.isHidden = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if saving { setSaving(false) }
    if isViewLoaded {
      rebuildContent()
      view.setNeedsLayout()
      view.layoutIfNeeded()
      scroll.setContentOffset(.zero, animated: false)
      if !errorLabel.isHidden { UIAccessibility.post(notification: .announcement, argument: message) }
    }
  }

  private func layoutDialog() {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }

    let wide = view.bounds.width >= 600
    let horizontalInset: CGFloat = wide ? 24 : 16
    let screenInset: CGFloat = wide ? 32 : 12
    let cardWidth = min(860, max(0, view.bounds.width - screenInset * 2))
    let titleWidth = max(0, cardWidth - horizontalInset - 56)
    let titleHeight = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height
    let headerHeight = max(54, titleHeight + 20)
    let userHeight: CGFloat = 64
    let tabHeight: CGFloat = 48
    let footerHeight: CGFloat = 60

    for stack in responsiveStacks {
      stack.axis = wide ? .horizontal : .vertical
    }
    contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 16, leading: horizontalInset, bottom: 16, trailing: horizontalInset
    )
    let fitting = contentStack.systemLayoutSizeFitting(
      CGSize(width: cardWidth, height: .greatestFiniteMagnitude),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let contentHeight = max(1, fitting.height)
    let safeTop = view.safeAreaInsets.top
    let safeBottom = view.safeAreaInsets.bottom
    let usableBottom = view.bounds.height - max(0, bottomAvoidance) - safeBottom - 12
    let usableTop = safeTop + 12
    let availableHeight = max(200, usableBottom - usableTop)
    let heightCap = min(900, availableHeight)
    let desiredHeight = headerHeight + userHeight + tabHeight + contentHeight + footerHeight
    let cardHeight = min(heightCap, max(220, desiredHeight))
    let centerY = min(max((usableTop + usableBottom) / 2, usableTop + cardHeight / 2), usableBottom - cardHeight / 2)
    let cardY = centerY - cardHeight / 2

    backdrop.frame = view.bounds
    card.frame = CGRect(x: (view.bounds.width - cardWidth) / 2, y: cardY, width: cardWidth, height: cardHeight)
    titleLabel.frame = CGRect(x: horizontalInset, y: 10, width: titleWidth, height: titleHeight)
    closeButton.frame = CGRect(x: cardWidth - (wide ? 16 : 12) - 36, y: titleHeight <= 30.5 ? 9 : 11, width: 36, height: 36)

    let userY = headerHeight
    userStrip.frame = CGRect(x: 0, y: userY, width: cardWidth, height: userHeight)
    userLabel.frame = CGRect(x: horizontalInset, y: 22, width: 86, height: 20)
    let enabledWidth: CGFloat = 82
    let pickerX = horizontalInset + userLabel.frame.width + 8
    userPicker.frame = CGRect(
      x: pickerX, y: 10,
      width: max(120, cardWidth - pickerX - horizontalInset - enabledWidth - 8),
      height: 44
    )
    enabledButton.frame = CGRect(x: cardWidth - horizontalInset - enabledWidth, y: 12, width: enabledWidth, height: 40)

    let tabY = userY + userHeight
    tabs.frame = CGRect(x: 0, y: tabY, width: cardWidth, height: tabHeight)
    let tabWidth = cardWidth / 2
    recordingTab.frame = CGRect(x: 0, y: 0, width: tabWidth, height: tabHeight)
    encodeTab.frame = CGRect(x: tabWidth, y: 0, width: tabWidth, height: tabHeight)
    tabIndicator.frame = CGRect(x: activeTab == 0 ? 0 : tabWidth, y: tabHeight - 2, width: tabWidth, height: 2)

    let footerY = cardHeight - footerHeight
    footer.frame = CGRect(x: 0, y: footerY, width: cardWidth, height: footerHeight)
    let footerButtonY: CGFloat = 9
    let footerButtonHeight: CGFloat = 42
    cancelButton.frame = CGRect(x: max(horizontalInset, cardWidth - horizontalInset - 164), y: footerButtonY, width: 76, height: footerButtonHeight)
    saveButton.frame = CGRect(x: cardWidth - horizontalInset - 80, y: footerButtonY, width: 80, height: footerButtonHeight)

    let contentY = tabY + tabHeight
    let contentHeightViewport = max(0, footerY - contentY)
    scroll.frame = CGRect(x: 0, y: contentY, width: cardWidth, height: contentHeightViewport)
    contentStack.frame = CGRect(x: 0, y: 0, width: cardWidth, height: contentHeight)
    scroll.contentSize = CGSize(width: cardWidth, height: contentHeight)
    contentStack.layoutIfNeeded()

  }

  private func rebuildContent() {
    guard isViewLoaded else { return }
    contentStack.arrangedSubviews.forEach {
      contentStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    responsiveStacks.removeAll()
    timeStartField = nil
    timeEndField = nil

    contentStack.addArrangedSubview(errorLabel)
    if activeTab == 0 {
      contentStack.addArrangedSubview(makeRecordingTab())
    } else {
      contentStack.addArrangedSubview(makeEncodeTab())
    }
    contentStack.setNeedsLayout()
    view.setNeedsLayout()
    refreshTabs()
  }

  private func makeRecordingTab() -> UIView {
    let root = verticalStack(spacing: 16)

    let timeToggle = UISwitch()
    timeToggle.isOn = draft.isTimeSpecification
    timeToggle.onTintColor = NeoStyle.accent
    timeToggle.isEnabled = !editingRule && !saving
    timeToggle.accessibilityLabel = "時刻指定"
    timeToggle.accessibilityIdentifier = "ruleEditor.timeSpecification"
    timeToggle.addAction(UIAction { [weak self, weak timeToggle] _ in
      guard let self, let timeToggle else { return }
      self.draft.isTimeSpecification = timeToggle.isOn
      self.rebuildContent()
    }, for: .valueChanged)
    let timeRow = horizontalStack(spacing: 12)
    timeRow.alignment = .center
    let timeLabel = NeoStyle.label("時刻指定", size: 15)
    timeRow.addArrangedSubview(timeLabel)
    timeRow.addArrangedSubview(UIView())
    timeRow.addArrangedSubview(timeToggle)
    root.addArrangedSubview(timeRow)

    if draft.isTimeSpecification {
      let timeFields = verticalStack(spacing: 12)
      let nameField = makeTextField(
        text: draft.timeName, placeholder: "番組名",
        label: "番組名", identifier: "ruleEditor.time.name"
      )
      nameField.addAction(UIAction { [weak self, weak nameField] _ in
        self?.draft.timeName = nameField?.text ?? ""
      }, for: .editingChanged)
      timeFields.addArrangedSubview(labeled("番組名", view: nameField))

      let channelPicker = NeoSelectButton()
      channelPicker.accessibilityLabel = "放送局"
      channelPicker.accessibilityIdentifier = "ruleEditor.time.channel"
      configureTimeChannelPicker(channelPicker)
      timeFields.addArrangedSubview(labeled("放送局", view: channelPicker))

      let start = makeTextField(
        text: draft.startTime, placeholder: "HH:mm",
        label: "開始時刻", identifier: "ruleEditor.time.start"
      )
      let end = makeTextField(
        text: draft.endTime, placeholder: "HH:mm",
        label: "終了時刻", identifier: "ruleEditor.time.end"
      )
      start.keyboardType = .numbersAndPunctuation
      end.keyboardType = .numbersAndPunctuation
      start.returnKeyType = .done
      end.returnKeyType = .done
      start.addTarget(self, action: #selector(timeChanged(_:)), for: .editingChanged)
      end.addTarget(self, action: #selector(timeChanged(_:)), for: .editingChanged)
      addTimePicker(to: start, title: "開始時刻")
      addTimePicker(to: end, title: "終了時刻")
      timePrevious["start"] = start.text ?? ""
      timePrevious["end"] = end.text ?? ""
      timeStartField = start
      timeEndField = end
      let range = horizontalStack(spacing: 12)
      range.addArrangedSubview(labeled("開始時刻", view: start))
      range.addArrangedSubview(labeled("終了時刻", view: end))
      responsiveStacks.append(range)
      timeFields.addArrangedSubview(range)

      let week = horizontalStack(spacing: 4)
      week.distribution = .fillEqually
      for (index, title) in ["日", "月", "火", "水", "木", "金", "土"].enumerated() {
        let bit = 1 << index
        let button = checkboxButton(
          title: title, selected: draft.week & bit != 0,
          identifier: "ruleEditor.time.week.\(bit)"
        ) { [weak self] in
          guard let self else { return }
          if self.draft.week & bit != 0 { self.draft.week &= ~bit }
          else { self.draft.week |= bit }
          self.refreshCheckboxInContent(
            identifier: "ruleEditor.time.week.\(bit)",
            selected: self.draft.week & bit != 0
          )
        }
        week.addArrangedSubview(button)
      }
      timeFields.addArrangedSubview(labeled("曜日", view: week))
      root.addArrangedSubview(timeFields)
    }

    root.addArrangedSubview(checkboxButton(
      title: "状況に応じて末尾切れを許可",
      selected: draft.allowEndLack,
      identifier: "ruleEditor.allowEndLack"
    ) { [weak self] in
      guard let self else { return }
      self.draft.allowEndLack.toggle()
      self.refreshCheckboxInContent(identifier: "ruleEditor.allowEndLack", selected: self.draft.allowEndLack)
    })
    root.addArrangedSubview(makeSeparator())

    root.addArrangedSubview(makeSection("重複回避") {
      let stack = verticalStack(spacing: 10)
      stack.addArrangedSubview(self.checkboxButton(
        title: "録画済み番組を除外",
        selected: self.draft.avoidDuplicate,
        identifier: "ruleEditor.avoidDuplicate"
      ) { [weak self] in
        guard let self else { return }
        self.draft.avoidDuplicate.toggle()
        self.refreshCheckboxInContent(identifier: "ruleEditor.avoidDuplicate", selected: self.draft.avoidDuplicate)
      })
      let days = self.makeTextField(
        text: self.draft.duplicateDays, placeholder: "日数",
        label: "対象日数", identifier: "ruleEditor.duplicateDays"
      )
      days.keyboardType = .decimalPad
      days.addAction(UIAction { [weak self, weak days] _ in
        self?.draft.duplicateDays = days?.text ?? ""
      }, for: .editingChanged)
      stack.addArrangedSubview(self.labeled("対象日数", view: days))
      return stack
    })
    root.addArrangedSubview(makeSeparator())

    root.addArrangedSubview(makeSection("録画ファイル") {
      let stack = self.verticalStack(spacing: 12)
      let directoryPicker = NeoSelectButton()
      directoryPicker.accessibilityLabel = "保存先"
      directoryPicker.accessibilityIdentifier = "ruleEditor.recording.parentDirectory"
      self.configureDirectoryPicker(directoryPicker, selected: self.draft.parentDirectoryName) { [weak self] value in
        self?.draft.parentDirectoryName = value
      }
      let directory = self.makeTextField(
        text: self.draft.directory, placeholder: "サブディレクトリ",
        label: "サブディレクトリ", identifier: "ruleEditor.recording.directory"
      )
      directory.addAction(UIAction { [weak self, weak directory] _ in
        self?.draft.directory = directory?.text ?? ""
      }, for: .editingChanged)
      let destination = self.horizontalStack(spacing: 12)
      destination.addArrangedSubview(self.labeled("保存先", view: directoryPicker))
      destination.addArrangedSubview(self.labeled("サブディレクトリ", view: directory))
      self.responsiveStacks.append(destination)
      stack.addArrangedSubview(destination)

      let format = self.makeTextField(
        text: self.draft.recordedFormat, placeholder: "ファイル名形式",
        label: "ファイル名形式", identifier: "ruleEditor.recording.format"
      )
      format.addAction(UIAction { [weak self, weak format] _ in
        self?.draft.recordedFormat = format?.text ?? ""
      }, for: .editingChanged)
      stack.addArrangedSubview(self.labeled("ファイル名形式", view: format))
      return stack
    })
    return root
  }

  private func makeEncodeTab() -> UIView {
    let root = verticalStack(spacing: 16)
    for index in 0..<encodeRowCount {
      let row = makeEncodeRow(index: index)
      root.addArrangedSubview(row)
    }

    let addRow = horizontalStack(spacing: 12)
    let add = NeoStyle.button("エンコードを追加", action: { [weak self] in self?.addEncodeRow() })
    add.setImage(NeoIcon.image("ControlPoint"), for: .normal)
    add.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
    add.accessibilityIdentifier = "ruleEditor.encode.add"
    add.isEnabled = encodeRowCount < 3 && !saving
    addRow.addArrangedSubview(add)
    let maximum = NeoStyle.label("最大3件", size: 13, muted: true)
    addRow.addArrangedSubview(maximum)
    addRow.addArrangedSubview(UIView())
    root.addArrangedSubview(addRow)
    root.addArrangedSubview(makeSeparator())

    root.addArrangedSubview(makeSection("共通設定") {
      let stack = self.verticalStack(spacing: 10)
      stack.addArrangedSubview(self.checkboxButton(
        title: "エンコード後に元ファイルを削除",
        selected: self.draft.deleteOriginal,
        identifier: "ruleEditor.encode.deleteOriginal"
      ) { [weak self] in
        guard let self else { return }
        self.draft.deleteOriginal.toggle()
        self.refreshCheckboxInContent(identifier: "ruleEditor.encode.deleteOriginal", selected: self.draft.deleteOriginal)
      })
      stack.addArrangedSubview(self.checkboxButton(
        title: "サムネイル再生成",
        selected: self.draft.updateThumbnail,
        identifier: "ruleEditor.encode.updateThumbnail"
      ) { [weak self] in
        guard let self else { return }
        self.draft.updateThumbnail.toggle()
        self.refreshCheckboxInContent(identifier: "ruleEditor.encode.updateThumbnail", selected: self.draft.updateThumbnail)
      })
      let delay = self.makeTextField(
        text: self.draft.delayMinutes, placeholder: "分",
        label: "エンコード開始待機時間（分）", identifier: "ruleEditor.encode.delayMinutes"
      )
      delay.keyboardType = .numberPad
      delay.addAction(UIAction { [weak self, weak delay] _ in
        self?.draft.delayMinutes = delay?.text ?? ""
      }, for: .editingChanged)
      delay.isEnabled = self.draft.encodes.prefix(self.encodeRowCount).allSatisfy { $0.mode.isEmpty }
        ? false : !self.saving
      stack.addArrangedSubview(self.labeled("エンコード開始待機時間（分）", view: delay))
      let hint = NeoStyle.label("録画完了後、通常のエンコードキューへ投入するまで待機", size: 12, muted: true)
      hint.numberOfLines = 0
      stack.addArrangedSubview(hint)
      return stack
    })
    return root
  }

  private func makeEncodeRow(index: Int) -> NeoRuleEncodeRow {
    let row = NeoRuleEncodeRow(index: index)
    row.accessibilityIdentifier = "ruleEditor.encode.\(index + 1)"
    responsiveStacks.append(row.destinationStack)
    row.deleteButton.addAction(UIAction { [weak self] _ in
      self?.removeEncodeRow(index: index)
    }, for: .touchUpInside)
    row.directoryField.tag = index
    row.directoryField.addTarget(self, action: #selector(encodeDirectoryChanged(_:)), for: .editingChanged)
    configureModePicker(row.modePicker, index: index)
    configureChannelPicker(row.channelPicker, index: index)
    configureDirectoryPicker(row.parentDirectoryPicker, selected: draft.encodes[index].parentDirectoryName) { [weak self] value in
      guard let self, self.draft.encodes.indices.contains(index) else { return }
      self.draft.encodes[index].parentDirectoryName = value
    }
    row.directoryField.text = draft.encodes[index].directory
    return row
  }

  private func addEncodeRow() {
    guard !saving, encodeRowCount < 3 else { return }
    draft.encodes[encodeRowCount] = NeoProgramRuleEncodeDraft()
    encodeRowCount += 1
    rebuildContent()
  }

  private func removeEncodeRow(index: Int) {
    guard !saving, encodeRowCount > 1, index < encodeRowCount else { return }
    if index < 2 {
      for offset in index..<2 {
        draft.encodes[offset] = draft.encodes[offset + 1]
      }
    }
    draft.encodes[2] = NeoProgramRuleEncodeDraft()
    encodeRowCount -= 1
    rebuildContent()
  }

  @objc private func encodeDirectoryChanged(_ sender: UITextField) {
    guard draft.encodes.indices.contains(sender.tag) else { return }
    draft.encodes[sender.tag].directory = sender.text ?? ""
  }

  @objc private func timeChanged(_ sender: UITextField) {
    let key: String
    if sender === timeStartField {
      key = "start"
    } else {
      key = "end"
    }
    let previous = timePrevious[key] ?? ""
    let value = NeoProgramSearchTime.editing(sender.text ?? "", previous: previous)
    if sender.text != value { sender.text = value }
    timePrevious[key] = value
    if key == "start" { draft.startTime = value }
    else { draft.endTime = value }
  }

  private func addTimePicker(to field: UITextField, title: String) {
    let button = NeoStyle.iconButton("ScheduleOutlined", label: "\(title)を時計から選択") { [weak self, weak field] in
      guard let self, let field, !saving, presentedViewController == nil else { return }
      view.endEditing(true)
      let picker = NeoProgramSearchPickerController(kind: .time, value: field.text ?? "", fieldLabel: title) { [weak self, weak field] value in
        guard let field else { return }
        field.text = value
        self?.timeChanged(field)
      }
      present(picker, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    field.rightView = button
    field.rightViewMode = .always
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  private func save() {
    guard !saving else { return }
    view.endEditing(true)
    // The editor pads its internal rows so adding a row is cheap. Do not leak
    // those UI-only empty slots into the model comparison/persistence layer.
    var value = draft
    value.encodes = Array(draft.encodes.prefix(encodeRowCount))
    onSave(value)
  }

  private func close() {
    guard !saving else { return }
    view.endEditing(true)
    dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
  }

  private func selectTab(_ tab: Int) {
    guard !saving, tab != activeTab else { return }
    view.endEditing(true)
    activeTab = tab
    rebuildContent()
    scroll.setContentOffset(.zero, animated: false)
  }

  private func refreshTabs() {
    let selected = UIColor.white
    let unselected = NeoStyle.muted
    recordingTab.setTitleColor(activeTab == 0 ? selected : unselected, for: .normal)
    encodeTab.setTitleColor(activeTab == 1 ? selected : unselected, for: .normal)
    encodeTab.setTitle("エンコード \(encodeRowCount)", for: .normal)
    tabIndicator.frame = CGRect(x: activeTab == 0 ? 0 : tabs.bounds.width / 2, y: max(0, tabs.bounds.height - 2), width: tabs.bounds.width / 2, height: 2)
  }

  private func configureTab(_ button: UIButton, title: String, identifier: String, action: @escaping () -> Void) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    button.accessibilityIdentifier = identifier
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
  }

  private func configureUserPicker() {
    var entries = users.filter { $0.id > 0 }.map { ($0.id, $0.name) }
    if let selected = draft.userID, !entries.contains(where: { $0.0 == selected }) {
      entries.insert((selected, "ユーザー \(selected)"), at: 0)
    }
    let selectedName = draft.userID.flatMap { id in entries.first(where: { $0.0 == id })?.1 } ?? "ユーザーを選択"
    userPicker.setTitle("\(selectedName) ▾", for: .normal)
    userPicker.accessibilityIdentifier = "ruleEditor.user"
    userPicker.accessibilityLabel = "予約ユーザー"
    userPicker.menu = UIMenu(options: [.singleSelection], children: entries.map { id, name in
      UIAction(title: name, state: id == draft.userID ? .on : .off) { [weak self] _ in
        guard let self else { return }
        self.draft.userID = id
        self.configureUserPicker()
      }
    })
  }

  private func configureTimeChannelPicker(_ picker: NeoSelectButton) {
    var entries = channels.map { ($0.id, $0.name) }
    if let selected = draft.timeChannelID, !entries.contains(where: { $0.0 == selected }) {
      entries.insert((selected, "チャンネル \(selected)"), at: 0)
    }
    let title = draft.timeChannelID.flatMap { id in entries.first(where: { $0.0 == id })?.1 } ?? "放送局を選択"
    picker.setTitle("\(title) ▾", for: .normal)
    picker.menu = UIMenu(options: [.singleSelection], children: entries.map { id, name in
      UIAction(title: name, state: id == draft.timeChannelID ? .on : .off) { [weak self, weak picker] _ in
        guard let self, let picker else { return }
        self.draft.timeChannelID = id
        self.configureTimeChannelPicker(picker)
      }
    })
  }

  private func configureModePicker(_ picker: NeoSelectButton, index: Int) {
    guard draft.encodes.indices.contains(index) else { return }
    let current = draft.encodes[index].mode
    var values = encodeModes.filter { !$0.isEmpty }
    if !current.isEmpty && !values.contains(current) { values.insert(current, at: 0) }
    picker.setTitle("\(current.isEmpty ? "なし" : current) ▾", for: .normal)
    picker.accessibilityLabel = "エンコードプリセット"
    picker.accessibilityIdentifier = "ruleEditor.encode.\(index + 1).mode"
    var children: [UIMenuElement] = [
      UIAction(title: "なし", state: current.isEmpty ? .on : .off) { [weak self] _ in
        guard let self, self.draft.encodes.indices.contains(index) else { return }
        self.draft.encodes[index].mode = ""
        self.rebuildContent()
      }
    ]
    children.append(contentsOf: values.map { value in
      UIAction(title: value, state: current == value ? .on : .off) { [weak self] _ in
        guard let self, self.draft.encodes.indices.contains(index) else { return }
        self.draft.encodes[index].mode = value
        self.rebuildContent()
      }
    })
    picker.menu = UIMenu(options: [.singleSelection], children: children)
  }

  private func configureChannelPicker(_ picker: NeoSelectButton, index: Int) {
    guard draft.encodes.indices.contains(index) else { return }
    let selected = draft.encodes[index].channelIDs
    let selectedSet = Set(selected)
    var values = channels.filter { Self.isAudioVideoChannel($0) }
    for id in selected where !values.contains(where: { $0.id == id }) {
      values.insert(NeoLiveChannel(id: id, name: "チャンネル \(id)", channelType: ""), at: 0)
    }
    let title: String
    if selected.isEmpty {
      title = "対象局（未指定）"
    } else if selected.count <= 2 {
      title = values.filter { selectedSet.contains($0.id) }.map(\.name).joined(separator: "、")
    } else {
      title = "\(selected.count)局を選択"
    }
    picker.setTitle("\(title) ▾", for: .normal)
    picker.accessibilityLabel = "対象局（未指定なら全局）"
    picker.accessibilityIdentifier = "ruleEditor.encode.\(index + 1).channels"
    var children: [UIMenuElement] = [
      UIAction(title: "全局（未指定）", state: selected.isEmpty ? .on : .off) { [weak self, weak picker] _ in
        guard let self, let picker, self.draft.encodes.indices.contains(index) else { return }
        self.draft.encodes[index].channelIDs = []
        self.configureChannelPicker(picker, index: index)
      }
    ]
    children.append(contentsOf: values.map { channel in
      UIAction(title: channel.name, state: selectedSet.contains(channel.id) ? .on : .off) { [weak self, weak picker] _ in
        guard let self, let picker, self.draft.encodes.indices.contains(index) else { return }
        if let position = self.draft.encodes[index].channelIDs.firstIndex(of: channel.id) {
          self.draft.encodes[index].channelIDs.remove(at: position)
        } else {
          self.draft.encodes[index].channelIDs.append(channel.id)
        }
        self.configureChannelPicker(picker, index: index)
      }
    })
    picker.menu = UIMenu(title: "対象局", options: [], children: children)
  }

  private func configureDirectoryPicker(_ picker: NeoSelectButton, selected: String, onSelect: @escaping (String) -> Void) {
    var values = directories
    if !selected.isEmpty && !values.contains(selected) { values.insert(selected, at: 0) }
    var uniqueValues: [String] = []
    var seen = Set<String>()
    for value in values where seen.insert(value).inserted {
      uniqueValues.append(value)
    }
    values = uniqueValues
    picker.setTitle("\(selected.isEmpty ? "既定" : selected) ▾", for: .normal)
    let updateSelection: (String) -> Void = { [weak self, weak picker] value in
      guard let self, let picker else { return }
      onSelect(value)
      self.configureDirectoryPicker(picker, selected: value, onSelect: onSelect)
    }
    var children: [UIMenuElement] = [
      UIAction(title: "既定", state: selected.isEmpty ? .on : .off) { _ in updateSelection("") }
    ]
    children.append(contentsOf: values.map { value in
      UIAction(title: value, state: value == selected ? .on : .off) { _ in updateSelection(value) }
    })
    picker.menu = UIMenu(options: [.singleSelection], children: children)
  }

  private static func isAudioVideoChannel(_ channel: NeoLiveChannel) -> Bool {
    guard let type = channel.type else { return true }
    return [0x01, 0x02, 0xa1, 0xa2, 0xa5, 0xa6, 0xad].contains(type)
  }

  private func makeTextField(text: String, placeholder: String, label: String, identifier: String) -> UITextField {
    let field = UITextField()
    field.text = text
    field.placeholder = placeholder
    field.accessibilityLabel = label
    field.accessibilityIdentifier = identifier
    field.textColor = .white
    field.tintColor = NeoStyle.accent
    field.font = .systemFont(ofSize: 16)
    field.borderStyle = .none
    field.layer.cornerRadius = 7
    field.layer.borderWidth = 1
    field.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
    field.backgroundColor = UIColor.white.withAlphaComponent(0.025)
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    field.leftViewMode = .always
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.returnKeyType = .done
    field.delegate = self
    field.heightAnchor.constraint(equalToConstant: 44).isActive = true
    return field
  }

  private func labeled(_ title: String, view: UIView) -> UIView {
    let box = verticalStack(spacing: 4)
    let label = NeoStyle.label(title, size: 14, muted: true)
    label.accessibilityIdentifier = "\(view.accessibilityIdentifier ?? "ruleEditor.field").label"
    box.addArrangedSubview(label)
    box.addArrangedSubview(view)
    return box
  }

  private func makeSection(_ title: String, content: () -> UIView) -> UIView {
    let section = verticalStack(spacing: 8)
    let heading = NeoStyle.label(title, size: 15, bold: true)
    heading.accessibilityTraits = .header
    section.addArrangedSubview(heading)
    section.addArrangedSubview(content())
    return section
  }

  private func verticalStack(spacing: CGFloat) -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = spacing
    stack.alignment = .fill
    return stack
  }

  private func horizontalStack(spacing: CGFloat) -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = spacing
    stack.alignment = .fill
    return stack
  }

  private func makeSeparator() -> UIView {
    let line = UIView()
    line.backgroundColor = NeoStyle.border
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }

  private func checkboxButton(title: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    configureCheckbox(button, title: title, selected: selected, identifier: identifier, action: action)
    return button
  }

  private func configureCheckbox(_ button: UIButton, title: String, selected: Bool, identifier: String, action: @escaping () -> Void) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15)
    button.titleLabel?.numberOfLines = 0
    button.setTitleColor(.white, for: .normal)
    button.tintColor = NeoStyle.accent
    button.contentHorizontalAlignment = .left
    button.semanticContentAttribute = .forceLeftToRight
    button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
    button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 8)
    button.accessibilityLabel = title
    button.accessibilityIdentifier = identifier
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    refreshCheckbox(button, selected: selected)
  }

  private func refreshCheckbox(_ button: UIButton, selected: Bool) {
    button.setImage(NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank"), for: .normal)
    button.accessibilityValue = selected ? "オン" : "オフ"
    button.accessibilityTraits = selected ? [.button, .selected] : [.button]
  }

  private func refreshCheckboxInContent(identifier: String, selected: Bool) {
    guard let button = findView(withAccessibilityIdentifier: identifier, in: view) as? UIButton else { return }
    refreshCheckbox(button, selected: selected)
  }

  private func findView(withAccessibilityIdentifier identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier { return root }
    for child in root.subviews {
      if let match = findView(withAccessibilityIdentifier: identifier, in: child) { return match }
    }
    return nil
  }

  private func observeKeyboard() {
    let center = NotificationCenter.default
    keyboardObservers.append(center.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
    ) { [weak self] note in self?.updateKeyboardAvoidance(note) })
    keyboardObservers.append(center.addObserver(
      forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
    ) { [weak self] note in self?.updateKeyboardAvoidance(note) })
  }

  private func updateKeyboardAvoidance(_ notification: Notification) {
    guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let keyboardFrame = view.convert(frame, from: nil)
    bottomAvoidance = keyboardFrame.maxY >= view.bounds.maxY - 1
      ? max(0, view.bounds.maxY - keyboardFrame.minY) : 0
    view.setNeedsLayout()
    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
    let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
    ) { [weak self] in
      self?.view.layoutIfNeeded()
    }
  }

  @objc private func backdropTapped() {
    close()
  }
}

private final class NeoRuleEncodeRow: UIStackView {
  let modePicker = NeoSelectButton()
  let channelPicker = NeoSelectButton()
  let parentDirectoryPicker = NeoSelectButton()
  let directoryField = UITextField()
  let destinationStack = UIStackView()
  let deleteButton: UIButton

  init(index: Int) {
    deleteButton = NeoStyle.iconButton("DeleteOutlineOutlined", label: "エンコード\(index + 1)を削除") {}
    super.init(frame: .zero)
    axis = .vertical
    spacing = 12
    alignment = .fill
    isLayoutMarginsRelativeArrangement = true
    directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    layer.cornerRadius = 7
    layer.borderWidth = 1
    layer.borderColor = NeoStyle.border.cgColor
    backgroundColor = UIColor.white.withAlphaComponent(0.025)

    let header = UIStackView()
    header.axis = .horizontal
    header.alignment = .center
    header.addArrangedSubview(NeoStyle.label("エンコード\(index + 1)", size: 15, bold: true))
    header.addArrangedSubview(UIView())
    deleteButton.accessibilityIdentifier = "ruleEditor.encode.\(index + 1).remove"
    header.addArrangedSubview(deleteButton)
    addArrangedSubview(header)

    let modeLabel = NeoStyle.label("エンコードプリセット", size: 14, muted: true)
    modePicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    addArrangedSubview(UIStackView(arrangedSubviews: [modeLabel, modePicker]))
    let modeBox = arrangedSubviews.last as! UIStackView
    modeBox.axis = .vertical
    modeBox.spacing = 4

    let channelLabel = NeoStyle.label("対象局（未指定なら全局）", size: 14, muted: true)
    channelPicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    addArrangedSubview(UIStackView(arrangedSubviews: [channelLabel, channelPicker]))
    let channelBox = arrangedSubviews.last as! UIStackView
    channelBox.axis = .vertical
    channelBox.spacing = 4

    let directoryLabel = NeoStyle.label("保存先", size: 14, muted: true)
    parentDirectoryPicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    let directoryBox = UIStackView(arrangedSubviews: [directoryLabel, parentDirectoryPicker])
    directoryBox.axis = .vertical
    directoryBox.spacing = 4
    let subdirectory = UIStackView()
    subdirectory.axis = .vertical
    subdirectory.spacing = 4
    subdirectory.addArrangedSubview(NeoStyle.label("サブディレクトリ", size: 14, muted: true))
    directoryField.heightAnchor.constraint(equalToConstant: 44).isActive = true
    directoryField.borderStyle = .none
    directoryField.layer.cornerRadius = 7
    directoryField.layer.borderWidth = 1
    directoryField.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
    directoryField.backgroundColor = UIColor.white.withAlphaComponent(0.025)
    directoryField.textColor = .white
    directoryField.font = .systemFont(ofSize: 16)
    directoryField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    directoryField.leftViewMode = .always
    directoryField.autocorrectionType = .no
    directoryField.autocapitalizationType = .none
    directoryField.spellCheckingType = .no
    directoryField.accessibilityLabel = "サブディレクトリ"
    directoryField.accessibilityIdentifier = "ruleEditor.encode.\(index + 1).directory"
    subdirectory.addArrangedSubview(directoryField)
    destinationStack.addArrangedSubview(directoryBox)
    destinationStack.addArrangedSubview(subdirectory)
    destinationStack.axis = .vertical
    destinationStack.spacing = 12
    destinationStack.alignment = .fill
    addArrangedSubview(destinationStack)
  }

  required init(coder: NSCoder) { fatalError() }
}
