import UIKit

final class NeoProgramSearchPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private struct Context: Equatable {
    let revision: Int, viewer: String, halfWidth: Bool, limit: Int
    init(_ api: NeoAPI) {
      revision = api.identityRevision; viewer = api.viewer; halfWidth = api.isHalfWidthDisplayed; limit = api.programSearchLimit
    }
  }
  private enum Failure { case setup, search, reservations }
  private enum Stage {
    case loadingSetup, form, searching, loadingReservations, results
    case failed(Failure, String)
  }

  private let list = UITableView(frame: .zero, style: .plain)
  private let headerStack = UIStackView(), noticeStack = UIStackView(), resultCount = NeoStyle.label(size: 14, muted: true)
  private let footer = UIView()
  private var formView: NeoProgramSearchFormView?
  private var form = NeoProgramSearchForm(), autoSearch: Bool, focusOnArrival: Bool
  private var context: Context?
  private weak var apiForContext: NeoAPI?
  private var task: Task<Void, Never>?, namesTask: Task<Void, Never>?
  private var queryGeneration = 0, stage: Stage = .loadingSetup
  private var channelsByID: [Int: NeoLiveChannel] = [:], availableTypes: [String] = []
  private var ready = false, appearing = false, appeared = false, headerMeasurementPending = false
  private var lastListSize: CGSize = .zero
  private var refreshPreferences = false, refreshOnReturn = false
  private var submitted: NeoProgramSearchOption?
  private var programs: [NeoScheduledProgram] = [], reservations: [Int: NeoProgramReserveStatus] = [:]
  private var lastOpened: Int?, shouldScrollToResults = false
  private var viewerNames: [Int: String]?
  private weak var detail: NeoProgramDetailDialog?
  private var insets: CGFloat { max(0, (list.bounds.width - 980) / 2) + (list.bounds.width >= 900 ? 24 : 12) }
  private var hasResults: Bool { if case .results = stage { return true }; return false }

  init(shell: NeoShell, relatedForm: NeoProgramSearchForm? = nil) {
    autoSearch = relatedForm != nil; focusOnArrival = relatedForm == nil
    if let relatedForm { form = relatedForm }
    super.init(title: "検索", shell: shell)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    list.backgroundColor = NeoStyle.background
    list.separatorStyle = .none; list.sectionHeaderTopPadding = 0
    list.rowHeight = UITableView.automaticDimension; list.estimatedRowHeight = 120
    list.contentInsetAdjustmentBehavior = .never; list.keyboardDismissMode = .onDrag
    list.cellLayoutMarginsFollowReadableWidth = false
    list.dataSource = self; list.delegate = self
    list.accessibilityIdentifier = "programSearch.list"
    list.register(NeoProgramSearchCell.self, forCellReuseIdentifier: "program")
    body.addSubview(list); list.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: body.topAnchor), list.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      list.bottomAnchor.constraint(equalTo: body.keyboardLayoutGuide.topAnchor),
    ])
    headerStack.axis = .vertical; headerStack.spacing = 24; headerStack.isLayoutMarginsRelativeArrangement = true
    headerStack.insetsLayoutMarginsFromSafeArea = false
    noticeStack.axis = .vertical
    resultCount.textAlignment = .right; resultCount.accessibilityIdentifier = "programSearch.count"
    headerStack.addArrangedSubview(noticeStack); headerStack.addArrangedSubview(resultCount)
    let clear = Self.clearButton { [weak self] in self?.clear(resetFocus: false) }
    footer.addSubview(clear); clear.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      clear.topAnchor.constraint(equalTo: footer.topAnchor, constant: 6),
      clear.trailingAnchor.constraint(equalTo: footer.layoutMarginsGuide.trailingAnchor),
      clear.heightAnchor.constraint(equalToConstant: 36),
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(accountChanged(_:)), name: .neoAccountChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(accountChanged(_:)), name: .neoTextPreferencesChanged, object: nil)
    render()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); appearing = true; synchronize() }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated); appeared = true; synchronize(); focusIfNeeded()
    if refreshOnReturn { refreshOnReturn = false; refreshRetainedResults() }
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated); appearing = false; appeared = false
    formView?.dismissDropdown()
    view.endEditing(true)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); measureHeader(); focusIfNeeded()
    let resized = lastListSize != list.bounds.size
    lastListSize = list.bounds.size
    formView?.layoutDropdown(in: list, keepStationVisible: resized)
  }
  deinit { task?.cancel(); namesTask?.cancel() }

  func resetForNavigation() {
    autoSearch = false
    if isViewLoaded { clear(resetFocus: true) }
    else { form = .init(); focusOnArrival = true }
  }
  @objc private func accountChanged(_ note: Notification) {
    guard (note.object as? NeoAPI) === shell?.api else { return }
    synchronize()
  }

  private func synchronize() {
    guard let api = shell?.api else { return }
    let current = Context(api)
    let changedIdentity = apiForContext !== api || context?.revision != current.revision || context?.viewer != current.viewer
    if changedIdentity {
      let hadContext = context != nil
      cancelWork(); context = current; apiForContext = api
      detail?.dismiss(animated: false); detail = nil; viewerNames = nil
      ready = false; refreshPreferences = false; refreshOnReturn = false; channelsByID = [:]; availableTypes = []
      formView?.dismissDropdown()
      formView?.removeFromSuperview(); formView = nil
      submitted = nil; programs = []; reservations = [:]; lastOpened = nil
      if hadContext { form = .init(); autoSearch = false; shouldScrollToResults = false }
      stage = .loadingSetup; render()
    } else if context != current {
      cancelWork(); context = current
      refreshPreferences = ready && submitted != nil
      if ready { stage = .form; render() }
    }
    guard appearing, api.accountReady, task == nil else { return }
    if ready {
      if refreshPreferences, let submitted { refreshPreferences = false; run(submitted, scroll: false) }
      else if case .loadingReservations = stage { loadReservations() }
      return
    }
    if case .failed(.setup, _) = stage { return }
    loadSetup()
  }

  private func cancelWork() { queryGeneration += 1; task?.cancel(); task = nil; namesTask?.cancel(); namesTask = nil }
  private func accepts(_ api: NeoAPI, _ context: Context, _ generation: Int) -> Bool {
    !Task.isCancelled && shell?.api === api && self.context == context && queryGeneration == generation
      && api.identityRevision == context.revision && api.viewer == context.viewer
  }

  private func loadSetup() {
    guard let api = shell?.api, let context, api.accountReady else { return }
    cancelWork()
    let generation = queryGeneration, headers = api.profileHeaders
    stage = .loadingSetup; render()
    task = Task { [weak self] in
      do {
        async let roster = api.programSearchChannels(user: context.viewer, headers: headers)
        async let configuration: NeoServerConfig = api.request(api.url("/config"), user: context.viewer, headers: headers)
        let (channels, config) = try await (roster, configuration)
        guard let self, accepts(api, context, generation) else { return }
        task = nil
        channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        availableTypes = channels.map(\.channelType).filter { config.broadcast?[$0] != false && seen.insert($0).inserted }
        if form.channelIDs.isEmpty { form.channelTypes = availableTypes }
        ready = true
        let fields = NeoProgramSearchFormView(form: form, channels: channels, availableTypes: availableTypes, presenter: self, dropdownHost: body,
          onChange: { [weak self] in self?.form = $0 },
          onClear: { [weak self] in self?.clear(resetFocus: false) },
          onSearch: { [weak self] in self?.submit() })
        fields.onLayoutChange = { [weak self] in self?.scheduleHeaderMeasurement() }
        formView = fields; headerStack.insertArrangedSubview(fields, at: 0)
        stage = .form; render()
        if autoSearch, !form.channelIDs.isEmpty || !form.channelTypes.isEmpty {
          autoSearch = false; submit()
        } else { focusIfNeeded() }
      } catch {
        guard let self, accepts(api, context, generation) else { return }
        task = nil; stage = .failed(.setup, error.localizedDescription); render()
      }
    }
  }

  private func focusIfNeeded() {
    guard focusOnArrival, appeared, let formView, formView.window != nil, navigationController?.topViewController === self else { return }
    focusOnArrival = false
    formView.focusKeyword()
  }

  private func clear(resetFocus: Bool) {
    if ready { cancelWork() }
    autoSearch = false; focusOnArrival = resetFocus
    form = .init(); form.channelTypes = availableTypes
    formView?.update(form)
    submitted = nil; programs = []; reservations = [:]; lastOpened = nil; shouldScrollToResults = false
    refreshPreferences = false; refreshOnReturn = false
    if ready { stage = .form }
    view.endEditing(true); render()
    if resetFocus {
      list.setContentOffset(.zero, animated: false)
      DispatchQueue.main.async { [weak self] in self?.focusIfNeeded() }
    }
  }

  private func submit() {
    guard ready, shell?.api?.accountReady == true else { return }
    if case .searching = stage { return }
    formView?.dismissDropdown()
    do {
      let prepared = try form.prepared()
      if prepared.form != form { form = prepared.form; formView?.update(form) }
      view.endEditing(true)
      run(prepared.option, scroll: true)
    } catch { alert(error.localizedDescription) }
  }

  private func run(_ option: NeoProgramSearchOption, scroll: Bool) {
    guard let api = shell?.api, let context, api.accountReady else { return }
    cancelWork(); submitted = option; shouldScrollToResults = scroll
    programs = []; reservations = [:]; lastOpened = nil
    stage = .searching; render()
    let generation = queryGeneration, headers = api.profileHeaders
    task = Task { [weak self] in
      do {
        let items = try await api.searchPrograms(option, halfWidth: context.halfWidth, limit: context.limit, user: context.viewer, headers: headers)
        guard let self, accepts(api, context, generation) else { return }
        task = nil; programs = items; loadReservations()
      } catch {
        guard let self, accepts(api, context, generation) else { return }
        task = nil; stage = .failed(.search, error.localizedDescription); render()
      }
    }
  }

  private func loadReservations() {
    guard let api = shell?.api, let context else { return }
    guard let start = programs.map(\.startAt).min(), let end = programs.map(\.endAt).max() else { showResults(); return }
    stage = .loadingReservations; render()
    guard api.accountReady else { return }
    cancelWork()
    let generation = queryGeneration, headers = api.profileHeaders
    task = Task { [weak self] in
      do {
        let lists = try await api.programReservationLists(startAt: start, endAt: end, user: context.viewer, headers: headers)
        guard let self, accepts(api, context, generation) else { return }
        task = nil; reservations = lists.index; showResults()
      } catch {
        guard let self, accepts(api, context, generation) else { return }
        task = nil; stage = .failed(.reservations, error.localizedDescription); render()
      }
    }
  }

  private func showResults() {
    stage = .results; render()
    guard shouldScrollToResults else { return }
    shouldScrollToResults = false
    DispatchQueue.main.async { [weak self] in
      guard let self, hasResults else { return }
      view.layoutIfNeeded(); list.layoutIfNeeded()
      let y = resultCount.convert(CGPoint.zero, to: list).y - 16
      let bottom = max(0, list.contentSize.height - list.bounds.height)
      list.setContentOffset(CGPoint(x: 0, y: min(bottom, max(0, y))), animated: !UIAccessibility.isReduceMotionEnabled)
    }
  }

  // After back from a related search, keep the restored page visible while
  // rechecking the submitted conditions and reservation statuses.
  private func refreshRetainedResults() {
    guard hasResults, task == nil, let api = shell?.api, api.accountReady, let context, let submitted else { return }
    let generation = queryGeneration, headers = api.profileHeaders
    task = Task { [weak self] in
      do {
        let items = try await api.searchPrograms(submitted, halfWidth: context.halfWidth, limit: context.limit, user: context.viewer, headers: headers)
        let states: [Int: NeoProgramReserveStatus]
        if let start = items.map(\.startAt).min(), let end = items.map(\.endAt).max() {
          try Task.checkCancellation()
          let lists = try await api.programReservationLists(startAt: start, endAt: end, user: context.viewer, headers: headers)
          states = lists.index
        } else { states = [:] }
        guard let self, accepts(api, context, generation) else { return }
        task = nil
        guard items != programs || states != reservations else { return }
        let offset = list.contentOffset
        programs = items; reservations = states; render()
        list.layoutIfNeeded()
        let maxY = max(0, list.contentSize.height - list.bounds.height)
        list.setContentOffset(CGPoint(x: 0, y: min(offset.y, maxY)), animated: false)
      } catch {
        guard let self, accepts(api, context, generation) else { return }
        task = nil
      }
    }
  }

  private func retry(_ failure: Failure) {
    switch failure {
    case .setup: loadSetup()
    case .search: if let submitted { run(submitted, scroll: shouldScrollToResults) }
    case .reservations: loadReservations()
    }
  }

  private func render() {
    noticeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    switch stage {
    case .loadingSetup, .searching, .loadingReservations:
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.color = NeoStyle.accent; spinner.startAnimating()
      spinner.accessibilityLabel = "読み込み中"
      spinner.heightAnchor.constraint(equalToConstant: 48).isActive = true
      noticeStack.addArrangedSubview(spinner)
    case let .failed(failure, detail):
      let prefix: String
      switch failure {
      case .setup: prefix = "検索に必要な情報の取得に失敗しました"
      case .search: prefix = "検索に失敗しました"
      case .reservations: prefix = "予約情報の取得に失敗しました"
      }
      noticeStack.addArrangedSubview(failureView(message: "\(prefix): \(detail)", retry: { [weak self] in self?.retry(failure) }))
    case .form, .results: break
    }
    noticeStack.isHidden = noticeStack.arrangedSubviews.isEmpty
    if case .searching = stage { formView?.searchEnabled = false }
    else { formView?.searchEnabled = true }
    resultCount.isHidden = !hasResults
    resultCount.text = "\(programs.count)件ヒット"
    updateFooter()
    list.reloadData(); measureHeader()
  }

  private func failureView(message: String, retry: @escaping () -> Void) -> UIView {
    let stack = UIStackView(); stack.axis = .vertical; stack.alignment = .trailing; stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
    stack.layer.borderWidth = 1; stack.layer.borderColor = NeoProgramSearchCell.errorColor.cgColor; stack.layer.cornerRadius = 6
    let text = NeoStyle.label(message); text.textColor = UIColor(red: 1, green: 0.73, blue: 0.73, alpha: 1)
    text.numberOfLines = 0; text.lineBreakMode = .byCharWrapping
    stack.addArrangedSubview(text); text.widthAnchor.constraint(equalTo: stack.layoutMarginsGuide.widthAnchor).isActive = true
    let button = NeoStyle.button("再試行", action: retry); button.tintColor = text.textColor
    button.heightAnchor.constraint(equalToConstant: 36).isActive = true; stack.addArrangedSubview(button)
    return stack
  }

  private func scheduleHeaderMeasurement() {
    guard !headerMeasurementPending else { return }
    headerMeasurementPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }; headerMeasurementPending = false; measureHeader()
    }
  }
  private func measureHeader() {
    let width = list.bounds.width
    guard width > 0 else { return }
    let padding = width >= 900 ? 24.0 : 12.0
    headerStack.layoutMargins = UIEdgeInsets(top: padding, left: insets, bottom: hasResults ? 12 : padding, right: insets)
    formView?.prepareLayout(width: max(0, width - 2 * insets), viewportWidth: width)
    let size = headerStack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    let frame = CGRect(origin: .zero, size: CGSize(width: width, height: ceil(size.height)))
    if headerStack.frame.size != frame.size || list.tableHeaderView !== headerStack {
      headerStack.frame = frame; list.tableHeaderView = headerStack
    }
    updateFooter()
  }
  private func updateFooter() {
    guard hasResults, list.bounds.width > 0 else { if list.tableFooterView != nil { list.tableFooterView = nil }; return }
    footer.layoutMargins = UIEdgeInsets(top: 0, left: insets, bottom: 0, right: insets)
    let size = CGSize(width: list.bounds.width, height: 54)
    if list.tableFooterView !== footer || footer.frame.size != size {
      footer.frame = CGRect(origin: .zero, size: size); list.tableFooterView = footer
    }
  }
  private static func clearButton(_ action: @escaping () -> Void) -> UIButton {
    let b = NeoStyle.recordingButton("クリア", icon: "Close", action: action)
    var configuration = b.configuration!; configuration.baseForegroundColor = NeoStyle.accent
    configuration.baseBackgroundColor = .clear; b.configuration = configuration
    return b
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    hasResults ? max(1, programs.count) : 0
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    formView?.layoutDropdown(in: scrollView)
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard !programs.isEmpty else {
      let cell = UITableViewCell(); cell.backgroundColor = .clear; cell.selectionStyle = .none
      var content = cell.defaultContentConfiguration(); content.text = "条件に一致する番組はありません"
      content.textProperties.color = NeoStyle.muted; content.textProperties.font = .systemFont(ofSize: 16)
      content.textProperties.alignment = .center; content.directionalLayoutMargins = .init(top: 40, leading: 12, bottom: 40, trailing: 12)
      cell.contentConfiguration = content; return cell
    }
    let cell = tableView.dequeueReusableCell(withIdentifier: "program", for: indexPath) as! NeoProgramSearchCell
    let program = programs[indexPath.row]
    cell.fill(program, channel: channelsByID[program.channelId]?.name ?? String(program.channelId),
      status: reservations[program.id], selected: lastOpened == program.id, inset: insets)
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    guard programs.indices.contains(indexPath.row), let api = shell?.api, api.accountReady, presentedViewController == nil else { return }
    let program = programs[indexPath.row], status = reservations[program.id], prior = lastOpened
    lastOpened = program.id
    if prior != lastOpened {
      let paths = tableView.indexPathsForVisibleRows?.filter { programs[$0.row].id == prior || $0 == indexPath } ?? [indexPath]
      tableView.reloadRows(at: paths, with: .none)
    }
    let channel = channelsByID[program.channelId], owner = Context(api)
    let bookingUserName = Int(api.viewer).flatMap { viewerID -> String? in
      guard viewerID > 0 else { return nil }
      return viewerNames?[viewerID] ?? shell?.account?.currentName
    }
    let dialog = NeoProgramDetailDialog(program: program, channel: channel,
      logoURL: channel?.hasLogoData == true ? api.url("/channels/\(program.channelId)/logo") : nil,
      reservationLabel: status?.label(inResult: false), reservationConflict: status?.primary == .conflict,
      reservationUsers: reservationLabels(status, waiting: viewerNames == nil),
      alwaysShowBroadcastDetails: api.alwaysShowProgramBroadcastDetails,
      bookingUserName: bookingUserName) { [weak self] in
        guard let self, let shell, shell.api === api, api.accountReady, Context(api) == owner,
              navigationController?.topViewController === self else { return }
        let related = NeoProgramSearchForm.related(to: program, includeChannel: api.programRelatedIncludesChannel,
          includeGenre: api.programRelatedIncludesGenre)
      refreshOnReturn = true
      shell.pushPage { NeoProgramSearchPage(shell: shell, relatedForm: related) }
      }
    detail = dialog
    formView?.dismissDropdown()
    view.endEditing(true)
    present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
    guard let status, viewerNames == nil, let context else { return }
    namesTask?.cancel()
    let generation = queryGeneration
    namesTask = Task { [weak self, weak dialog] in
      let values = try? await api.viewers()
      guard let self, accepts(api, context, generation) else { return }
      if let values { viewerNames = Dictionary(values.users.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }
      if detail === dialog { dialog?.updateReservationUsers(reservationLabels(status, waiting: false, failed: values == nil)) }
      namesTask = nil
    }
  }

  private func reservationLabels(_ status: NeoProgramReserveStatus?, waiting: Bool, failed: Bool = false) -> [String] {
    status?.entries.map { entry in
      let user: String
      if waiting { user = "ユーザー読込中…" }
      else if failed { user = "予約ユーザー取得失敗" }
      else if let id = entry.item.userId { user = viewerNames?[id] ?? "ユーザーID: \(id)" }
      else { user = "ユーザー未指定" }
      return "\(user)・\(entry.kind.label)"
    } ?? []
  }
}

private final class NeoProgramSearchCell: UITableViewCell {
  static let errorColor = UIColor(red: 1, green: 82 / 255, blue: 82 / 255, alpha: 1)
  private static func formatter(_ format: String) -> DateFormatter {
    let value = DateFormatter(); value.locale = Locale(identifier: "ja_JP"); value.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
    value.dateFormat = format; return value
  }
  private static let date = formatter("yyyy/MM/dd(EEE) HH:mm"), time = formatter("HH:mm")
  private let card = UIView(), outline = CAShapeLayer()
  private let name = NeoStyle.label(size: 16, bold: true), channel = NeoStyle.label(size: 14, muted: true)
  private let time = NeoStyle.label(size: 12, muted: true), summary = NeoStyle.label(size: 14)
  private let chip = UILabel(), chipWrap = UIView()
  private var start: NSLayoutConstraint!, end: NSLayoutConstraint!
  private var chipWidth: NSLayoutConstraint!
  private var dashed = false

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear; selectionStyle = .none
    card.backgroundColor = NeoStyle.paper; card.layer.cornerRadius = 6
    card.layer.addSublayer(outline); outline.fillColor = UIColor.clear.cgColor
    contentView.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
    start = card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
    end = card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 1
    let titleRow = UIStackView(arrangedSubviews: [name, chipWrap]); titleRow.alignment = .center; titleRow.spacing = 8
    name.font = .systemFont(ofSize: 16, weight: .bold)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    [name, channel, time, summary].forEach { $0.numberOfLines = 0; $0.lineBreakMode = .byCharWrapping }
    [titleRow, channel, time, summary].forEach(stack.addArrangedSubview)
    stack.setCustomSpacing(4, after: time)
    chipWrap.layer.cornerRadius = 12; chipWrap.clipsToBounds = true
    chipWrap.accessibilityIdentifier = "programSearch.statusChip"
    chip.font = .systemFont(ofSize: 13); chip.textColor = NeoStyle.successText
    chipWrap.addSubview(chip); chip.translatesAutoresizingMaskIntoConstraints = false
    chip.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    chipWidth = chipWrap.widthAnchor.constraint(equalToConstant: 0)
    chipWidth.priority = UILayoutPriority(999); chipWidth.isActive = true
    card.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      start, end, card.topAnchor.constraint(equalTo: contentView.topAnchor),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      chip.leadingAnchor.constraint(equalTo: chipWrap.leadingAnchor, constant: 8),
      chip.trailingAnchor.constraint(equalTo: chipWrap.trailingAnchor, constant: -8),
      chip.centerYAnchor.constraint(equalTo: chipWrap.centerYAnchor),
      chipWrap.heightAnchor.constraint(equalToConstant: 24), chipWrap.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, multiplier: 0.57),
    ])
    accessibilityTraits.insert(.button)
  }
  required init?(coder: NSCoder) { fatalError() }

  func fill(_ program: NeoScheduledProgram, channel station: String, status: NeoProgramReserveStatus?, selected: Bool, inset: CGFloat) {
    start.constant = inset; end.constant = -inset
    name.text = program.name; channel.text = station
    let start = Self.date.string(from: Date(timeIntervalSince1970: program.startAt / 1000))
    let finish = Self.time.string(from: Date(timeIntervalSince1970: program.endAt / 1000))
    time.text = "\(start) - \(finish)（\(program.durationMinutes)分）"
    summary.text = program.description; summary.isHidden = program.description?.isEmpty != false
    chip.text = status?.label(inResult: true); chipWrap.isHidden = status == nil
    chipWidth.constant = status == nil ? 0 : ceil(chip.intrinsicContentSize.width) + 16
    let conflict = status?.primary == .conflict, scheduled = status?.primary == .normal || conflict
    chipWrap.backgroundColor = conflict ? Self.errorColor : NeoStyle.accent
    outline.strokeColor = (scheduled ? Self.errorColor : (status != nil || selected ? NeoStyle.accent : NeoStyle.border)).cgColor
    outline.lineWidth = scheduled ? 4 : 1
    dashed = conflict; setNeedsLayout()
    accessibilityLabel = [name.text, chip.text, channel.text, time.text, summary.text].compactMap { $0 }.joined(separator: "、")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    outline.frame = card.bounds
    let inset = outline.lineWidth / 2
    outline.path = UIBezierPath(roundedRect: card.bounds.insetBy(dx: inset, dy: inset), cornerRadius: 6 - inset).cgPath
    outline.lineDashPattern = dashed ? [7, 4] : nil
    CATransaction.commit()
  }
}
