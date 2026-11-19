import UIKit

/// The presentation-only form used by the native program-search page.
///
/// The page/controller owns the search request, validation, navigation and
/// results.  This view only edits a value-type `NeoProgramSearchForm` and
/// reports the edited value through `onChange`.
final class NeoProgramSearchFormView: UIView {
  typealias Change = (NeoProgramSearchForm) -> Void

  private weak var presenter: UIViewController?
  private let channels: [NeoLiveChannel]
  private let availableTypes: [String]
  private var form: NeoProgramSearchForm
  private let onChange: Change
  private let onClear: () -> Void
  private let onSearch: () -> Void

  /// Called after an accordion, chip, or wrapping layout changes.  A table
  /// header owner can re-measure itself on the next run loop turn.
  var onLayoutChange: (() -> Void)?

  var searchEnabled: Bool = true {
    didSet { searchButton.isEnabled = searchEnabled; searchButton.alpha = searchEnabled ? 1 : 0.45 }
  }

  private let card = UIView()
  private let content = UIStackView()
  private let keywordField = UITextField()
  private let ignoreKeywordField = UITextField()
  private let channelField = UITextField()
  private let durationMinField = UITextField()
  private let durationMaxField = UITextField()
  private let startDateField = UITextField()
  private let startTimeField = UITextField()
  private let endDateField = UITextField()
  private let endTimeField = UITextField()
  private let channelSuggestions = UIStackView()
  private let selectedChannels = NeoProgramSearchWrapView()
  private let keywordOptions = NeoProgramSearchWrapView()
  private let ignoreOptions = NeoProgramSearchWrapView()
  private let typeOptions = NeoProgramSearchWrapView()
  private let genreWeekOptions = NeoProgramSearchWrapView()
  private let detailsBody = UIStackView()
  private let detailsButton = UIButton(type: .system)
  private let genreButton = NeoSelectButton()
  private let subGenreButton = NeoSelectButton()
  private let startHourButton = NeoSelectButton()
  private let rangeHourButton = NeoSelectButton()
  private let freeSwitch = UISwitch()
  private let actions = UIStackView()
  private let clearButton = UIButton(type: .system)
  private let searchButton = UIButton(type: .system)
  private let channelSuggestionsScroll = UIScrollView()
  private var channelSuggestionsHeight: NSLayoutConstraint!

  private var dateText: [String: String] = [:]
  private var timeText: [String: String] = [:]
  private var channelQuery = ""
  private var detailsExpanded = true
  private var marginWidthClass: Bool?

  init(
    form: NeoProgramSearchForm,
    channels: [NeoLiveChannel],
    availableTypes: [String],
    presenter: UIViewController,
    onChange: @escaping Change,
    onClear: @escaping () -> Void,
    onSearch: @escaping () -> Void
  ) {
    self.form = form
    self.channels = channels
    self.availableTypes = availableTypes
    self.presenter = presenter
    self.onChange = onChange
    self.onClear = onClear
    self.onSearch = onSearch
    super.init(frame: .zero)
    configure()
    render()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Replaces the form without sending an edit callback.  This is used after
  /// a clear or after the root normalizes a submitted value.
  func update(_ form: NeoProgramSearchForm) {
    self.form = form
    channelQuery = ""
    dateText["startDate"] = dateDisplay(form.startDate)
    dateText["endDate"] = dateDisplay(form.endDate)
    timeText["startTime"] = form.startTime
    timeText["endTime"] = form.endTime
    render()
  }

  func focusKeyword() {
    keywordField.becomeFirstResponder()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let wide = bounds.width >= 600
    if marginWidthClass != wide {
      marginWidthClass = wide
      let inset: CGFloat = wide ? 24 : 12
      content.spacing = wide ? 16 : 12
      content.layoutMargins = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
      detailsBody.layoutMargins = UIEdgeInsets(top: 0, left: wide ? 16 : 12, bottom: wide ? 16 : 12, right: wide ? 16 : 12)
      content.invalidateIntrinsicContentSize()
      notifyLayoutChange()
    }
  }

  private func configure() {
    backgroundColor = .clear
    card.backgroundColor = NeoStyle.paper
    card.layer.cornerRadius = 6
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor
    card.translatesAutoresizingMaskIntoConstraints = false
    addSubview(card)
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: topAnchor), card.leadingAnchor.constraint(equalTo: leadingAnchor),
      card.trailingAnchor.constraint(equalTo: trailingAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    content.axis = .vertical
    content.spacing = 12
    content.alignment = .fill
    content.isLayoutMarginsRelativeArrangement = true
    content.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: card.topAnchor), content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: card.trailingAnchor), content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
    ])

    [selectedChannels, keywordOptions, ignoreOptions, typeOptions, genreWeekOptions].forEach { wrap in
      wrap.onHeightChange = { [weak self] in self?.notifyLayoutChange() }
    }
    configureTextField(keywordField, placeholder: "", identifier: "programSearch.keyword", returnKey: .search)
    keywordField.accessibilityLabel = "キーワード"
    configureTextField(ignoreKeywordField, placeholder: "", identifier: "programSearch.ignoreKeyword")
    ignoreKeywordField.accessibilityLabel = "除外キーワード"
    configureTextField(channelField, placeholder: "局名を入力して絞り込み", identifier: "programSearch.channel")
    channelField.delegate = self
    channelField.addTarget(self, action: #selector(channelQueryChanged), for: .editingChanged)
    keywordField.delegate = self

    configureNumberField(durationMinField, identifier: "programSearch.durationMin")
    configureNumberField(durationMaxField, identifier: "programSearch.durationMax")
    configureDateField(startDateField, identifier: "programSearch.startDate", label: "開始日", isDate: true)
    configureDateField(startTimeField, identifier: "programSearch.startTime", label: "開始時刻", isDate: false)
    configureDateField(endDateField, identifier: "programSearch.endDate", label: "終了日", isDate: true)
    configureDateField(endTimeField, identifier: "programSearch.endTime", label: "終了時刻", isDate: false)

    detailsButton.setTitle("詳細条件", for: .normal)
    detailsButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    detailsButton.tintColor = .white
    detailsButton.setTitleColor(.white, for: .normal)
    detailsButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    detailsButton.contentHorizontalAlignment = .left
    detailsButton.semanticContentAttribute = .forceRightToLeft
    detailsButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    detailsButton.accessibilityLabel = "詳細条件"
    detailsButton.addTarget(self, action: #selector(toggleDetails), for: .touchUpInside)

    detailsBody.axis = .vertical
    detailsBody.spacing = 16
    detailsBody.alignment = .fill
    detailsBody.isLayoutMarginsRelativeArrangement = true
    detailsBody.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 16, right: 16)

    genreButton.accessibilityLabel = "大ジャンル"
    genreButton.accessibilityIdentifier = "programSearch.genre"
    subGenreButton.accessibilityLabel = "小ジャンル"
    subGenreButton.accessibilityIdentifier = "programSearch.subGenre"
    startHourButton.accessibilityLabel = "開始時刻"
    startHourButton.accessibilityIdentifier = "programSearch.startHour"
    rangeHourButton.accessibilityLabel = "範囲"
    rangeHourButton.accessibilityIdentifier = "programSearch.rangeHour"
    [genreButton, subGenreButton, startHourButton, rangeHourButton].forEach {
      $0.titleLabel?.numberOfLines = 2
      $0.titleLabel?.lineBreakMode = .byTruncatingTail
      $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    freeSwitch.onTintColor = NeoStyle.accent
    freeSwitch.addTarget(self, action: #selector(freeChanged), for: .valueChanged)
    freeSwitch.accessibilityLabel = "無料放送のみ"

    styleActionButton(clearButton, title: "クリア", filled: false, identifier: "programSearch.clear", action: #selector(clearTapped))
    styleActionButton(searchButton, title: "検索", filled: true, identifier: "programSearch.search", action: #selector(searchTapped))
    searchButton.isEnabled = searchEnabled
    searchButton.alpha = searchEnabled ? 1 : 0.45

    channelSuggestions.axis = .vertical
    channelSuggestions.spacing = 2
    channelSuggestions.alignment = .fill
    channelSuggestionsScroll.backgroundColor = .clear
    channelSuggestionsScroll.showsVerticalScrollIndicator = true
    channelSuggestionsScroll.alwaysBounceVertical = false
    channelSuggestionsScroll.clipsToBounds = true
    channelSuggestionsScroll.accessibilityIdentifier = "programSearch.channelSuggestions"
    channelSuggestions.translatesAutoresizingMaskIntoConstraints = false
    channelSuggestionsScroll.addSubview(channelSuggestions)
    NSLayoutConstraint.activate([
      channelSuggestions.topAnchor.constraint(equalTo: channelSuggestionsScroll.contentLayoutGuide.topAnchor),
      channelSuggestions.leadingAnchor.constraint(equalTo: channelSuggestionsScroll.contentLayoutGuide.leadingAnchor),
      channelSuggestions.trailingAnchor.constraint(equalTo: channelSuggestionsScroll.contentLayoutGuide.trailingAnchor),
      channelSuggestions.bottomAnchor.constraint(equalTo: channelSuggestionsScroll.contentLayoutGuide.bottomAnchor),
      channelSuggestions.widthAnchor.constraint(equalTo: channelSuggestionsScroll.frameLayoutGuide.widthAnchor),
    ])
    channelSuggestionsHeight = channelSuggestionsScroll.heightAnchor.constraint(equalToConstant: 0)
    channelSuggestionsHeight.isActive = true

    // The outer controller provides scrolling.  Keep this view a single
    // self-sizing form surface so a table-header owner can re-measure it.
    content.addArrangedSubview(formLabeledField("キーワード", control: keywordField))
    content.addArrangedSubview(keywordOptions)
    content.addArrangedSubview(formLabeledField("除外キーワード", control: ignoreKeywordField))
    content.addArrangedSubview(ignoreOptions)
    let channelSection = UIStackView(arrangedSubviews: [
      NeoStyle.label("放送局", size: 13, muted: true), channelField, selectedChannels, channelSuggestionsScroll, typeOptions
    ])
    channelSection.axis = .vertical; channelSection.spacing = 5; channelSection.alignment = .fill
    content.addArrangedSubview(channelSection)
    actions.axis = .horizontal; actions.spacing = 8; actions.alignment = .center; actions.distribution = .fill
    actions.addArrangedSubview(UIView())
    actions.addArrangedSubview(clearButton)
    actions.addArrangedSubview(searchButton)
    actions.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  private func configureTextField(_ field: UITextField, placeholder: String, identifier: String, returnKey: UIReturnKeyType = .default) {
    field.placeholder = placeholder
    field.returnKeyType = returnKey
    field.textColor = .white
    field.tintColor = NeoStyle.accent
    field.backgroundColor = NeoStyle.background
    field.font = .systemFont(ofSize: 16)
    field.borderStyle = .none
    field.layer.cornerRadius = 4
    field.layer.borderWidth = 1
    field.layer.borderColor = NeoStyle.border.cgColor
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
    field.leftViewMode = .always
    field.clearButtonMode = .whileEditing
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.accessibilityIdentifier = identifier
    field.accessibilityLabel = placeholder
    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
  }

  private func configureNumberField(_ field: UITextField, identifier: String) {
    configureTextField(field, placeholder: "", identifier: identifier)
    field.keyboardType = .numberPad
    field.accessibilityLabel = identifier.replacingOccurrences(of: "programSearch.", with: "")
  }

  private func configureDateField(_ field: UITextField, identifier: String, label: String, isDate: Bool) {
    configureTextField(field, placeholder: isDate ? "YYYY/MM/DD" : "HH:mm", identifier: identifier)
    field.accessibilityLabel = label
    field.keyboardType = .asciiCapableNumberPad
    let button = UIButton(type: .system)
    button.tintColor = NeoStyle.accent
    button.setImage(UIImage(systemName: isDate ? "calendar" : "clock"), for: .normal)
    button.accessibilityLabel = isDate ? "\(label)をカレンダーから選択" : "\(label)を時計から選択"
    if isDate { button.addTarget(self, action: #selector(startDatePickerTapped(_:)), for: .touchUpInside) }
    else { button.addTarget(self, action: #selector(startTimePickerTapped(_:)), for: .touchUpInside) }
    button.tag = field === startDateField ? 0 : field === startTimeField ? 1 : field === endDateField ? 2 : 3
    button.frame = CGRect(x: 0, y: 0, width: 36, height: 44)
    field.rightView = button
    field.rightViewMode = .always
  }

  private func styleActionButton(_ button: UIButton, title: String, filled: Bool, identifier: String, action: Selector) {
    button.setTitle(title, for: .normal)
    button.setImage(NeoIcon.image(title == "クリア" ? "Close" : "SearchOutlined"), for: .normal)
    button.setTitleColor(filled ? .black : NeoStyle.accent, for: .normal)
    button.tintColor = filled ? .black : NeoStyle.accent
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    button.semanticContentAttribute = .forceLeftToRight
    button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
    button.backgroundColor = filled ? NeoStyle.accent : .clear
    button.layer.cornerRadius = 6
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    button.accessibilityIdentifier = identifier
    button.accessibilityLabel = title
    button.addTarget(self, action: action, for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
  }

  private func render() {
    dateText["startDate"] = dateText["startDate"] ?? dateDisplay(form.startDate)
    dateText["endDate"] = dateText["endDate"] ?? dateDisplay(form.endDate)
    timeText["startTime"] = timeText["startTime"] ?? form.startTime
    timeText["endTime"] = timeText["endTime"] ?? form.endTime
    keywordField.text = form.keyword
    ignoreKeywordField.text = form.ignoreKeyword
    durationMinField.text = form.durationMin
    durationMaxField.text = form.durationMax
    channelField.text = channelQuery
    startDateField.text = dateText["startDate"] ?? dateDisplay(form.startDate)
    endDateField.text = dateText["endDate"] ?? dateDisplay(form.endDate)
    startTimeField.text = timeText["startTime"] ?? form.startTime
    endTimeField.text = timeText["endTime"] ?? form.endTime
    freeSwitch.isOn = form.isFree

    keywordOptions.setItems(keywordFieldButtons(for: form.keywordFields, keyword: true))
    ignoreOptions.setItems(keywordFieldButtons(for: form.ignoreFields, keyword: false))
    selectedChannels.setItems(channelChipButtons())
    updateChannelSuggestions()
    typeOptions.setItems(typeButtons())
    genreWeekOptions.setItems(weekButtons())
    renderGenreMenu()
    renderSubGenreMenu()
    renderTimeMenus()
    renderDetails()
    notifyLayoutChange()
  }

  private func renderDetails() {
    let current = detailsBody.superview
    if current == nil {
      let surface = UIView()
      surface.backgroundColor = .clear
      surface.layer.cornerRadius = 4
      surface.layer.borderWidth = 1
      surface.layer.borderColor = NeoStyle.border.cgColor
      let detailsStack = UIStackView(arrangedSubviews: [detailsButton, detailsBody])
      detailsStack.axis = .vertical
      detailsStack.spacing = 0
      detailsStack.translatesAutoresizingMaskIntoConstraints = false
      surface.addSubview(detailsStack)
      NSLayoutConstraint.activate([
        detailsStack.topAnchor.constraint(equalTo: surface.topAnchor), detailsStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
        detailsStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor), detailsStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
      ])
      content.addArrangedSubview(surface)
      detailsBody.addArrangedSubview(formLabeledField("大ジャンル", control: genreButton))
      detailsBody.addArrangedSubview(formLabeledField("小ジャンル", control: subGenreButton))
      detailsBody.addArrangedSubview(hoursRow())
      detailsBody.addArrangedSubview(genreWeekOptions)
      detailsBody.addArrangedSubview(durationRow())
      detailsBody.addArrangedSubview(periodRow())
      detailsBody.addArrangedSubview(freeRow())
      content.addArrangedSubview(actions)
    }
    detailsBody.isHidden = !detailsExpanded
    detailsButton.setImage(UIImage(systemName: detailsExpanded ? "chevron.down" : "chevron.right"), for: .normal)
    detailsButton.accessibilityValue = detailsExpanded ? "展開" : "折りたたみ"
    detailsButton.accessibilityTraits = detailsExpanded ? [.button, .selected] : [.button]
  }

  private func formLabeledField(_ title: String, control: UIView) -> UIView {
    let stack = UIStackView(arrangedSubviews: [NeoStyle.label(title, size: 13, muted: true), control])
    stack.axis = .vertical; stack.spacing = 5; stack.alignment = .fill
    return stack
  }

  private func hoursRow() -> UIView {
    let start = formLabeledField("開始時刻", control: startHourButton)
    let range = formLabeledField("範囲", control: rangeHourButton)
    let separator = NeoStyle.label("～", size: 15); separator.textAlignment = .center
    let within = NeoStyle.label("以内", size: 15); within.textAlignment = .center
    let row = NeoProgramSearchAdaptiveRow(arrangedSubviews: [start, separator, range, within], breakpoint: 600)
    row.axis = .vertical; row.spacing = 8; row.alignment = .fill; row.distribution = .fill
    startHourButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    rangeHourButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.accessibilityIdentifier = "programSearch.hours"
    row.onAxisChange = { [weak self] in self?.notifyLayoutChange() }
    return row
  }

  private func durationRow() -> UIView {
    let row = NeoProgramSearchAdaptiveRow(arrangedSubviews: [
      formLabeledField("最小（分）", control: durationMinField),
      formLabeledField("最大（分）", control: durationMaxField)
    ], breakpoint: 600)
    row.axis = .vertical; row.spacing = 12; row.distribution = .fillEqually
    row.accessibilityIdentifier = "programSearch.duration"
    row.onAxisChange = { [weak self] in self?.notifyLayoutChange() }
    return row
  }

  private func periodRow() -> UIView {
    let start = UIStackView(arrangedSubviews: [formLabeledField("開始日", control: startDateField), formLabeledField("開始時刻", control: startTimeField)])
    let end = UIStackView(arrangedSubviews: [formLabeledField("終了日", control: endDateField), formLabeledField("終了時刻", control: endTimeField)])
    [start, end].forEach { $0.axis = .horizontal; $0.spacing = 8; $0.distribution = .fillEqually }
    let row = NeoProgramSearchAdaptiveRow(arrangedSubviews: [start, end])
    row.axis = .vertical; row.spacing = 12; row.distribution = .fill
    row.accessibilityIdentifier = "programSearch.period"
    row.onAxisChange = { [weak self] in self?.notifyLayoutChange() }
    return row
  }

  private func freeRow() -> UIView {
    let label = NeoStyle.label("無料放送のみ")
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [label, freeSwitch]); row.axis = .horizontal; row.alignment = .center; row.distribution = .equalSpacing
    return row
  }

  private func keywordFieldButtons(for fields: NeoProgramKeywordFields, keyword: Bool) -> [UIView] {
    let values: [(String, Bool, WritableKeyPath<NeoProgramKeywordFields, Bool>, String)] = [
      ("大小区別", fields.caseSensitive, \.caseSensitive, "caseSensitive"), ("正規表現", fields.regexp, \.regexp, "regexp"),
      ("名前", fields.name, \.name, "name"), ("概要", fields.description, \.description, "description"), ("詳細", fields.extended, \.extended, "extended")
    ]
    return values.map { title, selected, keyPath, identifierSuffix in
      makeCheckButton(title, selected: selected, identifier: "programSearch.\(keyword ? "keyword" : "ignore").\(identifierSuffix)") { [weak self] in
        guard let self else { return }
        var next = self.form
        var fields = keyword ? next.keywordFields : next.ignoreFields
        fields[keyPath: keyPath] = !fields[keyPath: keyPath]
        if keyword { next.keywordFields = fields } else { next.ignoreFields = fields }
        self.emit(next)
      }
    }
  }

  private func typeButtons() -> [UIView] {
    availableTypes.map { type in
      makeCheckButton(NeoProgramSearchMetadata.channelTypeLabel(type), selected: form.channelTypes.contains(type), identifier: "programSearch.channelType.\(type)", enabled: form.channelIDs.isEmpty) { [weak self] in
        guard let self else { return }
        var next = self.form
        if next.channelTypes.contains(type) { next.channelTypes.removeAll { $0 == type } } else { next.channelTypes.append(type) }
        self.emit(next)
      }
    }
  }

  private func weekButtons() -> [UIView] {
    NeoProgramSearchMetadata.weekItems.map { item in
      makeCheckButton(item.label, selected: form.week & item.bit != 0, identifier: "programSearch.week.\(item.bit)") { [weak self] in
        guard let self else { return }
        var next = self.form
        if next.week & item.bit != 0 { next.week &= ~item.bit } else { next.week |= item.bit }
        self.emit(next)
      }
    }
  }

  private func makeCheckButton(_ title: String, selected: Bool, identifier: String, enabled: Bool = true, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setImage(NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank"), for: .normal)
    button.tintColor = selected ? NeoStyle.accent : (enabled ? NeoStyle.muted : NeoStyle.muted.withAlphaComponent(0.55))
    button.setTitleColor(enabled ? .white : NeoStyle.muted, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14)
    button.contentHorizontalAlignment = .left
    button.semanticContentAttribute = .forceLeftToRight
    button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
    button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 10)
    button.accessibilityIdentifier = identifier
    button.accessibilityLabel = title
    button.accessibilityValue = selected ? "オン" : "オフ"
    button.accessibilityTraits = selected ? [.button, .selected] : [.button]
    button.isEnabled = enabled
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  private func channelChipButtons() -> [UIView] {
    form.channelIDs.compactMap { id in
      guard let channel = channels.first(where: { $0.id == id }) else { return nil }
      let button = UIButton(type: .system)
      button.setTitle("\(channel.name)  ×", for: .normal)
      button.setTitleColor(NeoStyle.accent, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 14)
      button.layer.cornerRadius = 14; button.layer.borderWidth = 1; button.layer.borderColor = NeoStyle.accent.withAlphaComponent(0.7).cgColor
      button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
      button.accessibilityLabel = "\(channel.name)を検索対象から削除"
      button.accessibilityIdentifier = "programSearch.channelChip.\(id)"
      button.addAction(UIAction { [weak self] _ in
        guard let self else { return }; var next = self.form; next.channelIDs.removeAll { $0 == id }; self.emit(next)
      }, for: .touchUpInside)
      return button
    }
  }

  private func channelSuggestionButtons() -> [UIView] {
    let needle = normalizedChannelQuery(channelQuery)
    guard channelField.isFirstResponder || !needle.isEmpty else { return [] }
    let matches = channels.filter { channel in
      guard !form.channelIDs.contains(channel.id) else { return false }
      guard !needle.isEmpty else { return true }
      return normalizedChannelQuery(channel.name).contains(needle) || normalizedChannelQuery(channel.halfWidthName ?? "").contains(needle)
    }
    guard !matches.isEmpty else {
      let empty = NeoStyle.label("該当する放送局がありません", size: 14, muted: true)
      empty.textAlignment = .center
      empty.numberOfLines = 0
      empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      return [empty]
    }
    return matches.map { channel in
      let button = UIButton(type: .system)
      button.setTitle(channel.name, for: .normal); button.setTitleColor(.white, for: .normal)
      button.contentHorizontalAlignment = .left; button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
      button.backgroundColor = NeoStyle.popupPaper
      button.accessibilityLabel = "\(channel.name)を選択"
      button.accessibilityIdentifier = "programSearch.channelOption.\(channel.id)"
      button.addAction(UIAction { [weak self] _ in self?.selectChannel(channel) }, for: .touchUpInside)
      return button
    }
  }

  private func updateChannelSuggestions() {
    let views = channelSuggestionButtons()
    channelSuggestions.setArrangedSubviews(views)
    let visible = channelField.isFirstResponder
    channelSuggestionsScroll.isHidden = !visible
    // Keep the dropdown compact while allowing every matching channel to be
    // reached by scrolling.  Each option is at least 44pt high for touch.
    let contentHeight = CGFloat(views.count) * 44 + CGFloat(max(0, views.count - 1)) * channelSuggestions.spacing
    channelSuggestionsHeight.constant = visible ? min(240, max(44, contentHeight)) : 0
    if !visible { channelSuggestionsScroll.setContentOffset(.zero, animated: false) }
    notifyLayoutChange()
  }

  private func selectChannel(_ channel: NeoLiveChannel) {
    var next = form
    if !next.channelIDs.contains(channel.id) { next.channelIDs.append(channel.id) }
    channelQuery = ""
    channelField.text = ""
    channelField.resignFirstResponder()
    emit(next)
  }

  private func renderGenreMenu() {
    let selected = Set(form.genres)
    let items = [UIAction(title: "すべて", state: selected.isEmpty ? .on : .off) { [weak self] _ in
      guard let self else { return }; var next = self.form; next.genres = []; next.subGenres = []; self.emit(next)
    }] + NeoProgramSearchMetadata.searchableGenres.map { genre in
      UIAction(title: NeoProgramSearchMetadata.genreNames.indices.contains(genre) ? NeoProgramSearchMetadata.genreNames[genre] : "ジャンル \(genre)", state: selected.contains(genre) ? .on : .off) { [weak self] _ in
        guard let self else { return }; var next = self.form
        if let index = next.genres.firstIndex(of: genre) { next.genres.remove(at: index); next.subGenres.removeAll { $0.hasPrefix("\(genre):") } }
        else { next.genres.append(genre) }
        self.emit(next)
      }
    }
    genreButton.menu = UIMenu(title: "大ジャンル", options: [.displayInline], children: items)
    genreButton.setTitle(form.genres.isEmpty ? "すべて" : form.genres.map { NeoProgramSearchMetadata.genreNames.indices.contains($0) ? NeoProgramSearchMetadata.genreNames[$0] : String($0) }.joined(separator: "、"), for: .normal)
  }

  private func renderSubGenreMenu() {
    let selected = Set(form.subGenres)
    var children: [UIMenuElement] = []
    for genre in form.genres {
      let title = NeoProgramSearchMetadata.genreNames.indices.contains(genre) ? NeoProgramSearchMetadata.genreNames[genre] : "ジャンル \(genre)"
      let values = (NeoProgramSearchMetadata.subGenreNames.indices.contains(genre) ? NeoProgramSearchMetadata.subGenreNames[genre] : []).enumerated().filter { !$0.element.isEmpty }
      let hasSubgenre = values.contains { selected.contains("\(genre):\($0.offset)") }
      var choices: [UIMenuElement] = [UIAction(title: "すべて", state: hasSubgenre ? .off : .on) { [weak self] _ in
        guard let self else { return }; var next = self.form; next.subGenres.removeAll { $0.hasPrefix("\(genre):") }; self.emit(next)
      }]
      choices += values.map { index, name in
        UIAction(title: name, state: selected.contains("\(genre):\(index)") ? .on : .off) { [weak self] _ in
          guard let self else { return }; var next = self.form; let key = "\(genre):\(index)"
          if let location = next.subGenres.firstIndex(of: key) { next.subGenres.remove(at: location) } else { next.subGenres.append(key) }
          self.emit(next)
        }
      }
      children.append(UIMenu(title: title, options: [.displayInline], children: choices))
    }
    subGenreButton.isEnabled = !form.genres.isEmpty
    subGenreButton.menu = UIMenu(title: "小ジャンル", children: children)
    if form.genres.isEmpty { subGenreButton.setTitle("すべて", for: .normal) }
    else {
      subGenreButton.setTitle(form.genres.map { genre in
        let title = NeoProgramSearchMetadata.genreNames.indices.contains(genre) ? NeoProgramSearchMetadata.genreNames[genre] : "ジャンル \(genre)"
        let values = form.subGenres.filter { $0.hasPrefix("\(genre):") }.compactMap { Int($0.split(separator: ":").last ?? "") }
        let names = values.compactMap { subGenre in NeoProgramSearchMetadata.subGenreNames.indices.contains(genre) && NeoProgramSearchMetadata.subGenreNames[genre].indices.contains(subGenre) ? NeoProgramSearchMetadata.subGenreNames[genre][subGenre] : nil }.filter { !$0.isEmpty }
        return names.isEmpty ? "\(title): すべて" : "\(title): \(names.joined(separator: "、"))"
      }.joined(separator: " / "), for: .normal)
    }
  }

  private func renderTimeMenus() {
    let hours = [UIAction(title: "指定なし", state: form.startHour == nil ? .on : .off) { [weak self] _ in self?.setStartHour(nil) }] + (0...23).map { hour in
      UIAction(title: "\(hour)時", state: form.startHour == hour ? .on : .off) { [weak self] _ in self?.setStartHour(hour) }
    }
    startHourButton.menu = UIMenu(title: "開始時刻", options: [.singleSelection], children: hours)
    startHourButton.setTitle(form.startHour.map { "\($0)時" } ?? "指定なし", for: .normal)
    let ranges = [UIAction(title: "指定なし", state: form.rangeHour == nil ? .on : .off) { [weak self] _ in self?.setRangeHour(nil) }] + (1...23).map { hour in
      UIAction(title: "\(hour)時間", state: form.rangeHour == hour ? .on : .off) { [weak self] _ in self?.setRangeHour(hour) }
    }
    rangeHourButton.menu = UIMenu(title: "範囲", options: [.singleSelection], children: ranges)
    rangeHourButton.setTitle(form.rangeHour.map { "\($0)時間" } ?? "指定なし", for: .normal)
  }

  private func setStartHour(_ value: Int?) { var next = form; next.startHour = value; emit(next) }
  private func setRangeHour(_ value: Int?) { var next = form; next.rangeHour = value; emit(next) }

  private func dateDisplay(_ raw: String) -> String {
    let displayed = NeoDateInput.display(raw)
    return displayed.isEmpty ? raw : displayed
  }

  private func emit(_ next: NeoProgramSearchForm) {
    form = next
    onChange(next)
    render()
  }

  private func notifyLayoutChange() {
    DispatchQueue.main.async { [weak self] in self?.onLayoutChange?() }
  }

  private func normalizedChannelQuery(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "[\\s　]+", with: "", options: .regularExpression)
  }

  @objc private func textChanged(_ sender: UITextField) {
    var next = form
    switch sender {
    case keywordField: next.keyword = sender.text ?? ""
    case ignoreKeywordField: next.ignoreKeyword = sender.text ?? ""
    case durationMinField: next.durationMin = sender.text ?? ""
    case durationMaxField: next.durationMax = sender.text ?? ""
    case startDateField:
      let previous = dateText["startDate"] ?? ""; let value = NeoDateInput.editing(sender.text ?? "", previous: previous); dateText["startDate"] = value; if sender.text != value { sender.text = value }; next.startDate = value
    case endDateField:
      let previous = dateText["endDate"] ?? ""; let value = NeoDateInput.editing(sender.text ?? "", previous: previous); dateText["endDate"] = value; if sender.text != value { sender.text = value }; next.endDate = value
    case startTimeField:
      let previous = timeText["startTime"] ?? ""; let value = NeoProgramSearchTime.editing(sender.text ?? "", previous: previous); timeText["startTime"] = value; if sender.text != value { sender.text = value }; next.startTime = value
    case endTimeField:
      let previous = timeText["endTime"] ?? ""; let value = NeoProgramSearchTime.editing(sender.text ?? "", previous: previous); timeText["endTime"] = value; if sender.text != value { sender.text = value }; next.endTime = value
    default: return
    }
    if sender !== channelField { form = next; onChange(next) }
  }

  @objc private func channelQueryChanged() {
    channelQuery = channelField.text ?? ""
    updateChannelSuggestions()
  }

  @objc private func toggleDetails() { detailsExpanded.toggle(); renderDetails(); notifyLayoutChange() }
  @objc private func freeChanged() { var next = form; next.isFree = freeSwitch.isOn; emit(next) }
  @objc private func clearTapped() { onClear() }
  @objc private func searchTapped() { if searchEnabled { onSearch() } }

  @objc private func startDatePickerTapped(_ sender: UIButton) { presentPicker(kind: .date, index: sender.tag) }
  @objc private func startTimePickerTapped(_ sender: UIButton) { presentPicker(kind: .time, index: sender.tag) }

  private func presentPicker(kind: PickerKind, index: Int) {
    guard let presenter else { return }
    let current: String
    switch index { case 0: current = startDateField.text ?? ""; case 1: current = startTimeField.text ?? ""; case 2: current = endDateField.text ?? ""; default: current = endTimeField.text ?? "" }
    let picker = NeoProgramSearchPickerController(kind: kind, value: current, presenter: presenter) { [weak self] value in
      guard let self else { return }; var next = self.form
      switch index {
      case 0: self.startDateField.text = value; self.dateText["startDate"] = value; next.startDate = value
      case 1: self.startTimeField.text = value; self.timeText["startTime"] = value; next.startTime = value
      case 2: self.endDateField.text = value; self.dateText["endDate"] = value; next.endDate = value
      default: self.endTimeField.text = value; self.timeText["endTime"] = value; next.endTime = value
      }
      self.emit(next)
    }
    if let popover = picker.popoverPresentationController {
      popover.sourceView = index < 2 ? (index == 0 ? startDateField : startTimeField) : (index == 2 ? endDateField : endTimeField)
      popover.sourceRect = popover.sourceView?.bounds ?? .zero
      popover.permittedArrowDirections = .any
    }
    presenter.present(picker, animated: true)
  }
}

extension NeoProgramSearchFormView: UITextFieldDelegate {
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === keywordField { if searchEnabled { onSearch() }; return true }
    textField.resignFirstResponder(); return true
  }

  func textFieldDidBeginEditing(_ textField: UITextField) {
    if textField === channelField { updateChannelSuggestions() }
  }

  func textFieldDidEndEditing(_ textField: UITextField) {
    if textField === channelField { updateChannelSuggestions() }
  }
}

private final class NeoProgramSearchWrapView: UIView {
  var onHeightChange: (() -> Void)?
  private(set) var arrangedSubviews: [UIView] = []
  private var lastHeight: CGFloat = -1
  var horizontalSpacing: CGFloat = 8
  var verticalSpacing: CGFloat = 2

  func setItems(_ items: [UIView]) {
    arrangedSubviews.forEach { $0.removeFromSuperview() }
    arrangedSubviews = items
    items.forEach { addSubview($0) }
    invalidateIntrinsicContentSize(); setNeedsLayout()
  }

  override var intrinsicContentSize: CGSize {
    guard bounds.width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 0) }
    return CGSize(width: UIView.noIntrinsicMetric, height: height(for: bounds.width))
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let width = size.width > 0 ? size.width : bounds.width
    return CGSize(width: width, height: height(for: width))
  }

  override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
    let width = targetSize.width > 0 ? targetSize.width : bounds.width
    return CGSize(width: targetSize.width, height: height(for: width))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let newHeight = height(for: bounds.width)
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
    for view in arrangedSubviews {
      let size = view.sizeThatFits(CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height))
      let width = min(bounds.width, max(size.width, view.intrinsicContentSize.width))
      if x > 0 && x + width > bounds.width { x = 0; y += lineHeight + verticalSpacing; lineHeight = 0 }
      view.frame = CGRect(x: x, y: y, width: min(width, bounds.width), height: max(30, size.height))
      x += width + horizontalSpacing; lineHeight = max(lineHeight, view.bounds.height)
    }
    if abs(newHeight - lastHeight) > 0.5 {
      lastHeight = newHeight
      invalidateIntrinsicContentSize()
      onHeightChange?()
    }
  }

  private func height(for width: CGFloat) -> CGFloat {
    guard width > 0 else { return 0 }
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
    for view in arrangedSubviews {
      let size = view.sizeThatFits(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height))
      let itemWidth = min(width, max(size.width, view.intrinsicContentSize.width)); let itemHeight = max(30, size.height)
      if x > 0 && x + itemWidth > width { x = 0; y += lineHeight + verticalSpacing; lineHeight = 0 }
      x += itemWidth + horizontalSpacing; lineHeight = max(lineHeight, itemHeight)
    }
    return arrangedSubviews.isEmpty ? 0 : y + lineHeight
  }
}

private enum NeoProgramSearchPickerKind { case date, time }

private typealias PickerKind = NeoProgramSearchPickerKind

private final class NeoProgramSearchPickerController: UIViewController {
  private let kind: PickerKind
  private let value: String
  private weak var presenter: UIViewController?
  private let onCommit: (String) -> Void
  private let picker = UIDatePicker()

  init(kind: PickerKind, value: String, presenter: UIViewController, onCommit: @escaping (String) -> Void) {
    self.kind = kind; self.value = value; self.presenter = presenter; self.onCommit = onCommit; super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .formSheet
    if let popover = popoverPresentationController { popover.sourceView = presenter.view }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = NeoStyle.paper
    let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 16; stack.alignment = .fill; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
    ])
    let title = NeoStyle.label(kind == .date ? "日付を選択" : "時刻を選択", size: 17, bold: true)
    stack.addArrangedSubview(title)
    picker.datePickerMode = kind == .date ? .date : .time
    picker.preferredDatePickerStyle = .wheels
    picker.locale = Locale(identifier: "ja_JP")
    picker.timeZone = TimeZone(identifier: "Asia/Tokyo")
    picker.date = parsedDate() ?? Date()
    stack.addArrangedSubview(picker)
    let buttons = UIStackView(); buttons.axis = .horizontal; buttons.spacing = 12; buttons.distribution = .fillEqually
    let cancel = NeoStyle.button("キャンセル") { [weak self] in self?.dismiss(animated: true) }
    let done = NeoStyle.button("決定", filled: true) { [weak self] in self?.commit() }
    buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(done); stack.addArrangedSubview(buttons)
  }

  private func parsedDate() -> Date? {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = kind == .date ? "yyyy/MM/dd" : "HH:mm"
    return formatter.date(from: value)
  }

  private func commit() {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = kind == .date ? "yyyy/MM/dd" : "HH:mm"
    onCommit(formatter.string(from: picker.date)); dismiss(animated: true)
  }
}

private extension UIStackView {
  func setArrangedSubviews(_ views: [UIView]) {
    arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
    views.forEach { addArrangedSubview($0) }
  }
}

private final class NeoProgramSearchAdaptiveRow: UIStackView {
  var onAxisChange: (() -> Void)?
  private var lastWide: Bool?
  private let breakpoint: CGFloat

  init(arrangedSubviews: [UIView], breakpoint: CGFloat = 900) {
    self.breakpoint = breakpoint
    super.init(frame: .zero)
    arrangedSubviews.forEach { addArrangedSubview($0) }
  }

  override init(frame: CGRect) {
    breakpoint = 900
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) {
    breakpoint = 900
    super.init(coder: coder)
  }

  override func layoutSubviews() {
    let wide = bounds.width >= breakpoint
    if lastWide != wide {
      lastWide = wide
      axis = wide ? .horizontal : .vertical
      spacing = wide ? 12 : 12
      onAxisChange?()
    }
    super.layoutSubviews()
  }
}
