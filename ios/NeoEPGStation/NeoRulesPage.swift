import UIKit

final class NeoRulesPage: NeoPage, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
  private struct Account: Equatable {
    let api: NeoAPI
    let viewer: String
    let revision: Int

    init(_ api: NeoAPI) {
      self.api = api
      viewer = api.viewer
      revision = api.identityRevision
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.api === rhs.api && lhs.viewer == rhs.viewer && lhs.revision == rhs.revision
    }

    var userID: Int? { Int(viewer).flatMap { $0 > 0 ? $0 : nil } }
  }

  private let userFilter = NeoUserSelector()
  private let keywordField = UITextField()
  private let table = UITableView(frame: .zero, style: .plain)
  private let pagination = NeoPaginationFooter()
  private let pullToRefresh = UIRefreshControl()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let emptyLabel = NeoStyle.label("該当するルールはありません", size: 16, muted: true)
  private let selectionCount = NeoStyle.label(size: 16)
  private let errorLabel = NeoStyle.label(size: 14)
  private let selectionBar = UIStackView(), errorBar = UIStackView()
  private let selectionSection = UIStackView(), errorSection = UIStackView()

  private lazy var reservationFilter = NeoStyle.iconButton("FilterAltOutlined", label: "予約有のみ表示") { [weak self] in
    guard let self else { return }
    var next = query
    next.hasReserve.toggle()
    next.page = 1
    applyQuery(next)
  }
  private lazy var selectButton = NeoStyle.iconButton("CheckBoxOutlined", label: "選択") { [weak self] in
    guard let self, mutation == nil else { return }
    selecting.toggle()
    selectedIDs.removeAll()
    render()
  }
  private lazy var refreshButton = NeoStyle.iconButton("RefreshOutlined", label: "更新") { [weak self] in self?.reloadRules() }
  private lazy var selectAll = NeoStyle.iconButton("CheckBoxOutlineBlank", label: "このページをすべて選択") { [weak self] in
    guard let self, mutation == nil, selecting else { return }
    selectedIDs = selectedIDs.count == rules.count ? [] : Set(rules.map(\.id))
    render()
  }
  private lazy var deleteSelection = NeoStyle.iconButton("DeleteOutlineOutlined", label: "選択したルールを削除") { [weak self] in
    guard let self, selecting else { return }
    confirmDeletion(rules.filter { self.selectedIDs.contains($0.id) }, bulk: true)
  }
  private lazy var addRule = NeoStyle.iconButton("AddOutlined", label: "ルールを作成") { [weak self] in self?.openEditor() }
  private lazy var searchInput = NeoProgramSearchInput(label: "ルールを検索", placeholder: "", field: keywordField,
    accessory: NeoStyle.iconButton("SearchOutlined", label: "検索") { [weak self] in self?.submitKeyword() }, verticalInset: 0)

  private var account: Account?
  private var query = NeoRuleListQuery()
  private var userFilterExplicit = false
  private var result: NeoRuleList?
  private var rules: [NeoProgramRule] { result?.rules ?? [] }
  private var pageCount: Int { query.pageCount(total: result?.total ?? 0) }
  private var viewers: [NeoViewer]?
  private var viewersFailed = false
  private var channelNames: [Int: String]?
  private var loadError: String?
  private var displayed = false
  private var selecting = false
  private var selectedIDs = Set<Int>()
  private var selectionGeneration = 0
  private var readToken = UUID()
  private var read: Task<Void, Never>?, channelRead: Task<Void, Never>?, mutation: Task<Void, Never>?
  private let statusUpdates = NeoServerStatusUpdates()
  private var statusRefresh: Task<Void, Never>?
  private var statusNeedsRefresh = false
  private var observers: [NSObjectProtocol] = []
  private var measuredWidth: CGFloat = 0
  private let errorColor = UIColor(red: 239/255, green: 83/255, blue: 80/255, alpha: 1)

  init(shell: NeoShell) { super.init(title: "ルール", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    userFilter.accessibilityIdentifier = "rules.user"
    reservationFilter.accessibilityIdentifier = "rules.hasReserve"
    selectButton.accessibilityIdentifier = "rules.select"
    refreshButton.accessibilityIdentifier = "rules.refresh"
    actions = [userFilter, reservationFilter, selectButton, refreshButton]
    configureBody()
    let center = NotificationCenter.default
    for name in [Notification.Name.neoAccountChanged, .neoRuleListPreferencesChanged] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        guard let self, let api = notification.object as? NeoAPI, shell?.api === api else { return }
        synchronizeAccount()
        reloadRules()
      })
    }
    observers.append(center.addObserver(forName: .neoRecordingPreferencesChanged, object: nil, queue: .main) { [weak self] notification in
      guard let self, let api = notification.object as? NeoAPI, shell?.api === api else { return }
      updatePagination()
    })
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      self?.stopStatusUpdates()
      self?.stopRead()
    })
    observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self, displayed else { return }
      synchronizeAccount()
      reloadRules(quiet: true)
    })
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    displayed = true
    synchronizeAccount()
    reloadRules()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    displayed = false
    stopRead()
    stopStatusUpdates()
    view.endEditing(true)
    shell?.dismissPopup()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let width = table.bounds.width
    if width > 0, abs(measuredWidth - width) > 0.5 {
      measuredWidth = width
      updateHeader()
      updatePagination()
      table.contentInset = UIEdgeInsets(top: width >= 900 ? 24 : 12, left: 0, bottom: 96, right: 0)
      table.reloadData()
    }
    userFilter.frame = userFilter.frame.insetBy(dx: 0, dy: 2)
    if view.bounds.width >= 600 {
      reservationFilter.frame = reservationFilter.frame.insetBy(dx: 4, dy: 4)
      selectButton.frame = selectButton.frame.insetBy(dx: 4, dy: 4)
    }
  }

  override func width(forHeaderAction action: UIView) -> CGFloat {
    let wide = view.bounds.width >= 600
    if action === userFilter { return wide ? 180 : 84 }
    if wide, action === reservationFilter || action === selectButton { return 76 }
    return super.width(forHeaderAction: action)
  }

  private func configureBody() {
    keywordField.textColor = .white
    keywordField.font = .systemFont(ofSize: 16)
    keywordField.returnKeyType = .search
    keywordField.clearButtonMode = .never
    keywordField.autocorrectionType = .no
    keywordField.autocapitalizationType = .none
    keywordField.accessibilityIdentifier = "rules.keyword"
    keywordField.delegate = self
    keywordField.addAction(UIAction { [weak self] _ in self?.searchInput.updateAppearance() }, for: .editingChanged)
    let searchBar = UIStackView(arrangedSubviews: [searchInput])
    searchBar.isLayoutMarginsRelativeArrangement = true
    searchBar.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    searchBar.backgroundColor = NeoStyle.paper
    let divider = UIView()
    divider.backgroundColor = NeoStyle.border
    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

    selectionBar.alignment = .center
    selectionBar.spacing = 8
    selectionBar.isLayoutMarginsRelativeArrangement = true
    selectionBar.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    selectAll.accessibilityIdentifier = "rules.selectAll"
    selectionCount.accessibilityIdentifier = "rules.selectionCount"
    deleteSelection.accessibilityIdentifier = "rules.deleteSelection"
    selectAll.widthAnchor.constraint(equalToConstant: 42).isActive = true
    selectAll.heightAnchor.constraint(equalToConstant: 42).isActive = true
    deleteSelection.heightAnchor.constraint(equalToConstant: 42).isActive = true
    selectionCount.setContentHuggingPriority(.defaultLow, for: .horizontal)
    [selectAll, selectionCount, deleteSelection].forEach(selectionBar.addArrangedSubview)
    let selectionLine = UIView()
    selectionLine.backgroundColor = NeoStyle.border
    selectionLine.heightAnchor.constraint(equalToConstant: 1).isActive = true
    selectionSection.addArrangedSubview(selectionBar)
    selectionSection.addArrangedSubview(selectionLine)
    selectionSection.axis = .vertical
    selectionSection.accessibilityIdentifier = "rules.selectionBar"

    errorBar.spacing = 8
    errorBar.alignment = .center
    errorBar.isLayoutMarginsRelativeArrangement = true
    errorBar.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    errorLabel.numberOfLines = 0
    errorLabel.accessibilityIdentifier = "rules.loadError"
    let retry = NeoStyle.button("再試行") { [weak self] in self?.reloadRules() }
    retry.accessibilityIdentifier = "rules.retry"
    retry.setContentCompressionResistancePriority(.required, for: .horizontal)
    retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    [errorLabel, retry].forEach(errorBar.addArrangedSubview)
    errorSection.addArrangedSubview(errorBar)
    errorSection.isLayoutMarginsRelativeArrangement = true
    errorSection.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 0, right: 12)
    errorSection.accessibilityIdentifier = "rules.errorBar"
    errorBar.layer.cornerRadius = 6

    table.backgroundColor = NeoStyle.background
    table.separatorStyle = .none
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 104
    table.contentInsetAdjustmentBehavior = .never
    table.keyboardDismissMode = .onDrag
    table.alwaysBounceVertical = true
    table.dataSource = self
    table.delegate = self
    table.accessibilityIdentifier = "rules.list"
    table.register(NeoRuleCard.self, forCellReuseIdentifier: "rule")
    pullToRefresh.tintColor = NeoStyle.accent
    pullToRefresh.addAction(UIAction { [weak self] _ in self?.reloadRules() }, for: .valueChanged)
    table.refreshControl = pullToRefresh
    let status = UIView()
    status.isUserInteractionEnabled = false
    emptyLabel.textAlignment = .center
    emptyLabel.numberOfLines = 0
    spinner.color = NeoStyle.accent
    spinner.hidesWhenStopped = true
    for item in [emptyLabel, spinner] { item.translatesAutoresizingMaskIntoConstraints = false; status.addSubview(item) }
    NSLayoutConstraint.activate([
      emptyLabel.topAnchor.constraint(equalTo: status.topAnchor, constant: 76),
      emptyLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 12),
      emptyLabel.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -12),
      spinner.centerXAnchor.constraint(equalTo: status.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: status.topAnchor, constant: 144),
    ])
    table.backgroundView = status
    pagination.accessibilityIdentifier = "rules.pagination"

    let content = UIStackView(arrangedSubviews: [searchBar, divider, selectionSection, errorSection, table])
    content.axis = .vertical
    content.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: body.topAnchor),
      content.leadingAnchor.constraint(equalTo: body.safeAreaLayoutGuide.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: body.safeAreaLayoutGuide.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: body.keyboardLayoutGuide.topAnchor),
    ])

    addRule.accessibilityIdentifier = "rules.add"
    addRule.backgroundColor = NeoStyle.accent
    addRule.tintColor = NeoStyle.successText
    addRule.layer.cornerRadius = 28
    addRule.layer.shadowOpacity = 0.28
    addRule.layer.shadowRadius = 6
    addRule.layer.shadowOffset = CGSize(width: 0, height: 3)
    addRule.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(addRule)
    NSLayoutConstraint.activate([
      addRule.widthAnchor.constraint(equalToConstant: 56), addRule.heightAnchor.constraint(equalToConstant: 56),
      addRule.trailingAnchor.constraint(equalTo: body.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      addRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ])
    render()
  }

  private func updateHeader() {
    let wide = view.bounds.width >= 600
    userFilter.setCaptionVisible(wide)
    func update(_ button: UIButton, icon: String, title: String, active: Bool) {
      button.setTitle(wide ? title : nil, for: .normal)
      button.setImage(wide ? nil : NeoIcon.image(icon), for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
      button.tintColor = wide ? (active ? NeoStyle.successText : NeoStyle.accent) : (active ? NeoStyle.accent : .white)
      button.backgroundColor = wide && active ? NeoStyle.accent : .clear
      button.layer.cornerRadius = 6
      button.layer.borderWidth = wide && !active ? 1 : 0
      button.layer.borderColor = NeoStyle.accent.withAlphaComponent(0.5).cgColor
      if active { button.accessibilityTraits.insert(.selected) } else { button.accessibilityTraits.remove(.selected) }
    }
    update(reservationFilter, icon: "FilterAltOutlined", title: "予約有", active: query.hasReserve)
    reservationFilter.accessibilityLabel = query.hasReserve ? "予約なしも表示" : "予約有のみ表示"
    update(selectButton, icon: selecting ? "DoneOutlined" : "CheckBoxOutlined", title: selecting ? "完了" : "選択", active: selecting)
    selectButton.accessibilityLabel = selecting ? "選択を終了" : "選択"
    deleteSelection.setTitle(wide ? "選択したルールを削除" : nil, for: .normal)
    deleteSelection.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    deleteSelection.tintColor = errorColor
  }

  private func updateUsers() {
    let user = query.userID.flatMap { id in viewers?.first { $0.id == id }?.name }
    userFilter.setValue(user ?? query.userID.map { "ユーザーID: \($0)" } ?? "master（すべて）")
    userFilter.isEnabled = account?.api.accountReady == true && (viewers != nil || viewersFailed)
    if viewersFailed, viewers == nil {
      userFilter.dropdownRows = [.init(title: "ユーザーを取得できません。再試行") { [weak self] in self?.reloadRules() }]
      return
    }
    userFilter.dropdownRows = [.init(title: "master（すべて）", selected: query.userID == nil) { [weak self] in self?.filterUser(nil) }]
      + (viewers ?? []).map { viewer in
        .init(title: viewer.name, selected: query.userID == viewer.id) { [weak self] in self?.filterUser(viewer.id) }
      }
  }

  private func render() {
    guard isViewLoaded else { return }
    let ready = account?.api.accountReady == true
    updateHeader()
    updateUsers()
    keywordField.isEnabled = ready
    reservationFilter.isEnabled = ready
    refreshButton.isEnabled = ready
    selectButton.isEnabled = ready && mutation == nil
    addRule.isHidden = selecting
    addRule.isEnabled = ready
    selectionSection.isHidden = !selecting
    selectionCount.text = "\(selectedIDs.count)件選択"
    let all = !rules.isEmpty && rules.count == selectedIDs.count
    let selectIcon = all ? "CheckBox" : selectedIDs.isEmpty ? "CheckBoxOutlineBlank" : "IndeterminateCheckBox"
    selectAll.setImage(NeoIcon.image(selectIcon), for: .normal)
    selectAll.tintColor = selectedIDs.isEmpty ? NeoStyle.muted : NeoStyle.accent
    selectAll.accessibilityLabel = all ? "すべて解除" : "このページをすべて選択"
    selectAll.isEnabled = ready && !rules.isEmpty && mutation == nil
    deleteSelection.isEnabled = ready && !selectedIDs.isEmpty && mutation == nil

    let message = loadError.map { error in
      result == nil ? "ルールの取得に失敗しました: \(error)" : "最新のルールを取得できませんでした。表示中の結果を続けて利用できます: \(error)"
    }
    errorLabel.text = message
    let severityLight: (r: CGFloat, g: CGFloat, b: CGFloat) = result == nil ? (229, 115, 115) : (255, 183, 77)
    errorLabel.textColor = UIColor(red: 0.6 + 0.4 * severityLight.r / 255, green: 0.6 + 0.4 * severityLight.g / 255,
      blue: 0.6 + 0.4 * severityLight.b / 255, alpha: 1)
    errorBar.backgroundColor = UIColor(red: 0.1 * severityLight.r / 255, green: 0.1 * severityLight.g / 255,
      blue: 0.1 * severityLight.b / 255, alpha: 1)
    errorSection.isHidden = message == nil
    emptyLabel.isHidden = result == nil || !rules.isEmpty || message != nil
    if result == nil && (read != nil || account?.api.accountRevalidating == true) { spinner.startAnimating() } else { spinner.stopAnimating() }
    table.reloadData()
    updatePagination()
  }

  private func updatePagination() {
    guard pageCount > 1 else {
      if table.tableFooterView != nil { table.tableFooterView = nil }
      return
    }
    let width = max(1, table.bounds.width)
    pagination.frame = CGRect(x: 0, y: 0, width: width, height: 72)
    pagination.configure(page: query.page, count: pageCount, mobile: width <= 500,
      extended: account?.api.extendedPagination == true, jump: { [weak self] in self?.openPageJump() }) { [weak self] in
        self?.selectPage($0)
      }
    table.tableFooterView = pagination
  }

  private func filterUser(_ id: Int?) {
    userFilterExplicit = true
    var next = query
    next.userID = id
    next.page = 1
    applyQuery(next)
  }

  private func submitKeyword() {
    view.endEditing(true)
    var next = query
    next.keyword = (keywordField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    keywordField.text = next.keyword
    searchInput.updateAppearance()
    next.page = 1
    applyQuery(next)
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool { submitKeyword(); return true }
  func textFieldDidBeginEditing(_ textField: UITextField) { searchInput.updateAppearance() }
  func textFieldDidEndEditing(_ textField: UITextField) { searchInput.updateAppearance() }

  private func selectPage(_ page: Int) {
    guard (1...pageCount).contains(page) else { return }
    var next = query
    next.page = page
    applyQuery(next)
  }

  private func openPageJump() {
    guard pageCount > 1, presentedViewController == nil else { return }
    view.endEditing(true)
    present(NeoPageJumpDialog(page: query.page, count: pageCount) { [weak self] in self?.selectPage($0) }, animated: true)
  }

  private func applyQuery(_ next: NeoRuleListQuery) {
    guard next != query else { return }
    query = next
    result = nil
    loadError = nil
    clearSelection()
    table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    reloadRules()
  }

  private func clearSelection() {
    selecting = false
    selectedIDs.removeAll()
    selectionGeneration += 1
  }

  private func synchronizeAccount() {
    let next = (shell?.api).map(Account.init)
    if next != account {
      let sameServer = account?.api.base == next?.api.base
      stopRead()
      stopStatusUpdates()
      channelRead?.cancel(); channelRead = nil
      mutation?.cancel(); mutation = nil
      shell?.dismissPopup()
      if presentedViewController is NeoRuleDeleteDialog || presentedViewController is NeoPageJumpDialog {
        presentedViewController?.dismiss(animated: false)
      }
      account = next
      result = nil
      viewers = nil
      viewersFailed = false
      channelNames = nil
      loadError = nil
      clearSelection()
      let limit = next?.api.rulesLength ?? 24
      if !sameServer {
        userFilterExplicit = false
        query = NeoRuleListQuery(userID: next?.userID, limit: limit)
        keywordField.text = ""
        searchInput.updateAppearance()
      } else {
        if query.limit != limit || (!userFilterExplicit && query.userID != next?.userID) { query.page = 1 }
        if !userFilterExplicit { query.userID = next?.userID }
        query.limit = limit
      }
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    } else if let limit = next?.api.rulesLength, query.limit != limit {
      query.limit = limit
      query.page = 1
      result = nil
      clearSelection()
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }
  }

  private func owns(_ owner: Account) -> Bool { account == owner && shell?.api === owner.api && Account(owner.api) == owner }

  private func stopRead(endRefresh: Bool = true) {
    readToken = UUID()
    read?.cancel(); read = nil
    if endRefresh { pullToRefresh.endRefreshing() }
  }

  private func reloadRules(quiet: Bool = false) {
    stopRead(endRefresh: false)
    guard let owner = account, displayed, owns(owner), owner.api.accountReady else {
      stopStatusUpdates()
      if let owner = account, !owner.api.accountReady, !owner.api.accountRevalidating { loadError = "アクティブユーザーの確認が必要です。" }
      pullToRefresh.endRefreshing()
      render()
      return
    }
    let token = readToken
    let headers = owner.api.profileHeaders
    statusNeedsRefresh = false
    statusRefresh?.cancel(); statusRefresh = nil
    statusUpdates.start(api: owner.api, port: shell?.serverConfig?.socketIOPort, events: ["updateStatus"]) { [weak self] in
      guard let self, displayed, owns(owner) else { return }
      statusNeedsRefresh = true
      scheduleStatusRefresh()
    }
    loadChannelNames(owner, headers: headers)
    read = Task { [weak self] in
      guard let self else { return }
      @MainActor func acceptsRead() -> Bool {
        !Task.isCancelled && readToken == token && owns(owner) && owner.api.accountReady
      }
      if viewers == nil {
        do {
          let names = try await owner.api.viewers().users.filter { $0.id > 0 }
          guard acceptsRead() else { return }
          viewers = names
          viewersFailed = false
          if let id = query.userID, !names.contains(where: { $0.id == id }) {
            userFilterExplicit = false
            query.userID = names.first(where: { $0.id == owner.userID })?.id ?? (owner.userID == nil ? nil : names.first?.id)
            query.page = 1
            result = nil
            clearSelection()
          }
        } catch {
          guard acceptsRead() else { return }
          viewersFailed = true
        }
        updateUsers()
      }
      let requested = query
      var renderResult = !quiet || result == nil || loadError != nil
      do {
        let list = try await owner.api.programRules(requested, user: owner.viewer, headers: headers)
        guard acceptsRead() else { return }
        let pages = requested.pageCount(total: list.total)
        if requested.page > pages {
          var next = requested
          next.page = pages
          applyQuery(next)
          return
        }
        renderResult = renderResult || result != list
        result = list
        selectedIDs.formIntersection(list.rules.map(\.id))
        loadError = nil
      } catch {
        guard acceptsRead() else { return }
        renderResult = renderResult || loadError != error.localizedDescription
        loadError = error.localizedDescription
      }
      read = nil
      pullToRefresh.endRefreshing()
      if renderResult { render() }
      scheduleStatusRefresh()
    }
    if !quiet || result == nil { render() }
  }

  private func scheduleStatusRefresh() {
    guard statusNeedsRefresh, statusRefresh == nil, displayed, read == nil, mutation == nil else { return }
    statusRefresh = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self, !Task.isCancelled else { return }
      statusRefresh = nil
      guard displayed, read == nil, mutation == nil else { return }
      reloadRules(quiet: true)
    }
  }

  private func stopStatusUpdates() {
    statusRefresh?.cancel(); statusRefresh = nil
    statusNeedsRefresh = false
    statusUpdates.stop()
  }

  private func loadChannelNames(_ owner: Account, headers: [String: String]) {
    guard channelNames == nil, channelRead == nil else { return }
    channelRead = Task { [weak self] in
      let channels = try? await owner.api.programSearchChannels(user: owner.viewer, headers: headers)
      guard let self, !Task.isCancelled, owns(owner) else { return }
      channelRead = nil
      guard let channels else { return }
      channelNames = Dictionary(channels.map { ($0.id, $0.name) }, uniquingKeysWith: { current, _ in current })
      table.reloadData()
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rules.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let card = tableView.dequeueReusableCell(withIdentifier: "rule", for: indexPath) as! NeoRuleCard
    let rule = rules[indexPath.row]
    let width = max(1, tableView.bounds.width)
    let inset = max(0, (width - 1100) / 2) + (width >= 900 ? 24 : 12)
    let item = NeoRuleCard.Content(id: rule.id, title: rule.listTitle, ignoredKeyword: rule.searchOption.ignoreKeyword,
      conditions: rule.listConditions(channelNames: channelNames ?? [:]), encodeSummary: rule.listEncodeSummary,
      enabled: rule.reserveOption.enable, reserveCount: rule.reservesCnt ?? 0, hasAnnict: rule.annictId != nil)
    card.configure(item, selecting: selecting, selected: selectedIDs.contains(rule.id),
      controlsEnabled: account?.api.accountReady == true && mutation == nil, tableWidth: width, sideInset: inset)
    let id = rule.id
    card.onSelect = { [weak self] in self?.toggleSelected(id) }
    card.onToggle = { [weak self] enabled in self?.setEnabled(id, enabled: enabled) }
    card.onMenu = { [weak self] anchor in self?.openMenu(id, anchor: anchor) }
    return card
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    if rules.indices.contains(indexPath.row) { toggleSelected(rules[indexPath.row].id) }
  }

  private func toggleSelected(_ id: Int) {
    guard selecting, mutation == nil, account?.api.accountReady == true, rules.contains(where: { $0.id == id }) else { return }
    if selectedIDs.remove(id) == nil { selectedIDs.insert(id) }
    render()
  }

  private func openMenu(_ id: Int, anchor: UIView) {
    guard !selecting, let rule = rules.first(where: { $0.id == id }), account?.api.accountReady == true else { return }
    view.endEditing(true)
    shell?.showPopup(anchor: anchor, entries: [
      .init(title: "録画済み", icon: "SearchOutlined") { [weak self] in self?.openRecordings(id) },
      .init(title: "編集", icon: "EditOutlined") { [weak self] in self?.openEditor(id) },
      .init(title: "削除", icon: "DeleteOutlineOutlined") { [weak self] in self?.confirmDeletion([rule], bulk: false) },
    ], appearance: .pageActions)
  }

  private func openEditor(_ id: Int? = nil) {
    guard let shell, let owner = account, owns(owner), owner.api.accountReady else { return }
    view.endEditing(true)
    shell.pushPage { NeoProgramSearchPage(shell: shell, ruleID: id) }
  }

  private func openRecordings(_ id: Int) {
    guard let shell, let owner = account, owns(owner), owner.api.accountReady else { return }
    var filters = NeoRecordedFilters()
    filters.ruleID = id
    let user = query.userID.map(String.init) ?? "master"
    shell.pushPage { NeoRecordedPage(shell: shell, filters: filters, viewerFilter: user) }
  }

  private func setEnabled(_ id: Int, enabled: Bool) {
    guard mutation == nil, let owner = account, owns(owner), owner.api.accountReady,
      let rule = rules.first(where: { $0.id == id }), rule.reserveOption.enable != enabled else { return }
    let headers = owner.api.profileHeaders
    mutation = Task { [weak self] in
      let label = enabled ? "有効" : "無効"
      do {
        let response = try await owner.api.setProgramRuleEnabled(id, enabled: enabled, user: owner.viewer, headers: headers)
        guard let self, !Task.isCancelled, owns(owner) else { return }
        if let warning = response.annictStatusError {
          shell?.recordingNotice("ルールは\(label)にしましたが、Annict視聴ステータスを更新できませんでした: \(warning)", warning: true)
        } else { shell?.recordingNotice("ルールを\(label)にしました") }
        refreshAfterMutation()
      } catch {
        guard let self, !Task.isCancelled, owns(owner) else { return }
        shell?.recordingNotice("ルールの変更に失敗しました: \(error.localizedDescription)", error: true)
        refreshAfterMutation()
      }
    }
    render()
  }

  private func confirmDeletion(_ targets: [NeoProgramRule], bulk: Bool) {
    guard !targets.isEmpty, mutation == nil, presentedViewController == nil, let owner = account, owns(owner), owner.api.accountReady else { return }
    view.endEditing(true)
    let requested = query
    let selection = selectionGeneration
    let dialog = NeoRuleDeleteDialog(ruleTitle: targets[0].listTitle, count: bulk ? targets.count : nil) { [weak self] in
      guard let self, owns(owner), query == requested, selectionGeneration == selection else { return }
      deleteRules(targets.map(\.id), bulk: bulk, owner: owner)
    }
    present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  private func deleteRules(_ ids: [Int], bulk: Bool, owner: Account) {
    guard mutation == nil, owns(owner), owner.api.accountReady else { return }
    let requested = query
    let selection = selectionGeneration
    let headers = owner.api.profileHeaders
    mutation = Task { [weak self] in
      var failed: [(Int, String)] = []
      var warnings: [String] = []
      for id in ids {
        guard let self, !Task.isCancelled, owns(owner) else { return }
        guard owner.api.accountReady else {
          failed.append((id, "アクティブユーザーの確認中です。"))
          continue
        }
        do {
          let response = try await owner.api.deleteProgramRule(id, user: owner.viewer, headers: headers)
          if let warning = response.annictLinkError { warnings.append(warning) }
        } catch { failed.append((id, error.localizedDescription)) }
      }
      guard let self, !Task.isCancelled, owns(owner) else { return }
      if bulk, selecting, query == requested, selectionGeneration == selection {
        selectedIDs = Set(failed.map(\.0)).intersection(rules.map(\.id))
        selecting = !selectedIDs.isEmpty
      }
      showDeletionResult(total: ids.count, failed: failed, warnings: warnings, bulk: bulk)
      if failed.count < ids.count { NotificationCenter.default.post(name: .neoRecordedChanged, object: owner.api) }
      refreshAfterMutation()
    }
    render()
  }

  private func showDeletionResult(total: Int, failed: [(Int, String)], warnings: [String], bulk: Bool) {
    if !bulk {
      if let failure = failed.first { shell?.recordingNotice("ルールの削除に失敗しました: \(failure.1)", error: true) }
      else if let warning = warnings.first { shell?.recordingNotice("ルールは削除しましたが、Annictとの関連付けを解除できませんでした: \(warning)", warning: true) }
      else { shell?.recordingNotice("ルールを削除しました") }
      return
    }
    var messages: [String] = []
    let succeeded = total - failed.count
    if succeeded > 0 { messages.append("\(succeeded)件のルールを削除しました") }
    if !warnings.isEmpty { messages.append("\(warnings.count)件のルールは削除しましたが、Annictとの関連付けを解除できませんでした") }
    if !failed.isEmpty {
      let detail = failed.prefix(3).map { "ID \($0.0): \($0.1)" }.joined(separator: " / ")
      messages.append("\(failed.count)件を削除できませんでした: \(detail)")
    }
    shell?.recordingNotice(messages.joined(separator: "\n"), error: !failed.isEmpty, warning: !warnings.isEmpty)
  }

  private func refreshAfterMutation() {
    mutation = nil
    if let api = account?.api { NotificationCenter.default.post(name: .neoAnnictChanged, object: api) }
    reloadRules()
  }

  deinit {
    read?.cancel(); channelRead?.cancel(); mutation?.cancel(); statusRefresh?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

#if targetEnvironment(simulator)
  var smokeRules: [NeoProgramRule] { rules }
  var smokeQuery: NeoRuleListQuery { query }
  var smokeSelecting: Bool { selecting }
  var smokeSelectedIDs: Set<Int> { selectedIDs }
  var smokeIdle: Bool { read == nil && mutation == nil }
#endif
}

private final class NeoRuleDeleteDialog: NeoLiveDialog {
  override var contentBackground: UIColor { .clear }
  override var contentHorizontalInset: CGFloat { 24 }

  init(ruleTitle: String, count: Int?, onConfirm: @escaping () -> Void) {
    super.init(title: count == nil ? "ルールを削除" : "選択したルールを削除")
    let summary = NeoStyle.label(count.map { "\($0)件のルールを削除します。" } ?? ruleTitle, size: 16)
    summary.numberOfLines = 0
    addView(summary)
    addText(count == nil ? "このルールを削除します。作成済みの予約も更新されます。"
      : "作成済みの予約も更新されます。この操作は取り消せません。")
    let cancel = addAction(count == nil ? "戻る" : "キャンセル") { [weak self] in self?.cancel() }
    cancel.layer.borderWidth = 0
    cancel.tintColor = NeoStyle.accent
    cancel.accessibilityIdentifier = "rules.cancelDelete"
    let confirm = addAction("削除", filled: true) { [weak self] in
      guard let self, !isBeingDismissed else { return }
      dismiss(animated: !UIAccessibility.isReduceMotionEnabled, completion: onConfirm)
    }
    confirm.backgroundColor = UIColor(red: 239/255, green: 83/255, blue: 80/255, alpha: 1)
    confirm.accessibilityIdentifier = "rules.confirmDelete"
  }

  required init?(coder: NSCoder) { fatalError() }
}
