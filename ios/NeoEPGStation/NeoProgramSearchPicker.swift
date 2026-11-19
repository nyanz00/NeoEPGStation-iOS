import UIKit

/// Compact date/time picker used by the program-search form.
///
/// The Web dialog uses a bounded paper surface over a dimmed backdrop.  The
/// native app keeps that same interaction model rather than presenting a
/// `formSheet`, whose height is unconstrained in an iPad split view.  The date
/// surface is a small Japanese month grid; the time surface is an explicit
/// two-column wheel so the 24-hour, minute-by-minute contract does not depend
/// on the user's system clock preference.
final class NeoProgramSearchPickerController: UIViewController {
  enum Kind {
    case date
    case time
  }

  private static let japanTimeZone = TimeZone(identifier: "Asia/Tokyo")!

  private let kind: Kind
  private let fieldLabel: String
  private let onCommit: (String) -> Void
  private let calendar: Calendar

  private var draftDate: Date
  private var draftHour: Int
  private var draftMinute: Int
  private var visibleYear: Int
  private var visibleMonth: Int

  private let dimmingView = UIControl()
  private let card = UIView()
  private let titleLabel = UILabel()
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let actionBar = UIView()
  private var cardWidthConstraint: NSLayoutConstraint!
  private var cardHeightConstraint: NSLayoutConstraint!

  private let monthButton = UIButton(type: .system)
  private var dayButtons: [UIButton] = []
  private let timeValueLabel = UILabel()
  private let timePicker = UIPickerView()

  init(kind: Kind, value: String, fieldLabel: String, onCommit: @escaping (String) -> Void) {
    self.kind = kind
    self.fieldLabel = fieldLabel
    self.onCommit = onCommit

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "ja_JP")
    calendar.timeZone = Self.japanTimeZone
    calendar.firstWeekday = 2 // Monday, matching dayjs.updateLocale('ja', { weekStart: 1 }).
    calendar.minimumDaysInFirstWeek = 1
    self.calendar = calendar

    let now = Date()
    let initialDate = Self.initialDate(for: kind, value: value, calendar: calendar, now: now)
    let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
    let initialComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: initialDate)
    self.draftDate = initialDate
    self.draftHour = initialComponents.hour ?? nowComponents.hour ?? 0
    self.draftMinute = initialComponents.minute ?? nowComponents.minute ?? 0
    self.visibleYear = initialComponents.year ?? calendar.component(.year, from: now)
    self.visibleMonth = initialComponents.month ?? calendar.component(.month, from: now)

    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureSurface()
    configureActions()
    if kind == .date {
      configureDateContent()
    } else {
      configureTimeContent()
    }
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    let viewport = view.bounds.inset(by: view.safeAreaInsets)
    cardWidthConstraint.constant = viewport.width >= 600 ? 400 : max(0, viewport.width - 24)
    cardHeightConstraint.constant = min(preferredHeight, max(0, viewport.height - 24))
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
  }

  private var preferredHeight: CGFloat { kind == .date ? 432 : 332 }

  private func configureSurface() {
    view.backgroundColor = .clear

    dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.56)
    dimmingView.accessibilityLabel = "閉じる"
    dimmingView.accessibilityHint = "背景をタップして閉じます"
    dimmingView.addTarget(self, action: #selector(backgroundTapped), for: .touchUpInside)
    dimmingView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(dimmingView)

    card.backgroundColor = NeoStyle.paper
    card.layer.cornerRadius = 12
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.35
    card.layer.shadowRadius = 28
    card.layer.shadowOffset = CGSize(width: 0, height: 16)
    card.accessibilityIdentifier = "programSearch.picker.card"
    card.accessibilityLabel = "\(fieldLabel)を選択"
    card.accessibilityViewIsModal = true
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: 400)
    cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: preferredHeight)
    NSLayoutConstraint.activate([
      dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
      dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      card.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      cardWidthConstraint,
      cardHeightConstraint,
    ])

    titleLabel.text = "\(fieldLabel)を選択"
    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    titleLabel.numberOfLines = 0
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.accessibilityTraits = [.header]

    scrollView.backgroundColor = .clear
    scrollView.alwaysBounceVertical = false
    scrollView.showsVerticalScrollIndicator = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(scrollView)
    actionBar.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(actionBar)

    contentStack.axis = .vertical
    contentStack.alignment = .fill
    contentStack.spacing = 12
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentStack)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -8),
      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])
    contentStack.addArrangedSubview(titleLabel)

    NSLayoutConstraint.activate([
      actionBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      actionBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      actionBar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
      actionBar.heightAnchor.constraint(equalToConstant: 66),
    ])
    let separator = UIView()
    separator.backgroundColor = NeoStyle.border
    separator.translatesAutoresizingMaskIntoConstraints = false
    actionBar.addSubview(separator)
    NSLayoutConstraint.activate([
      separator.topAnchor.constraint(equalTo: actionBar.topAnchor),
      separator.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  private func configureActions() {
    let clear = makeActionButton(
      title: "クリア",
      icon: nil,
      filled: false,
      identifier: "programSearch.picker.clear",
      action: #selector(clearTapped)
    )
    let cancel = makeActionButton(
      title: "キャンセル",
      icon: nil,
      filled: false,
      identifier: "programSearch.picker.cancel",
      action: #selector(cancelTapped)
    )
    let select = makeActionButton(
      title: "選択",
      icon: kind == .date ? "CalendarMonthOutlined" : "ScheduleOutlined",
      filled: true,
      identifier: "programSearch.picker.select",
      action: #selector(selectTapped)
    )

    let stack = UIStackView(arrangedSubviews: [clear, UIView(), cancel, select])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    actionBar.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: actionBar.topAnchor),
      stack.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor),
    ])
    stack.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
    clear.setContentHuggingPriority(.required, for: .horizontal)
    cancel.setContentHuggingPriority(.required, for: .horizontal)
    select.setContentHuggingPriority(.required, for: .horizontal)
  }

  private func makeActionButton(title: String, icon: String?, filled: Bool, identifier: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    if let icon {
      button.setImage(NeoIcon.image(icon), for: .normal)
      button.semanticContentAttribute = .forceLeftToRight
      button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
    }
    button.setTitleColor(filled ? .black : NeoStyle.accent, for: .normal)
    button.tintColor = filled ? .black : NeoStyle.accent
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    button.backgroundColor = filled ? NeoStyle.accent : .clear
    button.layer.cornerRadius = 7
    button.contentEdgeInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    button.accessibilityIdentifier = identifier
    button.accessibilityLabel = title
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func configureDateContent() {
    let header = UIStackView()
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 6
    header.distribution = .fill

    let previous = makeNavigationButton(icon: "ChevronLeft", label: "前の月", action: #selector(previousMonthTapped))
    let next = makeNavigationButton(icon: "ChevronRight", label: "次の月", action: #selector(nextMonthTapped))
    header.addArrangedSubview(monthButton)
    header.addArrangedSubview(previous)
    header.addArrangedSubview(next)
    previous.widthAnchor.constraint(equalToConstant: 42).isActive = true
    next.widthAnchor.constraint(equalToConstant: 42).isActive = true
    monthButton.setTitleColor(.white, for: .normal)
    monthButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    monthButton.titleLabel?.adjustsFontSizeToFitWidth = true
    monthButton.titleLabel?.minimumScaleFactor = 0.8
    monthButton.accessibilityLabel = "年月を選択"
    monthButton.accessibilityHint = "年または月を変更します"
    monthButton.showsMenuAsPrimaryAction = true
    monthButton.contentHorizontalAlignment = .left
    monthButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    monthButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    monthButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    contentStack.addArrangedSubview(header)

    let calendarStack = UIStackView()
    calendarStack.axis = .vertical
    calendarStack.spacing = 4
    calendarStack.alignment = .fill

    let weekdayRow = UIStackView()
    weekdayRow.axis = .horizontal
    weekdayRow.distribution = .fillEqually
    weekdayRow.alignment = .fill
    let weekdaySymbols = ["月", "火", "水", "木", "金", "土", "日"]
    for (index, symbol) in weekdaySymbols.enumerated() {
      let label = NeoStyle.label(symbol, size: 12, muted: index < 5)
      label.textAlignment = .center
      label.heightAnchor.constraint(equalToConstant: 24).isActive = true
      weekdayRow.addArrangedSubview(label)
    }
    calendarStack.addArrangedSubview(weekdayRow)

    dayButtons.removeAll(keepingCapacity: true)
    for row in 0..<6 {
      let rowStack = UIStackView()
      rowStack.axis = .horizontal
      rowStack.distribution = .fillEqually
      rowStack.alignment = .fill
      for column in 0..<7 {
        let button = UIButton(type: .system)
        button.tag = row * 7 + column
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.layer.cornerRadius = 17
        button.accessibilityTraits = [.button]
        button.addTarget(self, action: #selector(dayTapped(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        rowStack.addArrangedSubview(button)
        dayButtons.append(button)
      }
      calendarStack.addArrangedSubview(rowStack)
    }
    calendarStack.accessibilityIdentifier = "programSearch.picker.date"
    contentStack.addArrangedSubview(calendarStack)
    renderCalendar()
  }

  private func configureTimeContent() {
    timeValueLabel.textColor = .white
    timeValueLabel.font = .systemFont(ofSize: 24, weight: .semibold)
    timeValueLabel.textAlignment = .center
    timeValueLabel.adjustsFontForContentSizeCategory = true
    timeValueLabel.accessibilityLabel = "時刻"
    contentStack.addArrangedSubview(timeValueLabel)

    let captions = UIStackView(arrangedSubviews: [
      NeoStyle.label("時", size: 12, muted: true),
      NeoStyle.label("分", size: 12, muted: true),
    ])
    captions.axis = .horizontal
    captions.distribution = .fillEqually
    captions.alignment = .center
    captions.arrangedSubviews.forEach { ($0 as? UILabel)?.textAlignment = .center }
    contentStack.addArrangedSubview(captions)

    timePicker.backgroundColor = .clear
    timePicker.delegate = self
    timePicker.dataSource = self
    timePicker.accessibilityIdentifier = "programSearch.picker.time"
    timePicker.accessibilityLabel = "時刻を選択"
    timePicker.heightAnchor.constraint(equalToConstant: 132).isActive = true
    contentStack.addArrangedSubview(timePicker)
    timePicker.selectRow(draftHour, inComponent: 0, animated: false)
    timePicker.selectRow(draftMinute, inComponent: 1, animated: false)
    renderTime()
  }

  private func makeNavigationButton(icon: String, label: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(NeoIcon.image(icon), for: .normal)
    button.tintColor = NeoStyle.accent
    button.accessibilityLabel = label
    button.addTarget(self, action: action, for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    return button
  }

  private func renderCalendar() {
    let monthTitle = String(format: "%04d年%02d月", visibleYear, visibleMonth)
    monthButton.setTitle(monthTitle, for: .normal)
    monthButton.accessibilityValue = monthTitle
    monthButton.menu = makeMonthMenu()

    let firstDay = calendar.date(from: DateComponents(year: visibleYear, month: visibleMonth, day: 1))
    let firstWeekday = firstDay.map { calendar.component(.weekday, from: $0) } ?? 2
    let offset = (firstWeekday - calendar.firstWeekday + 7) % 7
    let days = firstDay.flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 0
    let selected = calendar.dateComponents([.year, .month, .day], from: draftDate)

    for index in dayButtons.indices {
      let day = index - offset + 1
      let button = dayButtons[index]
      guard day >= 1, day <= days else {
        button.setTitle(nil, for: .normal)
        button.isEnabled = false
        button.accessibilityElementsHidden = true
        button.backgroundColor = .clear
        continue
      }

      button.isEnabled = true
      button.accessibilityElementsHidden = false
      button.setTitle("\(day)", for: .normal)
      let isSelected = selected.year == visibleYear && selected.month == visibleMonth && selected.day == day
      button.backgroundColor = isSelected ? NeoStyle.accent : .clear
      button.setTitleColor(isSelected ? .black : .white, for: .normal)
      button.accessibilityLabel = "\(visibleYear)年\(visibleMonth)月\(day)日"
      button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
  }

  private func renderTime() {
    timeValueLabel.text = String(format: "%02d:%02d", draftHour, draftMinute)
    timeValueLabel.accessibilityValue = timeValueLabel.text
  }

  private func makeMonthMenu() -> UIMenu {
    let lowerYear = max(1, visibleYear - 50)
    let upperYear = min(9999, visibleYear + 50)
    let yearActions = (lowerYear...upperYear).map { year in
      UIAction(title: String(format: "%04d年", year), state: year == visibleYear ? .on : .off) { [weak self] _ in
        self?.visibleYear = year
        self?.renderCalendar()
      }
    }
    let monthActions = (1...12).map { month in
      UIAction(title: "\(month)月", state: month == visibleMonth ? .on : .off) { [weak self] _ in
        self?.visibleMonth = month
        self?.renderCalendar()
      }
    }
    let years = UIMenu(title: "年", options: [.displayInline, .singleSelection], children: yearActions)
    let months = UIMenu(title: "月", options: [.displayInline, .singleSelection], children: monthActions)
    return UIMenu(title: "年月を選択", children: [years, months])
  }

  @objc private func previousMonthTapped() {
    adjustVisibleMonth(by: -1)
  }

  @objc private func nextMonthTapped() {
    adjustVisibleMonth(by: 1)
  }

  private func adjustVisibleMonth(by offset: Int) {
    if offset < 0 && visibleYear == 1 && visibleMonth == 1 { return }
    if offset > 0 && visibleYear == 9999 && visibleMonth == 12 { return }
    guard let date = calendar.date(from: DateComponents(year: visibleYear, month: visibleMonth, day: 1)),
          let next = calendar.date(byAdding: .month, value: offset, to: date) else { return }
    let components = calendar.dateComponents([.year, .month], from: next)
    visibleYear = components.year ?? visibleYear
    visibleMonth = components.month ?? visibleMonth
    renderCalendar()
  }

  @objc private func dayTapped(_ sender: UIButton) {
    let firstDay = calendar.date(from: DateComponents(year: visibleYear, month: visibleMonth, day: 1))
    let firstWeekday = firstDay.map { calendar.component(.weekday, from: $0) } ?? 2
    let offset = (firstWeekday - calendar.firstWeekday + 7) % 7
    let day = sender.tag - offset + 1
    guard day >= 1, let selected = calendar.date(from: DateComponents(year: visibleYear, month: visibleMonth, day: day)) else { return }
    draftDate = selected
    renderCalendar()
  }

  @objc private func backgroundTapped() {
    dismiss(animated: true)
  }

  @objc private func cancelTapped() {
    dismiss(animated: true)
  }

  @objc private func clearTapped() {
    onCommit("")
    dismiss(animated: true)
  }

  @objc private func selectTapped() {
    onCommit(kind == .date ? dateValue() : timeValue())
    dismiss(animated: true)
  }

  private func dateValue() -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: draftDate)
    return String(format: "%04d/%02d/%02d", components.year ?? visibleYear, components.month ?? visibleMonth, components.day ?? 1)
  }

  private func timeValue() -> String {
    String(format: "%02d:%02d", draftHour, draftMinute)
  }

  private static func initialDate(for kind: Kind, value: String, calendar: Calendar, now: Date) -> Date {
    switch kind {
    case .date:
      let normalized = value.replacingOccurrences(of: "/", with: "-")
      guard let canonical = NeoDateInput.parse(normalized) else { return now }
      let parts = canonical.split(separator: "-").compactMap { Int($0) }
      guard parts.count == 3,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return now }
      return date
    case .time:
      guard let parsed = NeoProgramSearchTime.parse(value) else { return now }
      let current = calendar.dateComponents([.year, .month, .day], from: now)
      return calendar.date(from: DateComponents(year: current.year, month: current.month, day: current.day, hour: parsed.hour, minute: parsed.minute)) ?? now
    }
  }
}

extension NeoProgramSearchPickerController: UIPickerViewDataSource, UIPickerViewDelegate {
  func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }

  func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
    component == 0 ? 24 : 60
  }

  func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { 44 }

  func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
    let label = (view as? UILabel) ?? UILabel()
    label.text = String(format: "%02d", row)
    label.textColor = .white
    label.font = .systemFont(ofSize: 20)
    label.textAlignment = .center
    label.accessibilityLabel = component == 0 ? "\(row)時" : "\(row)分"
    return label
  }

  func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
    if component == 0 {
      draftHour = row
    } else {
      draftMinute = row
    }
    renderTime()
  }
}
