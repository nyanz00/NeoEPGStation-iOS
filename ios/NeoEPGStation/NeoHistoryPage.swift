import UIKit

private final class NeoHistoryCell: UITableViewCell {
  private let card = UIView(), thumbnail = NeoThumbnail(), title = NeoStyle.label(size: 16, bold: true)
  private let channel = NeoStyle.label(muted: true), watched = NeoStyle.label(size: 12, muted: true)
  private let position = NeoStyle.label(size: 12), duration = NeoStyle.label(size: 12, muted: true)
  private let progress = UIProgressView(progressViewStyle: .default)
  var locate: (() -> Void)?, remove: (() -> Void)?
  private lazy var locateButton = NeoStyle.iconButton("ViewListOutlined", label: "録画済み一覧で表示") { [weak self] in self?.locate?() }
  private lazy var deleteButton = NeoStyle.iconButton("DeleteOutlineOutlined", label: "このユーザーの視聴履歴から削除") { [weak self] in self?.remove?() }
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier); backgroundColor = NeoStyle.background; selectionStyle = .none
    card.backgroundColor = NeoStyle.paper; card.layer.cornerRadius = 4; card.layer.borderWidth = 1; card.layer.borderColor = NeoStyle.border.cgColor
    card.clipsToBounds = true; contentView.addSubview(card)
    [thumbnail, title, channel, watched, position, duration, progress, locateButton, deleteButton].forEach(card.addSubview)
    progress.progressTintColor = NeoStyle.accent; progress.trackTintColor = NeoStyle.accent.withAlphaComponent(0.25)
    duration.textAlignment = .right
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews(); card.frame = contentView.bounds.insetBy(dx: 12, dy: 6)
    let w = card.bounds.width, imageWidth: CGFloat = w >= 600 ? 220 : 132, x = imageWidth + 10
    thumbnail.frame = CGRect(x: 0, y: 0, width: imageWidth, height: card.bounds.height)
    locateButton.frame = CGRect(x: w-76, y: 3, width: 36, height: 36); deleteButton.frame = CGRect(x: w-40, y: 3, width: 36, height: 36)
    title.frame = CGRect(x: x, y: 10, width: max(0, w-x-82), height: 22)
    channel.frame = CGRect(x: x, y: 35, width: max(0, w-x-12), height: 20)
    watched.frame = CGRect(x: x, y: 57, width: max(0, w-x-12), height: 18)
    progress.frame = CGRect(x: x, y: 88, width: max(0, w-x-12), height: 7)
    progress.transform = CGAffineTransform(scaleX: 1, y: 3.5)
    position.frame = CGRect(x: x, y: 101, width: max(0, (w-x-12)*0.4), height: 18)
    duration.frame = CGRect(x: position.frame.maxX, y: 101, width: max(0, (w-x-12)*0.6), height: 18)
  }
  func configure(_ item: NeoHistoryItem, shell: NeoShell, disabled: Bool) {
    title.text = item.recorded.name; channel.text = item.recorded.channelName ?? item.recorded.channelId.flatMap { shell.channels[$0] } ?? ""
    if let date = item.playback.updatedAt {
      let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "yyyy/MM/dd(EEE) HH:mm"
      watched.text = "最終視聴: " + formatter.string(from: Date(timeIntervalSince1970: date/1000))
    } else { watched.text = "" }
    let value = item.playback.duration > 0 ? min(1, max(0, item.playback.position/item.playback.duration)) : 0
    progress.progress = Float(value); position.text = NeoHistoryPage.mediaTime(item.playback.position)
    duration.text = "\(NeoHistoryPage.mediaTime(item.playback.duration))・\(Int((value*100).rounded()))%"
    thumbnail.load(item.recorded.thumbnails?.first.flatMap { shell.api?.url("/thumbnails/\($0)") })
    locateButton.isEnabled = !disabled; deleteButton.isEnabled = !disabled
    accessibilityLabel = "\(item.recorded.name)、\(position.text ?? "")、\(duration.text ?? "")"
  }
  override func prepareForReuse() { super.prepareForReuse(); thumbnail.load(nil); locate = nil; remove = nil }
}

final class NeoHistoryPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private let table = UITableView(frame: .zero, style: .plain), refresh = UIRefreshControl()
  private let banner = UIView(), save = UISwitch(), saveTitle = NeoStyle.label("視聴履歴を保存", size: 16, bold: true)
  private let hint = NeoStyle.label("現在のアクティブユーザーだけに適用します。オフにしても既存の履歴とリジューム再生位置は残ります。", muted: true)
  private let message = NeoStyle.label(muted: true), spinner = UIActivityIndicatorView(style: .medium)
  private var items: [NeoHistoryItem] = [], owner: String?
  private var task: Task<Void, Never>?, mutation: Task<Void, Never>?
  private var pending = false, settings: NeoHistorySettings?, observers: [NSObjectProtocol] = []
  init(shell: NeoShell) { super.init(title: "視聴履歴", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); table.backgroundColor = NeoStyle.background; table.separatorStyle = .none
    table.dataSource = self; table.delegate = self; table.rowHeight = 144
    table.register(NeoHistoryCell.self, forCellReuseIdentifier: "history")
    refresh.addTarget(self, action: #selector(reload), for: .valueChanged); table.refreshControl = refresh
    body.addSubview(table); body.addSubview(spinner)
    hint.numberOfLines = 0; message.numberOfLines = 0; message.textColor = NeoStyle.muted
    [saveTitle, save, hint, message].forEach(banner.addSubview); save.onTintColor = NeoStyle.accent
    save.accessibilityLabel = "視聴履歴を保存"; save.addTarget(self, action: #selector(saveChanged), for: .valueChanged)
    actions = [NeoStyle.iconButton("Refresh", label: "視聴履歴を更新") { [weak self] in self?.reload() }]
    for name in [Notification.Name.neoAccountChanged, .neoHistoryChanged] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        guard let self else { return }
        if let api = note.object as? NeoAPI, self.shell?.api !== api { return }
        if name == .neoAccountChanged { self.task?.cancel(); self.items = []; self.owner = nil; self.settings = nil; self.table.reloadData() }
        if self.view.window != nil, self.navigationController?.topViewController === self, self.shell?.presentedViewController == nil { self.reload() }
      })
    }
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); table.frame = body.bounds; spinner.center = CGPoint(x: body.bounds.midX, y: 245); layoutBanner()
  }
  private func layoutBanner() {
    let width = body.bounds.width
    saveTitle.frame = CGRect(x: 16, y: 16, width: max(0, width-100), height: 24)
    save.frame = CGRect(x: width-68, y: 14, width: 52, height: 32)
    hint.frame = CGRect(x: 16, y: 48, width: max(0, width-32), height: 60)
    message.frame = CGRect(x: 16, y: 116, width: max(0, width-32), height: 76)
    banner.frame = CGRect(x: 0, y: 0, width: width, height: message.text?.isEmpty == false ? 204 : 120)
    table.tableHeaderView = banner
  }
  @objc func reload() {
    guard isViewLoaded, let api = shell?.api else { return }
#if targetEnvironment(simulator)
    if shell?.smokeStage == "history" {
      items = NeoRecordedPage.fixtures.records.enumerated().map { index, item in
        NeoHistoryItem(recorded: item, playback: NeoPlayback(position: Double(index+1)*120, duration: 1800, watchedSeconds: 60, updatedAt: 1_700_000_000_000))
      }
      saveTitle.isHidden = false; save.isHidden = false; hint.isHidden = false; save.isOn = true
      message.text = nil; table.reloadData(); layoutBanner(); return
    }
#endif
    task?.cancel(); let user = api.viewer, revision = api.identityRevision
    if owner != user { items = []; settings = nil; table.reloadData() }; owner = user
    save.isEnabled = false
    guard api.accountReady, Int(user).map({ $0 > 0 }) == true else {
      saveTitle.isHidden = true; save.isHidden = true; hint.isHidden = true
      message.text = api.accountReady ? "視聴履歴を表示するには通常ユーザーへ切り替えてください。masterでは視聴履歴を記録しません。" : "アクティブユーザーの確認が必要です。設定のアカウントで確認してください。"
      spinner.stopAnimating(); refresh.endRefreshing(); layoutBanner(); return
    }
    saveTitle.isHidden = false; save.isHidden = false; hint.isHidden = false; message.text = nil
    if items.isEmpty { spinner.startAnimating() }; layoutBanner()
    task = Task { [weak self] in
      guard let self else { return }
      async let historyResult = api.history(user: user)
      async let settingsResult = api.historySettings(user: user)
      var errors: [String] = []
      do {
        let history = try await historyResult
        guard !Task.isCancelled, self.shell?.api === api, api.identityRevision == revision else { return }
        items = history.items; table.reloadData()
        if items.isEmpty { errors.append("このユーザーの視聴履歴はありません。") }
      } catch { errors.append("視聴履歴を更新できませんでした。\(error.localizedDescription)") }
      do {
        let result = try await settingsResult
        guard !Task.isCancelled, self.shell?.api === api, api.identityRevision == revision else { return }
        settings = result; save.isOn = result.enabled; save.isEnabled = !pending
      } catch { errors.append("視聴履歴設定を取得できませんでした。\(error.localizedDescription)") }
      guard !Task.isCancelled, self.shell?.api === api, api.identityRevision == revision else { return }
      message.text = errors.joined(separator: "\n"); spinner.stopAnimating(); refresh.endRefreshing(); layoutBanner()
    }
  }
  @objc private func saveChanged() {
    guard let api = shell?.api, let settings, let owner, owner == api.viewer, !pending else { return }
    let enabled = save.isOn, revision = api.identityRevision; pending = true; save.isEnabled = false
    mutation = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await api.updateHistorySettings(user: owner, enabled: enabled)
        if self.shell?.api === api, api.identityRevision == revision { self.settings = result; save.isOn = result.enabled }
      } catch {
        if self.shell?.api === api, api.identityRevision == revision { save.isOn = settings.enabled; alert(error.localizedDescription) }
      }
      pending = false
      if self.shell?.api === api, api.identityRevision == revision { save.isEnabled = true }
    }
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "history", for: indexPath) as! NeoHistoryCell
    let item = items[indexPath.row]
    if let shell { cell.configure(item, shell: shell, disabled: pending) }
    cell.locate = { [weak self] in self?.locate(item.recorded.id) }
    cell.remove = { [weak self] in self?.remove(item.recorded.id) }
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { shell?.openDetail(items[indexPath.row].recorded) }
  private func remove(_ id: Int) {
    guard let api = shell?.api, let owner, api.viewer == owner, !pending else { return }
    let revision = api.identityRevision; pending = true; table.reloadData()
    mutation = Task { [weak self] in
      guard let self else { return }
      do {
        try await api.removeHistory(id, user: owner)
        if self.shell?.api === api, api.identityRevision == revision { items.removeAll { $0.recorded.id == id } }
      } catch { if self.shell?.api === api, api.identityRevision == revision { alert(error.localizedDescription) } }
      pending = false; table.reloadData()
    }
  }
  private func locate(_ id: Int) {
    guard let api = shell?.api, !pending else { return }
    let revision = api.identityRevision; pending = true; table.reloadData()
    mutation = Task { [weak self] in
      guard let self else { return }
      do {
        let position = try await api.listPosition(id)
        if self.shell?.api === api, api.identityRevision == revision { self.shell?.locateRecording(id, position: position) }
      } catch { if self.shell?.api === api, api.identityRevision == revision { alert(error.localizedDescription) } }
      pending = false; table.reloadData()
    }
  }
  static func mediaTime(_ time: Double) -> String {
    guard time.isFinite else { return "0:00" }; let s = max(0, Int(time))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, s/60%60, s%60) : String(format: "%d:%02d", s/60, s%60)
  }
#if targetEnvironment(simulator)
  var smokeReady: Bool { items.count == 4 && table.numberOfRows(inSection: 0) == 4 && !saveTitle.isHidden }
#endif
  deinit { task?.cancel(); mutation?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}
