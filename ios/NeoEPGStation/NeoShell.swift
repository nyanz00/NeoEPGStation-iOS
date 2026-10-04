import UIKit

struct NeoDestination {
  let id: String; let title: String; let icon: String
  static let all: [NeoDestination] = [
    .init(id: "dashboard", title: "ダッシュボード", icon: "DashboardOutlined"),
    .init(id: "onair", title: "放映中", icon: "LiveTvOutlined"),
    .init(id: "guide", title: "番組表", icon: "TelevisionGuide"),
    .init(id: "anime", title: "アニメ", icon: "AlphaA"),
    .init(id: "recording", title: "録画中", icon: "RadioButtonUncheckedOutlined"),
    .init(id: "recorded", title: "録画済み", icon: "FilmstripBoxMultiple"),
    .init(id: "encode", title: "エンコード", icon: "SyncOutlined"),
    .init(id: "reserves", title: "予約", icon: "ScheduleOutlined"),
    .init(id: "search", title: "検索", icon: "SearchOutlined"),
    .init(id: "rule", title: "ルール", icon: "CalendarMonthOutlined"),
    .init(id: "history", title: "視聴履歴", icon: "HistoryOutlined"),
    .init(id: "system", title: "システム", icon: "DnsOutlined"),
    .init(id: "settings", title: "設定", icon: "SettingsOutlined")]
}

class NeoPage: UIViewController {
  weak var shell: NeoShell?
  let header = UIView(), body = UIView()
  let titleLabel = NeoStyle.label(size: 20, bold: true)
  private var menu: UIButton!, back: UIButton!
  var actions: [UIView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; actions.forEach(header.addSubview); view.setNeedsLayout() } }
  init(title: String, shell: NeoShell) { super.init(nibName: nil, bundle: nil); self.shell = shell; titleLabel.text = title }
  required init?(coder: NSCoder) { fatalError() }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = NeoStyle.background; header.backgroundColor = NeoStyle.paper
    view.addSubview(body); view.addSubview(header)
    menu = NeoStyle.iconButton("Menu", label: "サイドメニューを開閉") { [weak self] in self?.shell?.toggleMenu() }
    back = NeoStyle.iconButton("ArrowBack", label: "戻る") { [weak self] in self?.shell?.goBack() }
    header.addSubview(menu); header.addSubview(back); header.addSubview(titleLabel)
    let line = UIView(); line.backgroundColor = UIColor.white.withAlphaComponent(0.18); line.tag = 701; header.addSubview(line)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let width = view.bounds.width; header.frame = CGRect(x: 0, y: 0, width: width, height: 56)
    body.frame = CGRect(x: 0, y: 56, width: width, height: max(0, view.bounds.height - 56))
    menu.frame = CGRect(x: 4, y: 6, width: 44, height: 44)
    let canBack = (navigationController?.viewControllers.count ?? 1) > 1 || shell?.hasRouteHistory == true
    back.isHidden = !canBack; back.frame = CGRect(x: 48, y: 6, width: 40, height: 44)
    var right = width - 4
    for action in actions.reversed() { right -= 44; action.frame = CGRect(x: right, y: 6, width: 44, height: 44) }
    let left: CGFloat = canBack ? 88 : 48
    titleLabel.frame = CGRect(x: left, y: 0, width: max(0, right - left - 4), height: 56)
    header.viewWithTag(701)?.frame = CGRect(x: 0, y: 55.5, width: width, height: 0.5)
  }
  func alert(_ text: String) {
    let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "閉じる", style: .cancel)); present(alert, animated: true)
  }
}

final class NeoShell: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
  let storage = NeoNative()
  private(set) var api: NeoAPI?
  private(set) var channels: [Int: String] = [:]
  private(set) var route = "recorded"
  private var history: [String] = []
  var hasRouteHistory: Bool { !history.isEmpty }
  private var controllers: [String: UINavigationController] = [:]
  private var active: UINavigationController?
  private let content = UIView(), sidebar = UIView(), bottom = UIView(), dim = UIView()
  private let menuList = UITableView(frame: .zero, style: .plain)
  private let brand = NeoStyle.label("NeoEPGStation", size: 18, bold: true)
  private let logo = UIImageView(image: UIImage(named: "Brand"))
  private var shortcuts: [String] = []
  private var bottomButtons: [UIButton] = []
  private var menuOpen = false, tabletExpanded = true
  private var openingPan: UIScreenEdgePanGestureRecognizer!, closingPan: UIPanGestureRecognizer!
  private var rootBackPan: UIScreenEdgePanGestureRecognizer!
  private var panStart: CGFloat = 0
  private var player: NeoPlayerController?
  var tablet: Bool { traitCollection.userInterfaceIdiom == .pad }
  var smokeStage: String {
#if targetEnvironment(simulator)
    return ProcessInfo.processInfo.environment["NEO_EPG_UI_SMOKE"] ?? ""
#else
    return ""
#endif
  }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  override func viewDidLoad() {
    super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = NeoStyle.background
    shortcuts = storage.shortcuts
    view.addSubview(content); view.addSubview(bottom); view.addSubview(dim); view.addSubview(sidebar)
    sidebar.backgroundColor = NeoStyle.paper; bottom.backgroundColor = NeoStyle.paper
    sidebar.addSubview(brand); sidebar.addSubview(logo); sidebar.addSubview(menuList)
    menuList.backgroundColor = .clear; menuList.separatorStyle = .none; menuList.rowHeight = 40
    menuList.dataSource = self; menuList.delegate = self; menuList.contentInset.top = 8
    menuList.register(UITableViewCell.self, forCellReuseIdentifier: "menu")
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.5); dim.alpha = 0
    dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeMenu)))
    openingPan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(dragMenu(_:))); openingPan.edges = .left; openingPan.delegate = self
    view.addGestureRecognizer(openingPan)
    closingPan = UIPanGestureRecognizer(target: self, action: #selector(dragMenu(_:))); closingPan.delegate = self
    sidebar.addGestureRecognizer(closingPan)
    rootBackPan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(dragRootBack(_:))); rootBackPan.edges = .left; rootBackPan.delegate = self
    view.addGestureRecognizer(rootBackPan)
    rebuildBottom()
    if !smokeStage.isEmpty {
      api = NeoAPI(base: URL(string: "https://example.com")!); channels = [1: "サンプル放送 BS"]
      showRoute("recorded", remember: false)
    } else {
      do {
        if let url = try storage.loadConnection() { connect(url) }
        else { showConnection() }
      } catch { showConnection(message: error.localizedDescription) }
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets, width = view.bounds.width
    let sidebarWidth: CGFloat = tablet && tabletExpanded ? 240 : 0
    let navHeight: CGFloat = tablet ? 0 : 56
    content.frame = CGRect(x: sidebarWidth, y: safe.top, width: max(0, width - sidebarWidth), height: max(0, view.bounds.height - safe.top - safe.bottom - navHeight))
    active?.view.frame = content.bounds
    bottom.isHidden = tablet || api == nil
    if api == nil { content.frame.size.height += navHeight; active?.view.frame = content.bounds }
    bottom.frame = CGRect(x: 0, y: view.bounds.height - safe.bottom - navHeight, width: width, height: navHeight + safe.bottom)
    for (i, b) in bottomButtons.enumerated() {
      b.frame = CGRect(x: CGFloat(i) * width / CGFloat(bottomButtons.count), y: 0, width: width / CGFloat(bottomButtons.count), height: navHeight)
    }
    dim.frame = view.bounds; dim.isHidden = tablet || api == nil
    sidebar.isHidden = api == nil || tablet && !tabletExpanded
    sidebar.frame = CGRect(x: tablet || menuOpen ? 0 : -240, y: 0, width: 240, height: view.bounds.height)
    brand.frame = CGRect(x: 16, y: safe.top, width: 177, height: 60)
    logo.frame = CGRect(x: 198, y: safe.top + 16, width: 28, height: 28); logo.contentMode = .scaleAspectFit
    menuList.frame = CGRect(x: 0, y: safe.top + 60, width: 240, height: max(0, view.bounds.height - safe.top - 60 - safe.bottom))
    sidebar.layer.borderColor = NeoStyle.border.cgColor; sidebar.layer.borderWidth = 0.5
    bottom.layer.borderColor = NeoStyle.border.cgColor; bottom.layer.borderWidth = 0.5
  }
  func connect(_ url: URL) {
    api = NeoAPI(base: url); channels = [:]; history = []
    for controller in controllers.values { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
    controllers.removeAll(); active = nil
    showRoute("recorded", remember: false)
    let api = self.api!
    Task { [weak self] in
      if let channels = try? await api.channels(), self?.api === api {
        self?.channels = Dictionary(channels.map { ($0.id, $0.name) }, uniquingKeysWith: { _, new in new })
        (self?.controllers["recorded"]?.viewControllers.first as? NeoRecordedPage)?.reloadLabels()
      }
    }
  }
  func showConnection(message: String? = nil) {
    api = nil; menuOpen = false; route = "connection"
    let page = NeoConnectionPage(shell: self)
    page.initialMessage = message
    let nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false)
    attach(nav); view.setNeedsLayout()
  }
  func showRoute(_ id: String, remember: Bool = true) {
    guard api != nil else { return }
    if remember && route != id { history.append(route) }
    route = id
    let nav: UINavigationController
    if let cached = controllers[id] { nav = cached }
    else {
      let page: NeoPage
      if id == "recorded" { page = NeoRecordedPage(shell: self) }
      else if id == "settings" { page = NeoSettingsPage(shell: self) }
      else { page = NeoPlaceholderPage(id: id, shell: self) }
      nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false)
      nav.interactivePopGestureRecognizer?.delegate = self; nav.interactivePopGestureRecognizer?.isEnabled = true
      controllers[id] = nav
    }
    attach(nav); menuList.reloadData(); updateBottom(); setMenu(false, animated: true)
  }
  private func attach(_ nav: UINavigationController) {
    if active !== nav {
      active?.willMove(toParent: nil); active?.view.removeFromSuperview(); active?.removeFromParent()
      addChild(nav); content.addSubview(nav.view); nav.view.frame = content.bounds; nav.didMove(toParent: self); active = nav
    }
    active?.topViewController?.view.setNeedsLayout(); view.setNeedsLayout()
  }
  func goBack() {
    if let active, active.viewControllers.count > 1 { active.popViewController(animated: true) }
    else if let id = history.popLast() { showRoute(id, remember: false) }
  }
  func openDetail(_ recording: NeoRecording) {
    active?.pushViewController(NeoDetailPage(item: recording, shell: self), animated: true)
  }
  func play(_ file: NeoVideoFile, title: String) {
    guard player == nil, let api else { return }
    let controller = NeoPlayerController(url: api.url("/videos/\(file.id)"), title: title, username: "", password: "", networkCaching: 5000)
    controller.modalPresentationStyle = .fullScreen; player = controller
    controller.onClose = { [weak self] in self?.player = nil }
    present(controller, animated: true)
  }
  func toggleMenu() {
    if tablet { tabletExpanded.toggle(); view.setNeedsLayout(); view.layoutIfNeeded() }
    else { setMenu(!menuOpen, animated: true) }
  }
  @objc private func closeMenu() { setMenu(false, animated: true) }
  private func setMenu(_ open: Bool, animated: Bool) {
    guard !tablet else { return }
    menuOpen = open
    let changes = { self.sidebar.frame.origin.x = open ? 0 : -240; self.dim.alpha = open ? 1 : 0 }
    if animated { UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes) }
    else { changes() }
    sidebar.accessibilityViewIsModal = open
  }
  @objc private func dragMenu(_ recognizer: UIPanGestureRecognizer) {
    guard !tablet else { return }
    if recognizer.state == .began {
      sidebar.layer.removeAllAnimations(); dim.layer.removeAllAnimations(); panStart = menuOpen ? 240 : 0
    }
    let progress = min(240, max(0, panStart + recognizer.translation(in: view).x))
    if recognizer.state == .changed || recognizer.state == .began {
      sidebar.frame.origin.x = progress - 240; dim.alpha = progress / 240
    } else if recognizer.state == .ended {
      let velocity = recognizer.velocity(in: view).x
      setMenu(abs(velocity) > 350 ? velocity > 0 : progress > 120, animated: true)
    } else if recognizer.state == .cancelled { setMenu(menuOpen, animated: true) }
  }
  @objc private func dragRootBack(_ recognizer: UIPanGestureRecognizer) {
    if recognizer.state == .ended && (recognizer.translation(in: view).x > 60 || recognizer.velocity(in: view).x > 400) { goBack() }
  }
  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    let pan = recognizer as? UIPanGestureRecognizer
    let velocity = pan?.velocity(in: view) ?? .zero
    guard abs(velocity.x) > abs(velocity.y) * 1.6 else { return false }
    if recognizer === closingPan { return menuOpen && !tablet && velocity.x < 0 }
    let upper = recognizer.location(in: view).y < view.bounds.height / 2
    if recognizer === openingPan { return api != nil && !tablet && !menuOpen && upper && velocity.x > 0 }
    if recognizer === rootBackPan { return !menuOpen && !upper && hasRouteHistory && active?.viewControllers.count == 1 && velocity.x > 0 }
    // UINavigationController drives an interactive native back transition.
    return !menuOpen && !upper && (active?.viewControllers.count ?? 0) > 1 && velocity.x > 0
  }
  func saveShortcuts(_ values: [String]) throws { try storage.saveShortcuts(values); shortcuts = values; rebuildBottom(); view.setNeedsLayout() }
  private func rebuildBottom() {
    bottomButtons.forEach { $0.removeFromSuperview() }; bottomButtons = []
    for id in shortcuts {
      guard let item = NeoDestination.all.first(where: { $0.id == id }) else { continue }
      let b = UIButton(type: .system)
      var config = UIButton.Configuration.plain(); config.image = NeoIcon.image(item.icon); config.title = item.title
      config.imagePlacement = .top; config.imagePadding = 3; config.contentInsets = .zero
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in var attrs = attrs; attrs.font = .systemFont(ofSize: 10); return attrs }
      b.configuration = config; b.accessibilityLabel = item.title; b.accessibilityIdentifier = "tab-" + id
      b.addAction(UIAction { [weak self] _ in self?.showRoute(id) }, for: .touchUpInside)
      bottom.addSubview(b); bottomButtons.append(b)
    }
    updateBottom()
  }
  private func updateBottom() {
    for (i, b) in bottomButtons.enumerated() {
      b.tintColor = shortcuts[i] == route ? NeoStyle.accent : NeoStyle.muted
      b.isSelected = shortcuts[i] == route
      b.accessibilityTraits = shortcuts[i] == route ? [.button, .selected] : .button
    }
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { NeoDestination.all.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "menu", for: indexPath), item = NeoDestination.all[indexPath.row]
    var config = cell.defaultContentConfiguration(); config.text = item.title; config.image = NeoIcon.image(item.icon)
    config.textProperties.font = .systemFont(ofSize: 14); config.textProperties.color = .white
    config.imageProperties.tintColor = NeoStyle.muted; config.imageToTextPadding = 16
    config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    cell.contentConfiguration = config
    cell.backgroundColor = item.id == route ? NeoStyle.accent.withAlphaComponent(0.16) : .clear
    cell.accessibilityIdentifier = "menu-" + item.id; return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { showRoute(NeoDestination.all[indexPath.row].id) }

#if targetEnvironment(simulator)
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !smokeStage.isEmpty else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.runUISmoke() }
  }
  private func runUISmoke() {
    let recorded = controllers["recorded"]!.viewControllers.first as! NeoRecordedPage
    let original = recorded.collection
    showRoute("settings"); showRoute("recorded")
    let retained = original === recorded.collection
    history.removeAll()
    if smokeStage == "menu" { setMenu(true, animated: false) }
    if smokeStage == "settings" { showRoute("settings", remember: false) }
    if smokeStage == "detail" { openDetail(NeoRecordedPage.fixtures.records[0]) }
    if smokeStage == "pagination" { recorded.smokePageSeven() }
    view.layoutIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      let cardHeight = recorded.cardHeight
      let pages = recorded.renderedPages
      let correct = retained && (self.tablet || cardHeight == 108) && self.controllers["recorded"]?.viewControllers.first === recorded
        && (self.smokeStage != "pagination" || pages == ["5", "6", "7", "8", "9"])
      NeoNative.writeSmoke("ui-\(self.smokeStage)-smoke", ["success": correct, "stage": self.smokeStage,
        "route": self.route, "recordCount": recorded.records.count, "theme": "neon-teal-dark", "sidebarWidth": self.tablet ? 240 : 0,
        "uiEngine": "Swift / UIKit", "retainedList": retained, "cardHeight": cardHeight,
        "pagination": pages, "shortcuts": self.shortcuts])
    }
  }
#endif
}
