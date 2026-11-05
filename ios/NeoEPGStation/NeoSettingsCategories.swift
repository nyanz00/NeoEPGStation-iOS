import UIKit

// Keep each settings row's text sizing independent. A long vertical stack of
// nested horizontal/vertical stacks made first layout a coupled constraint
// problem even for controls far below the visible viewport.
private final class NeoSettingsRow: UIView {
  private let name: UILabel, detail: UILabel?, control: UIView
  var availableWidth: CGFloat = 1 { didSet { if oldValue != availableWidth { invalidateIntrinsicContentSize(); setNeedsLayout() } } }
  init(title: String, explanation: String, control: UIView) {
    name = NeoStyle.label(title,size:16); name.numberOfLines = 0; name.lineBreakMode = .byWordWrapping
    if explanation.isEmpty { detail = nil }
    else { let label = NeoStyle.label(explanation,muted:true); label.numberOfLines = 0; label.lineBreakMode = .byWordWrapping; detail = label }
    self.control = control; super.init(frame:.zero)
    addSubview(name); if let detail { addSubview(detail) }; addSubview(control)
  }
  required init?(coder: NSCoder) { fatalError() }
  private var controlSize: CGSize {
    let intrinsic = control is UISwitch ? control.sizeThatFits(.zero) : control.intrinsicContentSize
    // A control also owns constraints for its internal labels and layout guides.
    // Their zero-width constants must not become the width of the whole field.
    let fixedWidth = control.constraints.first { $0.firstItem === control && $0.firstAttribute == .width && $0.secondItem == nil && $0.relation == .equal && $0.priority == .required && $0.constant > 0 }?.constant
    let width = min(max(0,availableWidth-16),fixedWidth ?? (intrinsic.width > 0 ? intrinsic.width : 180))
    let minimumHeight = control.constraints.filter { $0.firstItem === control && $0.firstAttribute == .height && $0.secondItem == nil && $0.relation != .lessThanOrEqual }.map(\.constant).max() ?? 0
    let height = max(minimumHeight,intrinsic.height > 0 ? intrinsic.height : control.systemLayoutSizeFitting(CGSize(width:width,height:0),withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height)
    return CGSize(width:width,height:max(0,height))
  }
  override var intrinsicContentSize: CGSize {
    let size = controlSize, width = max(0,availableWidth-size.width-16)
    let textHeight = name.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude)).height + (detail.map { $0.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude)).height+4 } ?? 0)
    return CGSize(width:UIView.noIntrinsicMetric,height:max(56,max(size.height,textHeight)))
  }
  override func layoutSubviews() {
    super.layoutSubviews(); let size = controlSize, width = max(0,bounds.width-size.width-16)
    let titleHeight = name.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude)).height
    let detailHeight = detail?.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude)).height ?? 0
    let total = titleHeight+(detail == nil ? 0 : detailHeight+4), top = (bounds.height-total)/2
    name.frame = CGRect(x:0,y:top,width:width,height:titleHeight)
    detail?.frame = CGRect(x:0,y:top+titleHeight+4,width:width,height:detailHeight)
    control.frame = CGRect(x:bounds.width-size.width,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
    // UIKit can adjust a switch to its native dimensions after assigning frame.
    control.frame.origin = CGPoint(x:bounds.width-control.bounds.width,y:(bounds.height-control.bounds.height)/2)
  }
#if targetEnvironment(simulator)
  var smokeControlFits: Bool {
    layoutIfNeeded(); control.layoutIfNeeded()
    return control.bounds.width >= 44 && control.bounds.height >= 20 && bounds.insetBy(dx:-0.5,dy:-0.5).contains(control.frame)
  }
  var smokeGeometry: [String:Any] {
    let fits = smokeControlFits
    func numbers(_ rect: CGRect) -> [Double] { [Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height)] }
    return ["title":name.text ?? "", "control":String(describing:type(of:control)),
      "rowFrame":numbers(frame), "controlFrame":numbers(control.frame),
      "availableWidth":availableWidth, "fits":fits,
      "dimensionConstraints":control.constraints.filter { $0.secondItem == nil && [.width,.height].contains($0.firstAttribute) }.map { ["self":$0.firstItem === control,"attribute":$0.firstAttribute.rawValue,"constant":$0.constant] as [String:Any] }]
  }
#endif
}

private final class NeoSettingsFormCell: UITableViewCell {
  var setting: UIView? {
    didSet {
      // A retained setting can already have moved to another visible cell.
      // Reusing its former cell must not detach it from that new owner.
      if oldValue?.superview === contentView { oldValue?.removeFromSuperview() }
      if let setting { setting.translatesAutoresizingMaskIntoConstraints = true; contentView.addSubview(setting) }
      setNeedsLayout()
    }
  }
  override func prepareForReuse() { super.prepareForReuse(); setting = nil }
  override func layoutSubviews() {
    super.layoutSubviews(); setting?.frame = contentView.bounds.insetBy(dx:16,dy:8)
  }
}

private final class NeoDeferredSettingsRow: UIView {
  private let build: () -> UIView
  private var content: UIView?
  var isResolved: Bool { content != nil }
  var availableWidth: CGFloat = 1 { didSet { if oldValue != availableWidth { (content as? NeoSettingsRow)?.availableWidth = availableWidth; invalidateIntrinsicContentSize(); setNeedsLayout() } } }
  init(build: @escaping () -> UIView) { self.build = build; super.init(frame:.zero) }
  required init?(coder: NSCoder) { fatalError() }
  func resolve() -> UIView {
    if let content { return content }
    let view = build(); content = view; view.translatesAutoresizingMaskIntoConstraints = true
    (view as? NeoSettingsRow)?.availableWidth = availableWidth; addSubview(view); return view
  }
  override var intrinsicContentSize: CGSize { resolve().intrinsicContentSize }
  override func layoutSubviews() { super.layoutSubviews(); resolve().frame = bounds }
}

// SettingsPage's small outlined field / ContentPaste / contained connect /
// error-colored disconnect share one row, including the empty and busy states.
final class NeoAnnictTokenControl: UIView, UITextFieldDelegate {
  let field = UITextField(), connect = UIButton(type:.system), remove = UIButton(type:.system)
  private let paste = UIButton(type:.system)
  var connected = false { didSet { refresh() } }
  var allowed = false { didSet { refresh() } }
  var busy = false { didSet { refresh() } }
  var onChange: ((String?) -> Void)?
  init(write: Bool) {
    super.init(frame:.zero)
    heightAnchor.constraint(equalToConstant:40).isActive = true
    field.isSecureTextEntry = true; field.autocorrectionType = .no; field.autocapitalizationType = .none
    field.textContentType = .password; field.font = .systemFont(ofSize:16); field.textColor = .white
    field.placeholder = write ? "Annict書き込みアクセストークン" : "Annictアクセストークン"
    field.attributedPlaceholder = NSAttributedString(string:field.placeholder!,attributes:[.foregroundColor:UIColor.white.withAlphaComponent(0.5)])
    field.accessibilityIdentifier = write ? "annict-write-token" : "annict-read-token"
    field.layer.cornerRadius = 6; field.layer.borderWidth = 1; field.delegate = self
    let inset = UIView(frame:CGRect(x:0,y:0,width:14,height:40)); field.leftView = inset; field.leftViewMode = .always
    field.addAction(UIAction { [weak self] _ in self?.refresh() },for:.editingChanged)
    paste.setImage(NeoIcon.image("ContentPasteOutlined"),for:.normal); paste.tintColor = .white
    paste.addAction(UIAction { [weak self] _ in self?.field.text = UIPasteboard.general.string; self?.refresh() },for:.touchUpInside)
    paste.accessibilityLabel = write ? "書き込みトークンを貼り付け" : "読み取り専用トークンを貼り付け"
    for (button,title) in [(connect,"接続"),(remove,"解除")] {
      button.setTitle(title,for:.normal); button.titleLabel?.font = .systemFont(ofSize:14,weight:.medium)
      button.layer.cornerRadius = 6; button.setTitleColor(UIColor.white.withAlphaComponent(0.3),for:.disabled)
    }
    connect.setTitleColor(.black,for:.normal)
    remove.setTitleColor(UIColor(red:244/255,green:67/255,blue:54/255,alpha:1),for:.normal)
    connect.addAction(UIAction { [weak self] _ in
      guard let self, connect.isEnabled else { return }
      let token = field.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
      guard !token.isEmpty else { return }; field.text = ""; field.resignFirstResponder(); refresh(); onChange?(token)
    },for:.touchUpInside)
    remove.addAction(UIAction { [weak self] _ in guard let self, remove.isEnabled else { return }; onChange?(nil) },for:.touchUpInside)
    [field,paste,connect,remove].forEach(addSubview); refresh()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func refresh() {
    connect.isEnabled = allowed && !busy && !(field.text?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)
    connect.backgroundColor = connect.isEnabled ? NeoStyle.accent : UIColor.white.withAlphaComponent(0.12)
    remove.isHidden = !connected; remove.isEnabled = connected && allowed && !busy
    field.isEnabled = allowed && !busy; paste.isEnabled = allowed && !busy
    field.layer.borderColor = (field.isFirstResponder ? NeoStyle.accent : UIColor.white.withAlphaComponent(0.23)).cgColor
    setNeedsLayout()
  }
  func textFieldDidBeginEditing(_ textField: UITextField) { refresh() }
  func textFieldDidEndEditing(_ textField: UITextField) { refresh() }
  override func layoutSubviews() {
    super.layoutSubviews(); var right = bounds.width
    if !remove.isHidden { right -= 64; remove.frame = CGRect(x:right,y:0,width:64,height:40); right -= 8 }
    right -= 64; connect.frame = CGRect(x:right,y:2,width:64,height:36); right -= 8
    right -= 40; paste.frame = CGRect(x:right,y:0,width:40,height:40); right -= 8
    field.frame = CGRect(x:0,y:0,width:max(0,right),height:40)
  }
}

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
    table.delaysContentTouches = false
    table.panGestureRecognizer.delaysTouchesEnded = false
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
    let began = CACurrentMediaTime()
    tableView.deselectRow(at: indexPath, animated: true)
    guard let shell else { return }
    shell.pushPage(requestedAt:began) { NeoSettingsCategoryPage(category:NeoSettingsCategory.allCases[indexPath.row],shell:shell) }
  }
#if targetEnvironment(simulator)
  func smokeOpenCategory(_ category: NeoSettingsCategory) {
    tableView(table,didSelectRowAt:IndexPath(row:NeoSettingsCategory.allCases.firstIndex(of:category)!,section:0))
  }
  var smokeTapDeliveryImmediate: Bool { !table.delaysContentTouches && !table.panGestureRecognizer.delaysTouchesEnded }
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

final class NeoSettingsCategoryPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  let category: NeoSettingsCategory
  private let scroll = UIScrollView(), stack = UIStackView()
  private let viewingTable = UITableView(frame:.zero,style:.plain)
  private var viewingRows: [UIView] = [], viewingHeights: [Int:CGFloat] = [:]
  private var viewingWidth: CGFloat = 0
  private let historyToggle = UISwitch()
  private var task: Task<Void, Never>?
  private var firstAppearance = true
  private var annictMutation: Task<Void,Never>?
  private var annictTokens: [NeoAnnictTokenControl] = []
  private var observers: [NSObjectProtocol] = []
  init(category: NeoSettingsCategory, shell: NeoShell) { self.category = category; super.init(title: category.title, shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); stack.axis = .vertical; stack.spacing = 16
    scroll.delaysContentTouches = false
    scroll.panGestureRecognizer.delaysTouchesEnded = false
    if category == .annict {
      stack.backgroundColor = NeoStyle.paper; stack.layer.cornerRadius = 6; stack.layer.borderWidth = 1; stack.layer.borderColor = NeoStyle.border.cgColor
      stack.isLayoutMarginsRelativeArrangement = true; stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top:16,leading:16,bottom:16,trailing:16)
    }
    if category == .viewing {
      viewingTable.backgroundColor = NeoStyle.background; viewingTable.separatorStyle = .none
      viewingTable.delaysContentTouches = false; viewingTable.panGestureRecognizer.delaysTouchesEnded = false
      viewingTable.estimatedRowHeight = 72; viewingTable.contentInset = UIEdgeInsets(top:8,left:0,bottom:16,right:0)
      viewingTable.dataSource = self; viewingTable.delegate = self
      viewingTable.register(NeoSettingsFormCell.self,forCellReuseIdentifier:"setting"); body.addSubview(viewingTable)
    } else {
      body.addSubview(scroll); stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
        stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
        stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
        stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)])
    }
    observers.append(NotificationCenter.default.addObserver(forName: .neoAccountChanged, object: nil, queue: .main) { [weak self] note in
      guard let self, let api = note.object as? NeoAPI, self.shell?.api === api else { return }; self.annictMutation?.cancel(); self.render()
    })
    render()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if firstAppearance { firstAppearance = false } else { render() } }
  override func viewDidLayoutSubviews() {
#if targetEnvironment(simulator)
    let began = CACurrentMediaTime()
#endif
    super.viewDidLayoutSubviews(); scroll.frame = body.bounds
    if category == .viewing {
      viewingTable.frame = body.bounds
      if viewingWidth != body.bounds.width { viewingWidth = body.bounds.width; viewingHeights.removeAll(); viewingTable.reloadData() }
    }
    let width = max(0,body.bounds.width-32-(category == .annict ? 32 : 0))
    for case let row as NeoSettingsRow in stack.arrangedSubviews { row.availableWidth = width }
#if targetEnvironment(simulator)
    smokeOpeningTimes["layoutCallbackWorkMs",default:0] += (CACurrentMediaTime()-began)*1000
#endif
  }
  private func render() {
#if targetEnvironment(simulator)
    smokeRenderCount += 1
    let renderBegan = CACurrentMediaTime()
    defer { smokeOpeningTimes["renderWorkMs",default:0] += (CACurrentMediaTime()-renderBegan)*1000 }
#endif
    task?.cancel(); stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    defer {
      if category == .viewing {
        viewingRows.forEach { $0.removeFromSuperview() }
        viewingRows = stack.arrangedSubviews
        // UIStackView turns autoresizing-mask translation off for arranged
        // children. Cells below own these frames, so restore that ownership.
        viewingRows.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview(); $0.translatesAutoresizingMaskIntoConstraints = true }
        viewingHeights.removeAll(); viewingTable.reloadData()
      }
    }
    guard let shell, let api = shell.api else { return }
    switch category {
    case .viewing:
      buildViewingPreferences()
      deferred { [weak self] in
      guard let self else { return UIView() }
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
      return makeRow("再生エンジン", explanation: "Aetherはエンコード済みPLAY・STREAMINGに使用します。コメント・字幕・PiP・視聴履歴は共通のプレイヤー機能を使います。TSはARIB字幕対応のVLCで再生します。診断用はAV1動画を比較します。次の再生から適用します。", control: engine)
      }
      if NeoPlaybackExperiment.selected == .checkpointPlayer {
        deferred { [weak self] in
        guard let self else { return UIView() }
        let checkpoint = NeoSelectButton(frame:.zero)
        checkpoint.setTitle(NeoPlaybackExperiment.checkpointMode.title, for: .normal)
        checkpoint.showsMenuAsPrimaryAction = true
        checkpoint.menu = UIMenu(children: NeoCheckpointMode.allCases.map { value in
          UIAction(title: value.title, state: NeoPlaybackExperiment.checkpointMode == value ? .on : .off) { [weak self] _ in
            NeoPlaybackExperiment.checkpointMode = value; self?.render()
          }
        })
        return makeRow("チェックポイント", explanation: "1080p以下のAV1が対象です。自動はサーバー解析の最大間隔が10秒以上の場合に使用します。未解析・旧版は解析完了後に選択します。オフでは通常経路で再生します。過去60秒・先読み20秒、保持上限128MiB。次の再生から適用します。", control: checkpoint)
        }
      }
      toggle("リジューム再生", explanation: "保存された再生位置から続けて再生します。", on: api.resumePlayback) { api.resumePlayback = $0 }
      deferred { [weak self] in
      guard let self else { return UIView() }
      historyToggle.isOn = api.disablePlaybackHistory; historyToggle.onTintColor = NeoStyle.accent
      historyToggle.accessibilityLabel = "視聴履歴を送信しない"
      historyToggle.removeTarget(nil, action: nil, for: .valueChanged)
      historyToggle.addTarget(self, action: #selector(historyChanged), for: .valueChanged)
      return makeRow("視聴履歴を送信しない", explanation: "このアプリからの送信だけを止めます。既存の履歴とリジューム位置は残ります。", control: historyToggle)
      }
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
    case .annict: buildAnnictPreferences(api)
    case .discord: break
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
  private func buildAnnictPreferences(_ api: NeoAPI) {
    stack.addArrangedSubview(NeoStyle.label("Annict連携",size:20,bold:true))
    annictTokens = []
    for write in [false,true] {
      stack.addArrangedSubview(NeoStyle.label(write ? "書き込みアクセストークン" : "読み取り専用アクセストークン",size:16))
      let status = NeoStyle.label(size:13,muted:true); status.numberOfLines = 0
      let description = write ? "視聴記録の更新に使用します。現在のアクティブユーザーのプロフィールに保存されます。" : "アニメ作品と放送予定の取得に使用します。トークンはサーバーだけに保存されます。"
      status.textColor = UIColor.white.withAlphaComponent(0.5); status.text = description+" 現在: 確認中"; stack.addArrangedSubview(status)
      let control = NeoAnnictTokenControl(write:write)
      control.allowed = api.accountReady && (!write || api.profileHeaders["X-Viewer-Profile-Id"] != nil)
      control.busy = annictMutation != nil
      control.onChange = { [weak self] token in self?.updateAnnictToken(token,write:write,api:api) }
      annictTokens.append(control); stack.addArrangedSubview(control)
      let line = UIView(); line.backgroundColor = NeoStyle.border; line.heightAnchor.constraint(equalToConstant:1).isActive = true; stack.addArrangedSubview(line)
      status.tag = write ? 8002 : 8001
    }
    if api.profileHeaders["X-Viewer-Profile-Id"] == nil { info("書き込み連携には、アカウント設定で通常ユーザーを選択してください。") }
    choice("自動視聴記録",values:[("disabled","自動記録しない"),("start","PLAY／STREAMING開始時"),("progress","指定割合まで視聴した時")],selected:NeoAnnictPreferences.mode) { NeoAnnictPreferences.mode = $0 }
    if NeoAnnictPreferences.mode == "progress" {
      let amount = UIStepper(); amount.minimumValue = 1; amount.maximumValue = 100; amount.value = Double(NeoAnnictPreferences.threshold)
      amount.accessibilityIdentifier = "annict-threshold"
      let value = NeoStyle.label("\(NeoAnnictPreferences.threshold)%")
      amount.addAction(UIAction { [weak amount,weak value] _ in
        NeoAnnictPreferences.threshold = Int(amount?.value ?? 90); value?.text = "\(NeoAnnictPreferences.threshold)%"
      },for:.valueChanged)
      let control = UIStackView(arrangedSubviews:[value,amount]); control.spacing = 8
      row("視聴判定割合",explanation:"シークを除き、実際に再生した累計時間がこの割合に達した時に記録します。",control:control)
    }
    toggle("最終話視聴後に作品を「見た」にする",explanation:"EPGの最終回表示を最優先し、表示がない場合はAnnictのエピソード情報で最終話を確認して更新します。",on:NeoAnnictPreferences.markFinal) { [weak self] in NeoAnnictPreferences.markFinal = $0; self?.render() }
    let rules = UISwitch(); rules.isOn = NeoAnnictPreferences.disableFinalRules; rules.onTintColor = NeoStyle.accent; rules.isEnabled = NeoAnnictPreferences.markFinal
    rules.accessibilityLabel = "最終話視聴後にルールを無効化する"
    rules.addAction(UIAction { [weak rules] _ in NeoAnnictPreferences.disableFinalRules = rules?.isOn ?? false },for:.valueChanged)
    row("最終話視聴後にルールを無効化する",explanation:"Annictに次話がなく、予約が残っていない、視聴したプロフィール所有のルールだけを無効化します。",control:rules)
    let revision = api.identityRevision
    task = Task { [weak self] in
      do {
        let value = try await api.annictStatus(); guard !Task.isCancelled, api.identityRevision == revision, let self else { return }
        for (index,connected) in [value.configured,value.writeConfigured].enumerated() {
          guard self.annictTokens.indices.contains(index) else { continue }
          self.annictTokens[index].connected = connected
          let status = self.view.viewWithTag(index == 0 ? 8001 : 8002) as? UILabel
          status?.text = status?.text?.replacingOccurrences(of:"確認中",with:connected ? "接続済み" : "未設定")
        }
      } catch { if !Task.isCancelled, api.identityRevision == revision {
        for tag in [8001,8002] { (self?.view.viewWithTag(tag) as? UILabel)?.text = "連携状態を取得できませんでした。" }
      } }
    }
  }
  private func updateAnnictToken(_ token: String?, write: Bool, api: NeoAPI) {
    guard annictMutation == nil, api.accountReady else { return }
    let revision = api.identityRevision
    let user = api.viewer, headers = api.profileHeaders
    annictTokens.forEach { $0.busy = true }
    annictMutation = Task { [weak self] in
      guard let self else { return }; defer { self.annictMutation = nil; self.annictTokens.forEach { $0.busy = false } }
      guard !Task.isCancelled, api.identityRevision == revision else { return }
      do {
        try await api.annictToken(token,write:write,user:user,headers:headers)
        guard !Task.isCancelled, api.identityRevision == revision else { return }; self.render()
      } catch { if !Task.isCancelled, api.identityRevision == revision { self.alert("Annictの連携設定を更新できませんでした。") } }
    }
  }
  private func choice(_ title: String, values: [(String,String)], selected: String, save: @escaping (String) -> Void) {
    let build: () -> UIView = { [weak self] in
      guard let self else { return UIView() }
      let control = NeoSelectButton(frame:.zero)
      control.setTitle(values.first { $0.0 == selected }?.1 ?? selected,for:.normal)
      control.accessibilityIdentifier = "viewing-"+title
      control.menu = UIMenu(children:values.map { key,text in UIAction(title:text,state:key == selected ? .on : .off) { [weak self] _ in save(key); self?.render() } })
      return self.makeRow(title,control:control)
    }
    stack.addArrangedSubview(category == .viewing ? NeoDeferredSettingsRow(build:build) : build())
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
    deferred { [weak self] in
    guard let self else { return UIView() }
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
    return makeRow("優先字幕",explanation:"上から順に弾幕と通常字幕を照合します。通常字幕は一致がなければオフになります。",control:priorities)
    }
    toggle("コメントを表示",on:NeoViewingPreferences.commentsEnabled) { NeoViewingPreferences.commentsEnabled = $0 }
    toggle("字幕・コメントの準備を待ってPLAY再生を開始",on:NeoCommentOverlay.waitBeforePlayback) { NeoCommentOverlay.waitBeforePlayback = $0 }
    deferred { [weak self] in
    guard let self else { return UIView() }
    let network = UIStepper(); network.minimumValue = 1; network.maximumValue = 30; network.value = Double(NeoViewingPreferences.networkSeconds)
    network.accessibilityIdentifier = "viewing-network-cache"
    network.addAction(UIAction { [weak self,weak network] _ in NeoViewingPreferences.networkSeconds = Int(network?.value ?? 5); self?.render() },for:.valueChanged)
    return makeRow("PLAYのネットワークキャッシュ：\(NeoViewingPreferences.networkSeconds)秒",explanation:"次の再生・再読み込みから適用します。",control:network)
    }
    choice("PLAYの巻き戻し用キャッシュ",values:NeoPlaybackCache.presets.map { (String($0),$0 == 0 ? "オフ" : "\($0)秒") },selected:String(NeoPlaybackCache.savedSeconds)) { UserDefaults.standard.set(Int($0) ?? 60,forKey:NeoPlaybackCache.preference) }
    for ts in [false,true] {
      for rewind in [false,true] {
        choice("\(ts ? "TS" : "エンコード済み")STREAMINGの\(rewind ? "巻き戻し用キャッシュ" : "先読み")",values:(rewind ? NeoStreamBuffer.rewindChoices : NeoStreamBuffer.aheadChoices).map { (String($0),NeoStreamBuffer.label($0,ts:ts)) },selected:String(NeoStreamBuffer.count(ts:ts,rewind:rewind))) { NeoStreamBuffer.save(Int($0) ?? 0,ts:ts,rewind:rewind) }
      }
    }
    let sizeLabel = NeoStyle.label(String(format:"文字サイズ %.2f倍",NeoViewingPreferences.commentSize))
    stack.addArrangedSubview(sizeLabel)
    deferred { [weak sizeLabel] in
    let size = UISlider(); size.minimumValue = 0.5; size.maximumValue = 2; size.value = Float(NeoViewingPreferences.commentSize)
    size.minimumTrackTintColor = NeoStyle.accent; size.maximumTrackTintColor = NeoStyle.border
    size.accessibilityIdentifier = "viewing-comment-size"
    size.addAction(UIAction { [weak size,weak sizeLabel] _ in NeoViewingPreferences.commentSize = Double(size?.value ?? 1); sizeLabel?.text = String(format:"文字サイズ %.2f倍",NeoViewingPreferences.commentSize) },for:.valueChanged)
    return size
    }
    let opacityLabel = NeoStyle.label("コメントの不透明度 \(Int(NeoViewingPreferences.commentOpacity*100))%")
    stack.addArrangedSubview(opacityLabel)
    deferred { [weak opacityLabel] in
    let opacity = UISlider(); opacity.minimumValue = 0; opacity.maximumValue = 1; opacity.value = NeoViewingPreferences.commentOpacity
    opacity.minimumTrackTintColor = NeoStyle.accent; opacity.maximumTrackTintColor = NeoStyle.border
    opacity.accessibilityIdentifier = "viewing-comment-opacity"
    opacity.addAction(UIAction { [weak opacity,weak opacityLabel] _ in NeoViewingPreferences.commentOpacity = opacity?.value ?? 1; opacityLabel?.text = "コメントの不透明度 \(Int(NeoViewingPreferences.commentOpacity*100))%" },for:.valueChanged)
    return opacity
    }
  }
  private func deferred(_ build: @escaping () -> UIView) { stack.addArrangedSubview(NeoDeferredSettingsRow(build:build)) }
  private func info(_ text: String) { let label = NeoStyle.label(text, muted: true); label.numberOfLines = 0; stack.addArrangedSubview(label) }
  private func button(_ title: String, action: @escaping () -> Void) {
    let button = NeoStyle.button(title, action: action); button.contentHorizontalAlignment = .left
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true; stack.addArrangedSubview(button)
  }
  private func row(_ title: String, explanation: String = "", control: UIView) {
    stack.addArrangedSubview(makeRow(title,explanation:explanation,control:control))
  }
  private func makeRow(_ title: String, explanation: String = "", control: UIView) -> UIView {
    let row = NeoSettingsRow(title:title,explanation:explanation,control:control)
    row.availableWidth = max(1,(navigationController?.view.bounds.width ?? view.bounds.width)-32-(category == .annict ? 32 : 0))
    return row
  }
  private func toggle(_ title: String, explanation: String = "", on: Bool, action: @escaping (Bool) -> Void) {
    let build: () -> UIView = { [weak self] in
      guard let self else { return UIView() }
      let toggle = UISwitch(); toggle.isOn = on; toggle.onTintColor = NeoStyle.accent; toggle.accessibilityLabel = title
      toggle.addAction(UIAction { [weak toggle] _ in if let toggle { action(toggle.isOn) } }, for:.valueChanged)
      return self.makeRow(title,explanation:explanation,control:toggle)
    }
    stack.addArrangedSubview(category == .viewing ? NeoDeferredSettingsRow(build:build) : build())
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { viewingRows.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier:"setting",for:indexPath) as! NeoSettingsFormCell
    cell.backgroundColor = NeoStyle.background; cell.selectionStyle = .none; cell.setting = viewingRows[indexPath.row]; return cell
  }
  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    if let height = viewingHeights[indexPath.row] { return height }
    let setting = viewingRows[indexPath.row], width = max(1,tableView.bounds.width-32)
    if let deferred = setting as? NeoDeferredSettingsRow { deferred.availableWidth = width }
    if let row = setting as? NeoSettingsRow { row.availableWidth = width }
    let intrinsic = setting.intrinsicContentSize
    let height: CGFloat
    if let label = setting as? UILabel { height = label.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude)).height }
    else if intrinsic.height > 0 { height = intrinsic.height }
    else { height = setting.systemLayoutSizeFitting(CGSize(width:width,height:0),withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height }
    let result = max(16,height+16); viewingHeights[indexPath.row] = result; return result
  }
#if targetEnvironment(simulator)
  var smokeAllSettingViews: [UIView] {
    func all(_ view: UIView) -> [UIView] {
      if let deferred = view as? NeoDeferredSettingsRow { _ = deferred.resolve() }
      return [view]+view.subviews.flatMap(all)
    }
    return category == .viewing ? viewingRows.flatMap(all) : all(view)
  }
  func smokeViewingListScrolls() -> Bool {
    guard category == .viewing, viewingRows.count > 12 else { return false }
    viewingTable.layoutIfNeeded()
    let lazy = viewingTable.visibleCells.count < viewingRows.count
    let deferred = viewingRows.compactMap { $0 as? NeoDeferredSettingsRow }
    let lazyCreation = deferred.contains { !$0.isResolved }
    let last = IndexPath(row:viewingRows.count-1,section:0)
    viewingTable.scrollToRow(at:last,at:.bottom,animated:false); viewingTable.layoutIfNeeded()
    let bottom = viewingTable.indexPathsForVisibleRows?.contains(last) == true
    viewingTable.scrollToRow(at:IndexPath(row:0,section:0),at:.top,animated:false); viewingTable.layoutIfNeeded()
    return lazy && lazyCreation && bottom
  }
  var smokeVisibleViewingControlsFit: Bool {
    viewingTable.layoutIfNeeded()
    func all(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(all) }
    let visible = viewingTable.visibleCells.flatMap { cell -> [UIView] in cell.layoutIfNeeded(); return all(cell.contentView) }
    let choices = visible.compactMap { $0 as? NeoSelectButton }
    let required = Set(["viewing-エンコーダー","viewing-デフォルト画質"])
    return choices.filter { required.contains($0.accessibilityIdentifier ?? "") }.count == 2
      && choices.allSatisfy { $0.bounds.width >= 44 && $0.bounds.height >= 44 }
      && visible.compactMap { $0 as? NeoSettingsRow }.allSatisfy { $0.smokeControlFits }
  }
  func smokeSaveRowGeometry() {
    func all(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(all) }
    let rows = all(category == .viewing ? viewingTable : scroll).compactMap { $0 as? NeoSettingsRow }
    if let data = try? JSONSerialization.data(withJSONObject:rows.map(\.smokeGeometry),options:.prettyPrinted) {
      try? data.write(to:NeoPiPSmoke.directory.appendingPathComponent("recording-\(category.rawValue)-geometry.json"))
    }
  }
  func smokeConnectAnnict(write: Bool, token: String) {
    guard annictTokens.indices.contains(write ? 1 : 0) else { return }
    let control = annictTokens[write ? 1 : 0]; control.field.text = token; control.field.sendActions(for:.editingChanged)
    control.connect.sendActions(for:.touchUpInside)
  }
  var smokeTokenControls: [NeoAnnictTokenControl] { annictTokens }
  var smokeRenderCount = 0
  var smokeSettingCount: Int { category == .viewing ? viewingRows.count : stack.arrangedSubviews.count }
  var smokeControlsWithinWidth: Bool {
    view.layoutIfNeeded()
    func all(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(all) }
    let surface: UIView = category == .viewing ? viewingTable : scroll
    return all(surface).filter { $0 is UISwitch || $0 is UIStepper || $0 is UITextField || $0 is UISlider }.allSatisfy {
      let rect = surface.convert($0.bounds,from:$0)
      let hasSize = category != .annict || ($0.bounds.width >= 24 && $0.bounds.height >= 20)
      return hasSize && rect.minX >= 15 && rect.maxX <= surface.bounds.width-15
    }
  }
  var smokeAccountSelector: Bool {
    guard category == .account, let selector = stack.arrangedSubviews.flatMap({ $0.subviews }).first(where: { $0 is NeoUserSelector }) as? NeoUserSelector else { return false }
    return selector.bounds.size == CGSize(width: 160, height: 40) && selector.showsMenuAsPrimaryAction && selector.menu != nil
  }
  func smokeSetHistoryDisabled(_ value: Bool) { _ = smokeAllSettingViews; historyToggle.isOn = value; historyToggle.sendActions(for: .valueChanged) }
#endif
  deinit { task?.cancel(); annictMutation?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
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
