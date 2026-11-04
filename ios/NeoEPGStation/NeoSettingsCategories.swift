import UIKit

enum NeoSettingsCategory: String, CaseIterable {
  case general, viewing, display, account, annict, discord, about
  var title: String {
    switch self { case .general: return "全般"; case .viewing: return "視聴"; case .display: return "表示"; case .account: return "アカウント"; case .annict: return "Annict"; case .discord: return "Discord"; case .about: return "アプリについて" }
  }
  var icon: String {
    switch self { case .general: return "TuneOutlined"; case .viewing: return "PlayCircleOutlineOutlined"; case .display: return "VisibilityOutlined"; case .account: return "LinkOutlined"; case .annict: return "AlphaA"; case .discord: return "ChatBubbleOutlineOutlined"; case .about: return "InfoOutlined" }
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
    var config = cell.defaultContentConfiguration(); config.text = category.title; config.secondaryText = nil
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
  var smokeCategoryDescriptionsRemoved: Bool {
    (0..<NeoSettingsCategory.allCases.count).allSatisfy {
      let cell = tableView(table,cellForRowAt:IndexPath(row:$0,section:0))
      return (cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText == nil
    }
  }
  func smokeHistoryPreferences() -> Bool {
    guard let api = shell?.api, let shell else { return false }
    let original = api.disablePlaybackHistory
    defer { api.disablePlaybackHistory = original }
    let page = NeoSettingsCategoryPage(category: .viewing, shell: shell); page.loadViewIfNeeded()
    page.smokeSetHistoryDisabled(true)
    let restored = NeoAPI(base: api.base).disablePlaybackHistory
    page.smokeSetHistoryDisabled(false)
    return restored && !api.disablePlaybackHistory && table.numberOfRows(inSection: 0) == 7
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
    case .viewing:
      buildViewingPreferences()
      let engine = NeoSelectButton(frame:.zero)
      engine.setTitle(NeoPlaybackExperiment.selected.title, for: .normal); engine.tintColor = NeoStyle.accent
      engine.titleLabel?.font = .systemFont(ofSize: 14); engine.titleLabel?.numberOfLines = 2
      engine.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
      engine.accessibilityIdentifier = "playback-experiment-engine"; engine.showsMenuAsPrimaryAction = true
      engine.menu = UIMenu(children: NeoPlaybackExperiment.allCases.map { value in
        UIAction(title: value.title, state: value == NeoPlaybackExperiment.selected ? .on : .off) { [weak self] _ in
          NeoPlaybackExperiment.selected = value; self?.render()
        }
      })
      row("再生エンジン", explanation: "Aetherはエンコード済みPLAY・STREAMINGに使用します。コメント・字幕・PiP・視聴履歴は共通のプレイヤー機能を使います。TSはARIB字幕対応のVLCで再生します。診断用はAV1動画を比較します。次の再生から適用します。", control: engine)
      if NeoPlaybackExperiment.selected == .checkpointPlayer {
        let checkpoint = NeoSelectButton(frame:.zero)
        checkpoint.setTitle(NeoPlaybackExperiment.checkpointMode.title, for: .normal)
        checkpoint.showsMenuAsPrimaryAction = true
        checkpoint.menu = UIMenu(children: NeoCheckpointMode.allCases.map { value in
          UIAction(title: value.title, state: NeoPlaybackExperiment.checkpointMode == value ? .on : .off) { [weak self] _ in
            NeoPlaybackExperiment.checkpointMode = value; self?.render()
          }
        })
        row("チェックポイント", explanation: "1080p以下のAV1が対象です。自動はサーバー解析の最大間隔が10秒以上の場合に使用します。未解析・旧版は解析完了後に選択します。オフでは通常経路で再生します。過去60秒・先読み20秒、保持上限128MiB。次の再生から適用します。", control: checkpoint)
      }
      toggle("リジューム再生", explanation: "保存された再生位置から続けて再生します。", on: api.resumePlayback) { api.resumePlayback = $0 }
      historyToggle.isOn = api.disablePlaybackHistory; historyToggle.onTintColor = NeoStyle.accent
      historyToggle.accessibilityLabel = "視聴履歴を送信しない"
      historyToggle.removeTarget(nil, action: nil, for: .valueChanged)
      historyToggle.addTarget(self, action: #selector(historyChanged), for: .valueChanged)
      row("視聴履歴を送信しない", explanation: "このアプリからの送信だけを止めます。既存の履歴とリジューム位置は残ります。", control: historyToggle)
    case .general:
      toggle("下部ナビゲーションのラベルを表示", on: NeoViewingPreferences.navigationLabels) { [weak shell] in
        NeoViewingPreferences.navigationLabels = $0; shell?.refreshNavigationLabels()
      }
      button("接続先を変更") { [weak self, weak shell] in
        guard let shell else { return }; self?.navigationController?.pushViewController(NeoConnectionPage(shell: shell), animated: true)
      }
      button("下部ナビゲーションを編集") { [weak self, weak shell] in
        guard let shell else { return }; self?.navigationController?.pushViewController(NeoShortcutPage(shell: shell), animated: true)
      }
      info("テーマ：ターコイズ・ダーク")
    case .about:
      let bundle = Bundle.main
      info(bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "NeoEPGStation")
      info("バージョン：\(bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")")
      info("ビルド番号：\(bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—")")
      button("ソースコード（GitHub）") { UIApplication.shared.open(URL(string:"https://github.com/nyanz00/NeoEPGStation-iOS")!) }
      info("使用ライブラリ：VLCKit / libVLC、AetherEngine、FFmpeg、dav1d、LZ4、Zstandard、Noto Sans JP、アイコン等")
      button("使用ライブラリ・ライセンス") { [weak self,weak shell] in
        guard let shell else { return }; self?.navigationController?.pushViewController(NeoLicensePage(shell:shell),animated:true)
      }
    case .annict, .discord: break
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
  private func choice(_ title: String, values: [(String,String)], selected: String, save: @escaping (String) -> Void) {
    let control = NeoSelectButton(frame:.zero)
    control.setTitle(values.first { $0.0 == selected }?.1 ?? selected,for:.normal)
    control.accessibilityIdentifier = "viewing-"+title
    control.menu = UIMenu(children:values.map { key,text in UIAction(title:text,state:key == selected ? .on : .off) { [weak self] _ in save(key); self?.render() } })
    row(title,control:control)
  }
  private func buildViewingPreferences() {
    let config = shell?.serverConfig
    var seen = Set<String>()
    let encoders = (["Config"]+(config?.watchConfig?.availableEncoders ?? [])).filter { seen.insert($0).inserted }
    choice("エンコーダー",values:encoders.map { ($0,$0) },selected:NeoViewingPreferences.encoder) { NeoViewingPreferences.encoder = $0 }
    choice("デフォルト画質",values:[("","自動")]+(config?.watchConfig?.liveQualities ?? config?.streamingQualities("encoded") ?? []).map { ($0,$0) },selected:NeoViewingPreferences.quality) { NeoViewingPreferences.quality = $0 }
    toggle("HEVCでエンコード",on:NeoViewingPreferences.hevc) { NeoViewingPreferences.hevc = $0 }
    toggle("低遅延モード",on:NeoViewingPreferences.lowLatency) { NeoViewingPreferences.lowLatency = $0 }
    toggle("STREAMING開始バッファ",explanation:"先頭3セグメントを生成してから開始します。",on:NeoViewingPreferences.bufferedStart) { NeoViewingPreferences.bufferedStart = $0 }
    let priorities = UIStackView(); priorities.axis = .vertical; priorities.spacing = 8
    let saved = NeoViewingPreferences.subtitleKeywords
    for index in saved.indices {
      let field = UITextField(); field.text = saved.indices.contains(index) ? saved[index] : ""
      field.attributedPlaceholder = NSAttributedString(string:"優先字幕 \(index+1)",attributes:[.foregroundColor:NeoStyle.muted])
      field.backgroundColor = NeoStyle.paper; field.font = .systemFont(ofSize:16)
      field.accessibilityIdentifier = "viewing-subtitle-priority-\(index)"
      field.textColor = .white; field.borderStyle = .roundedRect; field.autocorrectionType = .no; field.autocapitalizationType = .none
      field.addAction(UIAction { [weak field] _ in
        var values = NeoViewingPreferences.subtitleKeywords; guard values.indices.contains(index) else { return }; values[index] = field?.text ?? ""; NeoViewingPreferences.subtitleKeywords = values
      },for:.editingChanged)
      if index >= 3 {
        let remove = NeoStyle.iconButton("DeleteOutlineOutlined",label:"優先順位\(index+1)を削除") { [weak self] in
          self?.view.endEditing(true); NeoViewingPreferences.removeSubtitlePriority(at:index); self?.render()
        }
        remove.accessibilityIdentifier = "viewing-subtitle-remove-\(index)"
        remove.widthAnchor.constraint(equalToConstant:36).isActive = true
        let line = UIStackView(arrangedSubviews:[field,remove]); line.spacing = 6; priorities.addArrangedSubview(line)
      } else { priorities.addArrangedSubview(field) }
    }
    let add = NeoStyle.button("＋ 優先順位を追加") { [weak self] in
      self?.view.endEditing(true); NeoViewingPreferences.addSubtitlePriority(); self?.render()
    }
    add.accessibilityIdentifier = "viewing-subtitle-add"; add.layer.borderWidth = 1; add.layer.borderColor = NeoStyle.accent.cgColor
    add.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true; priorities.addArrangedSubview(add)
    priorities.widthAnchor.constraint(equalToConstant:180).isActive = true
    row("優先字幕",explanation:"上から順に弾幕と通常字幕を照合します。通常字幕は一致がなければオフになります。",control:priorities)
    toggle("コメントを表示",on:NeoViewingPreferences.commentsEnabled) { NeoViewingPreferences.commentsEnabled = $0 }
    toggle("字幕・コメントの準備を待ってPLAY再生を開始",on:NeoCommentOverlay.waitBeforePlayback) { NeoCommentOverlay.waitBeforePlayback = $0 }
    let network = UIStepper(); network.minimumValue = 1; network.maximumValue = 30; network.value = Double(NeoViewingPreferences.networkSeconds)
    network.accessibilityIdentifier = "viewing-network-cache"
    network.addAction(UIAction { [weak self,weak network] _ in NeoViewingPreferences.networkSeconds = Int(network?.value ?? 5); self?.render() },for:.valueChanged)
    row("PLAYのネットワークキャッシュ：\(NeoViewingPreferences.networkSeconds)秒",explanation:"次の再生・再読み込みから適用します。",control:network)
    choice("PLAYの巻き戻し用キャッシュ",values:NeoPlaybackCache.presets.map { (String($0),$0 == 0 ? "オフ" : "\($0)秒") },selected:String(NeoPlaybackCache.savedSeconds)) { UserDefaults.standard.set(Int($0) ?? 60,forKey:NeoPlaybackCache.preference) }
    for ts in [false,true] {
      for rewind in [false,true] {
        choice("\(ts ? "TS" : "エンコード済み")STREAMINGの\(rewind ? "巻き戻し用キャッシュ" : "先読み")",values:(rewind ? NeoStreamBuffer.rewindChoices : NeoStreamBuffer.aheadChoices).map { (String($0),NeoStreamBuffer.label($0,ts:ts)) },selected:String(NeoStreamBuffer.count(ts:ts,rewind:rewind))) { NeoStreamBuffer.save(Int($0) ?? 0,ts:ts,rewind:rewind) }
      }
    }
    let size = UISlider(); size.minimumValue = 0.5; size.maximumValue = 2; size.value = Float(NeoViewingPreferences.commentSize)
    size.minimumTrackTintColor = NeoStyle.accent; size.maximumTrackTintColor = NeoStyle.border
    let sizeLabel = NeoStyle.label(String(format:"文字サイズ %.2f倍",NeoViewingPreferences.commentSize))
    size.accessibilityIdentifier = "viewing-comment-size"
    size.addAction(UIAction { [weak size,weak sizeLabel] _ in NeoViewingPreferences.commentSize = Double(size?.value ?? 1); sizeLabel?.text = String(format:"文字サイズ %.2f倍",NeoViewingPreferences.commentSize) },for:.valueChanged)
    stack.addArrangedSubview(sizeLabel); stack.addArrangedSubview(size)
    let opacity = UISlider(); opacity.minimumValue = 0; opacity.maximumValue = 1; opacity.value = NeoViewingPreferences.commentOpacity
    opacity.minimumTrackTintColor = NeoStyle.accent; opacity.maximumTrackTintColor = NeoStyle.border
    let opacityLabel = NeoStyle.label("コメントの不透明度 \(Int(opacity.value*100))%")
    opacity.accessibilityIdentifier = "viewing-comment-opacity"
    opacity.addAction(UIAction { [weak opacity,weak opacityLabel] _ in NeoViewingPreferences.commentOpacity = opacity?.value ?? 1; opacityLabel?.text = "コメントの不透明度 \(Int(NeoViewingPreferences.commentOpacity*100))%" },for:.valueChanged)
    stack.addArrangedSubview(opacityLabel); stack.addArrangedSubview(opacity)
  }
  private func info(_ text: String) { let label = NeoStyle.label(text, muted: true); label.numberOfLines = 0; stack.addArrangedSubview(label) }
  private func button(_ title: String, action: @escaping () -> Void) {
    let button = NeoStyle.button(title, action: action); button.contentHorizontalAlignment = .left
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true; stack.addArrangedSubview(button)
  }
  private func row(_ title: String, explanation: String = "", control: UIView) {
    let labels = UIStackView(); labels.axis = .vertical; labels.spacing = 4
    let name = NeoStyle.label(title, size: 16); name.numberOfLines = 0; name.lineBreakMode = .byWordWrapping
    name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    name.setContentCompressionResistancePriority(.required,for:.vertical); labels.addArrangedSubview(name)
    if !explanation.isEmpty {
      let detail = NeoStyle.label(explanation, muted: true); detail.numberOfLines = 0; detail.lineBreakMode = .byWordWrapping
      detail.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
      detail.setContentCompressionResistancePriority(.required,for:.vertical); labels.addArrangedSubview(detail)
    }
    let row = UIStackView(arrangedSubviews: [labels, control]); row.axis = .horizontal; row.alignment = .center; row.spacing = 16
    control.setContentHuggingPriority(.required, for: .horizontal); control.setContentCompressionResistancePriority(.required,for:.horizontal)
    labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    labels.widthAnchor.constraint(greaterThanOrEqualToConstant:0).isActive = true
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true; stack.addArrangedSubview(row)
  }
  private func toggle(_ title: String, explanation: String = "", on: Bool, action: @escaping (Bool) -> Void) {
    let toggle = UISwitch(); toggle.isOn = on; toggle.onTintColor = NeoStyle.accent; toggle.accessibilityLabel = title
    toggle.addAction(UIAction { [weak toggle] _ in if let toggle { action(toggle.isOn) } }, for: .valueChanged)
    row(title, explanation: explanation, control: toggle)
  }
#if targetEnvironment(simulator)
  var smokeSettingCount: Int { stack.arrangedSubviews.count }
  var smokeControlsWithinWidth: Bool {
    view.layoutIfNeeded()
    func all(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(all) }
    return all(stack).filter { $0 is UISwitch || $0 is UIStepper || $0 is UITextField || $0 is UISlider }.allSatisfy {
      let rect = scroll.convert($0.bounds,from:$0)
      return rect.minX >= 15 && rect.maxX <= scroll.bounds.width-15
    }
  }
  var smokeAccountSelector: Bool {
    guard category == .account, let selector = stack.arrangedSubviews.flatMap({ $0.subviews }).first(where: { $0 is NeoUserSelector }) as? NeoUserSelector else { return false }
    return selector.bounds.size == CGSize(width: 160, height: 40) && selector.showsMenuAsPrimaryAction && selector.menu != nil
  }
  func smokeSetHistoryDisabled(_ value: Bool) { historyToggle.isOn = value; historyToggle.sendActions(for: .valueChanged) }
#endif
  deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}

// Both Xcode builds carry the application notices; packaged IPA builds also
// contain the generated notices and pinned dependency sources.
final class NeoLicensePage: NeoPage {
  static var documents: [URL] {
    let bundle = Bundle.main.bundleURL
    var urls = [URL]()
    if let notice = Bundle.main.url(forResource:"THIRD_PARTY_NOTICES",withExtension:"md") { urls.append(notice) }
    for directory in ["licenses","ThirdPartyNotices"] {
      let root = bundle.appendingPathComponent(directory,isDirectory:true)
      guard let entries = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:.skipsHiddenFiles) else { continue }
      for case let url as URL in entries {
        let name = url.lastPathComponent.lowercased()
        let legalName = ["license","copying","notice"].contains(where:name.contains)
        guard (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true,
          (directory == "licenses" && ["txt","md",""].contains(url.pathExtension.lowercased())) || legalName else { continue }
        urls.append(url)
      }
    }
    return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }
  private let scroll = UIScrollView(), stack = UIStackView()
  init(shell: NeoShell) { super.init(title:"使用ライブラリ・ライセンス",shell:shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); body.addSubview(scroll); stack.axis = .vertical; stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
    NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:16),
      stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:16),
      stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-16),
      stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-16),
      stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-32)])
    for url in Self.documents {
      let relative = url.path.replacingOccurrences(of:Bundle.main.bundleURL.path+"/",with:"")
      let button = NeoStyle.button(relative) { [weak self] in
        guard let self, let shell = self.shell else { return }
        self.navigationController?.pushViewController(NeoLicenseTextPage(url:url,shell:shell),animated:true)
      }
      button.titleLabel?.numberOfLines = 0; button.titleLabel?.lineBreakMode = .byWordWrapping
      button.contentHorizontalAlignment = .left; button.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true
      stack.addArrangedSubview(button)
    }
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); scroll.frame = body.bounds }
}

private final class NeoLicenseTextPage: NeoPage {
  private let url: URL, text = UITextView()
  init(url: URL, shell: NeoShell) { self.url = url; super.init(title:url.lastPathComponent,shell:shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); text.isEditable = false; text.isSelectable = true
    text.backgroundColor = NeoStyle.background; text.textColor = .white; text.font = .systemFont(ofSize:14)
    text.textContainerInset = UIEdgeInsets(top:16,left:16,bottom:16,right:16)
    text.text = (try? String(contentsOf:url,encoding:.utf8)) ?? "文書を読み込めませんでした。"
    body.addSubview(text)
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); text.frame = body.bounds }
}
