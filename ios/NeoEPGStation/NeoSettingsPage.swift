import UIKit

final class NeoConnectionPage: NeoPage, UITextFieldDelegate {
  let field = UITextField()
  var initialMessage: String?
  private let scroll = UIScrollView(), panel = UIView()
  private let heading = NeoStyle.label("サーバー接続", size: 20, bold: true)
  private let hint = NeoStyle.label("NeoEPGStationのURLを入力してください。", muted: true)
  private let errorLabel = NeoStyle.label()
  private lazy var save = NeoStyle.button("保存して接続", filled: true) { [weak self] in self?.submit() }
  init(shell: NeoShell) { super.init(title: "NeoEPGStation", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); body.addSubview(scroll); scroll.addSubview(panel)
    panel.backgroundColor = NeoStyle.paper; panel.layer.cornerRadius = 6
    [heading, hint, field, save, errorLabel].forEach(panel.addSubview)
    field.font = .systemFont(ofSize: 16); field.textColor = .white; field.placeholder = "https://example.com"
    field.autocorrectionType = .no; field.autocapitalizationType = .none; field.keyboardType = .URL
    field.returnKeyType = .go; field.clearButtonMode = .whileEditing; field.delegate = self
    field.layer.borderWidth = 1; field.layer.borderColor = NeoStyle.border.cgColor; field.layer.cornerRadius = 6
    let padding = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 48)); field.leftView = padding; field.leftViewMode = .always
    field.text = (try? shell?.storage.loadConnection())?.absoluteString
    errorLabel.numberOfLines = 0; errorLabel.textColor = .systemRed; errorLabel.text = initialMessage
    NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); scroll.frame = body.bounds
    let width = min(640, max(0, body.bounds.width - 24))
    panel.frame = CGRect(x: (body.bounds.width - width) / 2, y: 12, width: width, height: 300)
    heading.frame = CGRect(x: 16, y: 16, width: width - 32, height: 28)
    hint.frame = CGRect(x: 16, y: 52, width: width - 32, height: 28)
    field.frame = CGRect(x: 16, y: 92, width: width - 32, height: 52)
    save.frame = CGRect(x: 16, y: 160, width: width - 32, height: 44)
    errorLabel.frame = CGRect(x: 16, y: 216, width: width - 32, height: 72)
    scroll.contentSize = CGSize(width: body.bounds.width, height: 336)
  }
  private func submit() {
    do {
      let url = try NeoServerURL.normalize(field.text ?? "")
      try shell?.storage.saveConnection(url); view.endEditing(true); shell?.connect(url)
    } catch { errorLabel.text = error.localizedDescription }
  }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool { submit(); return true }
  @objc private func keyboard(_ notification: Notification) {
    guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let local = view.convert(frame, from: nil)
    scroll.contentInset.bottom = max(0, view.bounds.maxY - local.minY)
    scroll.scrollIndicatorInsets.bottom = scroll.contentInset.bottom
  }
  deinit { NotificationCenter.default.removeObserver(self) }
}

final class NeoSettingsPage: NeoPage {
  private let stack = UIStackView()
  init(shell: NeoShell) { super.init(title: "設定", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); stack.axis = .vertical; stack.spacing = 12; body.addSubview(stack)
    let heading = NeoStyle.label("アプリ設定", size: 16, bold: true); stack.addArrangedSubview(heading)
    let server = NeoStyle.button("接続先を変更") { [weak self] in
      guard let self, let shell = self.shell else { return }
      self.navigationController?.pushViewController(NeoConnectionPage(shell: shell), animated: true)
    }
    let navigation = NeoStyle.button("下部ナビゲーションを編集") { [weak self] in
      guard let self, let shell = self.shell else { return }
      self.navigationController?.pushViewController(NeoShortcutPage(shell: shell), animated: true)
    }
    for button in [server, navigation] {
      button.contentHorizontalAlignment = .left; button.heightAnchor.constraint(equalToConstant: 48).isActive = true
      button.backgroundColor = NeoStyle.paper; stack.addArrangedSubview(button)
    }
    let thumbnail = UIStackView(); thumbnail.axis = .horizontal; thumbnail.spacing = 8; thumbnail.alignment = .center
    let label = NeoStyle.label("THUMBボタンを表示しない"); label.numberOfLines = 0
    let toggle = UISwitch(); toggle.isOn = shell?.storage.hideRecordedThumbnailButton ?? true; toggle.onTintColor = NeoStyle.accent
    toggle.accessibilityLabel = "THUMBボタンを表示しない"
    toggle.addAction(UIAction { [weak self, weak toggle] _ in
      guard let toggle else { return }; self?.shell?.storage.hideRecordedThumbnailButton = toggle.isOn
    }, for: .valueChanged)
    thumbnail.addArrangedSubview(label); thumbnail.addArrangedSubview(toggle)
    thumbnail.heightAnchor.constraint(equalToConstant: 48).isActive = true; stack.addArrangedSubview(thumbnail)
    let text = NeoStyle.label("テーマ：ターコイズ・ダーク", muted: true); stack.addArrangedSubview(text)
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); stack.frame = CGRect(x: 12, y: 16, width: body.bounds.width - 24, height: 270) }
}

final class NeoShortcutPage: NeoPage, UITableViewDataSource, UITableViewDelegate {
  private let table = UITableView(frame: .zero, style: .plain)
  private var values: [String]
  init(shell: NeoShell) { values = shell.storage.shortcuts; super.init(title: "下部ナビゲーション", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); table.backgroundColor = NeoStyle.background; table.separatorColor = NeoStyle.border
    table.dataSource = self; table.delegate = self; table.isEditing = true; table.allowsSelectionDuringEditing = true
    table.register(UITableViewCell.self, forCellReuseIdentifier: "option"); body.addSubview(table)
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); table.frame = body.bounds }
  func numberOfSections(in tableView: UITableView) -> Int { 2 }
  private var available: [NeoDestination] { NeoDestination.all.filter { !values.contains($0.id) } }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? values.count : available.count }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "表示する項目（1〜5個・ドラッグで並べ替え）" : "追加する項目" }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = indexPath.section == 0 ? NeoDestination.all.first { $0.id == values[indexPath.row] }! : available[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "option", for: indexPath)
    var config = cell.defaultContentConfiguration(); config.text = item.title; config.textProperties.color = .white
    config.image = NeoIcon.image(item.icon); config.imageProperties.tintColor = NeoStyle.accent
    cell.contentConfiguration = config; cell.backgroundColor = NeoStyle.paper; cell.showsReorderControl = indexPath.section == 0; return cell
  }
  func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { indexPath.section == 0 }
  func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath { proposed.section == 0 ? proposed : IndexPath(row: values.count - 1, section: 0) }
  func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
    let value = values.remove(at: source.row); values.insert(value, at: destination.row); persist()
  }
  func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { indexPath.section == 0 ? .delete : .insert }
  func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) { change(indexPath) }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { if indexPath.section == 1 { change(indexPath) } }
  private func change(_ indexPath: IndexPath) {
    if indexPath.section == 0 {
      guard values.count > 1 else { alert("少なくとも1項目を残してください。"); return }; values.remove(at: indexPath.row)
    } else {
      guard values.count < 5 else { alert("最大5項目まで選べます。"); return }; values.append(available[indexPath.row].id)
    }
    persist(); table.reloadData()
  }
  private func persist() { do { try shell?.saveShortcuts(values) } catch { alert(error.localizedDescription) } }
}

final class NeoPlaceholderPage: NeoPage {
  private let info = NeoStyle.label("この画面の機能は準備中です。\n現在は録画済みの検索・詳細・PLAY再生を利用できます。", muted: true)
  init(id: String, shell: NeoShell) { super.init(title: NeoDestination.all.first { $0.id == id }?.title ?? "", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() { super.viewDidLoad(); info.numberOfLines = 0; body.addSubview(info) }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); info.frame = CGRect(x: 16, y: 24, width: body.bounds.width - 32, height: 100) }
}
