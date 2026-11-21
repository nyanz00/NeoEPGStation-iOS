import UIKit

final class NeoEncodePage: NeoPage, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate {
  private enum Group: Int { case running, waiting, scheduled, recovery
    var title: String { ["エンコード中","待機中","エンコード予約","要確認"][rawValue] }
  }
  private struct HeaderState: Equatable {
    let mobile: Bool, busy: Bool, reordering: Bool, selecting: Bool
    let selectionCount: Int, allSelected: Bool, hasItems: Bool, canReorder: Bool, canSave: Bool
  }
  private let table = UITableView(frame:.zero,style:.plain), refresh = UIRefreshControl()
  private let message = NeoStyle.label(size:14,muted:true), spinner = UIActivityIndicatorView(style:.medium)
  private var info = NeoEncodeInfo.empty, groups: [Group] = [], editingSelection = false, reordering = false
  private var selected = Set<Int>(), orderedIDs: [Int] = [], expectedIDs: [Int] = []
  private var task: Task<Void,Never>?, mutation: Task<Void,Never>?, observers: [NSObjectProtocol] = []
  private let updates = NeoServerStatusUpdates()
  private let scrollUpdate = NeoDeferredScrollUpdate()
  private var latestInfo: NeoEncodeInfo = .empty
  private var updatesTask: Task<Void,Never>?, channelTask: Task<Void,Never>?
  private var needsReload = false, renderedRows: [[Int]] = [], channelError = false
  private var didFinishInitialRead = false
  private var channelAttempt = UUID()
  private var socketConnected = false
  private var revision: Int?, requestID = UUID(), visible = false
  private var mutationID = UUID(), headerState: HeaderState?, layoutWidth: CGFloat = 0
  private var confirm: NeoEncodeConfirm?
  private var mobile: Bool { (view.window?.bounds.width ?? view.bounds.width) < 600 }
  private var queueChanged: Bool { reordering && info.waitItems.map(\.id) != expectedIDs }
  init(shell: NeoShell) { super.init(title:"エンコード",shell:shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    super.loadView(); table.backgroundColor = NeoStyle.background; table.separatorStyle = .none
    table.dataSource = self; table.delegate = self; table.dragDelegate = self; table.dropDelegate = self
    table.register(NeoEncodeCard.self,forCellReuseIdentifier:"encode"); table.register(NeoEncodeRecoveryCell.self,forCellReuseIdentifier:"recovery")
    table.refreshControl = refresh; refresh.addAction(UIAction { [weak self] _ in self?.reload(); self?.loadChannels() },for:.valueChanged)
    body.addSubview(table); body.addSubview(message); body.addSubview(spinner); message.numberOfLines = 0; message.textAlignment = .center
    for name in [Notification.Name.neoEncodeChanged,.neoTextPreferencesChanged] {
      observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
        guard let self, self.visible else { return }; self.reload()
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName:.neoAccountChanged,object:nil,queue:.main) { [weak self] _ in self?.accountChanged() })
    observers.append(NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
      guard let self, self.visible else { return }; self.reload(); self.startUpdates(); self.loadChannels()
    })
    observers.append(NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
      self?.stopUpdates()
    })
    updateHeader()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); let width = min(900,body.bounds.width)
    table.frame = CGRect(x:(body.bounds.width-width)/2,y:0,width:width,height:body.bounds.height)
    message.frame = CGRect(x:16,y:40,width:max(0,body.bounds.width-32),height:140); spinner.center = CGPoint(x:body.bounds.midX,y:80)
    if headerState?.mobile != mobile { updateHeader() }
    layoutEncodeActions()
    if layoutWidth != width { layoutWidth = width; table.reloadData() }
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated); visible = true; reload()
    startUpdates(); loadChannels()
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated); visible = false; stopUpdates(); task?.cancel(); task = nil
    channelAttempt = UUID(); channelTask?.cancel(); channelTask = nil
  }
  private func startUpdates() {
    guard visible, UIApplication.shared.applicationState != .background, updatesTask == nil, let api = shell?.api else { return }
    updatesTask = Task { [weak self] in
      guard let self else { return }
      var config = shell?.serverConfig
      if config == nil { config = try? await api.configuration() }
      guard !Task.isCancelled, visible, shell?.api === api else { return }
      updates.start(api:api,port:config?.socketIOPort,connectionChanged:{ [weak self] in self?.socketConnected = $0 }) { [weak self] in self?.reload() }
    }
  }
  private func stopUpdates() {
    scrollUpdate.cancel()
    updatesTask?.cancel(); updatesTask = nil; updates.stop(); socketConnected = false
  }
  private func loadChannels() {
    guard channelTask == nil, let api = shell?.api else { return }
    let attempt = UUID(); channelAttempt = attempt
    channelTask = Task { [weak self] in
      guard let self else { return }; defer { if channelAttempt == attempt { channelTask = nil } }
      do {
        let channels = try await api.channels(); try Task.checkCancellation()
        guard shell?.api === api else { return }
        shell?.cacheChannels(channels)
        channelError = false; render(inPlace:true)
      } catch {
        guard !Task.isCancelled, shell?.api === api else { return }; channelError = true; render(inPlace:true)
      }
    }
  }
  private func accountChanged() {
    guard let api = shell?.api else { return }
    guard revision != api.identityRevision else { if visible { reload() }; return }
    scrollUpdate.cancel(); latestInfo = .empty
    requestID = UUID(); mutationID = UUID(); task?.cancel(); task = nil; mutation?.cancel(); mutation = nil
    confirm?.dismiss(animated:false); confirm = nil; info = .empty; selected = []; reordering = false; editingSelection = false
    didFinishInitialRead = false; message.text = nil; spinner.stopAnimating()
    revision = api.identityRevision; render(); if visible { reload() }
  }
  func reload() {
    guard UIApplication.shared.applicationState != .background,
      let api = shell?.api, api.accountReady else { refresh.endRefreshing(); return }
    guard task == nil, mutation == nil else { needsReload = true; return }
    needsReload = false
    let user = api.viewer, headers = api.profileHeaders, capturedRevision = api.identityRevision, halfWidth = api.isHalfWidthDisplayed
    revision = capturedRevision; let attempt = UUID(); requestID = attempt
    if !didFinishInitialRead { spinner.startAnimating() }
    task = Task { [weak self] in
      guard let self else { return }
      defer { if requestID == attempt {
        task = nil; spinner.stopAnimating()
        if refresh.isRefreshing { refresh.endRefreshing() }
        if needsReload && visible { reload() }
      } }
      do {
        let value = try await api.encodes(user:user,headers:headers); try Task.checkCancellation()
        guard UIApplication.shared.applicationState != .background,
          shell?.api === api, api.identityRevision == capturedRevision, api.profileHeaders == headers,
          api.isHalfWidthDisplayed == halfWidth, requestID == attempt else { return }
        didFinishInitialRead = true
        let old = Set(latestInfo.allItems.map { $0.recorded.id }), new = Set(value.allItems.map { $0.recorded.id })
        latestInfo = value
        for id in old.symmetricDifference(new) { api.recordingChanged(id) }
        if info.hasSameRows(as: value) {
          scrollUpdate.cancel()
          applyQueue(value)
        } else if scrollUpdate.submit(in: table, { [weak self, weak api] in
          guard let self, let api, visible, shell?.api === api, api.identityRevision == capturedRevision,
            api.accountReady, api.profileHeaders == headers, api.isHalfWidthDisplayed == halfWidth else { return }
          applyQueue(value)
        }) {
          // Keep displaying updates for jobs that are still running while
          // the table continues to use the current section and row counts.
          let running = Dictionary(value.runningItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
          let current = info.runningItems.map { running[$0.id] ?? $0 }
          applyQueue(NeoEncodeInfo(runningItems: current, waitItems: info.waitItems,
            scheduledItems: info.scheduledItems, recoveryItems: info.recoveryItems))
        }
      } catch {
        guard !Task.isCancelled, requestID == attempt, shell?.api === api, api.identityRevision == capturedRevision,
          api.profileHeaders == headers, api.isHalfWidthDisplayed == halfWidth else { return }
        didFinishInitialRead = true
        if groups.isEmpty {
          message.text = "エンコード情報を取得できませんでした"
          message.isHidden = false
        }
      }
    }
  }
  private func applyQueue(_ value: NeoEncodeInfo) {
    let previous = info
    info = value
    selected.formIntersection(Set(value.allItems.map(\.id)))
    if !reordering { orderedIDs = value.waitItems.map(\.id) }
    render(inPlace: previous.hasSameRows(as: value), previous: previous)
  }
  private func items(_ group: Group) -> [NeoEncodeItem] {
    switch group {
    case .running: return info.runningItems
    case .waiting:
      if reordering { return orderedIDs.compactMap { id in info.waitItems.first { $0.id == id } } }
      return info.waitItems
    case .scheduled: return info.scheduledItems
    case .recovery: return []
    }
  }
  private func render(inPlace: Bool = false, previous: NeoEncodeInfo? = nil) {
    let previousGroups = groups
    groups = [Group.running,.waiting,.scheduled,.recovery].filter { $0 == .recovery ? !info.recoveryItems.isEmpty : !items($0).isEmpty }
    let rows = groups.map { $0 == .recovery ? info.recoveryItems.map(\.id) : items($0).map(\.id) }
    let emptyText = "実行中、待機中、または開始予約中のエンコードはありません"
    let notice = didFinishInitialRead && groups.isEmpty ? emptyText : nil
    if previous != nil || message.text == nil || message.text == emptyText {
      if message.text != notice { message.text = notice }
    }
    let warningText = queueChanged ? "編集中に待機キューが更新されました。キャンセルして最新の順番からやり直してください。"
      : channelError && !info.allItems.isEmpty ? "放送局情報を取得できないため、放送局IDで表示しています。" : nil
    let hideMessage = warningText != nil || message.text == nil
    if message.isHidden != hideMessage { message.isHidden = hideMessage }
    if let warningText {
      if let warning = table.tableHeaderView as? UILabel {
        if warning.text != warningText { warning.text = warningText }
      } else {
        let warning = NeoStyle.label(warningText,size:14); warning.numberOfLines = 0; warning.textColor = NeoStyle.warning
        warning.frame = CGRect(x:12,y:0,width:max(0,table.bounds.width-24),height:70); table.tableHeaderView = warning
      }
    } else if table.tableHeaderView != nil {
      table.tableHeaderView = nil
    }
    if inPlace, previousGroups == groups, renderedRows == rows {
      let disabled = mutation != nil
      let oldItems = Dictionary((previous?.allItems ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for path in table.indexPathsForVisibleRows ?? [] {
        if let cell = table.cellForRow(at:path) as? NeoEncodeCard {
          let item = items(groups[path.section])[path.row]
          if let old = oldItems[item.id], item.hasSameCardDetails(as: old), cell.controlsDisabled == disabled {
            if item.percent != old.percent || item.log != old.log { cell.updateProgressAndLog(item) }
          } else {
            configure(cell,at:path)
          }
        } else if let cell = table.cellForRow(at:path) as? NeoEncodeRecoveryCell,
          previous == nil || cell.controlsDisabled != disabled {
          cell.configure(info.recoveryItems[path.row],disabled:disabled)
        }
      }
    } else { table.reloadData() }
    renderedRows = rows; updateHeader()
  }
  private func updateHeader() {
    let busy = mutation != nil, all = Set(info.allItems.map(\.id)), allSelected = !all.isEmpty && selected == all
    let state = HeaderState(mobile: mobile, busy: busy, reordering: reordering, selecting: editingSelection,
      selectionCount: selected.count, allSelected: allSelected, hasItems: !all.isEmpty,
      canReorder: !reordering && info.waitItems.count >= 2,
      canSave: reordering && info.canSaveOrder(orderedIDs,expected:expectedIDs))
    guard headerState != state else { return }
    headerState = state
    titleLabel.text = editingSelection ? "\(state.selectionCount)件選択" : "エンコード"
    func icon(_ name:String,_ label:String,_ enabled:Bool = true,_ action:@escaping ()->Void) -> UIButton {
      let value = NeoStyle.iconButton(name,label:label,action:action); value.isEnabled = enabled && !busy; return value
    }
    func action(_ name:String,_ label:String,_ enabled:Bool = true,_ action:@escaping ()->Void) -> UIButton {
      if mobile { return icon(name,label,enabled,action) }
      let value = NeoStyle.button(label,action:action); value.setImage(NeoIcon.image(name),for:.normal)
      value.accessibilityIdentifier = "encode-wide-action"; value.accessibilityLabel = label
      var configuration = UIButton.Configuration.plain(); configuration.title = label; configuration.image = NeoIcon.image(name)
      configuration.imagePadding = 8; configuration.contentInsets = NSDirectionalEdgeInsets(top:6,leading:8,bottom:6,trailing:8)
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { original in var result = original; result.font = .systemFont(ofSize:14,weight:.medium); return result }
      value.configuration = configuration; value.isEnabled = enabled && !busy; return value
    }
    var values: [UIView] = []
    if reordering {
      values = [action("SaveOutlined","順番を保存",info.canSaveOrder(orderedIDs,expected:expectedIDs)) { [weak self] in self?.saveOrder() },
        action("Close","並べ替えをキャンセル") { [weak self] in self?.reordering = false; self?.render() }]
    } else if editingSelection {
      values = [action("SelectAllOutlined",allSelected ? "すべて解除" : "すべて選択") { [weak self] in
        guard let self else { return }
        let current = Set(info.allItems.map(\.id))
        selected = selected == current ? [] : current
        render()
      },
        action("CancelOutlined","キャンセル",!selected.isEmpty) { [weak self] in guard let self else { return }; self.askCancel(Array(self.selected)) },
        action("Close","選択を終了") { [weak self] in self?.editingSelection = false; self?.selected = []; self?.render() }]
    } else {
      values = [action("SwapVertOutlined","並べ替え",info.waitItems.count >= 2) { [weak self] in
        guard let self else { return }; self.expectedIDs = self.info.waitItems.map(\.id); self.orderedIDs = self.expectedIDs; self.reordering = true; self.render()
      }, icon("EditOutlined","選択",!all.isEmpty) { [weak self] in self?.editingSelection = true; self?.render() }]
    }
    values.append(icon("RefreshOutlined","更新") { [weak self] in self?.reload(); self?.loadChannels() })
    actions = values; table.dragInteractionEnabled = reordering && !mobile && !busy
  }
  private func toggle(_ id:Int) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }; render() }
  private func layoutEncodeActions() {
    guard !mobile else { return }
    var right = view.bounds.width-4
    for action in actions.reversed() {
      let desired = action.accessibilityIdentifier == "encode-wide-action" ? max(90,action.sizeThatFits(CGSize(width:220,height:44)).width) : 44
      let width = min(220,desired); right -= width; action.frame = CGRect(x:right,y:6,width:width,height:44)
    }
    titleLabel.frame.size.width = max(0,right-titleLabel.frame.minX-4)
  }
  private func move(_ id:Int,to index:Int) {
    guard reordering, !queueChanged, mutation == nil, orderedIDs.indices.contains(index), let old = orderedIDs.firstIndex(of:id) else { return }
    orderedIDs.remove(at:old); orderedIDs.insert(id,at:index); render()
  }
  private func askCancel(_ ids:[Int], recovery: NeoEncodeRecovery? = nil) {
    guard mutation == nil, presentedViewController == nil else { return }
    let targets = recovery.map { [$0.id] } ?? info.cancellationOrder(ids)
    guard !targets.isEmpty else { return }
    let single = info.allItems.first { targets.count == 1 && $0.id == targets[0] }
    let text = recovery.map { "\($0.recorded?.name ?? "番組情報が見つからないタスク")をキューから削除します。" }
      ?? single.map { "［\($0.mode)］\($0.recorded.name)を停止しますか？" } ?? "\(targets.count)件のエンコードをキャンセルします。"
    let dialog = NeoEncodeConfirm(title:recovery == nil ? "エンコードをキャンセルしますか？" : "要確認タスクを削除しますか？",text:text,
      submit:recovery == nil ? "キャンセル実行" : "削除")
    dialog.onSubmit = { [weak self] in self?.cancelItems(targets,recovery:recovery != nil) }
    confirm = dialog; present(dialog,animated:true)
  }
  private func cancelItems(_ ids:[Int],recovery:Bool) {
    guard mutation == nil, let api = shell?.api, api.accountReady else { return }
    let ids = recovery ? ids.filter { id in info.recoveryItems.contains { $0.id == id } } : info.cancellationOrder(ids)
    guard !ids.isEmpty else { confirm?.cancel(); return }
    let rev = api.identityRevision, user = api.viewer, headers = api.profileHeaders
    let attempt = beginMutation()
    confirm?.setBusy(true,completed:0,total:ids.count)
    mutation = Task { [weak self] in
      guard let self else { return }; var failed = Set<Int>(), details:[String] = [], done = 0
      defer { if mutationID == attempt { mutation = nil; updateHeader(); if visible { reload() } } }
      for id in ids {
        guard !Task.isCancelled, shell?.api === api, api.identityRevision == rev, api.accountReady else { return }
        do { try await api.cancelEncode(id,user:user,headers:headers) }
        catch { failed.insert(id); if details.count < 3 { details.append("ID \(id): \(error.localizedDescription)") } }
        guard !Task.isCancelled, shell?.api === api, api.identityRevision == rev else { return }
        done += 1; confirm?.setBusy(true,completed:done,total:ids.count)
      }
      if recovery, !failed.isEmpty { confirm?.setError("要確認タスクを削除できませんでした: " + details.joined(separator:" / ")) }
      else { confirm?.dismiss(animated:true); confirm = nil }
      if !recovery { selected = failed; editingSelection = editingSelection && !failed.isEmpty }
      let notice = failed.isEmpty ? (recovery ? "要確認のエンコードタスクを削除しました" : "\(ids.count)件のエンコードをキャンセルしました") : "\(ids.count-failed.count)件をキャンセルし、\(failed.count)件に失敗しました: " + details.joined(separator:" / ")
      shell?.recordingNotice(notice,error:!failed.isEmpty)
      info.allItems.filter { ids.contains($0.id) }.forEach { api.recordingChanged($0.recorded.id) }
      NotificationCenter.default.post(name:.neoEncodeChanged,object:api); render()
    }
  }
  private func retry(_ item:NeoEncodeRecovery) {
    guard mutation == nil, item.canRetry, let api = shell?.api, api.accountReady else { return }
    let rev = api.identityRevision, user = api.viewer, headers = api.profileHeaders
    let attempt = beginMutation()
    mutation = Task { [weak self] in
      guard let self else { return }; defer { if mutationID == attempt { mutation = nil; if visible { reload() } } }
      do { try await api.retryEncode(item.id,user:user,headers:headers); try Task.checkCancellation()
        guard shell?.api === api, api.identityRevision == rev else { return }; shell?.recordingNotice("エンコードを再開しました")
      } catch { if !Task.isCancelled, api.identityRevision == rev { shell?.recordingNotice("エンコードを再開できませんでした: " + error.localizedDescription,error:true) } }
    }; updateHeader(); table.reloadData()
  }
  private func saveOrder() {
    guard mutation == nil, latestInfo.canSaveOrder(orderedIDs,expected:expectedIDs), let api = shell?.api, api.accountReady else { return }
    let ids = orderedIDs, expected = expectedIDs, rev = api.identityRevision, user = api.viewer, headers = api.profileHeaders
    let attempt = beginMutation()
    mutation = Task { [weak self] in
      guard let self else { return }; defer { if mutationID == attempt { mutation = nil; if visible { reload() } } }
      do { try await api.reorderEncodes(ids,expected:expected,user:user,headers:headers); try Task.checkCancellation()
        guard shell?.api === api, api.identityRevision == rev else { return }; shell?.recordingNotice("待機中エンコードの順番を変更しました")
      } catch { guard !Task.isCancelled, api.identityRevision == rev else { return }
        let text = (error as? NeoError)?.message == "EncodeQueueChangedError" ? "編集中にエンコードキューが更新されました。最新の順番を読み込み直しました。" : "エンコードの並べ替えに失敗しました: " + error.localizedDescription
        shell?.recordingNotice(text,error:true)
      }
      reordering = false; render()
    }; updateHeader()
  }
  private func beginMutation() -> UUID {
    scrollUpdate.cancel()
    requestID = UUID(); task?.cancel(); task = nil; spinner.stopAnimating(); refresh.endRefreshing()
    mutationID = UUID(); return mutationID
  }
  func numberOfSections(in tableView:UITableView)->Int { groups.count }
  func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int { groups[section] == .recovery ? info.recoveryItems.count : items(groups[section]).count }
  func tableView(_ tableView:UITableView,heightForHeaderInSection section:Int)->CGFloat { 48 }
  func tableView(_ tableView:UITableView,viewForHeaderInSection section:Int)->UIView? {
    let header = UIView(); header.backgroundColor = NeoStyle.background
    let label = NeoStyle.label(groups[section].title,size:20); label.font = .systemFont(ofSize:20,weight:.medium)
    label.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(label)
    NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:12),label.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-12),label.topAnchor.constraint(equalTo:header.topAnchor,constant:8),label.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-8)])
    return header
  }
  func tableView(_ tableView:UITableView,heightForRowAt indexPath:IndexPath)->CGFloat {
    if groups[indexPath.section] == .recovery { return UITableView.automaticDimension }
    return NeoEncodeCard.height(width:table.bounds.width,mobile:mobile,waiting:groups[indexPath.section] != .running,editing:editingSelection)
  }
  func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell {
    let group = groups[indexPath.section]
    if group == .recovery {
      let item = info.recoveryItems[indexPath.row], cell = table.dequeueReusableCell(withIdentifier:"recovery",for:indexPath) as! NeoEncodeRecoveryCell
      cell.configure(item,disabled:mutation != nil); cell.onRetry = { [weak self] in self?.retry(item) }; cell.onDelete = { [weak self] in self?.askCancel([item.id],recovery:item) }; return cell
    }
    let cell = table.dequeueReusableCell(withIdentifier:"encode",for:indexPath) as! NeoEncodeCard
    configure(cell,at:indexPath); return cell
  }
  private func configure(_ cell:NeoEncodeCard,at indexPath:IndexPath) {
    let group = groups[indexPath.section], values = items(group), item = values[indexPath.row]
    if let shell { cell.configure(item,shell:shell,mobile:mobile,waiting:group != .running,editing:editingSelection,reordering:reordering && group == .waiting,
      selected:selected.contains(item.id),canMoveUp:indexPath.row > 0 && !queueChanged,canMoveDown:indexPath.row+1 < values.count && !queueChanged,disabled:mutation != nil) }
    cell.onSelect = { [weak self] in self?.toggle(item.id) }; cell.onCancel = { [weak self] in self?.askCancel([item.id]) }
    cell.onMoveUp = { [weak self] in self?.move(item.id,to:indexPath.row-1) }; cell.onMoveDown = { [weak self] in self?.move(item.id,to:indexPath.row+1) }
  }
  func tableView(_ tableView:UITableView,itemsForBeginning session:UIDragSession,at indexPath:IndexPath)->[UIDragItem] {
    guard reordering, !queueChanged, groups[indexPath.section] == .waiting else { return [] }
    let id = items(.waiting)[indexPath.row].id, item = UIDragItem(itemProvider:NSItemProvider(object:String(id) as NSString)); item.localObject = id; return [item]
  }
  func tableView(_ tableView:UITableView,dropSessionDidUpdate session:UIDropSession,withDestinationIndexPath path:IndexPath?)->UITableViewDropProposal {
    UITableViewDropProposal(operation:reordering && !queueChanged && session.localDragSession != nil && path.map { groups.indices.contains($0.section) && groups[$0.section] == .waiting } == true ? .move : .forbidden,intent:.insertAtDestinationIndexPath)
  }
  func tableView(_ tableView:UITableView,performDropWith coordinator:UITableViewDropCoordinator) {
    guard let path = coordinator.destinationIndexPath, groups.indices.contains(path.section), groups[path.section] == .waiting,
      let id = coordinator.items.first?.dragItem.localObject as? Int else { return }; move(id,to:min(orderedIDs.count-1,path.row))
  }
#if targetEnvironment(simulator)
  func smokeSetScrolling(_ value: Bool) { scrollUpdate.smokeScrolling = value }
  func smokeRecoveryControlsEnabled(_ id: Int, reveal: Bool = false) -> Bool {
    guard let section = groups.firstIndex(of: .recovery),
      let row = info.recoveryItems.firstIndex(where: { $0.id == id }) else { return false }
    let path = IndexPath(row: row, section: section)
    if reveal {
      table.layoutIfNeeded()
      table.scrollToRow(at: path, at: .middle, animated: false)
      table.layoutIfNeeded()
    }
    return (table.cellForRow(at: path) as? NeoEncodeRecoveryCell)?.controlsDisabled == false
  }
  var smokeInfo: NeoEncodeInfo { info }
  var smokeCards: [NeoEncodeCard] { table.visibleCells.compactMap { $0 as? NeoEncodeCard } }
  var smokeSocketConnected: Bool { socketConnected }
  var smokeReadIdle: Bool { task == nil && !needsReload }
  var smokeCentralSpinnerAnimating: Bool { spinner.isAnimating }
  var smokeQueueMessage: String? { message.isHidden ? nil : message.text }
  func smokeLayoutCards() { view.layoutIfNeeded(); table.layoutIfNeeded(); smokeCards.forEach { $0.layoutIfNeeded(); $0.smokeTitle.layoutIfNeeded() } }
  var smokeSelected: Set<Int> { selected }
  var smokeOrder: [Int] { orderedIDs }
  var smokeConflict: Bool { queueChanged }
  var smokeBusy: Bool { mutation != nil }
  var smokeHeaderLabelsFit: Bool { actions.filter { $0.accessibilityIdentifier == "encode-wide-action" }.allSatisfy { $0.bounds.width+1 >= $0.sizeThatFits(CGSize(width:220,height:44)).width } }
  var smokeConfirm: NeoEncodeConfirm? { confirm }
  func smokeSelect(_ id:Int) { editingSelection = true; toggle(id) }
  func smokeBeginOrder() { expectedIDs = info.waitItems.map(\.id); orderedIDs = expectedIDs; reordering = true; render() }
  func smokeMove(_ id:Int,to index:Int) { move(id,to:index) }
  func smokeSaveOrder() { saveOrder() }
  func smokeAskCancel(_ ids:[Int]) { askCancel(ids) }
  func smokeAskRecoveryDelete(_ id:Int) { if let item = info.recoveryItems.first(where:{$0.id == id}) { askCancel([id],recovery:item) } }
  func smokeRetry(_ id:Int) { if let item = info.recoveryItems.first(where:{$0.id == id}) { retry(item) } }
#endif
  deinit { task?.cancel(); mutation?.cancel(); updatesTask?.cancel(); channelTask?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}

extension NeoStyle {
  static var error: UIColor { UIColor(red:244/255,green:67/255,blue:54/255,alpha:1) }
  static var warning: UIColor { UIColor(red:255/255,green:226/255,blue:183/255,alpha:1) }
}

final class NeoEncodeConfirm: NeoLiveDialog {
  private var busy = false
  private let text = NeoStyle.label(size:16), progress = UIProgressView(progressViewStyle:.default)
  private var submitButton:UIButton?, cancelButton:UIButton?
  var onSubmit:(()->Void)?
  override var maximumWidth:CGFloat { 600 }
  init(title:String,text:String,submit:String) {
    super.init(title:title); self.text.text = text; self.text.numberOfLines = 0; addView(self.text)
    progress.isHidden = true; addView(progress)
    cancelButton = addAction("閉じる") { [weak self] in self?.cancel() }
    submitButton = addAction(submit,filled:true) { [weak self] in guard let self, !self.busy else { return }; self.onSubmit?() }
    submitButton?.backgroundColor = NeoStyle.error; submitButton?.tintColor = .white
  }
  required init?(coder:NSCoder) { fatalError() }
  func setBusy(_ value:Bool,completed:Int,total:Int) {
    busy = value; text.text = "キャンセル処理中：\(completed) / \(total)件"; progress.isHidden = !value
    progress.progress = Float(completed)/Float(max(1,total)); submitButton?.isEnabled = !value; cancelButton?.isEnabled = !value
  }
  func setError(_ message:String) { busy = false; text.text = message; progress.isHidden = true; submitButton?.isEnabled = true; cancelButton?.isEnabled = true }
  override func cancel() { if !busy { super.cancel() } }
#if targetEnvironment(simulator)
  func smokeSubmit() { submitButton?.sendActions(for:.touchUpInside) }
#endif
}

private final class NeoEncodeRecoveryCell:UITableViewCell {
  private let stack = UIStackView(), title = NeoStyle.label(size:16,bold:true), mode = NeoStyle.label(size:14,muted:true), reason = NeoStyle.label(size:14)
  private let reasonSurface = UIStackView(), reasonIcon = UIImageView()
  private let retry = UIButton(type:.system), remove = UIButton(type:.system)
  var onRetry:(()->Void)?, onDelete:(()->Void)?
  override init(style:UITableViewCell.CellStyle,reuseIdentifier:String?) {
    super.init(style:style,reuseIdentifier:reuseIdentifier); backgroundColor = NeoStyle.background; selectionStyle = .none
    let card = UIView(); card.backgroundColor = NeoStyle.paper; card.layer.cornerRadius = 4; card.layer.borderWidth = 1; card.layer.borderColor = NeoStyle.border.cgColor
    contentView.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
    NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo:contentView.leadingAnchor,constant:12),card.trailingAnchor.constraint(equalTo:contentView.trailingAnchor,constant:-12),card.topAnchor.constraint(equalTo:contentView.topAnchor,constant:5),card.bottomAnchor.constraint(equalTo:contentView.bottomAnchor,constant:-5),stack.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo:card.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-12)])
    stack.axis = .vertical; stack.spacing = 8; [title,mode].forEach { $0.numberOfLines = 0; stack.addArrangedSubview($0) }
    reason.numberOfLines = 0; reasonSurface.axis = .horizontal; reasonSurface.spacing = 12; reasonSurface.alignment = .center
    reasonSurface.isLayoutMarginsRelativeArrangement = true; reasonSurface.layoutMargins = UIEdgeInsets(top:6,left:16,bottom:6,right:16)
    reasonSurface.layer.cornerRadius = 4; reasonSurface.addArrangedSubview(reasonIcon); reasonSurface.addArrangedSubview(reason)
    reasonIcon.widthAnchor.constraint(equalToConstant:22).isActive = true; reasonIcon.heightAnchor.constraint(equalToConstant:22).isActive = true
    reasonSurface.heightAnchor.constraint(greaterThanOrEqualToConstant:48).isActive = true; stack.addArrangedSubview(reasonSurface)
    retry.setTitle("再開",for:.normal); retry.setImage(NeoIcon.image("ReplayOutlined"),for:.normal); retry.tintColor = NeoStyle.accent
    remove.setTitle("削除",for:.normal); remove.setImage(NeoIcon.image("DeleteOutlineOutlined"),for:.normal); remove.tintColor = NeoStyle.error
    retry.addAction(UIAction { [weak self] _ in self?.onRetry?() },for:.touchUpInside); remove.addAction(UIAction { [weak self] _ in self?.onDelete?() },for:.touchUpInside)
    let row = UIStackView(arrangedSubviews:[UIView(),retry,remove]); row.spacing = 12; row.heightAnchor.constraint(equalToConstant:36).isActive = true; stack.addArrangedSubview(row)
  }
  required init?(coder:NSCoder) { fatalError() }
  var controlsDisabled: Bool { !remove.isEnabled }
  func configure(_ item:NeoEncodeRecovery,disabled:Bool) {
    title.text = item.recorded?.name ?? "番組情報が見つかりません"
    mode.text = "\(item.mode ?? "エンコード設定を特定できません") ・ \(item.status == "paused" ? "一時停止中" : "要確認")"
    reason.text = item.reason; reasonSurface.backgroundColor = item.canRetry ? UIColor(red:7/255,green:19/255,blue:24/255,alpha:1) : UIColor(red:25/255,green:18/255,blue:7/255,alpha:1)
    reason.textColor = item.canRetry ? UIColor(red:184/255,green:231/255,blue:251/255,alpha:1) : NeoStyle.warning
    reasonIcon.image = NeoIcon.image(item.canRetry ? "InfoOutlined" : "ReportProblemOutlined"); reasonIcon.tintColor = reason.textColor
    retry.isHidden = !item.canRetry; retry.isEnabled = !disabled; remove.isEnabled = !disabled
  }
  override func prepareForReuse() { super.prepareForReuse(); onRetry = nil; onDelete = nil }
}
