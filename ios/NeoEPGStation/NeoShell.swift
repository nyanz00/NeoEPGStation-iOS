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

// A public UIKit interactive transition, rather than forwarding touches into
// UINavigationController's private edge-gesture implementation.
final class NeoSwipeBackAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private var animator: UIViewPropertyAnimator?
  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.3
  }
  func animateTransition(using context: UIViewControllerContextTransitioning) {
    interruptibleAnimator(using: context).startAnimation()
  }
  func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
    if let animator { return animator }
    guard let from = context.view(forKey: .from), let to = context.view(forKey: .to),
      let target = context.viewController(forKey: .to) else { fatalError("Missing native navigation transition views") }
    let container = context.containerView, width = container.bounds.width
    to.frame = context.finalFrame(for: target); container.insertSubview(to, belowSubview: from)
    to.transform = CGAffineTransform(translationX: -width * 0.25, y: 0)
    let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .linear) {
      from.transform = CGAffineTransform(translationX: width, y: 0); to.transform = .identity
    }
    animator.addCompletion { position in
      from.transform = .identity; to.transform = .identity
      context.completeTransition(position == .end && !context.transitionWasCancelled)
    }
    self.animator = animator; return animator
  }
  func animationEnded(_ transitionCompleted: Bool) { animator = nil }
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
    titleLabel.font = .systemFont(ofSize: 20, weight: .medium)
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
    menu.isHidden = shell?.api == nil
    let canBack = (navigationController?.viewControllers.count ?? 1) > 1
    back.isHidden = !canBack; back.frame = CGRect(x: 48, y: 6, width: 40, height: 44)
    var right = width - 4
    for action in actions.reversed() { right -= 44; action.frame = CGRect(x: right, y: 6, width: 44, height: 44) }
    let left: CGFloat = menu.isHidden ? 16 : canBack ? 88 : 48
    titleLabel.frame = CGRect(x: left, y: 0, width: max(0, right - left - 4), height: 56)
    header.viewWithTag(701)?.frame = CGRect(x: 0, y: 55.5, width: width, height: 0.5)
  }
  func alert(_ text: String) {
    let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "閉じる", style: .cancel)); present(alert, animated: true)
  }
}

final class NeoShell: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
  let storage = NeoNative()
  private(set) var api: NeoAPI?
  private(set) var channels: [Int: String] = [:]
  private(set) var serverConfig: NeoServerConfig?
  private(set) var route = "recorded"
  // Each destination keeps its own stack. Switching tabs never adds a back target.
  private var controllers: [String: UINavigationController] = [:]
  private var active: UINavigationController?
  private let content = UIView(), sidebar = UIView(), bottom = UIView(), dim = UIView()
  private let menuList = UITableView(frame: .zero, style: .plain)
  private let brand = NeoStyle.label("NeoEPGStation", size: 18, bold: true)
  private let logo = UIImageView(image: UIImage(named: "Brand"))
  private var shortcuts: [String] = []
  private var bottomButtons: [UIButton] = []
  private var menuOpen = false, tabletExpanded = true
  private var contentPan: UIPanGestureRecognizer!, closingPan: UIPanGestureRecognizer!, backdropPan: UIPanGestureRecognizer!
  private weak var closingScroll: UIScrollView?
  private var closingScrollWasEnabled = false
  private var popup: NeoAnchoredMenu?
  private var swipeStart = CGPoint.zero
  private var swipeAction: NeoSwipeAction?
  private weak var swipeScroll: UIScrollView?
  private var scrollWasEnabled = false
  private var popInteraction: UIPercentDrivenInteractiveTransition?
  private var panStart: CGFloat = 0
  private var menuDragging = false
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
    super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = NeoStyle.paper
    content.clipsToBounds = true
    shortcuts = storage.shortcuts
    view.addSubview(content); view.addSubview(bottom); view.addSubview(dim); view.addSubview(sidebar)
    sidebar.backgroundColor = NeoStyle.paper; bottom.backgroundColor = NeoStyle.paper
    sidebar.addSubview(brand); sidebar.addSubview(logo); sidebar.addSubview(menuList)
    menuList.backgroundColor = .clear; menuList.separatorStyle = .none; menuList.rowHeight = 40
    menuList.dataSource = self; menuList.delegate = self; menuList.contentInset.top = 8
    menuList.register(UITableViewCell.self, forCellReuseIdentifier: "menu")
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.5); dim.alpha = 0
    dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeMenu)))
    contentPan = UIPanGestureRecognizer(target: self, action: #selector(dragContent(_:))); contentPan.delegate = self
    contentPan.maximumNumberOfTouches = 1; content.addGestureRecognizer(contentPan)
    closingPan = UIPanGestureRecognizer(target: self, action: #selector(dragMenu(_:))); closingPan.delegate = self
    closingPan.maximumNumberOfTouches = 1
    sidebar.addGestureRecognizer(closingPan)
    backdropPan = UIPanGestureRecognizer(target: self, action: #selector(dragMenu(_:))); backdropPan.delegate = self
    backdropPan.maximumNumberOfTouches = 1; dim.addGestureRecognizer(backdropPan)
    rebuildBottom()
    if !smokeStage.isEmpty {
      api = NeoAPI(base: URL(string: "https://example.com")!); channels = [1: "サンプル放送 BS"]
      serverConfig = NeoServerConfig(encode: ["Sample"], developerMode: true, isEnableTSRecordedStream: true, isEnableEncodedRecordedStream: true)
      showRoute("recorded")
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
    let sidebarX: CGFloat = menuDragging ? sidebar.frame.minX : tablet || menuOpen ? 0 : -240
    sidebar.frame = CGRect(x: sidebarX, y: 0, width: 240, height: view.bounds.height)
    let brandWidth = min(173, ceil(brand.intrinsicContentSize.width))
    brand.frame = CGRect(x: 16, y: safe.top, width: brandWidth, height: 60)
    let logoWidth = (logo.image?.size.width ?? 28) / max(1, logo.image?.size.height ?? 28) * 28
    logo.frame = CGRect(x: brand.frame.maxX + 7, y: safe.top + 16, width: logoWidth, height: 28); logo.contentMode = .scaleAspectFit
    menuList.frame = CGRect(x: 0, y: safe.top + 60, width: 240, height: max(0, view.bounds.height - safe.top - 60 - safe.bottom))
    sidebar.layer.borderColor = NeoStyle.border.cgColor; sidebar.layer.borderWidth = 0.5
    bottom.layer.borderColor = NeoStyle.border.cgColor; bottom.layer.borderWidth = 0.5
    popup?.setNeedsLayout()
  }
  func connect(_ url: URL) {
    dismissPopup(); api = NeoAPI(base: url); channels = [:]; serverConfig = nil
    for controller in controllers.values { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
    controllers.removeAll(); active = nil
    showRoute("recorded")
    let api = self.api!
    Task { [weak self] in await self?.refreshServerConfig() }
    Task { [weak self] in
      if let channels = try? await api.channels(), self?.api === api {
        self?.channels = Dictionary(channels.map { ($0.id, $0.name) }, uniquingKeysWith: { _, new in new })
        (self?.controllers["recorded"]?.viewControllers.first as? NeoRecordedPage)?.reloadLabels()
      }
    }
  }
  func refreshServerConfig() async {
    guard let api, serverConfig == nil else { return }
    guard let config = try? await api.configuration(), self.api === api else { return }
    serverConfig = config
    for nav in controllers.values {
      for case let detail as NeoDetailPage in nav.viewControllers where detail.isViewLoaded { detail.refreshCapabilities() }
    }
  }
  func showConnection(message: String? = nil) {
    dismissPopup()
    api = nil; menuOpen = false; route = "connection"
    let page = NeoConnectionPage(shell: self)
    page.initialMessage = message
    let nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false)
    attach(nav); view.setNeedsLayout()
  }
  func showRoute(_ id: String) {
    guard api != nil, popInteraction == nil else { return }
    dismissPopup()
    route = id
    let nav: UINavigationController
    if let cached = controllers[id] { nav = cached }
    else {
      let page: NeoPage
      if id == "recorded" { page = NeoRecordedPage(shell: self) }
      else if id == "settings" { page = NeoSettingsPage(shell: self) }
      else { page = NeoPlaceholderPage(id: id, shell: self) }
      nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false)
      nav.delegate = self
      nav.interactivePopGestureRecognizer?.isEnabled = false
      controllers[id] = nav
    }
    attach(nav); menuList.reloadData(); updateBottom(); setMenu(false, animated: true)
  }
  private func attach(_ nav: UINavigationController) {
    if active !== nav {
      active?.willMove(toParent: nil); active?.view.removeFromSuperview(); active?.removeFromParent()
      addChild(nav); content.addSubview(nav.view); nav.view.frame = content.bounds; nav.didMove(toParent: self); active = nav
    }
    // The built-in edge recognizer may not exist until the navigation view loads.
    nav.interactivePopGestureRecognizer?.isEnabled = false
    active?.topViewController?.view.setNeedsLayout(); view.setNeedsLayout()
  }
  func goBack() {
    guard active?.transitionCoordinator == nil else { return }
    dismissPopup()
    if let active, active.viewControllers.count > 1 { active.popViewController(animated: true) }
  }
  func openDetail(_ recording: NeoRecording) {
    dismissPopup()
    active?.pushViewController(NeoDetailPage(item: recording, shell: self), animated: true)
  }
  func play(_ file: NeoVideoFile, recording: NeoRecording) {
    guard player == nil, let api else { return }
    let controller = NeoPlayerController(url: api.url("/videos/\(file.id)"), title: recording.name, username: "", password: "", networkCaching: 5000)
    controller.recordingContext = ["baseURL": api.base.absoluteString, "id": recording.id,
      "channelId": recording.channelId ?? 0, "channelName": recording.channelName ?? recording.channelId.flatMap { channels[$0] } ?? "",
      "name": recording.name, "startAt": recording.startAt, "endAt": recording.endAt,
      "description": recording.description ?? "", "extended": recording.extended ?? "", "ruleId": recording.ruleId ?? 0]
    controller.modalPresentationStyle = .fullScreen; player = controller
    controller.onClose = { [weak self] in self?.player = nil }
    controller.onNavigate = { [weak self] route in self?.showRoute(route) }
    controller.onRecording = { [weak self, weak api] id in
      Task { [weak self] in
        guard let self, let api else { return }
        do { let item = try await api.recording(id); guard self.api === api else { return }; self.openDetail(item) }
        catch { self.active?.topViewController.flatMap { $0 as? NeoPage }?.alert(error.localizedDescription) }
      }
    }
    present(controller, animated: true)
  }
  func showPopup(anchor: UIView, entries: [NeoMenuEntry], appearance: NeoAnchoredMenu.Appearance) {
    dismissPopup(); guard !entries.isEmpty, anchor.window != nil else { return }
    let menu = NeoAnchoredMenu(anchor: anchor, entries: entries, appearance: appearance)
    menu.onDismiss = { [weak self] in self?.popup = nil }
    popup = menu; menu.show(in: view)
  }
  func dismissPopup() { popup?.dismiss() }
  func toggleMenu() {
    if tablet { tabletExpanded.toggle(); view.setNeedsLayout(); view.layoutIfNeeded() }
    else { setMenu(!menuOpen, animated: true) }
  }
  @objc private func closeMenu() { setMenu(false, animated: true) }
  private func setMenu(_ open: Bool, animated: Bool) {
    guard !tablet else { return }
    if open { dismissPopup() }
    menuOpen = open
    let changes = { self.sidebar.frame.origin.x = open ? 0 : -240; self.dim.alpha = open ? 1 : 0 }
    if animated { UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes) }
    else { changes() }
    sidebar.accessibilityViewIsModal = open
  }
  @objc private func dragMenu(_ recognizer: UIPanGestureRecognizer) {
    guard !tablet else { return }
    if recognizer === closingPan || recognizer === backdropPan {
      if recognizer.state == .began {
        closingScrollWasEnabled = closingScroll?.isScrollEnabled == true; closingScroll?.isScrollEnabled = false
      }
      if [.ended, .cancelled, .failed].contains(recognizer.state) {
        if closingScrollWasEnabled { closingScroll?.isScrollEnabled = true }; closingScroll = nil
      }
    }
    updateMenu(state: recognizer.state, translation: recognizer.translation(in: view).x, velocity: recognizer.velocity(in: view).x)
  }
  private func updateMenu(state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat) {
    if state == .began {
      menuDragging = true
      let x = sidebar.layer.presentation()?.frame.minX ?? sidebar.frame.minX
      sidebar.layer.removeAllAnimations(); dim.layer.removeAllAnimations()
      sidebar.frame.origin.x = x; panStart = min(240, max(0, x + 240)); dim.alpha = panStart / 240
    }
    let progress = min(240, max(0, panStart + translation))
    if state == .changed || state == .began {
      sidebar.frame.origin.x = progress - 240; dim.alpha = progress / 240
    } else if state == .ended {
      menuDragging = false
      setMenu(abs(velocity) > 350 ? velocity > 0 : progress > 120, animated: true)
    } else if state == .cancelled || state == .failed { menuDragging = false; setMenu(menuOpen, animated: true) }
  }
  private var canGoBack: Bool { (active?.viewControllers.count ?? 1) > 1 }
  @objc private func dragContent(_ recognizer: UIPanGestureRecognizer) {
    if recognizer.state == .began {
      scrollWasEnabled = swipeScroll?.isScrollEnabled == true
      swipeScroll?.isScrollEnabled = false
    }
    if swipeAction == .menu { dragMenu(recognizer) }
    else if swipeAction == .back { dragBack(recognizer) }
    if [.ended, .cancelled, .failed].contains(recognizer.state) {
      if scrollWasEnabled { swipeScroll?.isScrollEnabled = true }
      swipeScroll = nil; swipeAction = nil
    }
  }
  private func dragBack(_ recognizer: UIPanGestureRecognizer) {
    updateBack(state: recognizer.state, translation: recognizer.translation(in: content).x, velocity: recognizer.velocity(in: content).x)
  }
  private func updateBack(state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat) {
    guard let active else { return }
    let width = max(1, content.bounds.width)
    let progress = min(1, max(0, translation / width))
    switch state {
    case .began:
      if active.viewControllers.count > 1 {
        let interaction = UIPercentDrivenInteractiveTransition(); interaction.completionCurve = .easeOut
        popInteraction = interaction; active.popViewController(animated: true)
#if targetEnvironment(simulator)
        backSmokeDetails["detailContextInteractive"] = active.transitionCoordinator?.isInteractive == true
#endif
        active.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.popInteraction = nil }
      }
    case .changed:
#if targetEnvironment(simulator)
      if active.viewControllers.count > 1 || popInteraction != nil { backSmokeDetails["detailDriverOnChange"] = popInteraction != nil }
#endif
      if let interaction = popInteraction { interaction.update(progress) }
    case .ended, .cancelled:
#if targetEnvironment(simulator)
      if state == .cancelled { backSmokeDetails["detailDriverOnCancel"] = popInteraction != nil }
#endif
      let finish = state == .ended && (progress > 0.28 || velocity > 450)
      if let interaction = popInteraction {
        if finish { interaction.finish() } else { interaction.cancel() }
      }
    default: break
    }
  }
  func navigationController(_ navigationController: UINavigationController,
    animationControllerFor operation: UINavigationController.Operation,
    from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    operation == .pop && popInteraction != nil ? NeoSwipeBackAnimator() : nil
  }
  func navigationController(_ navigationController: UINavigationController,
    interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
#if targetEnvironment(simulator)
    backSmokeDetails["interactionControllerRequested"] = true
#endif
    return popInteraction
  }
  func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
    popInteraction = nil; viewController.view.setNeedsLayout()
  }
  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if recognizer === closingPan || recognizer === backdropPan {
      closingScroll = nil
      var candidate = touch.view
      while let current = candidate, current !== sidebar && current !== dim {
        if let scroll = current as? UIScrollView { closingScroll = scroll; break }
        candidate = current.superview
      }
      return true
    }
    if recognizer !== contentPan { return true }
    swipeStart = touch.location(in: view); swipeScroll = nil
    var candidate = touch.view
    while let current = candidate, current !== content {
      if current is UISlider || current is UISwitch || current is UITextField || current is UITextView { return false }
      if let scroll = current as? UIScrollView {
        if scroll.contentSize.width > scroll.bounds.width + 1 { return false }
        if swipeScroll == nil { swipeScroll = scroll }
      }
      candidate = current.superview
    }
    return true
  }
  func gestureRecognizer(_ recognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    // Allow vertical scrolling to start naturally; freeze it only after a
    // horizontal drawer/back drag has actually been recognized.
    (recognizer === contentPan && other === swipeScroll?.panGestureRecognizer)
      || (recognizer === closingPan && other === closingScroll?.panGestureRecognizer)
  }
  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    let pan = recognizer as? UIPanGestureRecognizer
    let velocity = pan?.velocity(in: view) ?? .zero
    guard abs(velocity.x) >= abs(velocity.y), abs(velocity.x) > 0 else { return false }
    if recognizer === closingPan || recognizer === backdropPan { return menuOpen && !tablet && velocity.x < 0 }
    guard recognizer === contentPan, api != nil, !menuOpen, popup == nil, presentedViewController == nil,
      popInteraction == nil, active?.transitionCoordinator == nil else { return false }
    swipeAction = NeoNavigationGesture.action(startY: Double(swipeStart.y), height: Double(view.bounds.height),
      canGoBack: canGoBack, tablet: tablet, horizontal: Double(velocity.x), vertical: Double(velocity.y))
    return swipeAction != nil
  }
  func saveShortcuts(_ values: [String]) throws { try storage.saveShortcuts(values); shortcuts = values; rebuildBottom(); view.setNeedsLayout() }
  private func rebuildBottom() {
    bottomButtons.forEach { $0.removeFromSuperview() }; bottomButtons = []
    for id in shortcuts {
      guard let item = NeoDestination.all.first(where: { $0.id == id }) else { continue }
      let b = UIButton(type: .system)
      var config = UIButton.Configuration.plain(); config.image = NeoIcon.image(item.icon); config.title = item.title
      config.imagePlacement = .top; config.imagePadding = 3; config.contentInsets = .zero
      config.background = .clear()
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
      // Selection is expressed by the Web accent, not iOS 26's automatic pill.
      b.isSelected = false
      b.accessibilityTraits = shortcuts[i] == route ? [.button, .selected] : .button
    }
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { NeoDestination.all.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "menu", for: indexPath), item = NeoDestination.all[indexPath.row]
    var config = cell.defaultContentConfiguration(); config.text = item.title; config.image = NeoIcon.image(item.icon)
    config.textProperties.font = .systemFont(ofSize: 14); config.textProperties.color = .white
    config.imageProperties.tintColor = NeoStyle.muted
    config.imageToTextPadding = item.icon == "AlphaA" ? 13 : 16
    config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    cell.contentConfiguration = config
    cell.backgroundColor = item.id == route ? NeoStyle.accent.withAlphaComponent(0.16) : .clear
    cell.accessibilityIdentifier = "menu-" + item.id; return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { showRoute(NeoDestination.all[indexPath.row].id) }

#if targetEnvironment(simulator)
  private var backSmokeDetails: [String: Any] = [:]
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
    if smokeStage == "gestures" {
      Task { [self] in
        let popupCycles = NeoAnchoredMenu.runSmoke(in: view)
        setMenu(true, animated: false)
        // Commit the open frame before reading the presentation layer, as a
        // real user's next touch would. Otherwise the smoke drag starts closed.
        try? await Task.sleep(nanoseconds: 100_000_000)
        updateMenu(state: .began, translation: 0, velocity: -100)
        updateMenu(state: .changed, translation: -150, velocity: -100)
        let drawerFollowed = sidebar.frame.minX == -150 && dim.alpha == 0.375
        updateMenu(state: .ended, translation: -150, velocity: -500)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let drawerClosed = drawerFollowed && !menuOpen && sidebar.frame.minX == -240 && dim.alpha == 0
        let thumbnails = await NeoThumbnail.runSmoke()
        recorded.smokePageSeven(); try? await Task.sleep(nanoseconds: 100_000_000)
        let freshFade = recorded.lastFadeDuration
        recorded.smokePageOne(); try? await Task.sleep(nanoseconds: 400_000_000)
        let cachedFade = recorded.lastFadeDuration
        runBackSmoke(recorded) { [weak self] correct in
          guard let self else { return }
          let gap = self.logo.frame.minX - self.brand.frame.maxX
          NeoNative.writeSmoke("ui-gestures-smoke", ["success": correct && drawerClosed && popupCycles && gap == 7 && thumbnails && freshFade == 0.5 && cachedFade == 0.32,
            "stage": "gestures", "route": self.route, "recordCount": recorded.records.count,
            "theme": "neon-teal-dark", "uiEngine": "Swift / UIKit", "retainedList": retained,
            "shortcuts": self.shortcuts, "brandGap": gap, "interactiveBack": correct, "thumbnailLoading": thumbnails,
            "freshFade": freshFade, "cachedFade": cachedFade, "backDetails": self.backSmokeDetails,
            "drawerClosedByLeftSwipe": drawerClosed, "popupCycles": popupCycles])
        }
      }
      return
    }
    if smokeStage == "menu" { setMenu(true, animated: false) }
    if smokeStage == "settings" { showRoute("settings") }
    if ["detail", "detail-actions", "play-popup", "drop-dialog"].contains(smokeStage) { openDetail(NeoRecordedPage.fixtures.records[0]) }
    if smokeStage == "pagination" { recorded.smokePageSeven() }
    view.layoutIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      let cardHeight = recorded.cardHeight
      let pages = recorded.renderedPages
      var popupCorrect = true
      var dropText = ""
      if self.smokeStage == "record-actions" {
        recorded.smokeOpenFirstMenu()
        popupCorrect = self.popup?.titles == ["rule", "search", "user", "encode", "Info", "protect", "subtitle", "delete"]
      }
      if self.smokeStage == "list-actions" {
        recorded.smokeOpenListMenu()
        popupCorrect = self.popup?.titles == ["編集", "クリーンアップ", "アップロード"]
      }
      if let detail = self.active?.topViewController as? NeoDetailPage {
        detail.view.layoutIfNeeded(); dropText = detail.smokeDropText
        popupCorrect = dropText == "drop: 2, error: 0, scrambling: 0 1.33 GB"
          && detail.smokeButtonsInOneRow && detail.smokeButtonTitles == ["PLAY", "STREAMING", "ENCODE"]
        if self.smokeStage == "detail-actions" {
          detail.smokeOpenMenu()
          popupCorrect = popupCorrect && self.popup?.titles == ["download", "rule", "search", "user", "encode", "thumbnail", "subtitle", "Info", "protect", "delete"]
        }
        if self.smokeStage == "play-popup" {
          detail.smokeOpenPlay()
          popupCorrect = popupCorrect && self.popup?.titles == ["TS", "AV1 / MKV"]
            && self.popup?.menuFrame.minY == detail.smokePlayFrame.maxY
            && self.popup?.menuFrame.minX == detail.smokePlayFrame.minX
            && self.popup?.smokeFileStyle == true
        }
        if self.smokeStage == "drop-dialog" {
          detail.smokeOpenDropLog(); detail.presentedViewController?.view.layoutIfNeeded()
          popupCorrect = popupCorrect && detail.smokeDropDialogVisible && self.active?.viewControllers.count == 2
        }
      }
      let correct = popupCorrect && retained && (self.tablet || cardHeight == 108) && self.controllers["recorded"]?.viewControllers.first === recorded
        && (self.smokeStage != "pagination" || pages == ["5", "6", "7", "8", "9"])
      NeoNative.writeSmoke("ui-\(self.smokeStage)-smoke", ["success": correct, "stage": self.smokeStage,
        "route": self.route, "recordCount": recorded.records.count, "theme": "neon-teal-dark", "sidebarWidth": self.tablet ? 240 : 0,
        "uiEngine": "Swift / UIKit", "retainedList": retained, "cardHeight": cardHeight,
        "pagination": pages, "shortcuts": self.shortcuts, "popupTitles": self.popup?.titles ?? [], "dropSummary": dropText,
        "detailButtons": (self.active?.topViewController as? NeoDetailPage)?.smokeButtonTitles ?? [],
        "dropDialogVisible": (self.active?.topViewController as? NeoDetailPage)?.smokeDropDialogVisible ?? false])
    }
  }
  private func runBackSmoke(_ recorded: NeoRecordedPage, completion: @escaping (Bool) -> Void) {
    func later(_ delay: TimeInterval = 0.45, _ action: @escaping () -> Void) {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
    func settled(_ attempts: Int = 0, _ action: @escaping () -> Void) {
      if active?.transitionCoordinator != nil && attempts < 50 {
        later(0.1) { settled(attempts + 1, action) }
      } else { action() }
    }
    func perform(cancel: Bool, done: @escaping () -> Void) {
      settled { [self] in
        backSmokeDetails[cancel ? "transitionBeforeCancel" : "transitionBeforeFinish"] = active?.transitionCoordinator != nil
        updateBack(state: .began, translation: 0, velocity: 100)
      // UIKit must have a run-loop turn to create the transition context,
      // just as it does between actual began/changed touch events.
      later(0.05) { [self] in
        updateBack(state: .changed, translation: content.bounds.width * 0.4, velocity: 100)
        later(0.05) { [self] in
          updateBack(state: cancel ? .cancelled : .ended, translation: content.bounds.width * 0.4, velocity: 500)
          later { settled { done() } }
        }
      }
      }
    }
    openDetail(NeoRecordedPage.fixtures.records[0])
    later(0.6) { [self] in
      perform(cancel: true) { [self] in
        let cancelled = active?.viewControllers.count == 2 && popInteraction == nil
        backSmokeDetails["detailCancelled"] = cancelled; backSmokeDetails["stackAfterCancel"] = active?.viewControllers.count ?? 0
        let detail = active?.topViewController
        showRoute("settings"); view.layoutIfNeeded()
        let settings = active
        let settingsRoot = !canGoBack
        goBack()
        // Even a direct back-transition request at a tab root must not switch tabs.
        updateBack(state: .began, translation: 0, velocity: 100)
        updateBack(state: .changed, translation: content.bounds.width * 0.4, velocity: 100)
        updateBack(state: .ended, translation: content.bounds.width * 0.4, velocity: 500)
        let isolated = settingsRoot && route == "settings" && active === settings && !canGoBack && popInteraction == nil
        backSmokeDetails["settingsRootIsolated"] = isolated
        showRoute("recorded"); view.layoutIfNeeded()
        let retainedDetail = canGoBack && active?.topViewController === detail && active?.viewControllers.count == 2
        backSmokeDetails["retainedDetailAcrossTabs"] = retainedDetail
        perform(cancel: false) { [self] in
          let finished = route == "recorded" && active?.viewControllers.count == 1 && active?.topViewController === recorded && !canGoBack
          backSmokeDetails["detailFinished"] = finished; backSmokeDetails["stackAfterFinish"] = active?.viewControllers.count ?? 0
          goBack()
          let recordedRoot = route == "recorded" && active?.topViewController === recorded
          backSmokeDetails["recordedRootIsolated"] = recordedRoot
          let rootMenu = NeoNavigationGesture.action(startY: Double(view.bounds.height) * 0.8,
            height: Double(view.bounds.height), canGoBack: canGoBack, tablet: false, horizontal: 100, vertical: 0) == .menu
          backSmokeDetails["rootLowerSwipeOpensMenu"] = rootMenu
          let search = NeoRecordedPage(shell: self, keyword: "サンプル")
          active?.pushViewController(search, animated: true)
          later(0.6) { [self] in
            settled { [self] in
              let searchOpened = route == "recorded" && canGoBack && active?.topViewController === search
              goBack()
              later(0.6) { [self] in
                settled { [self] in
                  let searchReturned = searchOpened && route == "recorded" && !canGoBack && active?.topViewController === recorded
                  backSmokeDetails["searchReturnedWithinTab"] = searchReturned
                  completion(cancelled && isolated && retainedDetail && finished && recordedRoot && rootMenu && searchReturned)
                }
              }
            }
          }
        }
      }
    }
  }
#endif
}
