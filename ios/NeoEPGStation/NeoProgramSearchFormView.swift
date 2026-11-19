import UIKit

/// The presentation-only form used by the native program-search page.
///
/// The page/controller owns the search request, validation, navigation and
/// results.  This view only edits a value-type `NeoProgramSearchForm` and
/// reports the edited value through `onChange`.
final class NeoProgramSearchFormView: UIView {
  typealias Change = (NeoProgramSearchForm) -> Void

  private enum DropdownKind: String { case channels, genre, subGenre, startHour, rangeHour }

  private weak var presenter: UIViewController?
  private weak var dropdownHost: UIView?
  private let channels: [NeoLiveChannel]
  private let availableTypes: [String]
  private var form: NeoProgramSearchForm
  private let onChange: Change
  private let onClear: () -> Void
  private let onSearch: () -> Void
  private let ruleActionTitle: String
  private let onRuleAction: () -> Void

  /// Called after an accordion, chip, or wrapping layout changes.  A table
  /// header owner can re-measure itself on the next run loop turn.
  var onLayoutChange: (() -> Void)?

  var searchEnabled: Bool = true {
    didSet { searchButton.isEnabled = searchEnabled; searchButton.alpha = searchEnabled ? 1 : 0.45 }
  }
  private(set) lazy var ruleButton = NeoProgramRuleButton.make(ruleActionTitle, filled: false, identifier: "programSearch.rule") { [weak self] in
    self?.onRuleAction()
  }

  private let card = UIView()
  private let content = UIStackView()
  private let keywordField = UITextField()
  private let ignoreKeywordField = UITextField()
  private let keywordClearButton = UIButton(type: .system)
  private let ignoreKeywordClearButton = UIButton(type: .system)
  private let channelField = UITextField()
  private let durationMinField = UITextField()
  private let durationMaxField = UITextField()
  private let startDateField = UITextField()
  private let startTimeField = UITextField()
  private let endDateField = UITextField()
  private let endTimeField = UITextField()
  private let selectedChannels = NeoProgramSearchWrapView()
  private let channelArrow = UIButton(type: .system)
  private lazy var channelControl = NeoProgramSearchInput(
    label: "放送局", placeholder: "局名を入力して絞り込み", field: channelField, accessory: channelArrow, fieldContent: selectedChannels
  )
  private var periodControls: [NeoProgramSearchInput] = []
  private let dropdown = NeoProgramSearchDropdown()
  private var dropdownKind: DropdownKind?
  private let keywordOptions = NeoProgramSearchWrapView()
  private let ignoreOptions = NeoProgramSearchWrapView()
  private let typeOptions = NeoProgramSearchWrapView()
  private let genreWeekOptions = NeoProgramSearchWrapView()
  private let detailsBody = UIStackView()
  private let detailsButton = UIButton(type: .system)
  private let detailsChevron = UIImageView(image: UIImage(systemName: "chevron.down"))
  private let genreButton = NeoSelectButton()
  private let subGenreButton = NeoSelectButton()
  private let startHourButton = NeoSelectButton()
  private let rangeHourButton = NeoSelectButton()
  private let freeSwitch = UISwitch()
  private let actions = UIStackView()
  private let clearButton = UIButton(type: .system)
  private let searchButton = UIButton(type: .system)

  private var dateText: [String: String] = [:]
  private var timeText: [String: String] = [:]
  private var channelQuery = ""
  private var detailsExpanded = true
  private var adaptiveRows: [NeoProgramSearchAdaptiveRow] = []

  init(
    form: NeoProgramSearchForm,
    channels: [NeoLiveChannel],
    availableTypes: [String],
    presenter: UIViewController,
    dropdownHost: UIView,
    ruleActionTitle: String,
    onChange: @escaping Change,
    onClear: @escaping () -> Void,
    onSearch: @escaping () -> Void,
    onRuleAction: @escaping () -> Void
  ) {
    self.form = form
    self.channels = channels
    self.availableTypes = availableTypes
    self.presenter = presenter
    self.dropdownHost = dropdownHost
    self.ruleActionTitle = ruleActionTitle
    self.onChange = onChange
    self.onClear = onClear
    self.onSearch = onSearch
    self.onRuleAction = onRuleAction
    super.init(frame: .zero)
    configure()
    render()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Replaces the form without sending an edit callback.  This is used after
  /// a clear or after the root normalizes a submitted value.
  func update(_ form: NeoProgramSearchForm) {
    dismissDropdown()
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

  func dismissDropdown() {
    guard dropdownKind != nil else { return }
    dropdownKind = nil
    dropdown.dismiss()
    updateDropdownAppearance()
  }

  func layoutDropdown(in scroll: UIScrollView, keepStationVisible: Bool = false) {
    guard let kind = dropdownKind else { return }
    if keepStationVisible && kind == .channels && channelField.isFirstResponder && scroll.bounds.height > 0 {
      let anchor = channelControl.convert(channelControl.bounds, to: scroll).insetBy(dx: 0, dy: -8)
      let visibleHeight = min(anchor.height, scroll.bounds.height)
      scroll.scrollRectToVisible(CGRect(x: anchor.minX, y: anchor.minY, width: anchor.width, height: visibleHeight), animated: false)
    }
    dropdown.setNeedsLayout()
  }

  /// A table header is measured before its views receive their first frames.
  /// Give the wrapping rows their actual width before Auto Layout measures it.
  func prepareLayout(width: CGFloat, viewportWidth: CGFloat) {
    let inset: CGFloat = viewportWidth >= 900 ? 24 : 16
    let margins = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
    if content.layoutMargins != margins { content.layoutMargins = margins }
    let innerWidth = max(0, width - 2 * inset)
    for group in [keywordOptions, ignoreOptions, typeOptions] { group.prepareLayout(width: innerWidth) }
    selectedChannels.prepareLayout(width: NeoProgramSearchInput.contentWidth(in: innerWidth))
    genreWeekOptions.prepareLayout(width: max(0, innerWidth - detailsBody.layoutMargins.left - detailsBody.layoutMargins.right))
    adaptiveRows.forEach { $0.prepareLayout(viewportWidth: viewportWidth) }
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
    content.insetsLayoutMarginsFromSafeArea = false
    content.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: card.topAnchor), content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: card.trailingAnchor), content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
    ])

    keywordOptions.accessibilityIdentifier = "programSearch.keywordOptions"
    ignoreOptions.accessibilityIdentifier = "programSearch.ignoreOptions"
    typeOptions.accessibilityIdentifier = "programSearch.channelWaveOptions"
    genreWeekOptions.accessibilityIdentifier = "programSearch.weekOptions"
    configureTextField(keywordField, placeholder: "", identifier: "programSearch.keyword", returnKey: .search)
    keywordField.accessibilityLabel = "キーワード"
    configureKeywordClearButton(keywordField, button: keywordClearButton, label: "キーワード", identifier: "programSearch.keyword.clear", action: #selector(keywordClearTapped))
    configureTextField(ignoreKeywordField, placeholder: "", identifier: "programSearch.ignoreKeyword")
    ignoreKeywordField.accessibilityLabel = "除外キーワード"
    configureKeywordClearButton(ignoreKeywordField, button: ignoreKeywordClearButton, label: "除外キーワード", identifier: "programSearch.ignoreKeyword.clear", action: #selector(ignoreKeywordClearTapped))
    configureTextField(channelField, placeholder: "", identifier: "programSearch.channel", outlined: true)
    channelField.delegate = self
    channelField.addTarget(self, action: #selector(channelQueryChanged), for: .editingChanged)
    selectedChannels.setTrailingField(channelField)
    channelControl.accessibilityIdentifier = "programSearch.channelControl"
    channelArrow.setImage(NeoIcon.image("ArrowDropDown"), for: .normal)
    channelArrow.tintColor = .white
    channelArrow.accessibilityIdentifier = "programSearch.channelToggle"
    channelArrow.addTarget(self, action: #selector(toggleChannelChoices), for: .touchUpInside)
    let channelTap = UITapGestureRecognizer(target: self, action: #selector(toggleChannelDropdown))
    channelTap.cancelsTouchesInView = false
    channelTap.delegate = self
    channelControl.addGestureRecognizer(channelTap)
    dropdown.onDismiss = { [weak self] in self?.dismissDropdown() }
    keywordField.delegate = self

    configureNumberField(durationMinField, identifier: "programSearch.durationMin")
    configureNumberField(durationMaxField, identifier: "programSearch.durationMax")
    periodControls = [
      makePeriodField(startDateField, key: "startDate", label: "開始日", index: 0),
      makePeriodField(startTimeField, key: "startTime", label: "開始時刻", index: 1),
      makePeriodField(endDateField, key: "endDate", label: "終了日", index: 2),
      makePeriodField(endTimeField, key: "endTime", label: "終了時刻", index: 3),
    ]

    detailsButton.setTitle("詳細条件", for: .normal)
    detailsButton.tintColor = .white
    detailsButton.setTitleColor(.white, for: .normal)
    detailsButton.titleLabel?.font = .systemFont(ofSize: 16)
    detailsButton.contentHorizontalAlignment = .left
    detailsButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 48)
    detailsChevron.tintColor = NeoStyle.muted; detailsChevron.contentMode = .scaleAspectFit
    detailsChevron.isUserInteractionEnabled = false; detailsChevron.translatesAutoresizingMaskIntoConstraints = false
    detailsButton.addSubview(detailsChevron)
    NSLayoutConstraint.activate([
      detailsChevron.trailingAnchor.constraint(equalTo: detailsButton.trailingAnchor, constant: -16),
      detailsChevron.centerYAnchor.constraint(equalTo: detailsButton.centerYAnchor),
      detailsChevron.widthAnchor.constraint(equalToConstant: 18), detailsChevron.heightAnchor.constraint(equalToConstant: 18),
    ])
    detailsButton.accessibilityLabel = "詳細条件"
    detailsButton.addTarget(self, action: #selector(toggleDetails), for: .touchUpInside)

    detailsBody.axis = .vertical
    detailsBody.spacing = 16
    detailsBody.alignment = .fill
    detailsBody.isLayoutMarginsRelativeArrangement = true
    detailsBody.insetsLayoutMarginsFromSafeArea = false
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
      $0.showsMenuAsPrimaryAction = false
      $0.titleLabel?.numberOfLines = 2
      $0.titleLabel?.lineBreakMode = .byTruncatingTail
      $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    for kind in [DropdownKind.genre, .subGenre, .startHour, .rangeHour] {
      (dropdownAnchor(for: kind) as? UIButton)?.addAction(UIAction { [weak self] _ in
        self?.toggleDropdown(kind)
      }, for: .touchUpInside)
    }

    freeSwitch.onTintColor = NeoStyle.accent
    freeSwitch.addTarget(self, action: #selector(freeChanged), for: .valueChanged)
    freeSwitch.accessibilityLabel = "無料放送のみ"

    styleActionButton(clearButton, title: "クリア", filled: false, identifier: "programSearch.clear", action: #selector(clearTapped))
    styleActionButton(searchButton, title: "検索", filled: true, identifier: "programSearch.search", action: #selector(searchTapped))
    searchButton.isEnabled = searchEnabled
    searchButton.alpha = searchEnabled ? 1 : 0.45

    // The outer controller provides scrolling.  Keep this view a single
    // self-sizing form surface so a table-header owner can re-measure it.
    let key = formLabeledField("キーワード", control: keywordField)
    content.addArrangedSubview(key); content.setCustomSpacing(2, after: key)
    content.addArrangedSubview(keywordOptions)
    let ignore = formLabeledField("除外キーワード", control: ignoreKeywordField)
    content.addArrangedSubview(ignore); content.setCustomSpacing(2, after: ignore)
    content.addArrangedSubview(ignoreOptions)
    let channelSection = UIStackView(arrangedSubviews: [channelControl, typeOptions])
    channelSection.axis = .vertical; channelSection.spacing = 5; channelSection.alignment = .fill
    content.addArrangedSubview(channelSection)
    actions.axis = .horizontal; actions.spacing = 8; actions.alignment = .center; actions.distribution = .fill
    actions.addArrangedSubview(UIView())
    actions.addArrangedSubview(clearButton)
    actions.addArrangedSubview(searchButton)
    actions.addArrangedSubview(ruleButton)
    ruleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    actions.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  private func configureTextField(
    _ field: UITextField, placeholder: String, identifier: String, returnKey: UIReturnKeyType = .default, outlined: Bool = false
  ) {
    field.placeholder = placeholder
    field.returnKeyType = returnKey
    field.textColor = .white
    field.tintColor = NeoStyle.accent
    field.backgroundColor = .clear
    field.font = .systemFont(ofSize: 16)
    field.borderStyle = .none
    if !outlined {
      field.layer.cornerRadius = 4
      field.layer.borderWidth = 1
      field.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
      field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
      field.leftViewMode = .always
      field.clearButtonMode = .whileEditing
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.accessibilityIdentifier = identifier
    field.accessibilityLabel = placeholder
    field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
  }

  private func configureNumberField(_ field: UITextField, identifier: String) {
    configureTextField(field, placeholder: "", identifier: identifier)
    field.keyboardType = .numberPad
    field.accessibilityLabel = identifier.replacingOccurrences(of: "programSearch.", with: "")
  }

  private func configureKeywordClearButton(
    _ field: UITextField, button: UIButton, label: String, identifier: String, action: Selector
  ) {
    // Use a row-local accessory instead of UITextField's while-editing clear
    // affordance so it remains available after the field resigns first
    // responder.  The trailing slot is removed while empty to keep the text
    // area aligned with the other form fields.
    field.clearButtonMode = .never
    button.frame = CGRect(x: 0, y: 0, width: 40, height: 44)
    button.setImage(NeoIcon.image("Close"), for: .normal)
    button.tintColor = NeoStyle.muted
    button.accessibilityIdentifier = identifier
    button.accessibilityLabel = "\(label)をクリア"
    button.accessibilityTraits = [.button]
    button.addTarget(self, action: action, for: .touchUpInside)
    field.rightView = button
    field.rightViewMode = .never
  }

  private func makePeriodField(_ field: UITextField, key: String, label: String, index: Int) -> NeoProgramSearchInput {
    let isDate = index.isMultiple(of: 2)
    configureTextField(field, placeholder: "", identifier: "programSearch.\(key)", outlined: true)
    field.delegate = self
    field.keyboardType = .asciiCapableNumberPad
    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    field.adjustsFontSizeToFitWidth = true
    field.minimumFontSize = 12
    let button = UIButton(type: .system)
    button.tintColor = .white
    button.setImage(NeoIcon.image(isDate ? "CalendarMonthOutlined" : "ScheduleOutlined"), for: .normal)
    button.accessibilityLabel = isDate ? "\(label)をカレンダーから選択" : "\(label)を時計から選択"
    button.accessibilityIdentifier = "programSearch.\(key).picker"
    button.addAction(UIAction { [weak self] _ in self?.presentPicker(index: index) }, for: .touchUpInside)
    return NeoProgramSearchInput(label: label, placeholder: isDate ? "YYYY/MM/DD" : "HH:mm", field: field, accessory: button)
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
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.8
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
    updateKeywordClearButtons()
    freeSwitch.isOn = form.isFree

    keywordOptions.setItems(keywordFieldButtons(for: form.keywordFields, keyword: true))
    ignoreOptions.setItems(keywordFieldButtons(for: form.ignoreFields, keyword: false))
    selectedChannels.setItems(channelChipButtons())
    typeOptions.setItems(typeButtons())
    genreWeekOptions.setItems(weekButtons())
    renderMenuValues()
    updateDropdownAppearance()
    refreshDropdown()
    updatePeriodAppearance()
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
    detailsChevron.transform = detailsExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
    detailsButton.accessibilityValue = detailsExpanded ? "展開" : "折りたたみ"
    detailsButton.accessibilityTraits = detailsExpanded ? [.button, .selected] : [.button]
  }

  private func formLabeledField(_ title: String, control: UIView) -> UIView {
    let stack = UIStackView(arrangedSubviews: [NeoStyle.label(title, size: 13, muted: true), control])
    stack.axis = .vertical; stack.spacing = 5; stack.alignment = .fill
    stack.accessibilityLabel = title
    return stack
  }

  private func hoursRow() -> UIView {
    let start = formLabeledField("開始時刻", control: startHourButton)
    let range = formLabeledField("範囲", control: rangeHourButton)
    let separator = NeoStyle.label("～", size: 15)
    let within = NeoStyle.label("以内", size: 15)
    let row = NeoProgramSearchAdaptiveRow(arrangedSubviews: [start, separator, range, within], breakpoint: 600)
    row.axis = .vertical; row.spacing = 8; row.alignment = .fill; row.distribution = .fill
    startHourButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    rangeHourButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.accessibilityIdentifier = "programSearch.hours"
    adaptiveRows.append(row)
    return row
  }

  private func durationRow() -> UIView {
    let row = NeoProgramSearchAdaptiveRow(arrangedSubviews: [
      formLabeledField("最小（分）", control: durationMinField),
      formLabeledField("最大（分）", control: durationMaxField)
    ], breakpoint: 600)
    row.axis = .vertical; row.spacing = 12; row.distribution = .fillEqually
    row.accessibilityIdentifier = "programSearch.duration"
    adaptiveRows.append(row)
    return row
  }

  private func periodRow() -> UIView {
    let start = UIStackView(arrangedSubviews: [periodControls[0], periodControls[1]])
    let end = UIStackView(arrangedSubviews: [periodControls[2], periodControls[3]])
    [start, end].forEach { $0.axis = .horizontal; $0.spacing = 8; $0.distribution = .fillEqually }
    let row = NeoProgramSearchAdaptiveRow(arrangedSubviews: [start, end])
    row.axis = .vertical; row.spacing = 12; row.distribution = .fill
    row.accessibilityIdentifier = "programSearch.period"
    adaptiveRows.append(row)
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
      button.setTitleColor(.white, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 14)
      button.layer.cornerRadius = 18
      button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
      button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
      button.accessibilityLabel = "\(channel.name)を検索対象から削除"
      button.accessibilityIdentifier = "programSearch.channelChip.\(id)"
      button.addAction(UIAction { [weak self] _ in
        guard let self else { return }; var next = self.form; next.channelIDs.removeAll { $0 == id }; self.emit(next)
      }, for: .touchUpInside)
      return button
    }
  }

  private func dropdownAnchor(for kind: DropdownKind) -> UIView {
    switch kind {
    case .channels: return channelControl
    case .genre: return genreButton
    case .subGenre: return subGenreButton
    case .startHour: return startHourButton
    case .rangeHour: return rangeHourButton
    }
  }

  private func toggleDropdown(_ kind: DropdownKind) {
    if dropdownKind == kind { dismissDropdown(); return }
    showDropdown(kind)
  }

  private func showDropdown(_ kind: DropdownKind) {
    let anchor = dropdownAnchor(for: kind)
    guard let host = dropdownHost, anchor.window != nil, presenter?.presentedViewController == nil else { return }
    if kind != .channels { presenter?.view.endEditing(true) }
    dropdownKind = kind
    updateDropdownAppearance()
    let labeledField = kind == .channels ? anchor : anchor.superview ?? anchor
    dropdown.show(in: host, anchor: labeledField, rows: dropdownRows(for: kind),
      identifier: kind == .channels ? "programSearch.channelSuggestions" : "programSearch.options.\(kind.rawValue)",
      isStationList: kind == .channels)
  }

  private func refreshDropdown(resetScroll: Bool = false) {
    guard let kind = dropdownKind else { return }
    dropdown.update(dropdownRows(for: kind), resetScroll: resetScroll)
  }

  private func updateDropdownAppearance() {
    let stationsOpen = dropdownKind == .channels
    channelControl.updateAppearance(hasSelection: !form.channelIDs.isEmpty, active: stationsOpen)
    channelArrow.accessibilityLabel = stationsOpen ? "放送局の候補を閉じる" : "放送局の候補を開く"
    channelArrow.imageView?.transform = stationsOpen ? CGAffineTransform(rotationAngle: .pi) : .identity
    for kind in [DropdownKind.genre, .subGenre, .startHour, .rangeHour] {
      let field = dropdownAnchor(for: kind)
      let isOpen = dropdownKind == kind
      field.layer.borderWidth = isOpen ? 2 : 1
      field.layer.borderColor = (isOpen ? NeoStyle.accent : UIColor.white.withAlphaComponent(0.23)).cgColor
    }
  }

  private func dropdownRows(for kind: DropdownKind) -> [NeoProgramSearchDropdown.Row] {
    switch kind {
    case .channels: return channelRows()
    case .genre: return genreRows()
    case .subGenre: return subGenreRows()
    case .startHour, .rangeHour: return hourRows(for: kind)
    }
  }

  private func channelRows() -> [NeoProgramSearchDropdown.Row] {
    let needle = normalizedChannelQuery(channelQuery)
    let matches = channels.filter { channel in
      needle.isEmpty || normalizedChannelQuery(channel.name).contains(needle)
        || normalizedChannelQuery(channel.halfWidthName ?? "").contains(needle)
    }
    guard !matches.isEmpty else {
      return [.init(title: "該当する放送局がありません", identifier: "programSearch.channelEmpty", style: .empty)]
    }
    return matches.map { channel in
      .init(title: channel.name, identifier: "programSearch.channelOption.\(channel.id)",
        selected: form.channelIDs.contains(channel.id), action: { [weak self] in self?.selectChannel(channel.id) })
    }
  }

  private func selectChannel(_ id: Int) {
    var next = form
    if let index = next.channelIDs.firstIndex(of: id) { next.channelIDs.remove(at: index) }
    else { next.channelIDs.append(id) }
    channelQuery = ""
    dismissDropdown()
    emit(next)
  }

  private func genreRows() -> [NeoProgramSearchDropdown.Row] {
    var options: [NeoProgramSearchDropdown.Row] = [
      .init(title: "すべて", identifier: "programSearch.option.genre.all", style: .checkbox, selected: form.genres.isEmpty,
        action: { [weak self] in self?.selectGenre(nil) })
    ]
    options += NeoProgramSearchMetadata.searchableGenres.map { genre in
      .init(title: genreName(genre), identifier: "programSearch.option.genre.\(genre)", style: .checkbox,
        selected: form.genres.contains(genre), action: { [weak self] in self?.selectGenre(genre) })
    }
    return options
  }

  private func selectGenre(_ genre: Int?) {
    var next = form
    if let genre {
      if let index = next.genres.firstIndex(of: genre) {
        next.genres.remove(at: index)
        next.subGenres.removeAll { $0.hasPrefix("\(genre):") }
      } else { next.genres.append(genre) }
    } else {
      next.genres = []
      next.subGenres = []
    }
    emit(next)
  }

  private func subGenreRows() -> [NeoProgramSearchDropdown.Row] {
    var rows: [NeoProgramSearchDropdown.Row] = []
    for genre in form.genres {
      let values = subGenreNames(genre)
      let prefix = "\(genre):"
      rows.append(.init(title: genreName(genre), identifier: "programSearch.option.subGenre.\(genre).header", style: .heading))
      rows.append(.init(title: "すべて", identifier: "programSearch.option.subGenre.\(genre).all", style: .checkbox,
        selected: !form.subGenres.contains { $0.hasPrefix(prefix) }, action: { [weak self] in
          guard let self else { return }
          var next = form
          next.subGenres.removeAll { $0.hasPrefix(prefix) }
          emit(next)
        }))
      for (index, name) in values.enumerated() where !name.isEmpty {
        let key = "\(prefix)\(index)"
        rows.append(.init(title: name, identifier: "programSearch.option.subGenre.\(genre).\(index)", style: .checkbox,
          selected: form.subGenres.contains(key), action: { [weak self] in
            guard let self else { return }
            var next = form
            if let location = next.subGenres.firstIndex(of: key) { next.subGenres.remove(at: location) }
            else { next.subGenres.append(key) }
            emit(next)
          }))
      }
    }
    return rows
  }

  private func hourRows(for kind: DropdownKind) -> [NeoProgramSearchDropdown.Row] {
    let range = kind == .rangeHour
    let selected = range ? form.rangeHour : form.startHour
    let unit = range ? "時間" : "時"
    let firstHour = range ? 1 : 0
    func row(_ hour: Int?) -> NeoProgramSearchDropdown.Row {
      .init(title: hour.map { "\($0)\(unit)" } ?? "指定なし",
        identifier: "programSearch.option.\(kind.rawValue).\(hour.map { String($0) } ?? "none")",
        selected: hour == selected, action: { [weak self] in
          guard let self else { return }
          var next = form
          if range { next.rangeHour = hour } else { next.startHour = hour }
          dismissDropdown()
          emit(next)
        })
    }
    return [row(nil)] + (firstHour...23).map { (hour: Int) in row(hour) }
  }

  private func renderMenuValues() {
    genreButton.setTitle(form.genres.isEmpty ? "すべて" : form.genres.map(genreName).joined(separator: "、"), for: .normal)
    subGenreButton.isEnabled = !form.genres.isEmpty
    let subGenres = form.genres.map { genre in
      let title = genreName(genre)
      let names = subGenreNames(genre)
      let selected = form.subGenres.filter { $0.hasPrefix("\(genre):") }
        .compactMap { Int($0.split(separator: ":").last ?? "") }
        .compactMap { names.indices.contains($0) ? names[$0] : nil }.filter { !$0.isEmpty }
      return "\(title): \(selected.isEmpty ? "すべて" : selected.joined(separator: "、"))"
    }
    subGenreButton.setTitle(subGenres.isEmpty ? "すべて" : subGenres.joined(separator: " / "), for: .normal)
    startHourButton.setTitle(form.startHour.map { "\($0)時" } ?? "指定なし", for: .normal)
    rangeHourButton.setTitle(form.rangeHour.map { "\($0)時間" } ?? "指定なし", for: .normal)
  }

  private func genreName(_ index: Int) -> String {
    let names = NeoProgramSearchMetadata.genreNames
    return names.indices.contains(index) ? names[index] : "ジャンル \(index)"
  }

  private func subGenreNames(_ genre: Int) -> [String] {
    let groups = NeoProgramSearchMetadata.subGenreNames
    return groups.indices.contains(genre) ? groups[genre] : []
  }

  private func dateDisplay(_ raw: String) -> String {
    let displayed = NeoDateInput.display(raw)
    return displayed.isEmpty ? raw : displayed
  }

  private func updatePeriodAppearance() {
    for (index, field) in [startDateField, startTimeField, endDateField, endTimeField].enumerated() {
      let value = field.text ?? ""
      let invalid = index.isMultiple(of: 2)
        ? value.count == 10 && NeoDateInput.parse(value) == nil
        : value.count == 5 && NeoProgramSearchTime.parse(value) == nil
      periodControls[index].updateAppearance(invalid: invalid)
    }
  }

  private func updateKeywordClearButtons() {
    let keywordHasValue = !(keywordField.text ?? "").isEmpty
    let ignoreHasValue = !(ignoreKeywordField.text ?? "").isEmpty
    keywordClearButton.isHidden = !keywordHasValue
    keywordClearButton.isEnabled = keywordHasValue
    keywordClearButton.accessibilityElementsHidden = !keywordHasValue
    keywordField.rightViewMode = keywordHasValue ? .always : .never
    ignoreKeywordClearButton.isHidden = !ignoreHasValue
    ignoreKeywordClearButton.isEnabled = ignoreHasValue
    ignoreKeywordClearButton.accessibilityElementsHidden = !ignoreHasValue
    ignoreKeywordField.rightViewMode = ignoreHasValue ? .always : .never
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
    form = next
    onChange(next)
    updateKeywordClearButtons()
    updatePeriodAppearance()
  }

  @objc private func channelQueryChanged() {
    channelQuery = channelField.text ?? ""
    if dropdownKind == .channels { refreshDropdown(resetScroll: true) }
    else if !channelQuery.isEmpty { showDropdown(.channels) }
  }

  @objc private func toggleChannelDropdown() {
    guard channelField.isFirstResponder || channelField.becomeFirstResponder() else { return }
    toggleDropdown(.channels)
  }

  @objc private func toggleChannelChoices() { toggleDropdown(.channels) }

  @objc private func toggleDetails() {
    dismissDropdown()
    detailsExpanded.toggle()
    renderDetails()
    notifyLayoutChange()
  }
  @objc private func freeChanged() { var next = form; next.isFree = freeSwitch.isOn; emit(next) }
  @objc private func keywordClearTapped() { clearKeywordField(keywordField) }
  @objc private func ignoreKeywordClearTapped() { clearKeywordField(ignoreKeywordField) }
  @objc private func clearTapped() { onClear() }
  @objc private func searchTapped() { if searchEnabled { onSearch() } }

  private func clearKeywordField(_ field: UITextField) {
    guard !(field.text ?? "").isEmpty else { return }
    var next = form
    if field === keywordField { next.keyword = "" }
    else if field === ignoreKeywordField { next.ignoreKeyword = "" }
    else { return }
    emit(next)
  }

  private func presentPicker(index: Int) {
    guard let presenter, presenter.presentedViewController == nil else { return }
    let control = periodControls[index]
    let field = [startDateField, startTimeField, endDateField, endTimeField][index]
    let picker = NeoProgramSearchPickerController(kind: index.isMultiple(of: 2) ? .date : .time,
      value: field.text ?? "", fieldLabel: control.fieldLabel) { [weak self] value in
      guard let self else { return }
      var next = form
      switch index {
      case 0: dateText["startDate"] = value; next.startDate = value
      case 1: timeText["startTime"] = value; next.startTime = value
      case 2: dateText["endDate"] = value; next.endDate = value
      default: timeText["endTime"] = value; next.endTime = value
      }
      emit(next)
    }
    dismissDropdown()
    presenter.view.endEditing(true)
    presenter.present(picker, animated: !UIAccessibility.isReduceMotionEnabled)
  }
}

extension NeoProgramSearchFormView: UITextFieldDelegate, UIGestureRecognizerDelegate {
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === keywordField { if searchEnabled { onSearch() }; return true }
    textField.resignFirstResponder(); return true
  }

  func textFieldDidBeginEditing(_ textField: UITextField) {
    if textField === channelField { updateDropdownAppearance() }
    else { updatePeriodAppearance() }
  }

  func textFieldDidEndEditing(_ textField: UITextField) {
    if textField === channelField { updateDropdownAppearance() }
    else { updatePeriodAppearance() }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var view = touch.view
    while let candidate = view, candidate !== channelControl {
      if candidate is UIButton { return false }
      view = candidate.superview
    }
    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

private final class NeoProgramSearchWrapView: UIView {
  private(set) var arrangedSubviews: [UIView] = []
  private weak var trailingField: UITextField?
  private var layoutWidth: CGFloat = 0
  private lazy var reservedHeight: NSLayoutConstraint = {
    let constraint = heightAnchor.constraint(equalToConstant: 0)
    constraint.priority = UILayoutPriority(999)
    constraint.isActive = true
    return constraint
  }()
  var horizontalSpacing: CGFloat = 8
  var verticalSpacing: CGFloat = 2

  func setTrailingField(_ field: UITextField) {
    trailingField = field
    addSubview(field)
  }

  func setItems(_ items: [UIView]) {
    arrangedSubviews.filter { $0 !== trailingField }.forEach { $0.removeFromSuperview() }
    arrangedSubviews = items
    if let trailingField { arrangedSubviews.append(trailingField) }
    items.forEach { addSubview($0) }
    updateHeight(); setNeedsLayout()
  }

  func prepareLayout(width: CGFloat) {
    guard width != layoutWidth else { return }
    layoutWidth = width; updateHeight(); setNeedsLayout()
  }

  private func updateHeight() {
    let height = frames(width: layoutWidth).last?.maxY ?? 0
    if reservedHeight.constant != height { reservedHeight.constant = height }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for (view, frame) in zip(arrangedSubviews, frames(width: layoutWidth)) { view.frame = frame }
  }

  private func frames(width: CGFloat) -> [CGRect] {
    guard width > 0 else { return [] }
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
    var result: [CGRect] = []
    for view in arrangedSubviews {
      let size = view.sizeThatFits(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height))
      let isField = view === trailingField
      let itemWidth = min(width, isField ? 100 : ceil(max(size.width, view.intrinsicContentSize.width)))
      let itemHeight: CGFloat = 36
      if x > 0 && x + itemWidth > width { x = 0; y += lineHeight + verticalSpacing; lineHeight = 0 }
      result.append(CGRect(x: x, y: y, width: isField ? width - x : itemWidth, height: itemHeight))
      x += itemWidth + horizontalSpacing; lineHeight = max(lineHeight, itemHeight)
    }
    return result
  }
}

private final class NeoProgramSearchAdaptiveRow: UIStackView {
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

  required init(coder: NSCoder) {
    breakpoint = 900
    super.init(coder: coder)
  }

  func prepareLayout(viewportWidth: CGFloat) {
    let desired: NSLayoutConstraint.Axis = viewportWidth >= breakpoint ? .horizontal : .vertical
    if axis != desired { axis = desired }
  }
}
