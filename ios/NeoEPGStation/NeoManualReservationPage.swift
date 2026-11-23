import UIKit

final class NeoManualReservationPage: NeoPage {
  enum Target {
    case program(Int)
    case reservation(Int)
    var editing: Bool { if case .reservation = self { return true }; return false }
  }

  private let target: Target
  private let owner: NeoReservationSession
  private let scroll = UIScrollView(), form = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var task: Task<Void, Never>?
  private var options: NeoReservationOptions?
  private var time: NeoReservationTime?
  private var timeEnabled = false
  private var saving = false
  private var roster: [NeoLiveChannel] = [], users: [NeoViewer] = []
  private var config: NeoServerConfig?
  private lazy var saveButton = NeoStyle.button(target.editing ? "更新" : "追加", filled: true) { [weak self] in self?.save() }

  init(shell: NeoShell, target: Target, owner: NeoReservationSession) {
    self.target = target
    self.owner = owner
    super.init(title: "番組詳細予約", shell: shell)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    scroll.keyboardDismissMode = .interactive
    scroll.alwaysBounceVertical = true
    scroll.accessibilityIdentifier = "manualReserve.form"
    saveButton.accessibilityIdentifier = "manualReserve.save"
    form.axis = .vertical; form.spacing = 12
    for element in [scroll, form, spinner] { element.translatesAutoresizingMaskIntoConstraints = false }
    body.addSubview(scroll); scroll.addSubview(form); body.addSubview(spinner)
    let width = form.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)
    width.priority = .defaultHigh
    let bottom = scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor)
    bottom.priority = .defaultHigh
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: body.topAnchor), bottom,
      scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      scroll.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
      form.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      form.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      form.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
      scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      width, form.widthAnchor.constraint(lessThanOrEqualToConstant: 800),
      spinner.centerXAnchor.constraint(equalTo: body.centerXAnchor), spinner.topAnchor.constraint(equalTo: body.topAnchor, constant: 80),
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(accountChanged(_:)), name: .neoAccountChanged, object: nil)
    load()
  }

  @objc private func accountChanged(_ note: Notification) {
    guard (note.object as? NeoAPI) === shell?.api else { return }
    guard owner.hasSameIdentity(as: shell?.api) else {
      task?.cancel()
      if navigationController?.topViewController === self { shell?.goBack() }
      return
    }
    updateButtons()
    if options == nil, task == nil, owner.api.accountReady { load() }
  }

  private func load() {
    guard task == nil, owner.hasSameIdentity(as: shell?.api), owner.api.accountReady else { return }
    let read = NeoReservationSession(owner.api), halfWidth = owner.api.isHalfWidthDisplayed
    let configuration = shell?.serverConfig
    clearForm()
    spinner.startAnimating()
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil; spinner.stopAnimating() }
      async let readUsers = try? read.api.viewers()
      async let readChannels = try? read.api.programSearchChannels(user: read.viewer, headers: read.headers)
      async let readConfig = try? read.api.configuration()
      do {
        let program: NeoScheduledProgram
        let draft: NeoReservationOptions
        var showFree = true
        switch target {
        case .program(let id):
          program = try await read.program(id, halfWidth: halfWidth)
          draft = NeoReservationOptions(userID: read.viewerID)
        case .reservation(let id):
          let item = try await read.reservation(id, halfWidth: halfWidth)
          guard item.ruleId == nil else { throw NeoError("この予約はルール編集から変更してください。") }
          var related: NeoScheduledProgram?
          if let programID = item.programId { related = try? await read.program(programID, halfWidth: halfWidth) }
          program = related ?? item.program
          showFree = related != nil
          draft = NeoReservationOptions(reservation: item)
        }
        let (viewers, channels, fetchedConfig) = await (readUsers, readChannels, readConfig)
        guard !Task.isCancelled, read.isCurrent(shell?.api) else { return }
        users = (viewers?.users ?? []).filter { $0.id > 0 }
        roster = channels ?? []
        config = fetchedConfig ?? configuration
        options = draft
        if !target.editing { time = NeoReservationTime(program) }
        buildForm(program, draft: draft, showFree: showFree)
      } catch {
        guard !Task.isCancelled, read.isCurrent(shell?.api) else { return }
        let warning = text("予約情報を取得できません: \(error.localizedDescription)")
        warning.textColor = NeoStyle.error
        form.addArrangedSubview(panel([warning, NeoStyle.button("再試行") { [weak self] in self?.load() }]))
      }
    }
  }

  private func clearForm() {
    form.arrangedSubviews.forEach { $0.removeFromSuperview() }
  }

  private func buildForm(_ program: NeoScheduledProgram, draft: NeoReservationOptions, showFree: Bool) {
    let title = text(program.name, size: 20, bold: true)
    let details = [program.description, program.extended].compactMap { $0 }.filter { !$0.isEmpty }
    var summary: [UIView] = [title, text(channelName(program.channelId), muted: true), text(Self.schedule(program), muted: true)]
    summary.append(contentsOf: program.genreLabels.map { text($0, muted: true) })
    summary.append(contentsOf: details.map { text($0) })
    if showFree { summary.append(text(program.isFree ? "無料放送" : "有料放送", muted: true)) }
    form.addArrangedSubview(panel(summary))
    if let time { form.addArrangedSubview(timePanel(time)) }

    let viewer = NeoSelectButton()
    fillMenu(viewer, label: "ユーザー", value: draft.userID, placeholder: "ユーザーを選択",
      choices: Self.entries(users, including: draft.userID)) { [weak self] id in
        self?.options?.userID = id
        self?.updateButtons()
      }
    form.addArrangedSubview(panel([
      viewer, toggle("状況に応じて末尾切れを許可", draft.allowEndLack) { [weak self] in self?.options?.allowEndLack = $0 },
    ], title: "ユーザー・オプション"))

    form.addArrangedSubview(panel([
      directoryMenu(draft.parentDirectory) { [weak self] in self?.options?.parentDirectory = $0 },
      field("サブディレクトリ", draft.directory) { [weak self] in self?.options?.directory = $0 },
      field("ファイル名形式", draft.recordedFormat) { [weak self] in self?.options?.recordedFormat = $0 },
    ], title: "録画ファイル"))
    for index in draft.encodes.indices {
      form.addArrangedSubview(encodePanel(draft.encodes[index], index: index))
    }
    form.addArrangedSubview(check("エンコード後に元ファイルを削除", draft.deleteOriginal) { [weak self] in self?.options?.deleteOriginal = $0 })
    form.addArrangedSubview(check("サムネイル再生成", draft.updateThumbnail) { [weak self] in self?.options?.updateThumbnail = $0 })
    let buttons = UIStackView(arrangedSubviews: [
      UIView(), NeoStyle.button("キャンセル") { [weak self] in self?.shell?.goBack() }, saveButton,
    ])
    buttons.spacing = 8
    form.addArrangedSubview(buttons)
    updateButtons()
  }

  private func timePanel(_ time: NeoReservationTime) -> UIView {
    let viewer = NeoSelectButton()
    var channels = roster.map { ($0.id, $0.name) }
    if !channels.contains(where: { $0.0 == time.channelID }) { channels.insert((time.channelID, channelName(time.channelID)), at: 0) }
    fillMenu(viewer, label: "放送局", value: time.channelID, placeholder: "", choices: channels) { [weak self] in self?.time?.channelID = $0 }
    let fields = UIStackView(arrangedSubviews: [
      field("番組名", time.name) { [weak self] in self?.time?.name = $0 }, viewer,
      dateFields("開始", date: time.startDay, clock: time.startClock,
        onDay: { [weak self] in self?.time?.startDay = $0 }, onClock: { [weak self] in self?.time?.startClock = $0 }),
      dateFields("終了", date: time.endDay, clock: time.endClock,
        onDay: { [weak self] in self?.time?.endDay = $0 }, onClock: { [weak self] in self?.time?.endClock = $0 }),
    ])
    fields.axis = .vertical; fields.spacing = 12; fields.isHidden = true
    let timeSwitch = toggle("時刻指定", false) { [weak self, weak fields] enabled in
      self?.timeEnabled = enabled
      fields?.isHidden = !enabled
    }
    return panel([timeSwitch, fields])
  }

  private func dateFields(_ label: String, date: String, clock: String, onDay: @escaping (String) -> Void,
    onClock: @escaping (String) -> Void) -> UIStackView {
    let values = [
      timeField(label + "日", date, kind: .date, change: onDay),
      timeField(label + "時刻", clock, kind: .time, change: onClock),
    ]
    let row = UIStackView(arrangedSubviews: values)
    row.distribution = .fillEqually; row.spacing = 8
    return row
  }

  private func timeField(_ label: String, _ value: String, kind: NeoProgramSearchPickerController.Kind,
    change: @escaping (String) -> Void) -> UIView {
    let field = UITextField()
    field.keyboardType = .numberPad
    let day = kind == .date
    let picker = NeoStyle.iconButton(day ? "CalendarMonthOutlined" : "ScheduleOutlined", label: label + "を選択") { [weak self, weak field] in
      guard let self, let field, presentedViewController == nil else { return }
      view.endEditing(true)
      let dialog = NeoProgramSearchPickerController(kind: kind, value: field.text ?? "", fieldLabel: label) { [weak field] value in
        field?.text = value
        field?.sendActions(for: .editingChanged)
      }
      present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    return bindField(label, value, textField: field, accessory: picker,
      normalize: day ? NeoDateInput.editing : NeoProgramSearchTime.editing, change: change)
  }

  private func encodePanel(_ option: NeoReservationOptions.Encode, index: Int) -> UIView {
    let mode = NeoSelectButton()
    let directory = directoryMenu(option.parentDirectory) { [weak self] in self?.options?.encodes[index].parentDirectory = $0 }
    let field = UITextField()
    let path = bindField("サブディレクトリ", option.directory, textField: field) { [weak self] in self?.options?.encodes[index].directory = $0 }
    directory.isEnabled = !option.mode.isEmpty; field.isEnabled = !option.mode.isEmpty; path.updateAppearance()
    let modes = Self.stringChoices(config?.encode ?? [], current: option.mode, defaultTitle: "なし")
    fillMenu(mode, label: "モード", value: option.mode, placeholder: "なし", choices: modes) { [weak self, weak directory, weak field, weak path] value in
      self?.options?.encodes[index].mode = value
      directory?.isEnabled = !value.isEmpty; field?.isEnabled = !value.isEmpty; path?.updateAppearance()
    }
    return panel([mode, directory, path], title: "エンコード\(index + 1)", expanded: false)
  }

  private func directoryMenu(_ value: String, change: @escaping (String) -> Void) -> NeoSelectButton {
    let button = NeoSelectButton()
    fillMenu(button, label: "保存先", value: value, placeholder: "既定",
      choices: Self.stringChoices(config?.recorded ?? [], current: value, defaultTitle: "既定"), change: change)
    return button
  }

  private static func stringChoices(_ choices: [String], current: String, defaultTitle: String) -> [(String, String)] {
    var seen = Set([""])
    return [("", defaultTitle)] + (choices + [current]).filter { seen.insert($0).inserted }.map { ($0, $0) }
  }

  private static func entries(_ users: [NeoViewer], including id: Int?) -> [(Int, String)] {
    var values = users.map { ($0.id, $0.name) }
    if let id, !values.contains(where: { $0.0 == id }) { values.append((id, "ユーザーID: \(id)")) }
    return values
  }

  private func fillMenu<Value: Equatable>(_ button: NeoSelectButton, label: String, value: Value?, placeholder: String,
    choices: [(Value, String)], change: @escaping (Value) -> Void) {
    button.setFieldLabel(label, alwaysFloated: true, minimumHeight: 48)
    var selected = value
    button.setTitle(choices.first { $0.0 == value }?.1 ?? placeholder, for: .normal)
    button.loadDropdownRows = { [weak button] completion in
      let rows = choices.map { item in
        NeoDropdownList.Row(title: item.1, selected: item.0 == selected) { [weak button] in
          selected = item.0
          button?.setTitle(item.1, for: .normal)
          change(item.0)
        }
      }
      completion(rows)
    }
  }

  private func field(_ label: String, _ value: String, change: @escaping (String) -> Void) -> NeoProgramSearchInput {
    bindField(label, value, textField: UITextField(), change: change)
  }

  private func bindField(_ label: String, _ value: String, textField: UITextField, accessory: UIButton? = nil,
    normalize: ((String, String) -> String)? = nil, change: @escaping (String) -> Void) -> NeoProgramSearchInput {
    textField.text = value; textField.textColor = .white; textField.font = .systemFont(ofSize: 16)
    textField.autocorrectionType = .no; textField.autocapitalizationType = .none
    let input = NeoProgramSearchInput(label: label, field: textField, accessory: accessory, verticalInset: 0, minimumHeight: 48)
    var previous = value
    textField.addAction(UIAction { [weak textField, weak input] _ in
      guard let field = textField, field.markedTextRange == nil else { return }
      let raw = field.text ?? "", value = normalize?(raw, previous) ?? raw
      if value != raw { field.text = value }
      previous = value
      change(value); input?.updateAppearance()
    }, for: .editingChanged)
    return input
  }

  private func panel(_ content: [UIView], title: String? = nil, expanded: Bool = true) -> UIStackView {
    let inner = UIStackView(arrangedSubviews: content)
    inner.axis = .vertical; inner.spacing = 12; inner.isHidden = !expanded
    let outer = UIStackView()
    outer.axis = .vertical; outer.spacing = 12
    outer.backgroundColor = NeoStyle.paper; outer.layer.cornerRadius = 6
    outer.layer.borderWidth = 1; outer.layer.borderColor = NeoStyle.border.cgColor
    outer.isLayoutMarginsRelativeArrangement = true
    outer.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    if let title {
      let header = UIButton(type: .system)
      header.setTitle(title, for: .normal); header.setTitleColor(.white, for: .normal)
      header.setImage(NeoIcon.image(expanded ? "ExpandLessOutlined" : "ExpandMoreOutlined"), for: .normal)
      header.semanticContentAttribute = .forceRightToLeft; header.contentHorizontalAlignment = .fill
      header.tintColor = NeoStyle.muted
      header.addAction(UIAction { [weak inner, weak header] _ in
        guard let inner else { return }
        inner.isHidden.toggle()
        header?.setImage(NeoIcon.image(inner.isHidden ? "ExpandMoreOutlined" : "ExpandLessOutlined"), for: .normal)
      }, for: .touchUpInside)
      outer.addArrangedSubview(header)
    }
    outer.addArrangedSubview(inner)
    return outer
  }

  private func toggle(_ label: String, _ enabled: Bool, change: @escaping (Bool) -> Void) -> UIView {
    let control = UISwitch()
    control.isOn = enabled; control.onTintColor = NeoStyle.accent; control.accessibilityLabel = label
    control.addAction(UIAction { [weak control] _ in if let control { change(control.isOn) } }, for: .valueChanged)
    let row = UIStackView(arrangedSubviews: [control, text(label)])
    row.spacing = 10; row.alignment = .center
    return row
  }

  private func check(_ label: String, _ checked: Bool, change: @escaping (Bool) -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.contentHorizontalAlignment = .left
    button.setTitle(label, for: .normal); button.setTitleColor(.white, for: .normal); button.tintColor = NeoStyle.accent
    button.setImage(NeoIcon.image("CheckBoxOutlineBlank"), for: .normal); button.setImage(NeoIcon.image("CheckBox"), for: .selected)
    button.isSelected = checked
    button.addAction(UIAction { [weak button] _ in
      guard let button else { return }
      button.isSelected.toggle(); change(button.isSelected)
    }, for: .touchUpInside)
    return button
  }

  private func text(_ value: String, size: CGFloat = 15, bold: Bool = false, muted: Bool = false) -> UILabel {
    let label = NeoStyle.label(value, size: size, bold: bold, muted: muted)
    label.numberOfLines = 0
    return label
  }

  private func channelName(_ id: Int) -> String { roster.first { $0.id == id }?.name ?? String(id) }

  static func schedule(_ program: NeoScheduledProgram) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "ja_JP"); format.timeZone = TimeZone(identifier: "Asia/Tokyo")
    format.dateFormat = "yyyy/MM/dd(EEE) HH:mm"
    let start = format.string(from: Date(timeIntervalSince1970: program.startAt / 1000))
    format.dateFormat = "HH:mm"
    let end = format.string(from: Date(timeIntervalSince1970: program.endAt / 1000))
    return "\(start) - \(end)（\(program.durationMinutes)分）"
  }

  private func updateButtons() {
    saveButton.isEnabled = !saving && options?.userID != nil && owner.hasSameIdentity(as: shell?.api) && owner.api.accountReady
  }

  private func save() {
    guard !saving, task == nil, let options, owner.hasSameIdentity(as: shell?.api), owner.api.accountReady else { return }
    let session = NeoReservationSession(owner.api), time = timeEnabled ? time : nil
    saving = true; updateButtons(); view.endEditing(true)
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil; saving = false; updateButtons() }
      do {
        switch target {
        case .program(let id): try await session.add(programID: id, options: options, time: time)
        case .reservation(let id): try await session.edit(id, options: options)
        }
        guard !Task.isCancelled, session.hasSameIdentity(as: shell?.api) else { return }
        NotificationCenter.default.post(name: .neoReservationsChanged, object: session.api)
        shell?.recordingNotice(target.editing ? "予約を更新しました" : "予約を追加しました")
        if navigationController?.topViewController === self { shell?.goBack() }
      } catch {
        guard !Task.isCancelled, session.hasSameIdentity(as: shell?.api) else { return }
        shell?.recordingNotice("予約の保存に失敗しました: \(error.localizedDescription)", error: true)
      }
    }
  }

  deinit { task?.cancel() }
}
