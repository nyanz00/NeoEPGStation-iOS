import UIKit

final class NeoProgramSearchPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private struct Context: Equatable {
    let revision: Int, viewer: String, halfWidth: Bool, limit: Int
    init(_ api: NeoAPI) {
      revision = api.identityRevision; viewer = api.viewer; halfWidth = api.isHalfWidthDisplayed; limit = api.programSearchLimit
    }
  }
  private enum Failure { case account, setup, rule, search, reservations, timeReservations }
  private enum Stage {
    case loadingSetup, form, searching, loadingReservations, loadingTimeReservations, results
    case failed(Failure, String)
  }

  private let list = UITableView(frame: .zero, style: .plain)
  private let headerStack = UIStackView(), noticeStack = UIStackView(), resultCount = NeoStyle.label(size: 14, muted: true)
  private let footer = UIView()
  private let ruleID: Int?
  private let ruleOrigin: Context?
  private weak var ruleOriginAPI: NeoAPI?
  private var loadedRule: NeoProgramRule?
  private var configuration: NeoServerConfig?
  private var channelRoster: [NeoLiveChannel] = []
  private var timeRuleSummary: UIView?
  private var timeReservationCount = 0
  private var editorTask: Task<Void, Never>?
  private var editorGeneration = 0
  private weak var ruleEditor: NeoProgramRuleEditor?
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
  private var isTimeRule: Bool { loadedRule?.isTimeSpecification == true }
  private var ruleActionTitle: String { ruleID == nil ? "ルール作成" : "ルール設定" }
  private lazy var footerRule = NeoProgramRuleButton.make(ruleActionTitle, filled: true, identifier: "programSearch.rule.bottom") { [weak self] in
    self?.openRuleEditor()
  }
  private lazy var floatingRule = NeoProgramRuleButton.make(ruleActionTitle, filled: true, identifier: "programSearch.rule.floating") { [weak self] in
    self?.openRuleEditor()
  }
  private lazy var timeRuleAction = NeoProgramRuleButton.make("ルール設定", filled: false,
    identifier: "programSearch.timeRule.settings", icon: "EditOutlined") { [weak self] in self?.openRuleEditor() }
  private var insets: CGFloat { max(0, (list.bounds.width - 980) / 2) + (list.bounds.width >= 900 ? 24 : 12) }
  private var hasResults: Bool { if case .results = stage { return true }; return false }

  init(shell: NeoShell, relatedForm: NeoProgramSearchForm? = nil, ruleID: Int? = nil) {
    self.ruleID = ruleID
    ruleOrigin = ruleID == nil ? nil : shell.api.map(Context.init)
    ruleOriginAPI = ruleID == nil ? nil : shell.api
    autoSearch = relatedForm != nil; focusOnArrival = relatedForm == nil
    if ruleID != nil { focusOnArrival = false }
    if let relatedForm { form = relatedForm }
    super.init(title: ruleID == nil ? "検索" : "ルール編集", shell: shell)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func width(forHeaderAction action: UIView) -> CGFloat {
    action === timeRuleAction ? 118 : super.width(forHeaderAction: action)
  }

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
    let footerActions = UIStackView(arrangedSubviews: [clear, footerRule])
    footerActions.spacing = 8; footerActions.translatesAutoresizingMaskIntoConstraints = false
    footer.addSubview(footerActions)
    floatingRule.isHidden = true
    body.addSubview(floatingRule); floatingRule.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      footerActions.topAnchor.constraint(equalTo: footer.topAnchor, constant: 6),
      footerActions.trailingAnchor.constraint(equalTo: footer.layoutMarginsGuide.trailingAnchor),
      footerActions.heightAnchor.constraint(equalToConstant: 40),
      floatingRule.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
      floatingRule.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -16),
      floatingRule.heightAnchor.constraint(equalToConstant: 42),
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(accountChanged(_:)), name: .neoAccountChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(accountChanged(_:)), name: .neoTextPreferencesChanged, object: nil)
    render()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); appearing = true; synchronize() }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated); appeared = true; synchronize(); focusIfNeeded()
    if refreshOnReturn {
      refreshOnReturn = false
      if isTimeRule { loadTimeReservations() }
      else { refreshRetainedResults() }
    }
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated); appearing = false; appeared = false
    formView?.dismissDropdown()
    view.endEditing(true)
    if ruleEditor == nil, editorTask != nil { cancelRuleEditor() }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); measureHeader(); focusIfNeeded()
    let resized = lastListSize != list.bounds.size
    lastListSize = list.bounds.size
    formView?.layoutDropdown(in: list, keepStationVisible: resized)
    refreshFloatingRule()
  }
  deinit { task?.cancel(); namesTask?.cancel(); editorTask?.cancel() }

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
      cancelRuleEditor()
      detail?.dismiss(animated: false); detail = nil; viewerNames = nil
      ready = false; refreshPreferences = false; refreshOnReturn = false; channelsByID = [:]; availableTypes = []
      channelRoster = []; configuration = nil; loadedRule = nil; timeReservationCount = 0
      timeRuleSummary?.removeFromSuperview(); timeRuleSummary = nil; actions = []
      formView?.dismissDropdown()
      formView?.removeFromSuperview(); formView = nil
      submitted = nil; programs = []; reservations = [:]; lastOpened = nil
      if hadContext { form = .init(); autoSearch = false; shouldScrollToResults = false }
      stage = .loadingSetup; render()
    } else if context != current {
      cancelWork(); context = current
      refreshPreferences = ready && (submitted != nil || isTimeRule)
      if ready { stage = .form; render() }
    }
    if ruleID != nil, ruleOriginAPI !== api || ruleOrigin?.revision != current.revision || ruleOrigin?.viewer != current.viewer {
      stage = .failed(.account, "元の画面からルールを開き直してください。")
      render()
      return
    }
    guard appearing, api.accountReady, task == nil else { return }
    if ready {
      if refreshPreferences {
        refreshPreferences = false
        if isTimeRule { loadTimeReservations() }
        else if let submitted { run(submitted, scroll: false) }
      }
      else if case .loadingReservations = stage { loadReservations() }
      else if case .loadingTimeReservations = stage { loadTimeReservations() }
      return
    }
    if case .failed(.setup, _) = stage { return }
    if case .failed(.rule, _) = stage { return }
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
    let generation = queryGeneration, headers = api.profileHeaders, ruleID = self.ruleID
    stage = .loadingSetup; render()
    task = Task { [weak self] in
      do {
        async let roster = api.programSearchChannels(user: context.viewer, headers: headers)
        async let configuration: NeoServerConfig = api.request(api.url("/config"), user: context.viewer, headers: headers)
        let rule: NeoProgramRule?
        if let ruleID {
          do { rule = try await api.programRule(ruleID, user: context.viewer, headers: headers) }
          catch {
            guard let self, accepts(api, context, generation) else { return }
            task = nil; stage = .failed(.rule, error.localizedDescription); render()
            return
          }
        } else { rule = nil }
        let (channels, config) = try await (roster, configuration)
        guard let self, accepts(api, context, generation) else { return }
        task = nil
        channelRoster = channels
        self.configuration = config
        loadedRule = rule
        channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        availableTypes = channels.map(\.channelType).filter { config.broadcast?[$0] != false && seen.insert($0).inserted }
        if let rule { form = NeoProgramSearchForm(restoring: rule.searchOption) }
        else if form.channelIDs.isEmpty { form.channelTypes = availableTypes }
        ready = true
        if let rule, rule.isTimeSpecification {
          showTimeRule(rule)
          loadTimeReservations()
          return
        }
        let fields = NeoProgramSearchFormView(form: form, channels: channels, availableTypes: availableTypes, presenter: self, dropdownHost: body,
          ruleActionTitle: ruleActionTitle,
          onChange: { [weak self] in self?.form = $0 },
          onClear: { [weak self] in self?.clear(resetFocus: false) },
          onSearch: { [weak self] in self?.submit() },
          onRuleAction: { [weak self] in self?.openRuleEditor() })
        fields.onLayoutChange = { [weak self] in self?.scheduleHeaderMeasurement() }
        formView = fields; headerStack.insertArrangedSubview(fields, at: 0)
        stage = .form; render()
        if let rule {
          run(rule.searchOption, scroll: true)
        } else if autoSearch, !form.channelIDs.isEmpty || !form.channelTypes.isEmpty {
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
      let option: NeoProgramSearchOption
      if let loadedRule { option = try form.ruleOption(preserving: loadedRule.searchOption) }
      else {
        let prepared = try form.prepared()
        if prepared.form != form { form = prepared.form; formView?.update(form) }
        option = prepared.option
      }
      view.endEditing(true)
      run(option, scroll: true)
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

  private func showTimeRule(_ rule: NeoProgramRule) {
    let name = NeoStyle.label(rule.searchOption.keyword ?? "番組名未指定", size: 20, bold: true)
    name.numberOfLines = 0
    let station = rule.searchOption.channelIds?.first.map { channelsByID[$0]?.name ?? String($0) } ?? "放送局未指定"
    let schedule = NeoStyle.label("\(station) ・ \(rule.scheduleLabel)", size: 14, muted: true)
    schedule.numberOfLines = 0
    let card = UIStackView(arrangedSubviews: [NeoStyle.label("時刻指定ルール", size: 12, muted: true), name, schedule])
    card.axis = .vertical; card.spacing = 8
    card.isLayoutMarginsRelativeArrangement = true
    card.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    card.backgroundColor = NeoStyle.paper
    card.layer.borderWidth = 1; card.layer.borderColor = NeoStyle.border.cgColor; card.layer.cornerRadius = 6
    card.accessibilityIdentifier = "programSearch.timeRule.summary"
    timeRuleSummary = card
    headerStack.insertArrangedSubview(card, at: 0)
    actions = [timeRuleAction]
  }

  private func loadTimeReservations() {
    guard let ruleID, isTimeRule, let api = shell?.api, let context else { return }
    cancelWork()
    stage = .loadingTimeReservations; render()
    guard api.accountReady else { return }
    let generation = queryGeneration, headers = api.profileHeaders
    task = Task { [weak self] in
      do {
        let list = try await api.programRuleReservations(ruleID, halfWidth: context.halfWidth, user: context.viewer, headers: headers)
        guard let self, accepts(api, context, generation) else { return }
        task = nil
        var seen = Set<Int>()
        let rows = list.reserves.filter { seen.insert($0.id).inserted }
        programs = rows.map(\.displayProgram)
        reservations = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
        timeReservationCount = list.total
        stage = .results; render()
      } catch {
        guard let self, accepts(api, context, generation) else { return }
        task = nil; stage = .failed(.timeReservations, error.localizedDescription); render()
      }
    }
  }

  private func openRuleEditor() {
    guard ready, editorTask == nil, presentedViewController == nil, let config = configuration,
          let api = shell?.api, let owner = context, api.accountReady, ownsEditorAccount(api, owner) else { return }
    let existing = loadedRule
    let conditions: NeoProgramSearchOption
    do {
      if let existing, existing.isTimeSpecification { conditions = existing.searchOption }
      else { conditions = try form.ruleOption(preserving: existing?.searchOption) }
    } catch { alert(error.localizedDescription); return }

    formView?.dismissDropdown()
    view.endEditing(true)
    setRuleButtonsEnabled(false)
    let generation = editorGeneration, headers = api.profileHeaders
    editorTask = Task { [weak self] in
      do {
        let result: NeoViewers = try await api.request(api.url("/users"), user: owner.viewer, headers: headers)
        guard let self, !Task.isCancelled, editorGeneration == generation, ownsEditorAccount(api, owner) else { return }
        editorTask = nil; setRuleButtonsEnabled(true)
        guard appeared, view.window != nil, presentedViewController == nil, navigationController?.topViewController === self else { return }
        let viewer = Int(owner.viewer).flatMap { $0 > 0 ? $0 : nil }
        let draft = NeoProgramRuleDraft(rule: existing, activeUserID: viewer)
        let editor = NeoProgramRuleEditor(draft: draft, editing: existing != nil, users: result.users,
          channels: ruleEditorChannels(fallback: conditions.channelIds ?? []), encodeModes: config.encode, directories: config.recorded) { [weak self] draft in
          self?.saveRule(draft, conditions: conditions, existing: existing, api: api, owner: owner)
        }
        ruleEditor = editor
        present(editor, animated: !UIAccessibility.isReduceMotionEnabled)
      } catch {
        guard let self, !Task.isCancelled, editorGeneration == generation, ownsEditorAccount(api, owner) else { return }
        editorTask = nil; setRuleButtonsEnabled(true)
        if appeared { alert("ルール設定に必要なユーザー情報を取得できませんでした: \(error.localizedDescription)") }
      }
    }
  }

  private func ruleEditorChannels(fallback: [Int]) -> [NeoLiveChannel] {
    let preferred = programs.isEmpty ? fallback : programs.map(\.channelId)
    var seen = Set<Int>()
    return (preferred.compactMap { channelsByID[$0] } + channelRoster).filter { seen.insert($0.id).inserted }
  }

  private func saveRule(_ draft: NeoProgramRuleDraft, conditions: NeoProgramSearchOption, existing: NeoProgramRule?, api: NeoAPI, owner: Context) {
    guard editorTask == nil, let editor = ruleEditor, ownsEditorAccount(api, owner) else { return }
    guard api.accountReady else { editor.showSaveError("アクティブユーザーを確認中です。時間をおいて保存してください。"); return }
    let option: NeoProgramRuleWrite
    do { option = try draft.write(searchOption: conditions, existing: existing) }
    catch { editor.showSaveError(error.localizedDescription); return }
    editor.setSaving(true)
    let generation = editorGeneration, headers = api.profileHeaders
    editorTask = Task { [weak self, weak editor] in
      do {
        let warnings = try await api.saveProgramRule(option, replacing: existing?.id, user: owner.viewer, headers: headers)
        guard let self, let editor, !Task.isCancelled, editorGeneration == generation,
              ownsEditorAccount(api, owner), ruleEditor === editor else { return }
        editorTask = nil
        editor.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
          guard let self, let shell, ownsEditorAccount(api, owner), navigationController?.topViewController === self else { return }
          ruleEditor = nil
          guard viewIfLoaded?.window != nil else { return }
          let message = existing == nil ? "ルールを追加しました" : "ルールを更新しました"
          if !shell.returnAfterRuleSave(from: self) { clear(resetFocus: true) }
          if warnings.isEmpty { shell.recordingNotice(message) }
          else { shell.recordingNotice("\(message)。\(warnings.joined(separator: "。"))", error: true) }
        }
      } catch {
        guard let self, let editor, !Task.isCancelled, editorGeneration == generation,
              ownsEditorAccount(api, owner), ruleEditor === editor else { return }
        editorTask = nil
        editor.setSaving(false)
        editor.showSaveError("ルールの保存に失敗しました: \(error.localizedDescription)")
      }
    }
  }

  private func ownsEditorAccount(_ api: NeoAPI, _ owner: Context) -> Bool {
    shell?.api === api && apiForContext === api && api.identityRevision == owner.revision && api.viewer == owner.viewer
  }

  private func cancelRuleEditor() {
    editorGeneration += 1
    editorTask?.cancel(); editorTask = nil
    ruleEditor?.dismiss(animated: false); ruleEditor = nil
    setRuleButtonsEnabled(true)
  }

  private func setRuleButtonsEnabled(_ enabled: Bool) {
    formView?.ruleButton.isEnabled = enabled
    footerRule.isEnabled = enabled; floatingRule.isEnabled = enabled; timeRuleAction.isEnabled = enabled
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
    case .account: shell?.goBack()
    case .setup, .rule: loadSetup()
    case .search: if let submitted { run(submitted, scroll: shouldScrollToResults) }
    case .reservations: loadReservations()
    case .timeReservations: loadTimeReservations()
    }
  }

  private func render() {
    noticeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    switch stage {
    case .loadingSetup, .searching, .loadingReservations, .loadingTimeReservations:
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.color = NeoStyle.accent; spinner.startAnimating()
      spinner.accessibilityLabel = "読み込み中"
      spinner.heightAnchor.constraint(equalToConstant: 48).isActive = true
      noticeStack.addArrangedSubview(spinner)
    case let .failed(failure, detail):
      let prefix: String
      switch failure {
      case .account: prefix = "接続先またはアクティブユーザーが変わりました"
      case .setup: prefix = "検索に必要な情報の取得に失敗しました"
      case .rule: prefix = "ルールの取得に失敗しました"
      case .search: prefix = "検索に失敗しました"
      case .reservations: prefix = "予約情報の取得に失敗しました"
      case .timeReservations: prefix = "このルールの予約取得に失敗しました"
      }
      noticeStack.addArrangedSubview(failureView(message: "\(prefix): \(detail)", actionTitle: failure == .account ? "戻る" : "再試行",
        retry: { [weak self] in self?.retry(failure) }))
    case .form, .results: break
    }
    noticeStack.isHidden = noticeStack.arrangedSubviews.isEmpty
    if case .searching = stage { formView?.searchEnabled = false }
    else { formView?.searchEnabled = true }
    resultCount.isHidden = !hasResults
    resultCount.text = isTimeRule ? "予約数 \(timeReservationCount)件" : "\(programs.count)件ヒット"
    updateFooter()
    list.reloadData(); measureHeader()
    refreshFloatingRule()
  }

  private func failureView(message: String, actionTitle: String, retry: @escaping () -> Void) -> UIView {
    let stack = UIStackView(); stack.axis = .vertical; stack.alignment = .trailing; stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
    stack.layer.borderWidth = 1; stack.layer.borderColor = NeoProgramSearchCell.errorColor.cgColor; stack.layer.cornerRadius = 6
    let text = NeoStyle.label(message); text.textColor = UIColor(red: 1, green: 0.73, blue: 0.73, alpha: 1)
    text.numberOfLines = 0; text.lineBreakMode = .byCharWrapping
    stack.addArrangedSubview(text); text.widthAnchor.constraint(equalTo: stack.layoutMarginsGuide.widthAnchor).isActive = true
    let button = NeoStyle.button(actionTitle, action: retry); button.tintColor = text.textColor
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
    guard hasResults, !isTimeRule, list.bounds.width > 0 else {
      if list.tableFooterView != nil { list.tableFooterView = nil }
      return
    }
    footer.layoutMargins = UIEdgeInsets(top: 0, left: insets, bottom: 0, right: insets)
    let size = CGSize(width: list.bounds.width, height: 54)
    if list.tableFooterView !== footer || footer.frame.size != size {
      footer.frame = CGRect(origin: .zero, size: size); list.tableFooterView = footer
    }
  }

  private func refreshFloatingRule() {
    guard ready, hasResults, !isTimeRule, let formButton = formView?.ruleButton, list.bounds.height > 0 else {
      floatingRule.isHidden = true
      return
    }
    let viewport = list.bounds
    let formButtonVisible = viewport.intersects(formButton.convert(formButton.bounds, to: list))
    let footerButtonVisible = footerRule.window != nil && viewport.intersects(footerRule.convert(footerRule.bounds, to: list))
    floatingRule.isHidden = formButtonVisible || footerButtonVisible
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
    refreshFloatingRule()
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard !programs.isEmpty else {
      let cell = UITableViewCell(); cell.backgroundColor = .clear; cell.selectionStyle = .none
      var content = cell.defaultContentConfiguration()
      content.text = isTimeRule ? "このルールの予約はありません" : "条件に一致する番組はありません"
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

extension NeoPage {
  func openProgramRule(for recording: NeoRecording) {
    guard let ruleID = recording.ruleId, ruleID > 0, let shell, shell.api?.accountReady == true else { return }
    shell.pushPage { NeoProgramSearchPage(shell: shell, ruleID: ruleID) }
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
