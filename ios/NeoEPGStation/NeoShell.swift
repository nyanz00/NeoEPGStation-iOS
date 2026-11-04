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
@objc(NeoSwipeBackAnimator)
final class NeoSwipeBackAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  var duration: TimeInterval = 0.22
  private var animator: UIViewPropertyAnimator?
  var curve: UIView.AnimationCurve = .linear
  var onCompletion: ((Bool) -> Void)?
  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.01 : duration
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
    let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: curve) {
      from.transform = CGAffineTransform(translationX: width, y: 0); to.transform = .identity
    }
    animator.addCompletion { position in
      from.transform = .identity; to.transform = .identity
      context.completeTransition(position == .end && !context.transitionWasCancelled)
    }
    self.animator = animator; return animator
  }
  func animationEnded(_ transitionCompleted: Bool) { animator = nil; onCompletion?(transitionCompleted) }
}

// Own the push animator so a back gesture can take over its current visual
// position instead of waiting for UINavigationController's default push.
private final class NeoPagePushAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private var animator: UIViewPropertyAnimator?
  private weak var incoming: UIView?
  private var width: CGFloat = 1
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.15
  }
  func animateTransition(using context: UIViewControllerContextTransitioning) { interruptibleAnimator(using:context).startAnimation() }
  func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
    if let animator { return animator }
    guard let from = context.view(forKey:.from), let to = context.view(forKey:.to),
      let target = context.viewController(forKey:.to) else { fatalError("Missing navigation push views") }
    width = max(1,context.containerView.bounds.width); incoming = to
    to.frame = context.finalFrame(for:target); context.containerView.addSubview(to)
    to.transform = CGAffineTransform(translationX:width,y:0)
    let animator = UIViewPropertyAnimator(duration:transitionDuration(using:context),curve:.easeOut) {
      to.transform = .identity; from.transform = CGAffineTransform(translationX:-self.width*0.25,y:0)
    }
#if targetEnvironment(simulator)
    if let page = target as? NeoPage, let began = page.smokeOpeningBegan {
      page.smokeOpeningTimes["handlerToAnimatorMs"] = (CACurrentMediaTime()-began)*1000
      NeoOpeningFrameProbe(page:page,width:width).start()
    }
#endif
    animator.addCompletion { position in
      from.transform = .identity; to.transform = .identity
      context.completeTransition(position == .end && !context.transitionWasCancelled)
    }
    self.animator = animator; return animator
  }
  func takeOverForBack() -> CGFloat? {
    guard let animator, animator.state == .active, let incoming else { return nil }
    let offset = min(width,max(0,incoming.layer.presentation()?.affineTransform().tx ?? incoming.transform.tx))
    animator.stopAnimation(false); animator.finishAnimation(at:.end)
    // Complete UIKit's push bookkeeping in this turn, but leave its pixels at
    // the captured position until the interactive pop starts on the next turn.
    incoming.transform = CGAffineTransform(translationX:offset,y:0)
    return offset/width
  }
  func animationEnded(_ transitionCompleted: Bool) { animator = nil; incoming = nil }
}

#if targetEnvironment(simulator)
// Observe presentation-layer movement, rather than treating a push request or
// the configured duration as proof that the screen has started moving.
private final class NeoOpeningFrameProbe: NSObject {
  private weak var page: NeoPage?
  private let width: CGFloat
  private var link: CADisplayLink?
  init(page: NeoPage, width: CGFloat) { self.page = page; self.width = width }
  func start() { link = CADisplayLink(target:self,selector:#selector(tick)); link?.add(to:.main,forMode:.common) }
  @objc private func tick() {
    guard let page, let began = page.smokeOpeningBegan else { link?.invalidate(); link = nil; return }
    let elapsed = CACurrentMediaTime()-began
    if let layer = page.view.layer.presentation(), layer.affineTransform().tx < width-0.5 {
      page.smokeOpeningTimes["handlerToFirstMovementMs"] = elapsed*1000
      link?.invalidate(); link = nil
    } else if elapsed > 1 { link?.invalidate(); link = nil }
  }
}
#endif

// UIKit creates the interactive context on a later run-loop iteration. Keep an
// early update/end from a short drag until that context has actually started.
private final class NeoPlayerInteractiveTransition: UIPercentDrivenInteractiveTransition {
  private var ready = false
  private var pendingProgress: CGFloat?
  private var pendingFinish: Bool?
  override func startInteractiveTransition(_ context: UIViewControllerContextTransitioning) {
    super.startInteractiveTransition(context)
    DispatchQueue.main.async { [self] in
      ready = true
      if let progress = pendingProgress { update(progress) }
      if let finish = pendingFinish { if finish { self.finish() } else { cancel() } }
      pendingProgress = nil; pendingFinish = nil
    }
  }
  override func update(_ percentComplete: CGFloat) {
    if ready { super.update(percentComplete) } else { pendingProgress = percentComplete }
  }
  override func finish() { if ready { super.finish() } else { pendingFinish = true } }
  override func cancel() { if ready { super.cancel() } else { pendingFinish = false } }
}

// Retained by the player: both its back button and its completed right swipe
// dismiss through the same horizontal animator used by detail navigation.
@objc(NeoPlayerTransition)
final class NeoPlayerTransition: NSObject, UIViewControllerTransitioningDelegate {
  private var interaction: UIPercentDrivenInteractiveTransition?
  @objc var onCompletion: ((Bool) -> Void)?
  @objc var interactive: Bool { interaction != nil }
  @objc func beginInteractiveDismissal(_ controller: UIViewController) -> Bool {
    guard interaction == nil, controller.presentingViewController != nil, controller.transitionCoordinator == nil else { return false }
    let driver = NeoPlayerInteractiveTransition(); driver.completionCurve = .easeOut
    interaction = driver; controller.dismiss(animated: true); return true
  }
  @objc func updateInteractiveDismissal(_ progress: CGFloat) { interaction?.update(min(1, max(0, progress))) }
  @objc func endInteractiveDismissal(_ finish: Bool) {
    if finish { interaction?.finish() } else { interaction?.cancel() }
  }
  func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    let animator = NeoSwipeBackAnimator()
    animator.duration = 0.3 // Player dismissal keeps its existing timing.
    animator.curve = interactive ? .linear : .easeOut
    animator.onCompletion = { [weak self] completed in
      guard let self else { return }; self.interaction = nil; self.onCompletion?(completed)
    }
    return animator
  }
  func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
    interaction
  }
}

class NeoPage: UIViewController {
#if targetEnvironment(simulator)
  var smokeOpeningBegan: CFTimeInterval?
  var smokeOpeningTimes: [String:Double] = [:]
#endif
  weak var shell: NeoShell?
  let header = UIView(), body = UIView()
  let titleLabel = NeoStyle.label(size: 20, bold: true)
  var headerAccessory: UIView? { didSet { oldValue?.removeFromSuperview(); if let headerAccessory { header.addSubview(headerAccessory) }; view.setNeedsLayout() } }
  private var menu: UIButton!, back: UIButton!
  var actions: [UIView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; actions.forEach(header.addSubview); view.setNeedsLayout() } }
  init(title: String, shell: NeoShell) { super.init(nibName: nil, bundle: nil); self.shell = shell; titleLabel.text = title }
  required init?(coder: NSCoder) { fatalError() }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { shell?.tablet == true ? .all : .portrait }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { shell?.tablet == true ? view.window?.windowScene?.interfaceOrientation ?? .portrait : .portrait }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard presentedViewController == nil, shell?.tablet != true else { return }
    setNeedsUpdateOfSupportedInterfaceOrientations()
    view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
  }
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
    let canBack = (navigationController?.viewControllers.count ?? 1) > 1 || shell?.canReturnToHistory == true
    back.isHidden = !canBack; back.frame = CGRect(x: 48, y: 6, width: 40, height: 44)
    var right = width - 4
    for action in actions.reversed() { right -= 44; action.frame = CGRect(x: right, y: 6, width: 44, height: 44) }
    if let headerAccessory {
      right -= 162
      headerAccessory.frame = CGRect(x: right, y: 8, width: 160, height: 40)
      right -= 8
    }
    let left: CGFloat = menu.isHidden ? 16 : canBack ? 88 : 48
    titleLabel.frame = CGRect(x: left, y: 0, width: max(0, right - left - 4), height: 56)
    header.viewWithTag(701)?.frame = CGRect(x: 0, y: 55.5, width: width, height: 0.5)
  }
  func alert(_ text: String) {
    let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "閉じる", style: .cancel)); present(alert, animated: true)
  }
}

// The same drawer content is used by navigation and fullscreen playback.
// Explicit safe-area margins keep the brand and icons aligned in either host.
private final class NeoSidebarCell: UITableViewCell {
  let icon = UIImageView(), caption = NeoStyle.label(size: 14)
  var leftInset: CGFloat = 0 { didSet { setNeedsLayout() } }
  var iconWidth: CGFloat = 24 { didSet { setNeedsLayout() } }
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    // Own the row geometry. UIListContentView can retain safe-area margins
    // from a previous orientation on only the reused/visible rows.
    addSubview(icon); addSubview(caption); icon.contentMode = .scaleAspectFit
    icon.tintColor = NeoStyle.muted; isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews()
    icon.frame = CGRect(x: leftInset+16, y: (bounds.height-27)/2, width: iconWidth, height: 27)
    caption.frame = CGRect(x: leftInset+56, y: 0, width: max(0, bounds.width-leftInset-72), height: bounds.height)
  }
}

private final class NeoNavigationButton: UIButton {
  var showsCaption = true { didSet { caption.isHidden = !showsCaption; setNeedsLayout() } }
  let icon = UIImageView(), caption = NeoStyle.label(size: 10)
  init(item: NeoDestination) {
    super.init(frame: .zero)
    icon.image = NeoIcon.image(item.icon); icon.contentMode = .scaleAspectFit
    caption.text = item.title; caption.textAlignment = .center
    addSubview(icon); addSubview(caption); isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func tintColorDidChange() { super.tintColorDidChange(); icon.tintColor = tintColor; caption.textColor = tintColor }
  override func layoutSubviews() {
    super.layoutSubviews()
    icon.frame = CGRect(x: (bounds.width-24)/2, y: showsCaption ? 7 : (bounds.height-24)/2, width: 24, height: 24)
    caption.frame = CGRect(x: 1, y: 34, width: max(0, bounds.width-2), height: 14)
  }
}

final class NeoSidebar: UIView, UITableViewDataSource, UITableViewDelegate {
  let brand = NeoStyle.label("NeoEPGStation", size: 18, bold: true)
  let logo = UIImageView(image: UIImage(named: "Brand"))
  let list = UITableView(frame: .zero, style: .plain)
  var onSelect: ((String) -> Void)?
  var selected = "recorded" { didSet { if oldValue != selected { list.reloadData() } } }
  var contentSafeArea = UIEdgeInsets.zero {
    didSet {
      if oldValue.left != contentSafeArea.left { list.reloadData() }
      if oldValue != contentSafeArea { setNeedsLayout() }
    }
  }
  override init(frame: CGRect) {
    super.init(frame: frame); backgroundColor = NeoStyle.paper
    [brand, logo, list].forEach(addSubview); logo.contentMode = .scaleAspectFit
    list.backgroundColor = .clear; list.separatorStyle = .none; list.rowHeight = 40
    list.delaysContentTouches = false; list.panGestureRecognizer.delaysTouchesEnded = false
    list.contentInsetAdjustmentBehavior = .never; list.insetsContentViewsToSafeArea = false
    list.contentInset.top = 8; list.dataSource = self; list.delegate = self
    list.register(NeoSidebarCell.self, forCellReuseIdentifier: "navigation")
    layer.borderColor = NeoStyle.border.cgColor; layer.borderWidth = 0.5
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews(); let safe = contentSafeArea
    let logoWidth = (logo.image?.size.width ?? 28) / max(1, logo.image?.size.height ?? 28) * 28
    let left = safe.left + 16
    brand.frame = CGRect(x: left, y: safe.top, width: min(ceil(brand.intrinsicContentSize.width), max(0, bounds.width - left - logoWidth - 11)), height: 60)
    logo.frame = CGRect(x: brand.frame.maxX + 7, y: safe.top + 16, width: logoWidth, height: 28)
    list.frame = CGRect(x: 0, y: safe.top + 60, width: bounds.width, height: max(0, bounds.height - safe.top - 60 - safe.bottom))
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { NeoDestination.all.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "navigation", for: indexPath) as! NeoSidebarCell, item = NeoDestination.all[indexPath.row]
    cell.insetsLayoutMarginsFromSafeArea = false; cell.preservesSuperviewLayoutMargins = false
    cell.contentView.insetsLayoutMarginsFromSafeArea = false; cell.contentView.preservesSuperviewLayoutMargins = false
    cell.leftInset = contentSafeArea.left; cell.icon.image = NeoIcon.image(item.icon); cell.caption.text = item.title
    cell.iconWidth = item.icon == "AlphaA" ? 27 : 24
    cell.accessibilityLabel = item.title
    cell.backgroundColor = item.id == selected ? NeoStyle.accent.withAlphaComponent(0.16) : .clear
    cell.accessibilityIdentifier = "menu-" + item.id; return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false); onSelect?(NeoDestination.all[indexPath.row].id)
  }
  func rowHasExpectedLayout(_ cell: UITableViewCell) -> Bool {
    guard let cell = cell as? NeoSidebarCell else { return false }
    cell.layoutIfNeeded()
    return cell.icon.frame.minX == contentSafeArea.left+16 && cell.icon.bounds.size == CGSize(width: cell.iconWidth, height: 27)
      && cell.caption.frame.minX == contentSafeArea.left+56
  }
}

final class NeoShell: UIViewController, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
  let storage = NeoNative()
  private(set) var api: NeoAPI?
  private(set) var account: NeoAccountCoordinator?
  private var preparingPlay = false
  private var playPreparationTask: Task<Void, Never>?
  private weak var preparationOrigin: UIViewController?
#if targetEnvironment(simulator)
  private var checkpointAnalysisProbe: ((NeoCheckpointDecision?) -> Void)?
#endif
  private(set) var channels: [Int: String] = [:]
  private(set) var serverConfig: NeoServerConfig?
  private(set) var route = "recorded"
  // Each destination keeps its own stack. Switching tabs never adds a back target.
  private var controllers: [String: UINavigationController] = [:]
  private var active: UINavigationController?
  private var historyReturnSnapshot: UIView?
  private var historyReturnRevision: Int?
  private var routeBackPreview: UIView?
  private var routeBackRunning = false
  var canReturnToHistory: Bool { route == "recorded" && historyReturnRevision != nil && historyReturnRevision == api?.identityRevision && controllers["history"] != nil }
  private let content = UIView(), bottom = UIView(), dim = UIView()
  private let sidebar = NeoSidebar()
  private var sidebarWidth: CGFloat { 240 + view.safeAreaInsets.left }
  private var shortcuts: [String] = []
  private var bottomButtons: [UIButton] = []
  private var menuOpen = false, tabletExpanded = true
  private var tabletReveal: CGFloat = 1
#if targetEnvironment(simulator)
  func smokeUseAPI(_ value: NeoAPI?) { api = value; account = value.map { NeoAccountCoordinator(api: $0, shell: self) } }
  private var startupDrawerWasStill = false
#endif
  private var contentPan: UIPanGestureRecognizer!, closingPan: UIPanGestureRecognizer!, backdropPan: UIPanGestureRecognizer!, sidebarBackPan: UIPanGestureRecognizer!
  private weak var closingScroll: UIScrollView?
  private var closingScrollWasEnabled = false
  private var popup: NeoAnchoredMenu?
  private var swipeStart = CGPoint.zero
  private var swipeAction: NeoSwipeAction?
  private var waveSwipe: Int?
  private weak var swipeScroll: UIScrollView?
  private var scrollWasEnabled = false
  private var popInteraction: UIPercentDrivenInteractiveTransition?
  private weak var pushingNavigation: UINavigationController?
  private weak var pushingPage: UIViewController?
  private var pushingAnimator: NeoPagePushAnimator?
  private var backInitialProgress: CGFloat = 0
  private var pendingBack: (navigation: UINavigationController, target: UIViewController,
    state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat, initialProgress: CGFloat)?
  private var panStart: CGFloat = 0
  private var menuDragging = false
  private var player: UIViewController?
  var tablet: Bool { traitCollection.userInterfaceIdiom == .pad }
  var smokeStage: String {
#if targetEnvironment(simulator)
    return ProcessInfo.processInfo.environment["NEO_EPG_UI_SMOKE"] ?? ""
#else
    return ""
#endif
  }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { tablet ? .all : .portrait }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { tablet ? view.window?.windowScene?.interfaceOrientation ?? .portrait : .portrait }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if presentedViewController == nil && !tablet {
      setNeedsUpdateOfSupportedInterfaceOrientations()
      view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
#if targetEnvironment(simulator)
    guard !smokeStage.isEmpty else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.runUISmoke() }
#endif
  }
  override func viewDidLoad() {
    super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = NeoStyle.paper
    content.clipsToBounds = true
    shortcuts = storage.shortcuts
    view.addSubview(content); view.addSubview(bottom); view.addSubview(dim); view.addSubview(sidebar)
    sidebar.backgroundColor = NeoStyle.paper; bottom.backgroundColor = NeoStyle.paper
    sidebar.onSelect = { [weak self] in self?.selectDestination($0) }
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.5); dim.alpha = 0
    dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeMenu)))
    contentPan = UIPanGestureRecognizer(target: self, action: #selector(dragContent(_:))); contentPan.delegate = self
    contentPan.maximumNumberOfTouches = 1; content.addGestureRecognizer(contentPan)
    closingPan = UIPanGestureRecognizer(target: self, action: #selector(dragMenu(_:))); closingPan.delegate = self
    closingPan.maximumNumberOfTouches = 1
    sidebar.addGestureRecognizer(closingPan)
    sidebarBackPan = UIPanGestureRecognizer(target: self, action: #selector(dragContent(_:))); sidebarBackPan.delegate = self
    sidebarBackPan.maximumNumberOfTouches = 1; sidebar.addGestureRecognizer(sidebarBackPan)
    backdropPan = UIPanGestureRecognizer(target: self, action: #selector(dragMenu(_:))); backdropPan.delegate = self
    backdropPan.maximumNumberOfTouches = 1; dim.addGestureRecognizer(backdropPan)
    for pan in [contentPan,closingPan,sidebarBackPan,backdropPan] { pan?.delaysTouchesBegan = false; pan?.delaysTouchesEnded = false }
    rebuildBottom()
    setMenu(false, animated: false)
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
#if targetEnvironment(simulator)
    startupDrawerWasStill = !menuOpen && (sidebar.layer.animationKeys()?.isEmpty ?? true)
#endif
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets, width = view.bounds.width
    let sidebarWidth: CGFloat = api != nil && tablet ? self.sidebarWidth * tabletReveal : 0
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
    sidebar.isHidden = api == nil
    let sidebarX: CGFloat = tablet ? self.sidebarWidth * (tabletReveal - 1) : menuDragging ? sidebar.frame.minX : menuOpen ? 0 : -self.sidebarWidth
    sidebar.frame = CGRect(x: sidebarX, y: 0, width: self.sidebarWidth, height: view.bounds.height)
    sidebar.contentSafeArea = safe
    sidebar.list.isScrollEnabled = !tablet; sidebar.list.bounces = !tablet
    sidebar.list.alwaysBounceVertical = !tablet
    bottom.layer.borderColor = NeoStyle.border.cgColor; bottom.layer.borderWidth = 0.5
    popup?.setNeedsLayout()
  }
  func connect(_ url: URL) {
    dismissPopup(); historyReturnSnapshot = nil; historyReturnRevision = nil; api = NeoAPI(base: url); channels = [:]; serverConfig = nil
    for controller in controllers.values { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
    controllers.removeAll(); active = nil
    showRoute("recorded")
    let api = self.api!
    account = NeoAccountCoordinator(api: api, shell: self)
    DispatchQueue.main.async { [weak self, weak api] in
      guard let self, self.api === api else { return }; self.account?.restore()
    }
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
  func revalidateAccount() { if player == nil { account?.restore() } }
  func showConnection(message: String? = nil) {
    dismissPopup()
    api = nil; account = nil; menuOpen = false; route = "connection"
    let page = NeoConnectionPage(shell: self)
    page.initialMessage = message
    let nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false)
    attach(nav); view.setNeedsLayout()
  }
  func showRoute(_ id: String) {
    guard api != nil, popInteraction == nil, !routeBackRunning else { return }
    dismissPopup()
    if id != route { historyReturnSnapshot = nil; historyReturnRevision = nil }
    route = id
    let nav: UINavigationController
    if let cached = controllers[id] { nav = cached }
    else {
      let page: NeoPage
      if id == "recorded" { page = NeoRecordedPage(shell: self) }
      else if id == "onair" { page = NeoOnAirPage(shell: self) }
      else if id == "settings" { page = NeoSettingsPage(shell: self) }
      else if id == "history" { page = NeoHistoryPage(shell: self) }
      else { page = NeoPlaceholderPage(id: id, shell: self) }
      nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false)
      nav.delegate = self
      nav.interactivePopGestureRecognizer?.isEnabled = false
      controllers[id] = nav
    }
    attach(nav); sidebar.selected = route; updateBottom(); setMenu(false, animated: true)
  }
  // A navigation button returns to the retained list first. Only a second tap
  // on that list resets pagination; programmatic route changes keep the stack.
  private func selectDestination(_ id: String) {
    guard api != nil, popInteraction == nil, !routeBackRunning, active?.transitionCoordinator == nil else { return }
    historyReturnSnapshot = nil; historyReturnRevision = nil
    if let nav = controllers[id] {
      if id == route, let list = nav.topViewController as? NeoRecordedPage {
        if nav.viewControllers.count > 1 { nav.popViewController(animated: true) }
        else { list.returnToFirstPage() }
      } else if let list = nav.viewControllers.last(where: { $0 is NeoRecordedPage }) {
        nav.popToViewController(list, animated: id == route)
      } else {
        nav.popToRootViewController(animated: id == route)
      }
    }
    showRoute(id)
  }
  private func attach(_ nav: UINavigationController) {
    if active !== nav {
      pendingBack?.target.view.transform = .identity
      pendingBack = nil
      active?.willMove(toParent: nil); active?.view.removeFromSuperview(); active?.removeFromParent()
      addChild(nav); content.addSubview(nav.view); nav.view.frame = content.bounds; nav.didMove(toParent: self); active = nav
    }
    // The built-in edge recognizer may not exist until the navigation view loads.
    nav.interactivePopGestureRecognizer?.isEnabled = false
    active?.topViewController?.view.setNeedsLayout(); view.setNeedsLayout()
  }
  func goBack() {
    guard active?.transitionCoordinator == nil, !routeBackRunning else { return }
    dismissPopup()
    if let active, active.viewControllers.count > 1 { active.popViewController(animated: true) }
    else if canReturnToHistory { beginHistoryReturn(); finishHistoryReturn(true) }
  }
  func openDetail(_ recording: NeoRecording) {
    let began = CACurrentMediaTime()
    dismissPopup()
    (active?.topViewController as? NeoRecordedPage)?.rememberDetail(recording.id)
    pushPage(requestedAt:began) { NeoDetailPage(item:recording,shell:self) }
  }
  func pushPage(requestedAt: CFTimeInterval = CACurrentMediaTime(), _ make: () -> NeoPage) {
#if targetEnvironment(simulator)
    let began = requestedAt
#endif
    let page = make()
#if targetEnvironment(simulator)
    page.smokeOpeningBegan = began
    page.smokeOpeningTimes["constructionMs"] = (CACurrentMediaTime()-began)*1000
#endif
    active?.pushViewController(page,animated:true)
#if targetEnvironment(simulator)
    page.smokeOpeningTimes["handlerToPushReturnedMs"] = (CACurrentMediaTime()-began)*1000
#endif
  }
  func locateRecording(_ id: Int, position: NeoListPosition) {
    guard !routeBackRunning, popInteraction == nil else { return }
    let fromHistory = route == "history"
    let origin = fromHistory ? active?.view.snapshotView(afterScreenUpdates: false) : nil
    showRoute("recorded")
    guard let nav = controllers["recorded"], let list = nav.viewControllers.first as? NeoRecordedPage else { return }
    nav.popToRootViewController(animated: false)
    historyReturnSnapshot = origin; historyReturnRevision = fromHistory ? api?.identityRevision : nil
    list.locate(id, page: position.page, userID: position.userId); list.view.setNeedsLayout()
  }
  func play(_ file: NeoVideoFile, recording: NeoRecording, fromBeginning: Bool = false, streaming: Int? = nil, streamSubtitle: Int? = nil, streamComment: Int? = nil, onPrepared: (() -> Void)? = nil) {
    guard player == nil, !preparingPlay, let api else { onPrepared?(); return }
    guard api.accountReady else {
      (active?.topViewController as? NeoPage)?.alert("アクティブユーザーの確認が必要です。設定のアカウントで確認してください。")
      onPrepared?(); return
    }
    preparingPlay = true
    let user = api.viewer, revision = api.identityRevision, origin = active?.topViewController
    let experiment = NeoPlaybackExperiment.selected, checkpointMode = NeoPlaybackExperiment.checkpointMode
    preparationOrigin = origin
    playPreparationTask = Task { [weak self, weak origin] in
      guard let self else { return }
      var analysisAlert: UIAlertController?
      defer {
        if let alert = analysisAlert, alert.presentingViewController != nil, !alert.isBeingDismissed { alert.dismiss(animated: false) }
        preparingPlay = false; playPreparationTask = nil; preparationOrigin = nil; onPrepared?()
      }
      var start = 0.0
      if !fromBeginning, api.resumePlayback, Int(user).map({ $0 > 0 }) == true {
        do { start = try await api.playback(recording.id, user: user).resumePosition ?? 0 }
        catch {
          guard self.api === api, api.identityRevision == revision, active?.topViewController === origin else { return }
          let alert = UIAlertController(title: "再生位置を取得できません", message: error.localizedDescription, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: "再試行", style: .default) { [weak self] _ in self?.play(file, recording: recording, streaming: streaming, streamSubtitle: streamSubtitle, streamComment: streamComment) })
          alert.addAction(UIAlertAction(title: "最初から再生", style: .default) { [weak self] _ in self?.play(file, recording: recording, fromBeginning: true, streaming: streaming, streamSubtitle: streamSubtitle, streamComment: streamComment) })
          alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel)); origin?.present(alert, animated: true); return
        }
      }
      var decision: NeoCheckpointDecision?
      if experiment == .checkpointPlayer, streaming == nil, experiment.applies(fileType: file.type, streaming: streaming != nil, recording: recording.isRecording) {
        if checkpointMode == .automatic {
          do {
            let result = try await NeoCheckpointAnalysis.resolve(fetch: { try await api.checkpointVideoInfo(file.id) },
              isCurrent: { self.viewIfLoaded?.window != nil && self.api === api && api.accountReady && api.identityRevision == revision && self.active?.topViewController === origin },
              progress: { _ in
                guard analysisAlert == nil, let origin, origin.presentedViewController == nil else { return }
                let alert = UIAlertController(title: "解析中", message: "再生方法を選択しています。解析が完了するまでお待ちください。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in self?.playPreparationTask?.cancel() })
                analysisAlert = alert; origin.present(alert, animated: true)
              })
            decision = result.decision
          } catch { return }
          if let alert = analysisAlert, alert.presentingViewController != nil, !alert.isBeingDismissed {
            await withCheckedContinuation { continuation in alert.dismiss(animated: true) { continuation.resume() } }
          }
        } else { decision = NeoCheckpointDecision.choose(checkpointMode, info: nil) }
      }
      guard !Task.isCancelled, self.api === api, api.accountReady, api.identityRevision == revision, active?.topViewController === origin, player == nil else { return }
#if targetEnvironment(simulator)
      if let probe = checkpointAnalysisProbe { probe(decision); return }
#endif
      presentPlayer(file, recording: recording, api: api, user: user, start: start, streaming: streaming, streamSubtitle: streamSubtitle, streamComment: streamComment,
        experiment: experiment, checkpointDecision: decision)
    }
  }
  private func presentPlayer(_ file: NeoVideoFile, recording: NeoRecording, api: NeoAPI, user: String, start: Double, streaming: Int?, streamSubtitle: Int?, streamComment: Int?,
    experiment: NeoPlaybackExperiment, checkpointDecision: NeoCheckpointDecision?) {
    if (experiment == .decodeTrial || experiment == .checkpointTrial), experiment.applies(fileType: file.type, streaming: streaming != nil, recording: recording.isRecording) {
      let controller = NeoDecodeTrialController(source: api.url("/videos/\(file.id)"), checkpoint: experiment == .checkpointTrial)
      player = controller; controller.onClose = { [weak self] in self?.player = nil }
      present(controller, animated: true); return
    }
    if experiment == .avplayer, experiment.applies(fileType: file.type, streaming: streaming != nil, recording: recording.isRecording) {
      let controller = NeoAVPlayerComparison(url: api.url("/videos/\(file.id)/web"), title: recording.name,
        context: ["baseURL": api.base.absoluteString, "id": recording.id, "disableHistory": true,
          "channelId": recording.channelId ?? 0, "channelName": recording.channelName ?? "",
          "name": recording.name, "startAt": recording.startAt, "endAt": recording.endAt,
          "description": recording.description ?? "", "extended": recording.extended ?? ""])
      player = controller; controller.onClose = { [weak self] in self?.player = nil }
      present(controller, animated: true); return
    }
    let controller = NeoPlayerController(url: api.url("/videos/\(file.id)"), title: recording.name, username: "", password: "", networkCaching: NeoViewingPreferences.networkSeconds*1000)
    controller.initialPosition = start
    if (experiment == .aether || experiment == .checkpointPlayer), experiment.applies(fileType:file.type, streaming:streaming != nil, recording:recording.isRecording) {
      var options: [String:Any] = ["checkpointEnabled":streaming == nil && checkpointDecision?.enabled == true]
      if let checkpointDecision { options["checkpointSelection"] = checkpointDecision.diagnosticFields }
      controller.aetherOptions = options
    }
    controller.recordingContext = ["baseURL": api.base.absoluteString, "id": recording.id, "user": user,
      "disableHistory": api.disablePlaybackHistory, "videoFileType": file.type,
      "channelId": recording.channelId ?? 0, "channelName": recording.channelName ?? recording.channelId.flatMap { channels[$0] } ?? "",
      "name": recording.name, "startAt": recording.startAt, "endAt": recording.endAt, "isRecording": recording.isRecording,
      "description": recording.description ?? "", "extended": recording.extended ?? "", "ruleId": recording.ruleId ?? 0]
    controller.annictTracker = NeoAnnictPlayback(api:api,recordingID:recording.id)
    if let mode = streaming {
      let qualities = serverConfig?.streamingQualities(file.type) ?? []
      guard qualities.indices.contains(mode), !qualities[mode].isEmpty else { return }
      var context = controller.recordingContext ?? [:]
      context["streaming"] = true; context["streamMode"] = mode; context["streamQualities"] = qualities
      if file.type == "encoded", let streamSubtitle { context["streamSubtitleIndex"] = streamSubtitle }
      if file.type == "encoded", let streamComment { context["streamCommentIndex"] = streamComment }
      controller.recordingContext = context
    }
    controller.modalPresentationStyle = .fullScreen; player = controller
    controller.onClose = { [weak self] in
      self?.player = nil
      NotificationCenter.default.post(name: .neoHistoryChanged, object: api)
    }
    controller.onNavigate = { [weak self] route in self?.selectDestination(route) }
    controller.onRecording = { [weak self, weak api] id in
      Task { [weak self] in
        guard let self, let api else { return }
        do { let item = try await api.recording(id); guard self.api === api else { return }; self.openDetail(item) }
        catch { self.active?.topViewController.flatMap { $0 as? NeoPage }?.alert(error.localizedDescription) }
      }
    }
    present(controller, animated: true)
  }
  func playLive(_ schedule: NeoLiveSchedule, option: NeoLiveOption, options: [NeoLiveOption], schedules: [NeoLiveSchedule], api: NeoAPI) {
    guard player == nil, !preparingPlay, self.api === api else { return }
    var context = schedule.context(base:api.base)
    context["liveType"] = option.type; context["liveMode"] = option.mode; context["liveQuality"] = option.quality
    context["liveOptions"] = options.map(\.dictionary); context["liveChannels"] = schedules.map { $0.context(base:api.base) }
    context["liveHeaders"] = api.liveRequestHeaders
    let buffer = UserDefaults.standard.object(forKey:"live.bufferMs") as? Int ?? (option.type == "m2tsll" ? 300 : 1500)
    let controller = NeoPlayerController(url:option.url(api:api,channel:schedule.channel.id),title:schedule.program?.name ?? schedule.channel.name,
      username:"",password:"",networkCaching:buffer)
    controller.recordingContext = context; controller.modalPresentationStyle = .fullScreen; player = controller
    controller.onClose = { [weak self] in self?.player = nil }
    controller.onNavigate = { [weak self] route in self?.selectDestination(route) }
    present(controller,animated:true)
  }
  func showPopup(anchor: UIView, entries: [NeoMenuEntry], appearance: NeoAnchoredMenu.Appearance) {
    dismissPopup(); guard !entries.isEmpty, anchor.window != nil else { return }
    let menu = NeoAnchoredMenu(anchor: anchor, entries: entries, appearance: appearance)
    menu.onDismiss = { [weak self] in self?.popup = nil }
    popup = menu; menu.show(in: view)
  }
  func dismissPopup() { popup?.dismiss() }
  func toggleMenu() {
    guard !routeBackRunning else { return }
    if tablet { setTabletMenu(!tabletExpanded, animated: true) }
    else { setMenu(!menuOpen, animated: true) }
  }
  private func setTabletMenu(_ open: Bool, animated: Bool) {
    if open { dismissPopup() }
    tabletExpanded = open; tabletReveal = open ? 1 : 0
    let changes = { self.view.setNeedsLayout(); self.view.layoutIfNeeded() }
    if animated && view.window != nil && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: changes)
    } else { changes() }
  }
  @objc private func closeMenu() { setMenu(false, animated: true) }
  private func setMenu(_ open: Bool, animated: Bool) {
    guard !tablet else { return }
    if open { dismissPopup() }
    let changed = menuOpen != open
    menuOpen = open
    // A fading backdrop must stop intercepting the new page immediately.
    // Its opacity animation previously swallowed the first swipe after routing.
    dim.isUserInteractionEnabled = open
    let changes = { self.sidebar.frame.origin.x = open ? 0 : -self.sidebarWidth; self.dim.alpha = open ? 1 : 0 }
    if animated && (changed || menuDragging || sidebar.bounds.width > 0 && sidebar.frame.minX > -sidebarWidth && !open) && view.window != nil {
      UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: changes)
    }
    else { changes() }
    sidebar.accessibilityViewIsModal = open
  }
  @objc private func dragMenu(_ recognizer: UIPanGestureRecognizer) {
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
    if tablet {
      if state == .began {
        let current = content.layer.presentation()?.frame.minX ?? content.frame.minX
        content.layer.removeAllAnimations(); active?.view.layer.removeAllAnimations(); sidebar.layer.removeAllAnimations()
        menuDragging = true; panStart = min(sidebarWidth, max(0, current))
      }
      let progress = min(sidebarWidth, max(0, panStart + translation))
      if state == .began || state == .changed {
        tabletReveal = progress / max(1, sidebarWidth); view.setNeedsLayout(); view.layoutIfNeeded()
      } else if [.ended, .cancelled, .failed].contains(state) {
        menuDragging = false
        let open = state == .ended ? (abs(velocity) > 350 ? velocity > 0 : progress > sidebarWidth / 2) : tabletExpanded
        setTabletMenu(open, animated: true)
      }
      return
    }
    if state == .began {
      menuDragging = true
      let x = sidebar.layer.presentation()?.frame.minX ?? sidebar.frame.minX
      sidebar.layer.removeAllAnimations(); dim.layer.removeAllAnimations()
      sidebar.frame.origin.x = x; panStart = min(sidebarWidth, max(0, x + sidebarWidth)); dim.alpha = panStart / sidebarWidth
    }
    let progress = min(sidebarWidth, max(0, panStart + translation))
    if state == .changed || state == .began {
      sidebar.frame.origin.x = progress - sidebarWidth; dim.alpha = progress / sidebarWidth
    } else if state == .ended {
      menuDragging = false
      setMenu(abs(velocity) > 350 ? velocity > 0 : progress > sidebarWidth / 2, animated: true)
    } else if state == .cancelled || state == .failed { menuDragging = false; setMenu(menuOpen, animated: true) }
  }
  private var canGoBack: Bool { (active?.viewControllers.count ?? 1) > 1 || canReturnToHistory }
  @objc private func dragContent(_ recognizer: UIPanGestureRecognizer) {
    if recognizer.state == .began {
      scrollWasEnabled = swipeScroll?.isScrollEnabled == true
      swipeScroll?.isScrollEnabled = false
    }
    if let direction = waveSwipe {
      if recognizer.state == .ended { finishWaveSwipe(direction,translation:recognizer.translation(in:content).x,velocity:recognizer.velocity(in:content).x) }
    } else if swipeAction == .menu { dragMenu(recognizer) }
    else if swipeAction == .back { dragBack(recognizer) }
    if [.ended, .cancelled, .failed].contains(recognizer.state) {
      if scrollWasEnabled { swipeScroll?.isScrollEnabled = true }
      swipeScroll = nil; swipeAction = nil; waveSwipe = nil
    }
  }
  private func beginWaveSwipe(horizontal: CGFloat) -> Bool {
    waveSwipe = nil
    guard let page = active?.topViewController as? NeoOnAirPage, let direction = page.waveSwipeDirection(horizontal:horizontal) else { return false }
    waveSwipe = direction; swipeAction = nil; return true
  }
  private func finishWaveSwipe(_ direction: Int, translation: CGFloat, velocity: CGFloat) {
    if translation*CGFloat(-direction) >= 44 || velocity*CGFloat(-direction) >= 350 { (active?.topViewController as? NeoOnAirPage)?.swipeWave(direction) }
  }
#if targetEnvironment(simulator)
  func smokeSwipeWave(horizontal: CGFloat, complete: Bool = true) -> Bool {
    let owns = beginWaveSwipe(horizontal:horizontal)
    if owns, complete, let direction = waveSwipe { finishWaveSwipe(direction,translation:horizontal,velocity:horizontal*5) }
    waveSwipe = nil; return owns
  }
#endif
  private func dragBack(_ recognizer: UIPanGestureRecognizer) {
    updateBack(state: recognizer.state, translation: recognizer.translation(in: content).x, velocity: recognizer.velocity(in: content).x)
  }
  private func updateBack(state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat) {
    guard let active else { return }
    // Finish only UIKit's push bookkeeping immediately and keep its visual
    // progress. The next run-loop turn can start a pop at exactly that point.
    if pendingBack != nil || (state == .began && canDeferBackUntilPushCompletes) {
      if let target = active.topViewController {
        let first = pendingBack == nil
        pendingBack = (active,target,state,translation,velocity,pendingBack?.initialProgress ?? 0)
        if first, let progress = pushingAnimator?.takeOverForBack() { pendingBack?.initialProgress = progress }
      }
      return
    }
    let width = max(1, content.bounds.width)
    let progress = min(1, max(0, translation / width))
    let visualProgress = min(1,max(0,backInitialProgress+translation/width))
    // Choose the gesture's owner at begin. UINavigationController removes
    // the outgoing detail from its stack before an interactive pop finishes;
    // that must not turn its subsequent change/cancel into a history return.
    if routeBackRunning || (state == .began && active.viewControllers.count == 1 && canReturnToHistory) {
      switch state {
      case .began: beginHistoryReturn()
      case .changed: active.view.transform = CGAffineTransform(translationX: max(0, translation), y: 0)
      case .ended, .cancelled, .failed: finishHistoryReturn(state == .ended && (progress > 0.28 || velocity > 450))
      default: break
      }
      return
    }
    switch state {
    case .began:
      if active.viewControllers.count > 1 {
        let interaction = NeoPlayerInteractiveTransition(); interaction.completionCurve = .easeOut
        popInteraction = interaction; active.popViewController(animated: true)
        interaction.update(backInitialProgress)
#if targetEnvironment(simulator)
        backSmokeDetails["detailContextInteractive"] = active.transitionCoordinator?.isInteractive == true
#endif
        active.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.popInteraction = nil }
      }
    case .changed:
#if targetEnvironment(simulator)
      if active.viewControllers.count > 1 || popInteraction != nil { backSmokeDetails["detailDriverOnChange"] = popInteraction != nil }
#endif
      if let interaction = popInteraction { interaction.update(visualProgress) }
    case .ended, .cancelled, .failed:
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
  // Only history's recorded-list deep link creates a cross-tab back target.
  // Keep both stacks intact and move the recorded view over a retained preview.
  private func beginHistoryReturn() {
    guard canReturnToHistory, !routeBackRunning, let active else { return }
    let origin = historyReturnSnapshot ?? UIView()
    origin.backgroundColor = NeoStyle.background; origin.isUserInteractionEnabled = false
    routeBackRunning = true; origin.frame = content.bounds; routeBackPreview = origin
    content.insertSubview(origin, belowSubview: active.view)
  }
  private func finishHistoryReturn(_ finish: Bool) {
    guard routeBackRunning, let active else { return }
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22, delay: 0,
      options: [.beginFromCurrentState, .curveEaseOut], animations: {
        active.view.transform = finish ? CGAffineTransform(translationX: self.content.bounds.width, y: 0) : .identity
      }, completion: { [weak self] _ in
        guard let self else { return }
        UIView.performWithoutAnimation {
          active.view.transform = .identity; active.view.frame = self.content.bounds
          self.routeBackPreview?.removeFromSuperview(); self.routeBackPreview = nil
        }
        self.routeBackRunning = false
        if finish { self.showRoute("history") }
      })
  }
  func navigationController(_ navigationController: UINavigationController,
    animationControllerFor operation: UINavigationController.Operation,
    from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    if operation == .push {
      pushingNavigation = navigationController; pushingPage = toVC
      let animator = NeoPagePushAnimator(); pushingAnimator = animator; return animator
    }
    if operation == .pop && popInteraction != nil { fromVC.view.transform = .identity }
    return operation == .pop && popInteraction != nil ? NeoSwipeBackAnimator() : nil
  }
  func navigationController(_ navigationController: UINavigationController,
    interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
#if targetEnvironment(simulator)
    backSmokeDetails["interactionControllerRequested"] = true
#endif
    return popInteraction
  }
  func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
    if navigationController === active, preparingPlay, viewController !== preparationOrigin { playPreparationTask?.cancel() }
    if pushingNavigation === navigationController { pushingNavigation = nil; pushingPage = nil; pushingAnimator = nil }
    if navigationController === active { popInteraction = nil; backInitialProgress = 0 }
    viewController.view.setNeedsLayout()
    // didShow can run before UIKit releases its transition context. The next
    // turn hands off the drag; the interrupted animation is already finished.
    DispatchQueue.main.async { [weak self] in self?.resumePendingBack() }
  }
  private var canDeferBackUntilPushCompletes: Bool {
    guard let active, active === pushingNavigation, active.topViewController === pushingPage,
      active.viewControllers.count > 1, let transition = active.transitionCoordinator else { return false }
    return !transition.isInteractive && pushingAnimator != nil
  }
  private func resumePendingBack() {
    guard let pending = pendingBack else { return }
    guard active === pending.navigation, active?.topViewController === pending.target else { pending.target.view.transform = .identity; pendingBack = nil; return }
    guard active?.transitionCoordinator == nil else { return }
    pendingBack = nil
    backInitialProgress = pending.initialProgress
    updateBack(state:.began,translation:0,velocity:pending.velocity)
    updateBack(state:.changed,translation:pending.translation,velocity:pending.velocity)
    if [.ended,.cancelled,.failed].contains(pending.state) { updateBack(state:pending.state,translation:pending.translation,velocity:pending.velocity) }
  }
  private func acceptsSidebarBack(start: CGPoint) -> Bool {
    tablet && tabletExpanded && start.x <= max(24, view.safeAreaInsets.left+24) && start.y >= view.bounds.height*0.3 && canGoBack
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
    if recognizer === sidebarBackPan {
      swipeStart = touch.location(in: view); swipeScroll = nil
      return acceptsSidebarBack(start: swipeStart)
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
    return beginNavigationSwipe(recognizer, velocity:velocity)
  }
  private func beginNavigationSwipe(_ recognizer: UIGestureRecognizer, velocity: CGPoint) -> Bool {
    guard abs(velocity.x) >= abs(velocity.y), abs(velocity.x) > 0 else { return false }
    if recognizer === closingPan || recognizer === backdropPan { return (tablet ? tabletReveal > 0 : menuOpen) && velocity.x < 0 }
    guard recognizer === contentPan || recognizer === sidebarBackPan, api != nil, !menuOpen, popup == nil, presentedViewController == nil,
      popInteraction == nil, pendingBack == nil, !routeBackRunning else { return false }
    if active?.transitionCoordinator == nil, recognizer === contentPan, beginWaveSwipe(horizontal:velocity.x) { return true }
    swipeAction = NeoNavigationGesture.action(startY: Double(swipeStart.y), height: Double(view.bounds.height),
      canGoBack: canGoBack, tablet: tablet && tabletExpanded, horizontal: Double(velocity.x), vertical: Double(velocity.y), persistentMenu: tablet)
    if active?.transitionCoordinator != nil && !(swipeAction == .back && canDeferBackUntilPushCompletes) { return false }
    if recognizer === sidebarBackPan { return tablet && tabletExpanded && swipeAction == .back }
    if tablet && tabletExpanded && swipeAction == .back { return false }
    return swipeAction != nil
  }
  func saveShortcuts(_ values: [String]) throws { try storage.saveShortcuts(values); shortcuts = values; rebuildBottom(); view.setNeedsLayout() }
  func refreshNavigationLabels() {
    for case let button as NeoNavigationButton in bottomButtons { button.showsCaption = NeoViewingPreferences.navigationLabels }
  }
  private func rebuildBottom() {
    bottomButtons.forEach { $0.removeFromSuperview() }; bottomButtons = []
    for id in shortcuts {
      guard let item = NeoDestination.all.first(where: { $0.id == id }) else { continue }
      let b = NeoNavigationButton(item: item)
      b.showsCaption = NeoViewingPreferences.navigationLabels
      b.accessibilityLabel = item.title; b.accessibilityIdentifier = "tab-" + id
      b.addAction(UIAction { [weak self] _ in self?.selectDestination(id) }, for: .touchUpInside)
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

#if targetEnvironment(simulator)
  func smokeMeasureOpening() async -> (checks:[String:Bool],timings:[String:[String:Double]]) {
    var checks = [String:Bool](), timings = [String:[String:Double]]()
    for kind in ["general","viewing","detail"] {
      showRoute(kind == "detail" ? "recorded" : "settings"); active?.popToRootViewController(animated:false); view.layoutIfNeeded()
      if kind == "detail" { openDetail(NeoRecordedPage.fixtures.records[0]) }
      else if let root = active?.topViewController as? NeoSettingsPage {
        checks["settingsTapDoesNotWaitForScroll"] = root.smokeTapDeliveryImmediate
        root.smokeOpenCategory(kind == "general" ? .general : .viewing)
      }
      let page = active?.topViewController as? NeoPage
      for _ in 0..<100 {
        if page?.smokeOpeningTimes["handlerToFirstMovementMs"] != nil && active?.transitionCoordinator == nil { break }
        try? await Task.sleep(nanoseconds:10_000_000)
      }
      timings[kind] = page?.smokeOpeningTimes ?? [:]
      checks[kind+"FirstMovementMeasured"] = page?.smokeOpeningTimes["handlerToFirstMovementMs"] != nil
      if kind == "viewing", let window = view.window {
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        try? image.pngData()?.write(to:NeoPiPSmoke.directory.appendingPathComponent("recording-viewing-settings.png"))
      }
      active?.popToRootViewController(animated:false)
    }
    if let general = timings["general"]?["handlerToFirstMovementMs"], let viewing = timings["viewing"]?["handlerToFirstMovementMs"] {
      checks["viewingOpeningAvoidsLongLayoutWait"] = viewing <= max(250,general*2)
    } else { checks["viewingOpeningAvoidsLongLayoutWait"] = false }
    return (checks,timings)
  }
  func smokeShowFeaturePage(_ page: UIViewController) {
    showRoute("settings"); active?.pushViewController(page,animated:false); view.setNeedsLayout(); view.layoutIfNeeded()
  }
  func smokePopFeaturePage() { active?.popViewController(animated:false); view.layoutIfNeeded() }
  var smokePushAnimationDuration: Double { NeoPagePushAnimator().transitionDuration(using:nil) }
  func runViewingSettingsProbe(base: URL) -> [String:Bool] {
    let keys = ["player.network.seconds","player.comments.size","player.comments.absoluteOpacity","player.comments.enabled","player.comments.waitBeforePlayback","neoepgstation.navigation.labels","watch.subtitleKeywords"]
    let old = keys.map { UserDefaults.standard.object(forKey:$0) }
    defer { for (key,value) in zip(keys,old) { if let value { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }; refreshNavigationLabels() }
    smokeUseAPI(NeoAPI(base:base)); showRoute("settings"); view.layoutIfNeeded()
    func capture(_ name: String) {
      view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds:view.bounds).image { _ in view.drawHierarchy(in:view.bounds,afterScreenUpdates:true) }
      try? image.pngData()?.write(to:NeoPiPSmoke.directory.appendingPathComponent(name+".png"))
    }
    func all(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(all) }
    let root = active!.topViewController!; root.loadViewIfNeeded()
    let cells = (root as? NeoSettingsPage)?.smokeCategoryDescriptionsRemoved ?? false
    var checks = ["settingsSevenCategories":NeoSettingsCategory.allCases.count == 7,"categoryDescriptionsRemoved":cells]
    checks["generalFirstAboutLast"] = NeoSettingsCategory.allCases.first == .general && NeoSettingsCategory.allCases.last == .about && !NeoSettingsCategory.allCases.contains { $0.rawValue == "app" }
    capture("feedback-settings-categories")
    for category in [NeoSettingsCategory.discord] {
      let page = NeoSettingsCategoryPage(category:category,shell:self); page.loadViewIfNeeded()
      checks[category.rawValue+"Empty"] = page.smokeSettingCount == 0
    }
    let annictPage = NeoSettingsCategoryPage(category:.annict,shell:self); annictPage.loadViewIfNeeded()
    checks["annictSettingsPopulated"] = annictPage.smokeSettingCount > 0
    NeoViewingPreferences.subtitleKeywords = ["","",""]
    let viewing = NeoSettingsCategoryPage(category:.viewing,shell:self); active!.pushViewController(viewing,animated:false); view.layoutIfNeeded()
    let views = all(viewing.view)
    let engine = views.contains { $0.accessibilityIdentifier == "playback-experiment-engine" }
    checks["engineInViewing"] = engine
    let network = views.first { $0.accessibilityIdentifier == "viewing-network-cache" } as? UIStepper
    network?.value = 7; network?.sendActions(for:.valueChanged)
    checks["globalNetworkPersists"] = NeoViewingPreferences.networkSeconds == 7
    let overlay = NeoCommentOverlay(frame:.zero)
    func control(_ id: String) -> UIControl? { all(viewing.view).first { $0.accessibilityIdentifier == id } as? UIControl }
    control("viewing-subtitle-add")?.sendActions(for:.touchUpInside)
    control("viewing-subtitle-add")?.sendActions(for:.touchUpInside)
    let fourth = control("viewing-subtitle-priority-3") as? UITextField
    fourth?.text = "Fourth priority"; fourth?.sendActions(for:.editingChanged)
    let fifth = control("viewing-subtitle-priority-4") as? UITextField
    fifth?.text = "Fifth priority"; fifth?.sendActions(for:.editingChanged)
    checks["priorityUIAddsAndSavesBeyondThree"] = NeoViewingPreferences.subtitleKeywords.count == 5 && NeoViewingPreferences.subtitleKeywords[4] == "Fifth priority"
    control("viewing-subtitle-remove-3")?.sendActions(for:.touchUpInside)
    checks["priorityUIRemovesAndRenumbers"] = NeoViewingPreferences.subtitleKeywords.count == 4 && (control("viewing-subtitle-priority-3") as? UITextField)?.text == "Fifth priority" && control("viewing-subtitle-remove-2") == nil
    let visibility = all(viewing.view).compactMap { $0 as? UISwitch }.first { $0.accessibilityLabel == "コメントを表示" }
    visibility?.isOn = false; visibility?.sendActions(for:.valueChanged)
    checks["globalVisibilityReachesPlayer"] = visibility != nil && !overlay.enabled && !NeoViewingPreferences.commentsEnabled
    overlay.enabled = true; viewing.viewWillAppear(false)
    checks["playerVisibilityReachesGlobal"] = NeoViewingPreferences.commentsEnabled && all(viewing.view).compactMap { $0 as? UISwitch }.first { $0.accessibilityLabel == "コメントを表示" }?.isOn == true
    checks["outlinedSelectKeepsNativeMenu"] = all(viewing.view).compactMap { $0 as? NeoSelectButton }.allSatisfy { $0.showsMenuAsPrimaryAction && $0.menu != nil && $0.layer.borderWidth == 1 }
    let size = all(viewing.view).first { $0.accessibilityIdentifier == "viewing-comment-size" } as? UISlider
    size?.value = 1.25; size?.sendActions(for:.valueChanged)
    checks["globalSizeReachesPlayer"] = overlay.sizeMultiplier == 1.25
    let opacity = all(viewing.view).first { $0.accessibilityIdentifier == "viewing-comment-opacity" } as? UISlider
    opacity?.value = 0.65; opacity?.sendActions(for:.valueChanged)
    checks["globalOpacityReachesPlayer"] = abs(overlay.opacity-0.65)<0.001
    let wait = all(viewing.view).compactMap { $0 as? UISwitch }.first { $0.accessibilityLabel == "字幕・コメントの準備を待ってPLAY再生を開始" }
    wait?.isOn = true; wait?.sendActions(for:.valueChanged)
    checks["globalWaitSharesPlayerSetting"] = wait != nil && NeoCommentOverlay.waitBeforePlayback
    capture("feedback-viewing-settings")
    checks["viewingControlsFitViewport"] = viewing.smokeControlsWithinWidth
    let general = NeoSettingsCategoryPage(category:.general,shell:self); general.loadViewIfNeeded()
    checks["engineRemovedFromGeneral"] = !all(general.view).contains { $0.accessibilityIdentifier == "playback-experiment-engine" }
    checks["generalHasAppPreferences"] = all(general.view).compactMap { $0 as? UIButton }.contains { $0.title(for:.normal) == "接続先を変更" } && all(general.view).contains { $0.accessibilityLabel == "下部ナビゲーションのラベルを表示" }
    let about = NeoSettingsCategoryPage(category:.about,shell:self); active!.pushViewController(about,animated:false); view.layoutIfNeeded()
    let aboutLabels = all(about.view).compactMap { ($0 as? UILabel)?.text }
    checks["aboutUsesInstalledVersionAndBuild"] = aboutLabels.contains("バージョン：\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")") && aboutLabels.contains("ビルド番号：\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—")") && !aboutLabels.contains { $0.lowercased().contains("ios") }
    checks["licensesBundledAndReadable"] = !NeoLicensePage.documents.isEmpty && NeoLicensePage.documents.allSatisfy { (try? String(contentsOf:$0,encoding:.utf8).isEmpty) == false }
    capture("feedback-about")
    NeoViewingPreferences.navigationLabels = false; refreshNavigationLabels(); bottom.layoutIfNeeded(); bottomButtons.forEach { $0.layoutIfNeeded() }
    checks["labelsOffCentersIcons"] = bottomButtons.allSatisfy { ($0 as? NeoNavigationButton).map { $0.caption.isHidden && abs($0.icon.frame.midY-$0.bounds.midY)<0.5 } ?? false }
    NeoViewingPreferences.navigationLabels = true; refreshNavigationLabels()
    checks["labelsRestored"] = bottomButtons.allSatisfy { ($0 as? NeoNavigationButton)?.caption.isHidden == false }
    setMenu(true,animated:false); setMenu(false,animated:true)
    checks["closingBackdropDoesNotBlockNewPage"] = !menuOpen && (tablet ? dim.isHidden : !dim.isUserInteractionEnabled)
    overlay.stop()
    return checks
  }
  private var backSmokeDetails: [String: Any] = [:]
  func runCheckpointAnalysisProbe(base: URL, scenario: String) {
    let oldEngine = NeoPlaybackExperiment.selected, oldMode = NeoPlaybackExperiment.checkpointMode
    NeoPlaybackExperiment.selected = .checkpointPlayer; NeoPlaybackExperiment.checkpointMode = .automatic
    let api = NeoAPI(base: base); smokeUseAPI(api)
    let payload = #"{"id":1,"name":"Synthetic analysis","startAt":0,"endAt":120000,"isRecording":false,"videoFiles":[{"id":17,"name":"AV1","type":"encoded","size":1024}]}"#
    let item = try! JSONDecoder().decode(NeoRecording.self, from: Data(payload.utf8))
    let page = NeoDetailPage(item: item, shell: self)
    let nav = UINavigationController(rootViewController: page); nav.setNavigationBarHidden(true, animated: false); nav.delegate = self
    route = "recorded"; controllers[route] = nav; attach(nav)
    Task { [weak self] in
      guard let self else { return }
      defer { NeoPlaybackExperiment.selected = oldEngine; NeoPlaybackExperiment.checkpointMode = oldMode; checkpointAnalysisProbe = nil }
      try? await Task.sleep(for: .milliseconds(700))
      var choice: NeoCheckpointDecision?, prepared = false, sawWaiting = false
      checkpointAnalysisProbe = { choice = $0 }
      play(item.videoFiles![0], recording: item, fromBeginning: true) { prepared = true }
      let deadline = ProcessInfo.processInfo.systemUptime+18
      while !prepared && ProcessInfo.processInfo.systemUptime < deadline {
        if let alert = page.presentedViewController as? UIAlertController, alert.title == "解析中" {
          sawWaiting = true
          if scenario == "cancel", !alert.isBeingPresented { playPreparationTask?.cancel() }
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      try? await Task.sleep(for: .milliseconds(500))
      var checks: [String: Bool] = ["finished": prepared && !preparingPlay, "noPlayerBeforeChoice": player == nil,
        "waitingDialogDismissed": page.presentedViewController == nil]
      if scenario == "cancel" {
        checks["cancelledWithoutChoice"] = choice == nil && sawWaiting
      } else {
        checks["currentVersionAccepted"] = choice?.analysisVersion == 2 && choice?.analysisCurrentVersion == 2 && choice?.analysisStale == false
        checks["correctRoute"] = choice?.enabled == (scenario == "stale")
        checks["completionWaited"] = scenario == "stale" ? sawWaiting && (choice?.analysisRequests ?? 0) >= 2 && (choice?.analysisWaitMs ?? 0) >= 2500 : !sawWaiting
      }
      NeoPiPSmoke.save("checkpoint-analysis-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks,
        "scenario": scenario, "reason": choice?.reason ?? "cancelled", "requests": choice?.analysisRequests ?? 0])
    }
  }
  static func reflowSmoke(in host: UIView) -> [String: Bool] {
    let drawer = NeoSidebar(frame: CGRect(x: 0, y: 0, width: 300, height: 650)); host.addSubview(drawer)
    var aligned = true
    for inset: CGFloat in [0, 59, 0, 59, 0] {
      drawer.contentSafeArea = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
      drawer.setNeedsLayout(); drawer.layoutIfNeeded(); drawer.list.layoutIfNeeded()
      for row in [0, 5, 11, 0] {
        drawer.list.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false); drawer.list.layoutIfNeeded()
        for case let cell as NeoSidebarCell in drawer.list.visibleCells {
          cell.layoutIfNeeded()
          aligned = aligned && cell.icon.frame.minX == inset+16 && cell.caption.frame.minX == inset+56
        }
      }
    }
    drawer.removeFromSuperview()
    let buttons = ["recorded", "onair", "guide", "history", "settings"].compactMap { id in NeoDestination.all.first { $0.id == id } }.map(NeoNavigationButton.init)
    var centered = true
    for width: CGFloat in [390, 844, 390, 1194, 834, 390] {
      for (i, button) in buttons.enumerated() {
        button.frame = CGRect(x: CGFloat(i)*width/5, y: 0, width: width/5, height: 56)
        button.setNeedsLayout(); button.layoutIfNeeded()
        centered = centered && abs(button.icon.frame.midX-button.bounds.midX) < 0.1 && abs(button.caption.frame.midX-button.bounds.midX) < 0.1
      }
    }
    return ["sidebarSafeAreaAndReusedRowsAligned": aligned, "bottomIconsAndTitlesStayCentered": centered,
      "recordedVisibleCellsFollowWidth": NeoRecordedPage.reflowSmoke(in: host),
      "detailBackCompletesFaster": NeoSwipeBackAnimator().transitionDuration(using: nil) == 0.22]
  }
  private func runUISmoke() {
    let recorded = controllers["recorded"]!.viewControllers.first as! NeoRecordedPage
    let original = recorded.collection
    showRoute("settings"); showRoute("recorded")
    let retained = original === recorded.collection
    if smokeStage == "recording-features" {
      Task { [self] in
        let checks = await NeoRecordingFeaturesSmoke.run(shell:self)
        writeIPadSmoke(recorded,checks:checks,retained:retained)
      }
      return
    }
    if smokeStage == "navigation" {
      Task { [self] in
        let checks = await runNavigationTimingSmoke()
        writeIPadSmoke(recorded,checks:checks,retained:retained)
      }
      return
    }
    if smokeStage == "ipad-connection" {
      showConnection(); view.layoutIfNeeded()
      let original = view.bounds
      let layouts = [CGSize(width: 1024, height: 1366), CGSize(width: 1366, height: 1024)].map { size -> Bool in
        view.bounds.size = size; view.setNeedsLayout(); view.layoutIfNeeded()
        return content.frame.minX == 0 && content.frame.width == size.width && sidebar.isHidden && bottom.isHidden
      }
      view.bounds = original; view.setNeedsLayout(); view.layoutIfNeeded()
      writeIPadSmoke(recorded, checks: ["connectionHasNoSidebarReservation": layouts.allSatisfy { $0 }], retained: retained)
      return
    }
    if smokeStage == "ipad-menu" {
      Task { [self] in
        toggleMenu(); try? await Task.sleep(nanoseconds: 90_000_000)
        let x = content.layer.presentation()?.frame.minX ?? 0
        let animated = x > 0 && x < sidebarWidth
        try? await Task.sleep(nanoseconds: 200_000_000)
        let closed = content.frame.minX == 0 && !tabletExpanded
        let action = NeoNavigationGesture.action(startY: 10, height: Double(view.bounds.height), canGoBack: false, tablet: tablet && tabletExpanded, horizontal: 100, vertical: 0)
        updateMenu(state: .began, translation: 0, velocity: 100)
        updateMenu(state: .changed, translation: sidebarWidth/2, velocity: 100)
        let followed = abs(content.frame.minX-sidebarWidth/2) < 1
        updateMenu(state: .ended, translation: sidebarWidth, velocity: 400)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let reopened = tabletExpanded && content.frame.minX == sidebarWidth
        updateMenu(state: .began, translation: 0, velocity: -100)
        updateMenu(state: .changed, translation: -sidebarWidth, velocity: -100)
        updateMenu(state: .ended, translation: -sidebarWidth, velocity: -400)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let swipeClosed = !tabletExpanded && content.frame.minX == 0
        let back = NeoNavigationGesture.action(startY: Double(view.bounds.height)*0.8, height: Double(view.bounds.height), canGoBack: true, tablet: false, horizontal: 100, vertical: 0) == .back
        setTabletMenu(true, animated: false); view.layoutIfNeeded()
        let historyReturn = await runHistoryReturnChecks(recorded)
        let noScroll = !sidebar.list.isScrollEnabled && !sidebar.list.bounces
        let below30 = NeoNavigationGesture.action(startY: Double(view.bounds.height)*0.31, height: Double(view.bounds.height), canGoBack: true, tablet: true, horizontal: 100, vertical: 0, persistentMenu: true) == .back
        writeIPadSmoke(recorded, checks: ["tabletMenuDoesNotScroll": noScroll, "tabletBackBoundaryThirtyPercent": below30,
          "tabletSidebarEdgeBack": historyReturn, "historyListReturnsToOrigin": historyReturn, "tabletMenuAnimates": animated, "tabletMenuClosesWithoutGap": closed,
          "collapsedTabletMenuSwipeRecognized": action == .menu, "tabletMenuFollowsFinger": followed,
          "tabletMenuSwipeReopens": reopened, "tabletMenuSwipeCloses": swipeClosed,
          "tabletBackRegionPreserved": back, "userSelectorMatchesHeader": recorded.smokeSelectorAligned], retained: retained)
      }
      return
    }
    if smokeStage == "ipad-player" {
      let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("player-tap.ts")
      let player = NeoPlayerController(url: file, title: "Synthetic iPad rotation", username: "", password: "", networkCaching: 100)
      player.recordingContext = ["id": 1, "disableHistory": true]; player.modalPresentationStyle = .fullScreen
      present(player, animated: false) { [weak self] in
        DispatchQueue.main.asyncAfter(deadline: .now()+3) {
          player.runIPadOrientationSmoke { result in
            guard let self else { return }
            if let file = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: file) {
              try? data.write(to: file.deletingLastPathComponent().appendingPathComponent("ipad-orientation-diagnostics.json"))
            }
            NeoNative.writeSmoke("ui-ipad-player-smoke", result.merging(["stage": self.smokeStage, "route": self.route,
              "recordCount": recorded.records.count, "theme": "neon-teal-dark", "uiEngine": "Swift / UIKit", "retainedList": retained, "sidebarWidth": 240]) { old, _ in old })
          }
        }
      }
      return
    }
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
          Task { [self] in
            let navigationButtons = await self.runNavigationButtonChecks(recorded)
            let listFeatures = await recorded.smokeListFeatures()
            let historyReturn = await self.runHistoryReturnChecks(recorded)
            let gap = self.sidebar.logo.frame.minX - self.sidebar.brand.frame.maxX
            NeoNative.writeSmoke("ui-gestures-smoke", ["success": correct && navigationButtons && listFeatures && historyReturn && self.startupDrawerWasStill && drawerClosed && popupCycles && gap == 7 && thumbnails && freshFade == 0.5 && cachedFade == 0.32,
              "stage": "gestures", "route": self.route, "recordCount": recorded.records.count,
              "theme": "neon-teal-dark", "uiEngine": "Swift / UIKit", "retainedList": retained,
              "shortcuts": self.shortcuts, "brandGap": gap, "interactiveBack": correct, "thumbnailLoading": thumbnails,
              "freshFade": freshFade, "cachedFade": cachedFade, "backDetails": self.backSmokeDetails,
              "drawerClosedByLeftSwipe": drawerClosed, "popupCycles": popupCycles,
              "startupDrawerDoesNotAnimate": self.startupDrawerWasStill, "navigationButtonReturnsThenResets": navigationButtons, "recordedFiltersAndHighlight": listFeatures, "historyListReturnsToOrigin": historyReturn])
          }
        }
      }
      return
    }
    if smokeStage == "menu" { setMenu(true, animated: false) }
    if smokeStage == "settings" { showRoute("settings") }
    if smokeStage == "history" { showRoute("history") }
    if ["settings-viewing", "settings-account", "settings-display"].contains(smokeStage) {
      showRoute("settings")
      active?.pushViewController(NeoSettingsCategoryPage(category: smokeStage == "settings-viewing" ? .viewing : smokeStage == "settings-display" ? .display : .account, shell: self), animated: false)
    }
    if ["detail", "detail-actions", "play-popup", "drop-dialog"].contains(smokeStage) { openDetail(NeoRecordedPage.fixtures.records[0]) }
    if smokeStage == "pagination" { recorded.smokePageSeven() }
    if smokeStage == "recorded-search" { recorded.smokeOpenSearch() }
    view.layoutIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      let cardHeight = recorded.cardHeight
      let pages = recorded.renderedPages
      var popupCorrect = true
      if self.smokeStage == "recorded-search" {
        popupCorrect = ((recorded.presentedViewController as? UINavigationController)?.topViewController as? NeoRecordedSearch)?.smokeValid == true
      }
      if let settings = self.active?.topViewController as? NeoSettingsPage {
        popupCorrect = settings.smokeHistoryPreferences()
      }
      if self.smokeStage == "settings-account" { popupCorrect = (self.active?.topViewController as? NeoSettingsCategoryPage)?.smokeAccountSelector == true }
      if self.smokeStage == "history" { popupCorrect = (self.active?.topViewController as? NeoHistoryPage)?.smokeReady == true }
      if self.smokeStage.hasPrefix("settings-") {
        popupCorrect = popupCorrect && self.active?.viewControllers.count == 2 && self.active?.topViewController is NeoSettingsCategoryPage
      }
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
      let correct = popupCorrect && retained && recorded.smokeSelectorAligned && (self.tablet || cardHeight == 108) && self.controllers["recorded"]?.viewControllers.first === recorded
        && (self.smokeStage != "pagination" || pages == ["5", "6", "7", "8", "9"])
      NeoNative.writeSmoke("ui-\(self.smokeStage)-smoke", ["success": correct, "stage": self.smokeStage,
        "route": self.route, "recordCount": recorded.records.count, "theme": "neon-teal-dark", "sidebarWidth": self.tablet ? 240 : 0,
        "uiEngine": "Swift / UIKit", "retainedList": retained, "cardHeight": cardHeight,
        "pagination": pages, "shortcuts": self.shortcuts, "popupTitles": self.popup?.titles ?? [], "dropSummary": dropText,
        "detailButtons": (self.active?.topViewController as? NeoDetailPage)?.smokeButtonTitles ?? [],
        "dropDialogVisible": (self.active?.topViewController as? NeoDetailPage)?.smokeDropDialogVisible ?? false])
    }
  }
  private func writeIPadSmoke(_ recorded: NeoRecordedPage, checks: [String: Bool], retained: Bool) {
    NeoNative.writeSmoke("ui-\(smokeStage)-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks,
      "stage": smokeStage, "route": route, "recordCount": recorded.records.count, "theme": "neon-teal-dark",
      "uiEngine": "Swift / UIKit", "retainedList": retained, "sidebarWidth": api == nil ? 0 : 240])
  }
  private func runNavigationTimingSmoke() async -> [String:Bool] {
    var checks = [String:Bool]()
    func settle() async {
      for _ in 0..<150 {
        if active?.transitionCoordinator == nil && popInteraction == nil && pendingBack == nil { return }
        try? await Task.sleep(nanoseconds:20_000_000)
      }
    }
    func classify() -> Bool {
      swipeStart = CGPoint(x:tablet ? 8 : 100,y:view.bounds.height*0.7)
      return beginNavigationSwipe(tablet ? sidebarBackPan : contentPan,velocity:CGPoint(x:500,y:0)) && swipeAction == .back
    }
    for (routeName,delay) in [("settings",30_000_000),("detail",30_000_000),("settings",70_000_000),("detail",70_000_000)] {
      let name = routeName+(delay == 30_000_000 ? "Early" : "Mid")
      showRoute(routeName == "settings" ? "settings" : "recorded"); view.layoutIfNeeded(); await settle()
      guard let nav = active else { checks[name+"NavigationExists"] = false; continue }
      nav.popToRootViewController(animated:false)
      let page: UIViewController = routeName == "settings" ? NeoSettingsCategoryPage(category:.general,shell:self) : NeoDetailPage(item:NeoRecordedPage.fixtures.records[0],shell:self)
      let pushBegan = CACurrentMediaTime()
      nav.pushViewController(page,animated:true)
      try? await Task.sleep(nanoseconds:UInt64(delay))
      checks[name+"PushActuallyInProgress"] = nav.transitionCoordinator != nil && canDeferBackUntilPushCompletes
      checks[name+"EarlySwipeAccepted"] = classify()
      let hit = view.hitTest(swipeStart,with:nil)
      checks[name+"EarlySwipeSurfaceReceivesTouches"] = hit != nil && (hit === (tablet ? sidebar : content) || hit!.isDescendant(of:tablet ? sidebar : content))
      updateBack(state:.began,translation:0,velocity:500)
      let initial = pendingBack?.initialProgress ?? backInitialProgress
      checks[name+"CapturesVisiblePushPosition"] = initial > 0 && initial < 1
      updateBack(state:.changed,translation:content.bounds.width*0.1,velocity:100)
      for _ in 0..<20 {
        if popInteraction != nil && pendingBack == nil { break }
        try? await Task.sleep(nanoseconds:5_000_000)
      }
      checks[name+"TakesOverBeforeOriginalPushEnds"] = popInteraction != nil && pendingBack == nil && pushingNavigation == nil && CACurrentMediaTime()-pushBegan < 0.14
      try? await Task.sleep(nanoseconds:40_000_000)
      let expected = min(1,initial+0.1)
      let painted = (page.view.layer.presentation()?.affineTransform().tx ?? page.view.transform.tx)/max(1,content.bounds.width)
      checks[name+"PixelsFollowCapturedPositionAndFinger"] = abs(painted-expected)<0.05 && abs((popInteraction?.percentComplete ?? -1)-expected)<0.01
      updateBack(state:.changed,translation:content.bounds.width*0.15,velocity:100)
      try? await Task.sleep(nanoseconds:40_000_000)
      let paintedAgain = (page.view.layer.presentation()?.affineTransform().tx ?? page.view.transform.tx)/max(1,content.bounds.width)
      checks[name+"ContinuesFollowingFinger"] = abs(paintedAgain-min(1,initial+0.15))<0.05
      updateBack(state:.ended,translation:content.bounds.width*0.5,velocity:500)
      await settle()
      checks[name+"FirstSwipeReturnsToRoot"] = nav.viewControllers.count == 1 && pendingBack == nil && popInteraction == nil
    }
    showRoute("settings"); view.layoutIfNeeded(); await settle()
    guard let nav = active else { return checks }
    for cancel in [true,false] {
      let page = NeoSettingsCategoryPage(category:.general,shell:self)
      nav.pushViewController(page,animated:true)
      try? await Task.sleep(nanoseconds:50_000_000)
      checks[cancel ? "CancelledEarlySwipeAccepted" : "ShortEarlySwipeAccepted"] = classify()
      updateBack(state:.began,translation:0,velocity:100)
      updateBack(state:cancel ? .cancelled : .ended,translation:10,velocity:0)
      await settle()
      checks[cancel ? "CancelledSwipeNeverReplayed" : "ShortSwipeNeverReplayed"] = nav.topViewController === page && pendingBack == nil
      checks[cancel ? "CancelledSwipeRestoresFullPage" : "ShortSwipeRestoresFullPage"] = page.view.transform == .identity
      checks[cancel ? "NextSwipeReadyAfterCancellation" : "NextSwipeReadyAfterShortDrag"] = classify()
      updateBack(state:.began,translation:0,velocity:500)
      updateBack(state:.changed,translation:content.bounds.width*0.5,velocity:500)
      updateBack(state:.ended,translation:content.bounds.width*0.5,velocity:500)
      checks[cancel ? "OverlappingPopRejectedAfterCancellation" : "OverlappingPopRejectedAfterShortDrag"] = !classify()
      await settle()
      checks[cancel ? "NextSwipeReturnsAfterCancellation" : "NextSwipeReturnsAfterShortDrag"] = nav.viewControllers.count == 1
    }
    showRoute("recorded"); goBack()
    checks["RootDoesNotReturnAcrossTabs"] = route == "recorded" && active?.viewControllers.count == 1
    if let nav = active {
      let page = NeoDetailPage(item:NeoRecordedPage.fixtures.records[0],shell:self)
      nav.pushViewController(page,animated:true)
      try? await Task.sleep(nanoseconds:50_000_000)
      checks["UninterruptedPushStillAnimates"] = canDeferBackUntilPushCompletes
      await settle(); goBack(); await settle()
      checks["UninterruptedPushAndButtonBackSettle"] = nav.viewControllers.count == 1 && page.view.transform == .identity
    }
    return checks
  }
  private func runHistoryReturnChecks(_ recorded: NeoRecordedPage) async -> Bool {
    func settle() async {
      try? await Task.sleep(nanoseconds: 100_000_000)
      for _ in 0..<100 {
        if active?.transitionCoordinator == nil && popInteraction == nil && !routeBackRunning { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
    }
    await settle()
    showRoute("history"); view.layoutIfNeeded(); await settle()
    let history = active
    let position = NeoListPosition(page: 7, userId: nil)
    locateRecording(1, position: position); view.layoutIfNeeded(); await settle()
    for _ in 0..<100 {
      if recorded.smokeLoadSettled && recorded.smokeCurrentPage == 7 { break }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let pageReady = recorded.smokeLoadSettled && recorded.smokeCurrentPage == 7
    let target = canReturnToHistory && canGoBack && recorded.smokeCurrentPage == 7
    updateBack(state: .began, translation: 0, velocity: 100)
    updateBack(state: .changed, translation: content.bounds.width*0.2, velocity: 100)
    let followed = abs((active?.view.transform.tx ?? 0)-content.bounds.width*0.2) < 1
    updateBack(state: .cancelled, translation: 0, velocity: 0); await settle()
    let transform = active?.view.transform ?? .identity
    let restored = abs(transform.tx) < 1 && abs(transform.ty) < 1 && abs(transform.a-1) < 0.000001
      && abs(transform.d-1) < 0.000001 && abs(transform.b) < 0.000001 && abs(transform.c) < 0.000001
    let cancelled = canReturnToHistory && !routeBackRunning && route == "recorded" && restored
    backSmokeDetails["historyCancelState"] = ["target": canReturnToHistory, "running": routeBackRunning, "route": route,
      "x": transform.tx, "y": transform.ty, "a": transform.a, "d": transform.d, "b": transform.b, "c": transform.c]
    openDetail(NeoRecordedPage.fixtures.records[0]); await settle(); goBack(); await settle()
    let detailFirst = canReturnToHistory && route == "recorded" && active?.topViewController === recorded
    if tablet {
      // Same edge and height classification used by the sidebar recognizer.
      let edge = acceptsSidebarBack(start: CGPoint(x: 8, y: view.bounds.height*0.31))
      let center = acceptsSidebarBack(start: CGPoint(x: sidebarWidth/2, y: view.bounds.height*0.31))
      guard edge && !center else { return false }
    }
    updateBack(state: .began, translation: 0, velocity: 100)
    updateBack(state: .changed, translation: content.bounds.width*0.5, velocity: 100)
    updateBack(state: .ended, translation: content.bounds.width*0.5, velocity: 500); await settle()
    let returned = route == "history" && active === history && !canReturnToHistory
    locateRecording(1, position: position); await settle(); goBack(); await settle()
    let button = route == "history" && active === history
    locateRecording(1, position: position); await settle(); selectDestination("recorded")
    let cleared = !canReturnToHistory
    showRoute("settings"); goBack(); let isolated = route == "settings"
    showRoute("recorded"); view.layoutIfNeeded()
    backSmokeDetails["historyReturn"] = ["pageReady": pageReady, "target": target, "finger": followed,
      "cancel": cancelled, "detailFirst": detailFirst, "swipe": returned, "button": button, "clear": cleared, "isolate": isolated]
    return pageReady && target && followed && cancelled && detailFirst && returned && button && cleared && isolated
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
  private func runNavigationButtonChecks(_ recorded: NeoRecordedPage) async -> Bool {
    func waitForPage(_ list: NeoRecordedPage, _ page: Int) async -> Bool {
      for _ in 0..<60 {
        if list.smokeLoadSettled && list.smokeCurrentPage == page { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      backSmokeDetails["pageWaitFailure"] = ["expected": page, "actual": list.smokeCurrentPage,
        "requested": list.smokeRequestedPage, "settled": list.smokeLoadSettled,
        "root": list === recorded, "stack": active?.viewControllers.count ?? 0]
      return false
    }
    func settledNavigation() async {
      for _ in 0..<60 {
        if active?.transitionCoordinator == nil { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    await settledNavigation()
    guard await waitForPage(recorded, recorded.smokeRequestedPage) else { return false }
    recorded.smokePageSeven()
    guard await waitForPage(recorded, 7) else { return false }
    let oldInset = recorded.collection.contentInset
    recorded.collection.contentInset.bottom = 1000
    defer { recorded.collection.contentInset = oldInset }
    recorded.collection.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
    let offset = recorded.collection.contentOffset
    openDetail(NeoRecordedPage.fixtures.records[0])
    await settledNavigation()
    selectDestination("recorded")
    await settledNavigation()
    let returned = active?.topViewController === recorded && recorded.smokeCurrentPage == 7 && recorded.collection.contentOffset == offset
    selectDestination("recorded")
    guard await waitForPage(recorded, 1) else { return false }
    let reset = active?.topViewController === recorded && recorded.collection.contentOffset.y == 0
    recorded.smokePageSeven()
    guard await waitForPage(recorded, 7) else { return false }
    showRoute("settings"); selectDestination("recorded")
    let acrossTabs = active?.topViewController === recorded && recorded.smokeCurrentPage == 7
    recorded.collection.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
    let searchOffset = recorded.collection.contentOffset
    // A detail opened from a search must return to that same filtered list.
    let search = NeoRecordedPage(shell: self, keyword: "サンプル")
    active?.pushViewController(search, animated: false); view.layoutIfNeeded()
    await settledNavigation()
    guard await waitForPage(search, 1) else { return false }
    search.smokePageSeven()
    guard await waitForPage(search, 7) else { return false }
    openDetail(NeoRecordedPage.fixtures.records[0])
    await settledNavigation()
    selectDestination("recorded")
    await settledNavigation()
    let searchReturned = active?.topViewController === search && search.smokeCurrentPage == 7
    selectDestination("recorded")
    await settledNavigation()
    let searchReturnsOriginal = active?.topViewController === recorded && recorded.smokeCurrentPage == 7 && recorded.collection.contentOffset == searchOffset
    selectDestination("recorded")
    let searchReset = await waitForPage(recorded, 1)
    recorded.smokePageSeven()
    guard await waitForPage(recorded, 7) else { return false }
    let directSearch = NeoRecordedPage(shell: self, keyword: "サンプル")
    active?.pushViewController(directSearch, animated: false); view.layoutIfNeeded()
    await settledNavigation()
    guard await waitForPage(directSearch, 1) else { return false }
    selectDestination("recorded")
    await settledNavigation()
    let directReturn = active?.topViewController === recorded && recorded.smokeCurrentPage == 7
    selectDestination("recorded")
    let directReset = await waitForPage(recorded, 1)
    backSmokeDetails["navigationReturnsListPageAndOffset"] = returned
    backSmokeDetails["navigationSecondTapResetsPage"] = reset
    backSmokeDetails["navigationAcrossTabsPreservesPage"] = acrossTabs
    backSmokeDetails["navigationPreservesSearchList"] = searchReturned && searchReturnsOriginal && searchReset
    backSmokeDetails["searchReturnsOriginalPage"] = searchReturnsOriginal
    backSmokeDetails["searchWithoutDetailReturnsOriginalThenFirstPage"] = directReturn && directReset
    active?.popToRootViewController(animated: false); recorded.returnToFirstPage()
    _ = await waitForPage(recorded, 1)
    return returned && reset && acrossTabs && searchReturned && searchReturnsOriginal && searchReset && directReturn && directReset
  }
#endif
}
