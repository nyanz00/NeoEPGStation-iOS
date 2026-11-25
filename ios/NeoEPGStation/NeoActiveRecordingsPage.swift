import UIKit

final class NeoActiveRecordingsPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private enum Operation {
    case stop, delete
    var title: String { self == .stop ? "録画を停止しますか？" : "録画中のファイルを削除しますか？" }
    var button: String { self == .stop ? "録画停止" : "削除" }
    var completed: String { self == .stop ? "停止" : "削除" }

    func message(_ targets: [NeoRecording]) -> String {
      let target = targets.count == 1 ? "「\(targets[0].name)」" : "\(targets.count)件"
      switch self {
      case .stop: return "\(target)の録画を停止します。停止するまでに録画されたファイルは録画済みに残ります。予約も取り消されます。"
      case .delete: return "\(targets.count)件の録画ファイルを削除します。録画処理にも影響します。"
      }
    }
  }

  private let table = UITableView(frame: .zero, style: .plain), progress = UIActivityIndicatorView(style: .medium)
  private let message = NeoStyle.label(size: 14, muted: true), footer = NeoPaginationFooter()
  private let deferredUpdate = NeoDeferredScrollUpdate()
  private var records: [NeoRecording] = []
  private var listedDrops: [Int: NeoDropLog] = [:], liveDrops: [Int: NeoDropLog] = [:], dropStatus: [Int: NeoDropLog] = [:]
  private var page = 1, requestedPage = 1, pageCount = 1, pageLength = 24
  private var editingSelection = false, selected: Set<Int> = []
  private var visible = false, loaded = false, reloadPending = false
  private var session: NeoReservationSession?
  private var listTask: Task<Void, Never>?, dropsTask: Task<Void, Never>?, mutationTask: Task<Void, Never>?, statusTask: Task<Void, Never>?
  private var mobileHeader = true
  private weak var confirm: NeoLiveDialog?

  init(shell: NeoShell) { super.init(title: "録画中", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    super.loadView()
    table.backgroundColor = NeoStyle.background; table.separatorStyle = .none
    table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 116
    table.contentInset.top = 8; table.contentInset.bottom = 8
    table.contentInsetAdjustmentBehavior = .never
    table.dataSource = self; table.delegate = self
    table.register(NeoActiveRecordingCard.self, forCellReuseIdentifier: "recording")
    table.accessibilityIdentifier = "recording.list"
    footer.accessibilityIdentifier = "recording.pagination"
    table.delaysContentTouches = false
    message.textAlignment = .center; message.numberOfLines = 0
    [table, message, progress].forEach(body.addSubview)
    let notifications = NotificationCenter.default
    for name in [Notification.Name.neoAccountChanged, .neoTextPreferencesChanged, .neoActiveRecordingPreferencesChanged, .neoRecordedChanged, .neoRecordingPreferencesChanged] {
      notifications.addObserver(self, selector: #selector(dataChanged(_:)), name: name, object: nil)
    }
    notifications.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    notifications.addObserver(self, selector: #selector(foregrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
    updateHeader()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let width = min(1024, body.bounds.width)
    let frame = CGRect(x: (body.bounds.width - width) / 2, y: 0, width: width, height: body.bounds.height)
    if frame.width != table.frame.width {
      table.frame = frame
      updateFooter()
    } else { table.frame = frame }
    let mobile = frame.width < 600
    if mobile != mobileHeader {
      mobileHeader = mobile
      updateHeader()
    }
    message.frame = CGRect(x: 16, y: 24, width: max(0, body.bounds.width - 32), height: 88)
    progress.center = CGPoint(x: body.bounds.midX, y: 68)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    visible = true
    foregrounded()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    visible = false
    backgrounded()
  }

  @objc private func foregrounded() {
    guard visible else { return }
    reload()
    synchronizeDropPolling()
  }

  @objc private func backgrounded() {
    listTask?.cancel(); listTask = nil
    dropsTask?.cancel(); dropsTask = nil
    statusTask?.cancel(); statusTask = nil
    deferredUpdate.cancel()
    progress.stopAnimating()
  }

  @objc private func dataChanged(_ note: Notification) {
    guard let api = shell?.api, note.object as? NeoAPI === api else { return }
    switch note.name {
    case .neoAccountChanged:
      backgrounded()
      mutationTask?.cancel(); mutationTask = nil
      confirm?.dismiss(animated: false)
      session = nil; page = 1; requestedPage = 1; pageCount = 1
      records = []; listedDrops = [:]; liveDrops = [:]; dropStatus = [:]; selected = []; editingSelection = false
      loaded = false; message.text = nil
      table.reloadData(); updateFooter(); updateHeader()
    case .neoActiveRecordingPreferencesChanged:
      requestedPage = 1
      backgrounded()
    case .neoRecordingPreferencesChanged:
      updateFooter()
      return
    default:
      break
    }
    if visible { reload() }
  }

  func refreshOnServerStatus() {
    guard visible, statusTask == nil else { return }
    statusTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      statusTask = nil
      reload()
    }
  }

  private func reload() {
    guard visible, UIApplication.shared.applicationState != .background, let api = shell?.api, api.accountReady else { return }
    guard listTask == nil, mutationTask == nil else { reloadPending = true; return }
    reloadPending = false
    let context = NeoReservationSession(api), length = api.activeRecordingLength
    let target = requestedPage, halfWidth = api.isHalfWidthDisplayed
    session = context
    if !loaded { progress.startAnimating() }
    listTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if !Task.isCancelled {
          listTask = nil; progress.stopAnimating()
          if reloadPending { reload() }
        }
      }
      do {
        let result = try await api.activeRecordings(offset: (target - 1) * length, limit: length,
          halfWidth: halfWidth, user: context.viewer, headers: context.headers)
        try Task.checkCancellation()
        guard context.isCurrent(shell?.api), visible else { return }
        guard target == requestedPage, halfWidth == api.isHalfWidthDisplayed else { reloadPending = true; return }
        shell?.activeRecordingTotalChanged(result.total, session: context)
        let count = max(1, result.total / length + (result.total % length == 0 ? 0 : 1))
        if target > count {
          requestedPage = count; reloadPending = true
          return
        }
        let next = result.records.map { item in
          var row = item
          row.dropLogFile = nil
          return row
        }
        let fallback = result.records.reduce(into: [Int: NeoDropLog]()) { $0[$1.id] = $1.dropLogFile }
        if page == target, pageLength == length, pageCount == count, records == next {
          deferredUpdate.cancel()
          loaded = true; updateMessage()
          listedDrops = fallback
          setDropStatus(listedDrops.merging(liveDrops) { _, live in live })
          synchronizeDropPolling()
        } else {
          deferredUpdate.submit(in: table) { [weak self] in
            guard let self, visible, context.isCurrent(shell?.api), requestedPage == target,
              api.activeRecordingLength == length, api.isHalfWidthDisplayed == halfWidth else { return }
            let pageChanged = page != target || pageLength != length
            page = target; pageCount = count; pageLength = length
            loaded = true; records = next
            if pageChanged { editingSelection = false; selected = [] }
            let ids = Set(records.map(\.id))
            selected.formIntersection(ids)
            listedDrops = fallback
            liveDrops = liveDrops.filter { ids.contains($0.key) }
            dropStatus = listedDrops.merging(liveDrops) { _, live in live }
            table.reloadData()
            if pageChanged { table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false) }
            updateFooter(); updateHeader(); updateMessage(); synchronizeDropPolling()
          }
        }
      } catch {
        guard !Task.isCancelled, context.isCurrent(shell?.api), visible else { return }
        if !loaded { message.text = "録画中情報を取得できませんでした" }
      }
    }
  }

  private func synchronizeDropPolling() {
    guard visible, UIApplication.shared.applicationState != .background, !records.isEmpty,
      let context = session, context.isCurrent(shell?.api) else {
      dropsTask?.cancel(); dropsTask = nil
      return
    }
    guard dropsTask == nil else { return }
    dropsTask = Task { [weak self] in
      while !Task.isCancelled {
        if let result = try? await context.api.activeRecordingDrops(user: context.viewer, headers: context.headers),
          !Task.isCancelled {
          self?.applyDropValues(result, session: context)
        }
        guard self != nil else { return }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func applyDropValues(_ result: [NeoActiveRecordingDrop], session: NeoReservationSession) {
    guard visible, session.isCurrent(shell?.api) else { return }
    let ids = Set(records.map(\.id))
    liveDrops = result.reduce(into: [:]) { values, drop in
      if ids.contains(drop.recordedId) { values[drop.recordedId] = drop.dropLogFile }
    }
    setDropStatus(listedDrops.merging(liveDrops) { _, live in live })
  }

  private func setDropStatus(_ next: [Int: NeoDropLog]) {
    guard next != dropStatus else { return }
    let previous = dropStatus
    dropStatus = next
    for index in table.indexPathsForVisibleRows ?? [] where records.indices.contains(index.row) {
      let id = records[index.row].id
      if previous[id] != next[id] {
        (table.cellForRow(at: index) as? NeoActiveRecordingCard)?.updateDrop(next[id])
      }
    }
  }

  private func updateMessage() { message.text = records.isEmpty ? "録画中の番組はありません" : nil }

  private func updateFooter() {
    guard pageCount > 1 else { table.tableFooterView = nil; return }
    let mobile = (view.window?.bounds.width ?? view.bounds.width) < 600
    let extended = shell?.api?.extendedPagination == true
    footer.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 68)
    footer.configure(page: page, count: pageCount, mobile: mobile, extended: extended, jump: { [weak self] in
      guard let self else { return }
      present(NeoPageJumpDialog(page: page, count: pageCount) { [weak self] in self?.move(to: $0) }, animated: true)
    }) { [weak self] in self?.move(to: $0) }
    table.tableFooterView = footer
  }

  private func move(to target: Int) {
    guard mutationTask == nil, target != requestedPage, (1...pageCount).contains(target) else { return }
    requestedPage = target
    editingSelection = false; selected = []; updateSelection()
    reload()
  }

  private func updateHeader() {
    let busy = mutationTask != nil
    titleLabel.text = editingSelection ? "\(selected.count)件選択" : "録画中"
    func button(_ icon: String, _ label: String, _ key: String, enabled: Bool = true, action: @escaping () -> Void) -> UIButton {
      let item = NeoStyle.iconButton(icon, label: label, action: action)
      item.isEnabled = enabled && !busy
      item.accessibilityIdentifier = "recording." + key
      if !mobileHeader && editingSelection && key != "reload" {
        var configuration = UIButton.Configuration.plain()
        configuration.title = key == "exitSelection" ? "終了" : label
        if key == "bulkStop" || key == "bulkDelete" {
          configuration.image = NeoIcon.image(icon)
          configuration.imagePadding = 6
          configuration.baseForegroundColor = key == "bulkDelete" ? NeoStyle.error : UIColor(red: 1, green: 0.655, blue: 0.149, alpha: 1)
        } else {
          configuration.baseForegroundColor = NeoStyle.accent
        }
        item.configuration = configuration
      }
      return item
    }
    if editingSelection {
      let ids = Set(records.map(\.id))
      let allSelected = !ids.isEmpty && selected == ids
      let canDelete = records.contains { selected.contains($0.id) && !($0.videoFiles?.isEmpty ?? true) }
      actions = [
        button("SelectAllOutlined", allSelected ? "すべて解除" : "すべて選択", "selectAll", enabled: !ids.isEmpty) { [weak self] in
          self?.selected = allSelected ? [] : ids; self?.updateSelection()
        },
        button("StopCircleOutlined", "録画停止", "bulkStop", enabled: !selected.isEmpty) { [weak self] in
          guard let self else { return }; ask(.stop, ids: selected)
        },
        button("DeleteOutlineOutlined", "削除", "bulkDelete", enabled: canDelete) { [weak self] in
          guard let self else { return }; ask(.delete, ids: selected)
        },
        button("Close", "選択を終了", "exitSelection") { [weak self] in
          self?.editingSelection = false; self?.selected = []; self?.updateSelection()
        },
        button("RefreshOutlined", "更新", "reload") { [weak self] in self?.reload() },
      ]
    } else {
      actions = [
        button("EditOutlined", "選択", "select", enabled: !records.isEmpty) { [weak self] in
          self?.editingSelection = true; self?.updateSelection()
        },
        button("RefreshOutlined", "更新", "reload") { [weak self] in self?.reload() },
      ]
    }
  }

  override func width(forHeaderAction action: UIView) -> CGFloat {
    if mobileHeader && editingSelection && view.bounds.width < 375 { return 40 }
    guard !mobileHeader, editingSelection, action.accessibilityIdentifier != "recording.reload" else { return 44 }
    return min(180, max(62, action.sizeThatFits(CGSize(width: 180, height: 44)).width))
  }

  private func updateSelection() {
    updateHeader()
    for index in table.indexPathsForVisibleRows ?? [] where records.indices.contains(index.row) {
      let item = records[index.row]
      (table.cellForRow(at: index) as? NeoActiveRecordingCard)?.updateSelection(editing: editingSelection, selected: selected.contains(item.id))
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { records.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = records[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "recording", for: indexPath) as! NeoActiveRecordingCard
    let channel = item.channelId.flatMap { shell?.channels[$0] } ?? item.channelName ?? ""
    let logo = item.channelId.flatMap { shell?.api?.url("/channels/\($0)/logo") }
    cell.configure(item, channel: channel, logoURL: logo, api: shell?.api, editing: editingSelection, selected: selected.contains(item.id))
    cell.updateDrop(dropStatus[item.id])
    cell.onMenu = { [weak self] in self?.showMenu(item.id, anchor: $0) }
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    guard mutationTask == nil else { return }
    let item = records[indexPath.row]
    if editingSelection {
      if selected.remove(item.id) == nil { selected.insert(item.id) }
      updateSelection()
    } else {
      shell?.openDetail(item)
    }
  }

  private func showMenu(_ id: Int, anchor: UIView) {
    guard mutationTask == nil, let item = records.first(where: { $0.id == id }) else { return }
    showRecordingMenu(item, anchor: anchor, detail: false) { [weak self] in self?.ask(.stop, ids: [id]) }
  }

  private func ask(_ operation: Operation, ids: Set<Int>) {
    guard mutationTask == nil, presentedViewController == nil, let context = session, context.isCurrent(shell?.api) else { return }
    let targets = records.filter { ids.contains($0.id) }
    guard !targets.isEmpty else { return }
    let dialog = NeoLiveDialog(title: operation.title)
    dialog.addText(operation.message(targets))
    dialog.addAction("キャンセル") { [weak dialog] in dialog?.cancel() }
    let submit = dialog.addAction(operation.button, filled: true) { [weak self, weak dialog] in
      dialog?.dismiss(animated: true) { [weak self] in self?.perform(operation, ids: ids, session: context) }
    }
    submit.accessibilityIdentifier = "recording.confirm"
    submit.backgroundColor = operation == .stop ? UIColor(red: 1, green: 0.655, blue: 0.149, alpha: 1) : NeoStyle.error
    submit.tintColor = operation == .stop ? .black : .white
    confirm = dialog
    present(dialog, animated: true)
  }

  private func perform(_ operation: Operation, ids: Set<Int>, session: NeoReservationSession) {
    guard visible, mutationTask == nil, session.isCurrent(shell?.api) else { return }
    let targets = records.filter { ids.contains($0.id) }
    guard !targets.isEmpty else { return }
    let api = session.api
    listTask?.cancel(); listTask = nil; deferredUpdate.cancel()
    mutationTask = Task { [weak self] in
      var failures: [(NeoRecording, Error)] = []
      var changed: Set<Int> = []
      for item in targets {
        guard !Task.isCancelled, let self, session.isCurrent(shell?.api) else { return }
        do {
          switch operation {
          case .stop:
            try await api.stopActiveRecording(item.id, user: session.viewer, headers: session.headers)
            changed.insert(item.id)
          case .delete:
            let latest = try await api.recording(item.id, refresh: true)
            guard let files = latest.videoFiles, !files.isEmpty else { throw NeoError("削除できる録画ファイルがありません") }
            for file in files {
              try Task.checkCancellation()
              guard session.isCurrent(shell?.api) else { return }
              try await api.deleteRecordingVideo(file.id, user: session.viewer, headers: session.headers)
              changed.insert(item.id)
              // The server promotes deletion of an in-progress file to removal of the entire recording.
              if latest.isRecording { break }
            }
          }
        } catch { failures.append((item, error)) }
      }
      guard !Task.isCancelled, let self, session.isCurrent(shell?.api) else { return }
      for id in changed { api.recordingChanged(id) }
      if !changed.isEmpty { NotificationCenter.default.post(name: .neoReservationsChanged, object: api) }
      selected = Set(failures.map { $0.0.id }); editingSelection = !selected.isEmpty
      mutationTask = nil; updateSelection(); reload()
      let count = targets.count - failures.count
      var result: [String] = []
      if count > 0 {
        result.append("\(count)件の録画を\(operation.completed)しました。" + (operation == .stop ? "録画済みの部分は保存されます。" : ""))
      }
      if !failures.isEmpty {
        let detail = failures.prefix(3).map { "\($0.0.name): \($0.1.localizedDescription)" }.joined(separator: " / ")
        result.append("\(failures.count)件を\(operation.completed)できませんでした。\n\(detail)")
      }
      if visible { shell?.recordingNotice(result.joined(separator: "\n"), error: !failures.isEmpty) }
    }
    updateHeader()
  }

  deinit { listTask?.cancel(); dropsTask?.cancel(); mutationTask?.cancel(); statusTask?.cancel() }
}
