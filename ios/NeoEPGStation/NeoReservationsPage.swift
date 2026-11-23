import UIKit

final class NeoReservationsPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private let scope = UIScrollView(), tabs = UIStackView()
  private let table = UITableView(frame: .zero, style: .plain)
  private let refreshControl = UIRefreshControl(), footer = NeoPaginationFooter()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let empty = NeoStyle.label("該当する予約はありません", size: 16, muted: true)
  private let errorLabel = NeoStyle.label(size: 14), errorBar = UIStackView()
  private let selectionBar = UIStackView(), countLabel = NeoStyle.label(size: 16)
  private let compactUser = NeoDropdownButton(frame: .zero), wideUser = NeoUserSelector(frame: .zero)
  private lazy var editButton = NeoStyle.iconButton("EditOutlined", label: "選択") { [weak self] in self?.toggleEditing() }
  private lazy var updateButton = NeoStyle.iconButton("RefreshOutlined", label: "予約情報更新") { [weak self] in self?.rebuildReservations() }
  private lazy var selectAll = NeoStyle.iconButton("CheckBoxOutlineBlank", label: "このページをすべて選択") { [weak self] in
    guard let self, bulkSelecting, mutation == nil else { return }
    selected = selected.count == items.count ? [] : Set(items.map(\.id))
    render()
  }
  private lazy var bulkAction = NeoStyle.iconButton("DeleteOutlineOutlined", label: "選択した予約をキャンセル") { [weak self] in
    guard let self else { return }
    confirm(items.filter { self.selected.contains($0.id) }, bulk: true)
  }

  private let updates = NeoServerStatusUpdates(), deferred = NeoDeferredScrollUpdate()
  private var read: Task<Void, Never>?, metadata: Task<Void, Never>?, mutation: Task<Void, Never>?, updateTask: Task<Void, Never>?
  private var readVersion = UUID(), account: NeoReservationSession?
  private var wantsUpdate = false, shown = false, bulkSelecting = false
  private var kind = NeoProgramReserveKind.normal, page = 1, limit = 24
  private var userID: Int?
  private var users: [NeoViewer]?, channels: [Int: NeoLiveChannel]?, userLoadFailed = false
  private var result: NeoReservationList?, loadError: String?
  private var counts: [NeoProgramReserveKind: Int] = [:], tabButtons: [NeoProgramReserveKind: UIButton] = [:]
  private var selected = Set<Int>()
  private var footerWidth: CGFloat = 0
  private var items: [NeoReservationItem] { result?.reserves ?? [] }
  private var pages: Int { max(1, ((result?.total ?? 0) - 1) / limit + 1) }
  private var compact: Bool { view.bounds.width < 900 }

  init(shell: NeoShell) { super.init(title: "予約", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    let stack = UIStackView(arrangedSubviews: [scope, selectionBar, errorBar, table])
    stack.axis = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: body.leadingAnchor), stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      stack.topAnchor.constraint(equalTo: body.topAnchor), stack.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      scope.heightAnchor.constraint(equalToConstant: 48),
    ])
    scope.backgroundColor = NeoStyle.paper; scope.showsHorizontalScrollIndicator = false
    tabs.distribution = .fillEqually
    tabs.translatesAutoresizingMaskIntoConstraints = false
    scope.addSubview(tabs)
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: scope.contentLayoutGuide.leadingAnchor),
      tabs.trailingAnchor.constraint(equalTo: scope.contentLayoutGuide.trailingAnchor),
      tabs.topAnchor.constraint(equalTo: scope.contentLayoutGuide.topAnchor),
      tabs.bottomAnchor.constraint(equalTo: scope.contentLayoutGuide.bottomAnchor),
      tabs.widthAnchor.constraint(greaterThanOrEqualTo: scope.frameLayoutGuide.widthAnchor),
      tabs.heightAnchor.constraint(equalTo: scope.frameLayoutGuide.heightAnchor),
    ])
    for tab in NeoProgramReserveKind.allCases {
      let button = UIButton(type: .system)
      button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
      button.accessibilityIdentifier = "reserves.tab." + tab.queryType
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
      let line = UIView()
      line.backgroundColor = NeoStyle.accent; line.tag = 851
      line.isUserInteractionEnabled = false; line.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(line)
      NSLayoutConstraint.activate([
        line.leadingAnchor.constraint(equalTo: button.leadingAnchor), line.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        line.bottomAnchor.constraint(equalTo: button.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 2),
      ])
      button.addAction(UIAction { [weak self] _ in self?.switchKind(tab) }, for: .touchUpInside)
      tabButtons[tab] = button
      tabs.addArrangedSubview(button)
    }

    selectionBar.backgroundColor = NeoStyle.paper; selectionBar.spacing = 8
    selectionBar.isLayoutMarginsRelativeArrangement = true
    selectionBar.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    [selectAll, countLabel, bulkAction].forEach(selectionBar.addArrangedSubview)
    for button in [selectAll, bulkAction] { button.widthAnchor.constraint(equalToConstant: 44).isActive = true }
    let selectionHeight = selectionBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
    selectionHeight.priority = .defaultHigh; selectionHeight.isActive = true

    errorLabel.numberOfLines = 0
    errorBar.backgroundColor = NeoStyle.paper; errorBar.spacing = 8
    errorBar.isLayoutMarginsRelativeArrangement = true
    errorBar.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    errorBar.addArrangedSubview(errorLabel)
    let retry = NeoStyle.button("再試行") { [weak self] in self?.load() }
    retry.setContentHuggingPriority(.required, for: .horizontal)
    errorBar.addArrangedSubview(retry)

    compactUser.setImage(NeoIcon.image("AccountCircleOutlined"), for: .normal)
    compactUser.tintColor = .white; compactUser.accessibilityLabel = "ユーザーを選択"
    compactUser.accessibilityIdentifier = "reserves.user"
    wideUser.accessibilityIdentifier = "reserves.user"
    wideUser.setCaptionVisible(true)
    editButton.accessibilityIdentifier = "reserves.edit"
    updateButton.accessibilityIdentifier = "reserves.update"
    selectAll.accessibilityIdentifier = "reserves.selectAll"
    bulkAction.accessibilityIdentifier = "reserves.bulkAction"
    table.accessibilityIdentifier = "reserves.list"
    table.backgroundColor = NeoStyle.background; table.separatorStyle = .none
    table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 108
    table.dataSource = self; table.delegate = self
    table.register(NeoReservationCard.self, forCellReuseIdentifier: "reserve")
    table.contentInset.top = 12
    table.refreshControl = refreshControl
    refreshControl.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
    body.addSubview(empty); body.addSubview(spinner)
    empty.textAlignment = .center; empty.numberOfLines = 0
    let center = UILayoutGuide()
    body.addLayoutGuide(center)
    empty.translatesAutoresizingMaskIntoConstraints = false; spinner.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      center.topAnchor.constraint(equalTo: table.topAnchor), center.bottomAnchor.constraint(equalTo: table.bottomAnchor),
      center.leadingAnchor.constraint(equalTo: table.leadingAnchor), center.trailingAnchor.constraint(equalTo: table.trailingAnchor),
      empty.centerXAnchor.constraint(equalTo: center.centerXAnchor), empty.centerYAnchor.constraint(equalTo: center.centerYAnchor),
      empty.widthAnchor.constraint(lessThanOrEqualTo: center.widthAnchor, constant: -32),
      spinner.centerXAnchor.constraint(equalTo: center.centerXAnchor), spinner.topAnchor.constraint(equalTo: center.topAnchor, constant: 70),
    ])
    for name in [Notification.Name.neoAccountChanged, .neoTextPreferencesChanged, .neoReservationsChanged,
      .neoReservationPreferencesChanged, .neoRecordingPreferencesChanged] {
      NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    shown = true; synchronize(); load()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    shown = false; suspendRead()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateHeader()
    if !compact { wideUser.frame = wideUser.frame.insetBy(dx: 4, dy: 7) }
    if footerWidth != table.bounds.width {
      footerWidth = table.bounds.width
      updateFooter()
    }
  }

  override func width(forHeaderAction action: UIView) -> CGFloat { action === wideUser ? 168 : 44 }

  @objc private func changed(_ note: Notification) {
    guard (note.object as? NeoAPI) === shell?.api else { return }
    if note.name == .neoReservationsChanged {
      if shown { requestUpdate() }
    } else {
      synchronize()
      if shown { load() }
    }
  }

  @objc private func backgrounded() { suspendRead() }
  @objc private func foregrounded() { if shown { synchronize(); load() } }

  private func synchronize() {
    guard let api = shell?.api else { return }
    let next = NeoReservationSession(api)
    if account?.hasSameIdentity(as: api) != true {
      suspendRead()
      mutation?.cancel(); mutation = nil
      if let presentedViewController { presentedViewController.dismiss(animated: false) }
      shell?.dismissPopup()
      users = nil; channels = nil; userLoadFailed = false
      userID = next.viewerID
      counts = [:]; resetRows()
    }
    account = next
    if limit != api.reservesLength { limit = api.reservesLength; resetRows() }
  }

  private func resetRows() {
    page = 1; result = nil; loadError = nil
    bulkSelecting = false; selected.removeAll()
    if isViewLoaded {
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }
  }

  private func suspendRead() {
    updates.stop()
    updateTask?.cancel(); updateTask = nil; wantsUpdate = false
    read?.cancel(); read = nil; readVersion = UUID()
    metadata?.cancel(); metadata = nil
    deferred.cancel()
  }

  private func switchKind(_ value: NeoProgramReserveKind) {
    guard kind != value, mutation == nil else { return }
    kind = value; resetRows(); load()
    if let button = tabButtons[value] { scope.scrollRectToVisible(button.frame, animated: true) }
  }

  private func switchUser(_ value: Int?) {
    guard mutation == nil else { return }
    guard userID != value else { return }
    userID = value; counts = [:]; resetRows(); load()
  }

  private func switchPage(_ value: Int) {
    guard page != value, value > 0, mutation == nil else { return }
    resetRows(); page = value; load()
  }

  private func requestUpdate() {
    wantsUpdate = true
    guard shown, read == nil, mutation == nil, updateTask == nil else { return }
    updateTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self, !Task.isCancelled else { return }
      updateTask = nil
      if shown, read == nil, mutation == nil { load() }
    }
  }

  private func load() {
    guard mutation == nil else { wantsUpdate = true; return }
    updateTask?.cancel(); updateTask = nil; wantsUpdate = false
    read?.cancel(); read = nil; readVersion = UUID()
    deferred.cancel()
    guard shown, let account, account.isCurrent(shell?.api) else { render(); refreshControl.endRefreshing(); return }
    let attempt = readVersion, activeKind = kind, halfWidth = account.api.isHalfWidthDisplayed
    let page = self.page, limit = self.limit
    updates.start(api: account.api, port: shell?.serverConfig?.socketIOPort, events: ["updateStatus"]) { [weak self] in self?.requestUpdate() }
    loadMetadata(account)
    read = Task { [weak self] in
      guard let self else { return }
      defer {
        if attempt == readVersion {
          read = nil
          if refreshControl.isRefreshing { refreshControl.endRefreshing() }
          if wantsUpdate { requestUpdate() }
        }
      }
      let filter = userID
      do {
        let list = try await account.list(activeKind, userID: filter, offset: (page - 1) * limit, limit: limit, halfWidth: halfWidth)
        guard !Task.isCancelled, attempt == readVersion, account.isCurrent(shell?.api) else { return }
        counts[activeKind] = list.total
        updateTabs()
        if result != list || loadError != nil {
          deferred.submit(in: table) { [weak self] in
            guard let self, attempt == readVersion, account.isCurrent(shell?.api) else { return }
            let last = max(1, (list.total - 1) / limit + 1)
            if page > last { switchPage(last); return }
            result = list; loadError = nil
            selected.formIntersection(items.map(\.id))
            render()
          }
        }
      } catch {
        guard !Task.isCancelled, attempt == readVersion, account.isCurrent(shell?.api) else { return }
        deferred.submit(in: table) { [weak self] in
          guard let self, attempt == readVersion, account.isCurrent(shell?.api) else { return }
          loadError = error.localizedDescription
          render()
        }
      }
      let countKinds = NeoProgramReserveKind.allCases.filter { $0 != activeKind }
      let totals = await withTaskGroup(of: (NeoProgramReserveKind, Int?).self) { group in
        for tab in countKinds {
          group.addTask { (tab, (try? await account.list(tab, userID: filter, offset: 0, limit: 1, halfWidth: halfWidth))?.total) }
        }
        var values: [NeoProgramReserveKind: Int] = [:]
        for await (tab, total) in group { if let total { values[tab] = total } }
        return values
      }
      guard !Task.isCancelled, attempt == readVersion, account.isCurrent(shell?.api) else { return }
      counts.merge(totals) { _, new in new }
      updateTabs()
    }
    if result == nil { render() }
  }

  private func loadMetadata(_ account: NeoReservationSession) {
    let needUsers = users == nil, needChannels = channels == nil
    guard metadata == nil, needUsers || needChannels else { return }
    metadata = Task { [weak self] in
      async let userData: NeoViewers? = needUsers ? (try? await account.api.viewers()) : nil
      async let channelData: [NeoLiveChannel]? = needChannels ? (try? await account.api.programSearchChannels(user: account.viewer, headers: account.headers)) : nil
      let (viewers, roster) = await (userData, channelData)
      guard let self, !Task.isCancelled else { return }
      metadata = nil
      guard shown, account.isCurrent(shell?.api) else { return }
      if let roster { channels = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
      if needUsers {
        users = viewers?.users.filter { $0.id > 0 }
        userLoadFailed = viewers == nil
        if let users, let id = userID, !users.contains(where: { $0.id == id }) {
          let defaultID = account.viewerID.flatMap { selected in users.first { $0.id == selected }?.id }
          userID = defaultID ?? (account.viewer == "master" ? nil : users.first?.id)
          counts = [:]; resetRows(); load()
        }
      }
      if roster != nil {
        for path in table.indexPathsForVisibleRows ?? [] {
          if let cell = table.cellForRow(at: path) as? NeoReservationCard, items.indices.contains(path.row) {
            configure(cell, item: items[path.row])
          }
        }
      }
      updateUsers()
    }
  }

  private func render() {
    let showSpinner = result == nil && read != nil && loadError == nil
    if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
    errorBar.isHidden = loadError == nil
    if let loadError {
      errorLabel.text = result == nil ? "予約データの取得に失敗しました: \(loadError)" : "予約データを更新できなかったため、取得済みの一覧を表示しています。"
      errorLabel.textColor = result == nil ? NeoStyle.error : NeoStyle.warning
    }
    empty.isHidden = result == nil || !items.isEmpty
    selectionBar.isHidden = !bulkSelecting
    countLabel.text = "\(selected.count)件選択"
    let all = !items.isEmpty && selected.count == items.count
    selectAll.setImage(NeoIcon.image(all ? "CheckBox" : selected.isEmpty ? "CheckBoxOutlineBlank" : "IndeterminateCheckBox"), for: .normal)
    selectAll.tintColor = selected.isEmpty ? NeoStyle.muted : NeoStyle.accent
    selectAll.isEnabled = mutation == nil && !items.isEmpty
    let action = NeoReservationAction(kind: kind)
    bulkAction.setImage(NeoIcon.image(action == .cancel ? "DeleteOutlineOutlined" : "LockOpenOutlined"), for: .normal)
    bulkAction.accessibilityLabel = "選択した" + action.label
    bulkAction.tintColor = action == .cancel ? NeoStyle.error : NeoStyle.accent
    bulkAction.isEnabled = !selected.isEmpty && mutation == nil
    table.reloadData()
    updateFooter(); updateHeader(); updateTabs(); updateUsers()
  }

  private func updateTabs() {
    for (value, button) in tabButtons {
      let active = value == kind
      let title = value.label + (counts[value].map { " \($0)" } ?? "")
      if button.title(for: .normal) != title { button.setTitle(title, for: .normal) }
      button.tintColor = active ? NeoStyle.accent : NeoStyle.muted
      button.viewWithTag(851)?.isHidden = !active
      button.accessibilityTraits = active ? [.button, .selected] : .button
      button.isEnabled = mutation == nil
    }
  }

  private func updateHeader() {
    titleLabel.text = bulkSelecting ? "\(selected.count)件選択" : kind.label
    editButton.setImage(NeoIcon.image(bulkSelecting ? "Close" : "EditOutlined"), for: .normal)
    editButton.accessibilityLabel = bulkSelecting ? "選択を終了" : "選択"
    let enabled = account?.isCurrent(shell?.api) == true && mutation == nil
    editButton.isEnabled = enabled; updateButton.isEnabled = enabled
    let next: [UIView] = bulkSelecting ? [editButton] : [compact ? compactUser : wideUser, editButton, updateButton]
    if next.map(ObjectIdentifier.init) != actions.map(ObjectIdentifier.init) { actions = next }
  }

  private func updateUsers() {
    let label = userID.map { id in users?.first { $0.id == id }?.name ?? "ユーザーID: \(id)" } ?? "master（すべて）"
    compactUser.accessibilityValue = label; wideUser.setValue(label)
    var rows: [NeoDropdownList.Row] = [ .init(title: "master（すべて）", selected: userID == nil) { [weak self] in self?.switchUser(nil) } ]
    if let users {
      rows += users.map { viewer in .init(title: viewer.name, selected: userID == viewer.id) { [weak self] in self?.switchUser(viewer.id) } }
    } else if userLoadFailed {
      rows.append(.init(title: "ユーザーの取得に失敗しました（再試行）") { [weak self] in self?.load() })
    } else {
      rows.append(.init(title: "ユーザーを読み込み中…", style: .empty))
    }
    for button in [compactUser, wideUser] {
      button.dropdownRows = rows; button.isEnabled = mutation == nil && account?.isCurrent(shell?.api) == true
    }
  }

  private func updateFooter() {
    guard pages > 1 else { if table.tableFooterView != nil { table.tableFooterView = nil }; return }
    footer.frame = CGRect(x: 0, y: 0, width: max(1, footerWidth), height: 72)
    footer.configure(page: page, count: pages, mobile: footerWidth < 600, extended: account?.api.extendedPagination == true, jump: { [weak self] in
      guard let self, mutation == nil else { return }
      present(NeoPageJumpDialog(page: page, count: pages) { [weak self] in self?.switchPage($0) }, animated: true)
    }) { [weak self] in self?.switchPage($0) }
    table.tableFooterView = footer
  }

  private func toggleEditing() {
    guard mutation == nil else { return }
    bulkSelecting.toggle(); selected.removeAll(); render()
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
  func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "reserve", for: path) as! NeoReservationCard
    configure(cell, item: items[path.row])
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
    tableView.deselectRow(at: path, animated: false)
    guard mutation == nil, items.indices.contains(path.row) else { return }
    let item = items[path.row]
    if bulkSelecting {
      if selected.remove(item.id) == nil { selected.insert(item.id) }
      render()
    } else { openDetails(item) }
  }

  private func configure(_ cell: NeoReservationCard, item: NeoReservationItem) {
    cell.configure(title: item.name, source: item.ruleId == nil ? "手動" : "ルール",
      status: item.kind == .normal ? nil : item.kind.label, conflict: item.isConflict == true,
      subdued: item.isSkip == true || item.isOverlap == true,
      channel: channels?[item.channelId]?.name ?? String(item.channelId),
      time: NeoManualReservationPage.schedule(item.program), summary: item.description,
      editing: bulkSelecting, selected: selected.contains(item.id))
    cell.onMenu = { [weak self] anchor in self?.openMenu(item, anchor: anchor) }
  }

  private func openMenu(_ item: NeoReservationItem, anchor: UIView) {
    guard !bulkSelecting, mutation == nil else { return }
    var entries: [NeoMenuEntry] = []
    if let rule = item.ruleId {
      entries.append(.init(title: "recorded", icon: "FilmstripBoxMultiple") { [weak self] in self?.openRecordings(rule) })
    }
    entries.append(.init(title: "edit", icon: "EditOutlined") { [weak self] in self?.openEditor(item) })
    if item.isConflict != true {
      entries.append(.init(title: item.action == .cancel ? "delete" : "unlock",
        icon: item.action == .cancel ? "DeleteOutlineOutlined" : "LockOpenOutlined") { [weak self] in self?.confirm([item], bulk: false) })
    }
    shell?.showPopup(anchor: anchor, entries: entries, appearance: .pageActions)
  }

  private func openEditor(_ item: NeoReservationItem) {
    guard let shell, let account, account.isCurrent(shell.api) else { return }
    if let id = item.ruleId { shell.pushPage { NeoProgramSearchPage(shell: shell, ruleID: id) } }
    else { shell.pushPage { NeoManualReservationPage(shell: shell, target: .reservation(item.id), owner: account) } }
  }

  private func openRecordings(_ rule: Int) {
    guard let shell, let account, account.isCurrent(shell.api) else { return }
    var filters = NeoRecordedFilters(); filters.ruleID = rule
    let viewer = userID.map(String.init) ?? "master"
    shell.pushPage { NeoRecordedPage(shell: shell, filters: filters, viewerFilter: viewer) }
  }

  private func openDetails(_ item: NeoReservationItem) {
    guard let account, account.isCurrent(shell?.api), presentedViewController == nil else { return }
    let station = channels?[item.channelId]
    let userName = item.userId.map { id in users?.first { $0.id == id }?.name ?? "ユーザーID: \(id)" } ?? "ユーザー未指定"
    let dialog = NeoProgramDetailDialog(program: item.program, channel: station,
      logoURL: station?.hasLogoData == true ? account.api.url("/channels/\(item.channelId)/logo") : nil,
      reservationLabel: item.kind.label, reservationConflict: item.isConflict == true, reservationUsers: [userName],
      alwaysShowBroadcastDetails: account.api.alwaysShowProgramBroadcastDetails) { [weak self] in
        if let rule = item.ruleId { self?.openRecordings(rule) }
      }
    let action: (() -> Void)? = item.isConflict == true ? nil : { [weak self, weak dialog] in
      self?.confirm([item], bulk: false, from: dialog)
    }
    let label = item.action != .cancel ? item.action.label : item.ruleId == nil ? "予約を削除" : "予約を除外"
    dialog.configureExistingReservation(detailsTitle: item.ruleId == nil ? "詳細" : "編集",
      showsSearch: item.ruleId != nil, onDetails: { [weak self] in self?.openEditor(item) },
      actionTitle: action == nil ? nil : label, onAction: action)
    present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  private func confirm(_ targets: [NeoReservationItem], bulk: Bool, from detail: NeoProgramDetailDialog? = nil) {
    guard !targets.isEmpty, mutation == nil, let account, account.isCurrent(shell?.api) else { return }
    let presenter = (detail as UIViewController?) ?? self
    guard presenter.presentedViewController == nil else { return }
    let action = bulk ? NeoReservationAction(kind: kind) : targets[0].action
    let heading = detail != nil && action == .cancel
      ? (targets[0].ruleId == nil ? "予約を削除しますか？" : "予約を除外しますか？") : action.confirmation
    let text = bulk ? "\(targets.count)件の\(action.label)を実行します。" : targets[0].name
    let footer = action == .cancel
      ? (bulk ? "手動予約は削除され、ルールから作成された予約は除外扱いになります。"
        : targets[0].ruleId == nil ? "この予約をキャンセルします。" : "ルールから作成された予約は除外扱いになります。") : nil
    let prompt = NeoReservationConfirmation(heading, text: text, note: footer, action: action)
    prompt.onConfirm = { [weak self, weak prompt, weak detail] in
      guard let self, let prompt, account.isCurrent(shell?.api), mutation == nil else { return }
      mutate(targets, session: account, prompt: prompt, detail: detail, bulk: bulk)
    }
    presenter.present(prompt, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  private func mutate(_ targets: [NeoReservationItem], session: NeoReservationSession,
    prompt: NeoReservationConfirmation, detail: NeoProgramDetailDialog?, bulk: Bool) {
    deferred.cancel(); prompt.setBusy(true)
    mutation = Task { [weak self, weak prompt, weak detail] in
      guard let self else { return }
      var succeeded: [NeoReservationAction: Int] = [:], failed: [(NeoReservationItem, String)] = []
      for item in targets {
        guard !Task.isCancelled, session.hasSameIdentity(as: shell?.api) else { return }
        guard session.isCurrent(shell?.api) else {
          failed.append((item, "アクティブユーザーの確認が必要です。"))
          continue
        }
        do { try await session.change(item.id, action: item.action); succeeded[item.action, default: 0] += 1 }
        catch { failed.append((item, error.localizedDescription)) }
      }
      guard !Task.isCancelled, session.hasSameIdentity(as: shell?.api) else { return }
      mutation = nil
      if bulk {
        selected = Set(failed.map { $0.0.id }); bulkSelecting = !selected.isEmpty
      }
      prompt?.dismiss(animated: true) { if !succeeded.isEmpty { detail?.finishReservationAction() } }
      if !succeeded.isEmpty {
        let summary = [NeoReservationAction.restoreSkip, .restoreOverlap, .cancel].compactMap { action in
          succeeded[action].map { action.success(count: bulk ? $0 : nil) }
        }.joined(separator: "、")
        shell?.recordingNotice(summary)
      }
      if !failed.isEmpty {
        let detail = failed.prefix(3).map { "\($0.0.name): \($0.1)" }.joined(separator: " / ")
        shell?.recordingNotice(bulk ? "\(failed.count)件を解除できませんでした: \(detail)" : "予約の変更に失敗しました: \(detail)", error: true)
      }
      if !succeeded.isEmpty { NotificationCenter.default.post(name: .neoReservationsChanged, object: session.api) }
      render()
      if shown { load() }
    }
    render()
  }

  private func rebuildReservations() {
    guard let session = account, session.isCurrent(shell?.api), mutation == nil else { return }
    deferred.cancel()
    mutation = Task { [weak self] in
      guard let self else { return }
      do {
        try await session.rebuild()
        guard !Task.isCancelled, session.hasSameIdentity(as: shell?.api) else { return }
        shell?.recordingNotice("予約情報を更新しました")
        NotificationCenter.default.post(name: .neoReservationsChanged, object: session.api)
      } catch {
        guard !Task.isCancelled, session.hasSameIdentity(as: shell?.api) else { return }
        shell?.recordingNotice("予約情報の更新に失敗しました: \(error.localizedDescription)", error: true)
      }
      mutation = nil; updateHeader(); updateTabs(); updateUsers()
      if shown { load() }
    }
    updateHeader(); updateTabs(); updateUsers()
  }

  deinit { read?.cancel(); metadata?.cancel(); mutation?.cancel(); updateTask?.cancel() }
}

private final class NeoReservationConfirmation: NeoLiveDialog {
  var onConfirm: (() -> Void)?
  private var submit: UIButton?
  private var cancelAction: UIButton?
  private var busy = false

  init(_ heading: String, text: String, note: String?, action: NeoReservationAction) {
    super.init(title: heading)
    addText(text)
    if let note { addText(note) }
    cancelAction = addAction("キャンセル") { [weak self] in self?.cancel() }
    submit = addAction(action.label, filled: true) { [weak self] in self?.onConfirm?() }
    submit?.accessibilityIdentifier = "reserves.confirm"
    if action == .cancel {
      submit?.backgroundColor = NeoStyle.error
      submit?.setTitleColor(.white, for: .normal)
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func cancel() { if !busy { super.cancel() } }
  func setBusy(_ busy: Bool) {
    self.busy = busy
    submit?.isEnabled = !busy; cancelAction?.isEnabled = !busy; setCloseEnabled(!busy)
  }
}
