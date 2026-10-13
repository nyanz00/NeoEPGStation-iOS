import UIKit

// Mobile search form: same fields, option endpoints and request semantics as RecordedPage.tsx.
final class NeoRecordedSearch: UIViewController {
  private let api: NeoAPI, channels: [Int: String], userID: Int?
  private var draft: NeoRecordedFilters
  private let scroll = UIScrollView(), stack = UIStackView()
  private var options: NeoRecordedOptions?, ruleName = "", task: Task<Void, Never>?
  var onApply: ((NeoRecordedFilters) -> Void)?
#if targetEnvironment(simulator)
  var smokeFixtures = false
  var smokeValid: Bool { stack.arrangedSubviews.filter { $0 is UITextField }.count == 3 && options?.encode.count == 2 }
#endif
  init(api: NeoAPI, channels: [Int: String], userID: Int?, filters: NeoRecordedFilters) {
    self.api = api; self.channels = channels; self.userID = userID; draft = filters
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "録画検索"; view.backgroundColor = NeoStyle.paper
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "閉じる", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "検索", primaryAction: UIAction { [weak self] _ in self?.apply() })
    navigationController?.navigationBar.tintColor = NeoStyle.accent
    view.addSubview(scroll); scroll.keyboardDismissMode = .interactive
    stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)])
    NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    render(); loadOptions()
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); scroll.frame = view.bounds.inset(by: view.safeAreaInsets) }
  private func loadOptions() {
    task?.cancel()
#if targetEnvironment(simulator)
    if smokeFixtures {
      options = NeoRecordedOptions(channels: [.init(channelId: 1, cnt: 12)], genres: [.init(genre: 7, cnt: 12)], encode: [.init(name: "AV1 / MKV", suffix: ".mkv"), .init(name: "H.264", suffix: ".mp4")])
      render(); return
    }
#endif
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await api.recordedOptions(userID: userID)
        if let id = draft.ruleID { ruleName = try await api.rule(id).searchOption.keyword ?? "" }
        guard !Task.isCancelled else { return }; options = result; render()
      } catch {
        guard !Task.isCancelled else { return }
        let message = NeoStyle.label("検索候補を取得できませんでした。", muted: true); stack.addArrangedSubview(message)
        stack.addArrangedSubview(NeoStyle.button("再試行") { [weak self] in self?.loadOptions() })
      }
    }
  }
  private func render() {
    let offset = scroll.contentOffset
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    field("キーワード", value: draft.keyword) { [weak self] in self?.draft.keyword = $0 }
    choice("ルール", value: draft.manualOnly ? "手動録画のみ" : draft.ruleID.map { ruleName.isEmpty ? "ルール \($0)" : ruleName } ?? "すべて", enabled: !draft.manualOnly && options != nil) { [weak self] in self?.selectRule() }
    choice("チャンネル", value: draft.channelID.flatMap { channels[$0] } ?? "すべて", enabled: options != nil) { [weak self] in
      guard let self, let options else { return }
      choose(title: "チャンネル", entries: [("すべて", "")] + options.channels.map { ("\(self.channels[$0.channelId] ?? String($0.channelId)) (\($0.cnt))", String($0.channelId)) }, selected: draft.channelID.map(String.init) ?? "") { [weak self] in self?.draft.channelID = Int($0); self?.render() }
    }
    let genres = ["ニュース・報道", "スポーツ", "情報・ワイドショー", "ドラマ", "音楽", "バラエティ", "映画", "アニメ・特撮", "ドキュメンタリー・教養", "劇場・公演", "趣味・教育", "福祉", "予備", "予備", "拡張", "その他"]
    choice("ジャンル", value: draft.genre.map { genres.indices.contains($0) ? genres[$0] : String($0) } ?? "すべて", enabled: options != nil) { [weak self] in
      guard let self, let options else { return }
      choose(title: "ジャンル", entries: [("すべて", "")] + options.genres.map { ("\(genres.indices.contains($0.genre) ? genres[$0.genre] : String($0.genre)) (\($0.cnt))", String($0.genre)) }, selected: draft.genre.map(String.init) ?? "") { [weak self] in self?.draft.genre = Int($0); self?.render() }
    }
    choice("ファイルタイプ", value: draft.encodeModes.isEmpty ? "すべて" : draft.encodeModes.map { $0 == "__ts__" ? "TS" : $0 }.joined(separator: "、"), enabled: options != nil) { [weak self] in self?.selectFiles() }
    segment(["含む", "のみ"], selected: draft.encodeModeMatch == "only" ? 1 : 0) { [weak self] in self?.draft.encodeModeMatch = $0 == 1 ? "only" : "include" }
    toggle("元ファイルを含む", on: draft.hasOriginalFile) { [weak self] in self?.draft.hasOriginalFile = $0 }
    toggle("手動録画のみ", on: draft.manualOnly) { [weak self] in self?.draft.manualOnly = $0; self?.draft.ruleID = nil; self?.render() }
    toggle("drop", on: draft.hasDrop) { [weak self] in self?.draft.hasDrop = $0 }
    toggle("error", on: draft.hasError) { [weak self] in self?.draft.hasError = $0 }
    toggle("scrambling", on: draft.hasScrambling) { [weak self] in self?.draft.hasScrambling = $0 }
    segment(["期間", "日付指定"], selected: draft.specificDate ? 1 : 0) { [weak self] in self?.draft.specificDate = $0 == 1; self?.render() }
    if draft.specificDate {
      field("年", value: draft.year, numeric: true) { [weak self] in self?.draft.year = $0 }
      field("月", value: draft.month, numeric: true) { [weak self] in self?.draft.month = $0 }
      field("日", value: draft.day, numeric: true) { [weak self] in self?.draft.day = $0 }
    } else {
      field("開始日", value: draft.startDate, placeholder: "YYYY-MM-DD") { [weak self] in self?.draft.startDate = $0 }
      field("終了日", value: draft.endDate, placeholder: "YYYY-MM-DD") { [weak self] in self?.draft.endDate = $0 }
    }
    stack.addArrangedSubview(NeoStyle.button("クリア") { [weak self] in self?.draft = NeoRecordedFilters(); self?.render() })
    stack.addArrangedSubview(NeoStyle.button("検索", filled: true) { [weak self] in self?.apply() })
    view.layoutIfNeeded(); scroll.setContentOffset(offset, animated: false)
  }
  private func field(_ title: String, value: String, placeholder: String = "", numeric: Bool = false, change: @escaping (String) -> Void) {
    let label = NeoStyle.label(title); stack.addArrangedSubview(label)
    let field = UITextField(); field.text = value; field.placeholder = placeholder; field.textColor = .white
    field.autocorrectionType = .no; field.autocapitalizationType = .none; field.clearButtonMode = .whileEditing
    field.keyboardType = numeric ? .numberPad : .default; field.borderStyle = .roundedRect
    field.backgroundColor = NeoStyle.background; field.heightAnchor.constraint(equalToConstant: 44).isActive = true
    field.accessibilityIdentifier = "recorded-search-\(title)"; field.accessibilityLabel = title
    field.addAction(UIAction { [weak field] _ in change(field?.text ?? "") }, for: .editingChanged); stack.addArrangedSubview(field)
  }
  private func choice(_ title: String, value: String, enabled: Bool = true, action: @escaping () -> Void) {
    stack.addArrangedSubview(NeoStyle.label(title))
    let button = NeoStyle.button(value + " ▾", action: action); button.contentHorizontalAlignment = .left
    button.isEnabled = enabled; button.titleLabel?.numberOfLines = 0; button.layer.borderWidth = 1; button.layer.borderColor = NeoStyle.border.cgColor
    button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; stack.addArrangedSubview(button)
  }
  private func toggle(_ title: String, on: Bool, change: @escaping (Bool) -> Void) {
    let toggle = UISwitch(); toggle.isOn = on; toggle.onTintColor = NeoStyle.accent
    toggle.addAction(UIAction { [weak toggle] _ in change(toggle?.isOn == true) }, for: .valueChanged)
    let label = NeoStyle.label(title); label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [label, toggle]); row.distribution = .equalSpacing; row.alignment = .center; stack.addArrangedSubview(row)
  }
  private func segment(_ titles: [String], selected: Int, change: @escaping (Int) -> Void) {
    let segment = UISegmentedControl(items: titles); segment.selectedSegmentIndex = selected; segment.selectedSegmentTintColor = NeoStyle.accent
    segment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
    segment.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
    segment.addAction(UIAction { [weak segment] _ in change(segment?.selectedSegmentIndex ?? 0) }, for: .valueChanged); stack.addArrangedSubview(segment)
  }
  private func choose(title: String, entries: [(String, String)], selected: String, apply: @escaping (String) -> Void) {
    let page = NeoRecordedChoices(title: title, entries: entries, selected: [selected])
    page.onChange = { values in apply(values.first ?? "") }; navigationController?.pushViewController(page, animated: true)
  }
  private func selectFiles() {
    guard let options else { return }
    let page = NeoRecordedChoices(title: "ファイルタイプ", entries: [("TS", "__ts__")] + options.encode.map { ($0.name + ($0.suffix.map { " (\($0))" } ?? ""), $0.name) }, selected: draft.encodeModes, multiple: true)
    page.onChange = { [weak self] in self?.draft.encodeModes = $0.sorted(); self?.render() }; navigationController?.pushViewController(page, animated: true)
  }
  private func selectRule() {
    let page = NeoRecordedChoices(title: "ルール", entries: [("すべて", "")], selected: [draft.ruleID.map(String.init) ?? ""])
    page.onChange = { [weak self, weak page] values in
      guard let self else { return }; draft.ruleID = values.first.flatMap(Int.init)
      ruleName = page?.entries.first { $0.1 == values.first }?.0 ?? ""; render()
    }
    page.onSearch = { [weak self, weak page] text in
      guard let self else { return }
      self.task?.cancel(); self.task = Task { [weak self, weak page] in
        guard let self else { return }
        do {
          try await Task.sleep(nanoseconds: 250_000_000)
          var rules = try await api.ruleKeywords(keyword: text, userID: userID)
          if let id = draft.ruleID, !rules.contains(where: { $0.id == id }) {
            let rule = try await api.rule(id); rules.insert(NeoRuleKeyword(id: id, keyword: rule.searchOption.keyword ?? ""), at: 0)
          }
          guard !Task.isCancelled else { return }
          page?.entries = [("すべて", "")] + rules.map { ($0.keyword.isEmpty ? "ルール \($0.id)" : $0.keyword, String($0.id)) }
          page?.reload()
        } catch { if !Task.isCancelled { page?.showError() } }
      }
    }
    navigationController?.pushViewController(page, animated: true); page.onSearch?("")
  }
  private func apply() {
    do { _ = try draft.queryItems(); view.endEditing(true); let value = draft, action = onApply; dismiss(animated: true) { action?(value) } }
    catch { let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "閉じる", style: .cancel)); present(alert, animated: true) }
  }
  @objc private func keyboard(_ note: Notification) {
    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    scroll.contentInset.bottom = max(0, scroll.frame.maxY - view.convert(frame, from: nil).minY)
    scroll.verticalScrollIndicatorInsets.bottom = scroll.contentInset.bottom
  }
  deinit { task?.cancel(); NotificationCenter.default.removeObserver(self) }
}

private final class NeoRecordedChoices: UITableViewController, UISearchResultsUpdating {
  var entries: [(String, String)], onChange: (([String]) -> Void)?, onSearch: ((String) -> Void)?
  private var selected: Set<String>, multiple: Bool
  private let search = UISearchController(searchResultsController: nil)
  init(title: String, entries: [(String, String)], selected: [String], multiple: Bool = false) {
    self.entries = entries; self.selected = Set(selected); self.multiple = multiple
    super.init(style: .plain); self.title = title
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); tableView.backgroundColor = NeoStyle.paper; tableView.separatorColor = NeoStyle.border
    search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
    definesPresentationContext = true
    search.searchBar.placeholder = title == "ルール" ? "ルールのキーワードを入力" : "検索"
    navigationItem.searchController = search; navigationItem.hidesSearchBarWhenScrolling = false
    if multiple { navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完了", primaryAction: UIAction { [weak self] _ in
      guard let self else { return }; onChange?(Array(selected)); navigationController?.popViewController(animated: true)
    }) }
    reload()
  }
  private var visible: [(String, String)] {
    let text = search.searchBar.text ?? ""
    return onSearch != nil || text.isEmpty ? entries : entries.filter { $0.0.localizedCaseInsensitiveContains(text) }
  }
  func updateSearchResults(for searchController: UISearchController) { onSearch?(searchController.searchBar.text ?? ""); reload() }
  func reload() { tableView.backgroundView = nil; tableView.reloadData(); if multiple { title = "ファイルタイプ（\(selected.count)件選択中）" } }
  func showError() {
    let retry = NeoStyle.button("候補を取得できませんでした。再試行") { [weak self] in self?.onSearch?(self?.search.searchBar.text ?? "") }; tableView.backgroundView = retry
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let entry = visible[indexPath.row], cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.textLabel?.text = entry.0; cell.textLabel?.numberOfLines = 0; cell.textLabel?.textColor = .white; cell.backgroundColor = NeoStyle.paper
    cell.accessoryType = selected.contains(entry.1) ? .checkmark : .none; cell.tintColor = NeoStyle.accent; return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let value = visible[indexPath.row].1
    if multiple { if selected.contains(value) { selected.remove(value) } else { selected.insert(value) }; reload() }
    else { selected = [value]; onChange?([value]); navigationController?.popViewController(animated: true) }
  }
}
