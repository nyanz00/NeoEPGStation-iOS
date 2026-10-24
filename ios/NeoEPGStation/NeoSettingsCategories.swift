import UIKit

enum NeoSettingsCategory: String, CaseIterable {
  case app, general, viewing, display, account
  var title: String {
    switch self { case .app: return "アプリ設定"; case .general: return "全般"; case .viewing: return "視聴"; case .display: return "表示"; case .account: return "アカウント" }
  }
  var explanation: String {
    switch self {
    case .app: return "接続先と下部ナビゲーションを設定します。"
    case .general: return "アプリ全体の外観を確認します。"
    case .viewing: return "リジューム再生と視聴履歴の送信を設定します。"
    case .display: return "録画一覧の表示件数とハイライト、操作ボタン、視聴履歴の保存件数を設定します。"
    case .account: return "アクティブユーザーの切り替えと外部連携の認証を管理します。"
    }
  }
  var icon: String {
    switch self { case .app: return "SettingsOutlined"; case .general: return "TuneOutlined"; case .viewing: return "PlayCircleOutlineOutlined"; case .display: return "VisibilityOutlined"; case .account: return "LinkOutlined" }
  }
}

final class NeoSettingsPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private let table = UITableView(frame: .zero, style: .plain)
  init(shell: NeoShell) { super.init(title: "設定", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); table.backgroundColor = NeoStyle.background; table.separatorColor = NeoStyle.border
    table.dataSource = self; table.delegate = self; table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 100
    table.register(UITableViewCell.self, forCellReuseIdentifier: "category"); body.addSubview(table)
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); table.frame = body.bounds }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { NeoSettingsCategory.allCases.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let category = NeoSettingsCategory.allCases[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "category", for: indexPath)
    var config = cell.defaultContentConfiguration(); config.text = category.title; config.secondaryText = category.explanation
    config.textProperties.font = .systemFont(ofSize: 17, weight: .bold); config.textProperties.color = .white
    config.secondaryTextProperties.font = .systemFont(ofSize: 14); config.secondaryTextProperties.color = NeoStyle.muted
    config.secondaryTextProperties.numberOfLines = 0; config.textToSecondaryTextVerticalPadding = 4
    config.image = NeoIcon.image(category.icon); config.imageProperties.tintColor = NeoStyle.muted
    config.imageProperties.maximumSize = CGSize(width: 24, height: 24)
    config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 16, bottom: 22, trailing: 16)
    cell.contentConfiguration = config; cell.backgroundColor = NeoStyle.background; cell.accessoryType = .disclosureIndicator
    cell.accessibilityIdentifier = "settings-category-\(category.rawValue)"
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let shell else { return }
    navigationController?.pushViewController(NeoSettingsCategoryPage(category: NeoSettingsCategory.allCases[indexPath.row], shell: shell), animated: true)
  }
#if targetEnvironment(simulator)
  func smokeHistoryPreferences() -> Bool {
    guard let api = shell?.api, let shell else { return false }
    let original = api.disablePlaybackHistory
    defer { api.disablePlaybackHistory = original }
    let page = NeoSettingsCategoryPage(category: .viewing, shell: shell); page.loadViewIfNeeded()
    page.smokeSetHistoryDisabled(true)
    let restored = NeoAPI(base: api.base).disablePlaybackHistory
    page.smokeSetHistoryDisabled(false)
    return restored && !api.disablePlaybackHistory && table.numberOfRows(inSection: 0) == 5
  }
#endif
}

final class NeoSettingsCategoryPage: NeoPage {
  let category: NeoSettingsCategory
  private let scroll = UIScrollView(), stack = UIStackView()
  private let historyToggle = UISwitch()
  private var task: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  init(category: NeoSettingsCategory, shell: NeoShell) { self.category = category; super.init(title: category.title, shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); body.addSubview(scroll); stack.axis = .vertical; stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)])
    observers.append(NotificationCenter.default.addObserver(forName: .neoAccountChanged, object: nil, queue: .main) { [weak self] note in
      guard let self, let api = note.object as? NeoAPI, self.shell?.api === api else { return }; self.render()
    })
    render()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if isViewLoaded { render() } }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); scroll.frame = body.bounds }
  private func render() {
    task?.cancel(); stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let shell, let api = shell.api else { return }
    switch category {
    case .app:
      let engine = UIButton(type: .system)
      engine.setTitle(NeoPlaybackExperiment.selected.title, for: .normal); engine.tintColor = NeoStyle.accent
      engine.titleLabel?.font = .systemFont(ofSize: 14); engine.titleLabel?.numberOfLines = 2
      engine.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
      engine.accessibilityIdentifier = "playback-experiment-engine"; engine.showsMenuAsPrimaryAction = true
      engine.menu = UIMenu(children: NeoPlaybackExperiment.allCases.map { value in
        UIAction(title: value.title, state: value == NeoPlaybackExperiment.selected ? .on : .off) { [weak self] _ in
          NeoPlaybackExperiment.selected = value; self?.render()
        }
      })
      row("再生エンジン", explanation: "試験用はエンコード済みPLAYを先頭から開きます。コメント・字幕・PiP・視聴履歴の保存には未対応です。次の再生から適用します。", control: engine)
      button("接続先を変更") { [weak self, weak shell] in
        guard let shell else { return }; self?.navigationController?.pushViewController(NeoConnectionPage(shell: shell), animated: true)
      }
      button("下部ナビゲーションを編集") { [weak self, weak shell] in
        guard let shell else { return }; self?.navigationController?.pushViewController(NeoShortcutPage(shell: shell), animated: true)
      }
    case .general:
      info("テーマ：ターコイズ・ダーク")
    case .viewing:
      toggle("リジューム再生", explanation: "保存された再生位置から続けて再生します。", on: api.resumePlayback) { api.resumePlayback = $0 }
      historyToggle.isOn = api.disablePlaybackHistory; historyToggle.onTintColor = NeoStyle.accent
      historyToggle.accessibilityLabel = "視聴履歴を送信しない"
      historyToggle.removeTarget(nil, action: nil, for: .valueChanged)
      historyToggle.addTarget(self, action: #selector(historyChanged), for: .valueChanged)
      row("視聴履歴を送信しない", explanation: "このアプリからの送信だけを止めます。既存の履歴とリジューム位置は残ります。", control: historyToggle)
    case .display:
      toggle("THUMBボタンを表示しない", on: shell.storage.hideRecordedThumbnailButton) { [weak shell] in shell?.storage.hideRecordedThumbnailButton = $0 }
      toggle("録画済みへ戻った番組を強調表示", explanation: "録画詳細や視聴履歴から一覧へ移動した際、対象の録画を約1秒間ハイライトします。", on: api.highlightRecorded) { api.highlightRecorded = $0 }
      let length = UITextField(); length.text = String(api.recordedLength); length.keyboardType = .numberPad; length.textColor = .white
      length.borderStyle = .roundedRect; length.backgroundColor = NeoStyle.paper
      length.widthAnchor.constraint(equalToConstant: 100).isActive = true; length.accessibilityIdentifier = "recorded-page-length"
      row("録画済み表示件数", explanation: "1ページの表示件数。初期値24件、1〜1000件。このアプリに保存します。", control: length)
      button("表示件数を保存") { [weak self, weak length] in
        guard let self, let value = Int(length?.text ?? ""), (1...1000).contains(value) else { self?.alert("表示件数は1〜1000で入力してください。"); return }
        self.view.endEditing(true); api.recordedLength = value; self.alert("設定を保存しました。")
      }
      guard api.accountReady, Int(api.viewer).map({ $0 > 0 }) == true else { info("視聴履歴の保存件数を変更するには通常ユーザーを選択してください。"); return }
      let user = api.viewer, revision = api.identityRevision
      let status = NeoStyle.label("視聴履歴設定を取得中…", muted: true); status.numberOfLines = 0; stack.addArrangedSubview(status)
      task = Task { [weak self, weak status] in
        guard let self else { return }
        do {
          let settings = try await api.historySettings(user: user)
          guard !Task.isCancelled, self.shell?.api === api, api.identityRevision == revision else { return }
          status?.removeFromSuperview()
          let field = UITextField(); field.text = String(settings.limit); field.keyboardType = .numberPad; field.textColor = .white
          field.borderStyle = .roundedRect; field.backgroundColor = NeoStyle.paper; field.widthAnchor.constraint(equalToConstant: 100).isActive = true
          field.accessibilityLabel = "視聴履歴の保存件数"
          row("視聴履歴の保存件数", explanation: "選択中のユーザーに適用し、すべての端末で共有します。1〜200件。", control: field)
          button("保存") { [weak self, weak field] in
            guard let self, api.identityRevision == revision, let limit = Int(field?.text ?? ""), (1...200).contains(limit) else { self?.alert("保存件数は1〜200で入力してください。"); return }
            self.view.endEditing(true)
            self.task = Task { [weak self] in
              do {
                _ = try await api.updateHistorySettings(user: user, limit: limit)
                guard !Task.isCancelled, self?.shell?.api === api, api.identityRevision == revision else { return }
                NotificationCenter.default.post(name: .neoHistoryChanged, object: api); self?.alert("設定を保存しました。")
              } catch { if !Task.isCancelled { self?.alert(error.localizedDescription) } }
            }
          }
        } catch { if !Task.isCancelled { status?.text = "視聴履歴設定を取得できませんでした。\n\(error.localizedDescription)"; button("再試行") { [weak self] in self?.render() } } }
      }
    case .account:
      let selector = NeoUserSelector(); selector.setValue(shell.account?.currentName ?? api.viewer, background: NeoStyle.background)
      selector.accessibilityIdentifier = "account-user-selector"
      selector.widthAnchor.constraint(equalToConstant: 160).isActive = true
      selector.heightAnchor.constraint(equalToConstant: 40).isActive = true
      selector.showsMenuAsPrimaryAction = true
      selector.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak shell] completion in
        guard let account = shell?.account else { completion([]); return }
        account.loadSelectionMenu(completion: completion)
      }])
      row("現在のユーザー", control: selector)
      info("このアプリで使用する標準ユーザー。masterでは視聴履歴を記録しません。")
      if !api.accountReady {
        info("アクティブユーザーの確認が必要です。")
        button("ユーザーを確認") { [weak shell] in shell?.account?.restore() }
      } else if api.profileHeaders["X-Viewer-Session"] != nil {
        info("外部連携の認証セッションは解除済みです。")
        button("外部連携をロックしてmasterへ戻る") { [weak shell] in shell?.account?.lockCurrent() }
      }
    }
  }
  @objc private func historyChanged() { shell?.api?.disablePlaybackHistory = historyToggle.isOn }
  private func info(_ text: String) { let label = NeoStyle.label(text, muted: true); label.numberOfLines = 0; stack.addArrangedSubview(label) }
  private func button(_ title: String, action: @escaping () -> Void) {
    let button = NeoStyle.button(title, action: action); button.contentHorizontalAlignment = .left
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true; stack.addArrangedSubview(button)
  }
  private func row(_ title: String, explanation: String = "", control: UIView) {
    let labels = UIStackView(); labels.axis = .vertical; labels.spacing = 4
    let name = NeoStyle.label(title, size: 16); name.numberOfLines = 0; labels.addArrangedSubview(name)
    if !explanation.isEmpty { let detail = NeoStyle.label(explanation, muted: true); detail.numberOfLines = 0; labels.addArrangedSubview(detail) }
    let row = UIStackView(arrangedSubviews: [labels, control]); row.axis = .horizontal; row.alignment = .center; row.spacing = 16
    control.setContentHuggingPriority(.required, for: .horizontal); labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true; stack.addArrangedSubview(row)
  }
  private func toggle(_ title: String, explanation: String = "", on: Bool, action: @escaping (Bool) -> Void) {
    let toggle = UISwitch(); toggle.isOn = on; toggle.onTintColor = NeoStyle.accent; toggle.accessibilityLabel = title
    toggle.addAction(UIAction { [weak toggle] _ in if let toggle { action(toggle.isOn) } }, for: .valueChanged)
    row(title, explanation: explanation, control: toggle)
  }
#if targetEnvironment(simulator)
  var smokeAccountSelector: Bool {
    guard category == .account, let selector = stack.arrangedSubviews.flatMap({ $0.subviews }).first(where: { $0 is NeoUserSelector }) as? NeoUserSelector else { return false }
    return selector.bounds.size == CGSize(width: 160, height: 40) && selector.showsMenuAsPrimaryAction && selector.menu != nil
  }
  func smokeSetHistoryDisabled(_ value: Bool) { historyToggle.isOn = value; historyToggle.sendActions(for: .valueChanged) }
#endif
  deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}
