import UIKit

// UserSelector's MUI small outlined field: 160 x 40, label 16 * .75,
// dark outline white .23, text white and a 24pt ArrowDropDown.
private final class NeoRecordedUserSelector: UIButton {
  private let caption = NeoStyle.label("ユーザー", size: 12, muted: true)
  private let value = NeoStyle.label(size: 16), arrow = UIImageView()
  private let outline = CAShapeLayer()
  override init(frame: CGRect) {
    super.init(frame: frame)
    outline.fillColor = UIColor.clear.cgColor; outline.strokeColor = UIColor.white.withAlphaComponent(0.23).cgColor; outline.lineWidth = 1
    layer.addSublayer(outline)
    caption.backgroundColor = NeoStyle.paper
    arrow.image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
      UIColor.white.setFill(); let path = UIBezierPath(); path.move(to: CGPoint(x: 7, y: 10))
      path.addLine(to: CGPoint(x: 12, y: 15)); path.addLine(to: CGPoint(x: 17, y: 10)); path.close(); path.fill()
    }
    [caption, value, arrow].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
    accessibilityLabel = "ユーザー"; accessibilityTraits = .button
  }
  required init?(coder: NSCoder) { fatalError() }
  func setValue(_ text: String) { value.text = text; accessibilityValue = text }
  override func layoutSubviews() {
    super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true)
    outline.frame = bounds; outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4).cgPath
    CATransaction.commit()
    caption.frame = CGRect(x: 12, y: -7, width: 52, height: 14)
    value.frame = CGRect(x: 14, y: 0, width: max(0, bounds.width - 46), height: bounds.height)
    arrow.frame = CGRect(x: bounds.width - 31, y: (bounds.height - 24) / 2, width: 24, height: 24)
  }
}

final class NeoRecordedCard: UICollectionViewCell {
  let thumbnail = NeoThumbnail(), title = NeoStyle.label(size: 14, bold: true)
  let channel = NeoStyle.label(size: 12, muted: true), time = NeoStyle.label(size: 12, muted: true)
  let descriptionLabel = NeoStyle.label(size: 12)
  var mobile = true
  func setFocused(_ focused: Bool) {
    // MUI dark warning.main orange[400], action.hover white at 0.08.
    contentView.layer.borderWidth = focused ? 2 : 0
    contentView.layer.borderColor = UIColor(red: 255/255, green: 167/255, blue: 38/255, alpha: 1).cgColor
    contentView.backgroundColor = focused ? UIColor.white.withAlphaComponent(0.08) : NeoStyle.paper
    if focused { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
  }
  var onMore: ((UIView) -> Void)?
  private lazy var more: UIButton = NeoStyle.iconButton("MoreVert", label: "録画メニュー") { [weak self] in
    guard let self else { return }; self.onMore?(self.more)
  }
  override init(frame: CGRect) {
    super.init(frame: frame); contentView.backgroundColor = NeoStyle.paper; contentView.layer.cornerRadius = 6
    contentView.clipsToBounds = true
    [thumbnail, title, channel, time, descriptionLabel, more].forEach(contentView.addSubview)
    more.imageView?.transform = CGAffineTransform(scaleX: 20/24, y: 20/24)
    accessibilityIdentifier = "recorded-card"
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews(); let width = contentView.bounds.width
    let imageWidth = mobile ? min(190, width * 0.32) : width
    let imageHeight = mobile ? contentView.bounds.height : width * 9 / 16
    thumbnail.frame = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
    let x = mobile ? imageWidth + 8 : 8, y = mobile ? (contentView.bounds.height - 90) / 2 : imageHeight + 8
    let bodyWidth = width - x - 8
    title.frame = CGRect(x: x, y: y + 5, width: max(0, bodyWidth - 32), height: 20)
    more.frame = CGRect(x: width - 38, y: y, width: 30, height: 30)
    channel.frame = CGRect(x: x, y: y + 30, width: bodyWidth, height: 20)
    time.frame = CGRect(x: x, y: y + 50, width: bodyWidth, height: 20)
    descriptionLabel.frame = CGRect(x: x, y: y + 70, width: bodyWidth, height: 20)
  }
  override func prepareForReuse() { super.prepareForReuse(); thumbnail.load(nil); onMore = nil; setFocused(false) }
  func configure(_ item: NeoRecording, channelName: String, api: NeoAPI?, mobile: Bool, fadeThumbnail: Bool) {
    self.mobile = mobile; title.text = item.name; channel.text = channelName
    time.text = NeoProgramText.interval(start: item.startAt, end: item.endAt)
    descriptionLabel.text = item.description?.replacingOccurrences(of: "\n", with: " ")
    thumbnail.load(item.thumbnails?.first.flatMap { api?.url("/thumbnails/\($0)") }, fadeIn: fadeThumbnail)
    accessibilityLabel = "\(item.name)、\(channelName)、\(time.text ?? "")"
    setNeedsLayout()
  }
}

final class NeoPaginationFooter: UICollectionReusableView {
  var onPage: ((Int) -> Void)?
  private var page = 1, count = 1, mobile = true
  private var lastWidth: CGFloat = -1
  func configure(page: Int, count: Int, mobile: Bool, action: @escaping (Int) -> Void) {
    self.page = page; self.count = count; self.mobile = mobile; onPage = action; lastWidth = -1; setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews(); guard lastWidth != bounds.width else { return }; lastWidth = bounds.width
    subviews.forEach { $0.removeFromSuperview() }; guard count > 1 else { return }
    let values: [Int?] = mobile ? NeoPagination.mobile(page: page, count: count).map { Optional($0) } : NeoPagination.desktop(page: page, count: count, width: Double(bounds.width))
    let small = bounds.width < 600
    let side: CGFloat = small ? 36 : 40, gap: CGFloat = small ? 6 : 8, arrowGap: CGFloat = small ? 4 : 8
    let ellipsisWidth: CGFloat = small ? 28 : 32
    let total = values.reduce(side * 2) { $0 + ($1 == nil ? ellipsisWidth : side) } + CGFloat(values.count + 1) * gap + arrowGap * 2
    var x = (bounds.width - total) / 2
    func add(_ value: Int?, icon: String? = nil, enabled: Bool = true) {
      if value == nil && icon == nil {
        let label = NeoStyle.label("…", size: 17.6); label.textAlignment = .center
        label.frame = CGRect(x: x, y: 16, width: ellipsisWidth, height: side); addSubview(label); x += ellipsisWidth + gap; return
      }
      let button = UIButton(type: .system)
      if let icon { button.setImage(NeoIcon.image(icon), for: .normal) }
      else { button.setTitle(value.map(String.init) ?? "…", for: .normal) }
      button.frame = CGRect(x: x, y: 16, width: side, height: side); x += side + gap
      button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
      let selected = icon == nil && value == page
      button.backgroundColor = selected ? NeoStyle.accent : NeoStyle.paper
      button.tintColor = selected ? .black : enabled ? .white : .white.withAlphaComponent(0.3)
      button.isEnabled = enabled && value != nil; button.layer.cornerRadius = 6
      button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.25
      button.layer.shadowOffset = CGSize(width: 0, height: 2); button.layer.shadowRadius = 2
      button.accessibilityLabel = icon == "ChevronLeft" ? "前のページ" : icon == "ChevronRight" ? "次のページ" : "\(value ?? 0)ページ"
      if selected { button.accessibilityTraits.insert(.selected) }
      if let value { button.addAction(UIAction { [weak self] _ in self?.onPage?(value) }, for: .touchUpInside) }
      addSubview(button)
    }
    add(page - 1, icon: "ChevronLeft", enabled: page > 1); x += arrowGap
    values.forEach { add($0, enabled: $0 != nil) }; x += arrowGap
    add(page + 1, icon: "ChevronRight", enabled: page < count)
    accessibilityIdentifier = "recorded-pagination"
  }
}

final class NeoRecordedPage: NeoPage, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  let collection: UICollectionView
  private(set) var records: [NeoRecording] = []
  private var total = 0, page = 1, reverse = false
  private var filters = NeoRecordedFilters()
  private var keyword: String { filters.keyword }
  private var pageLength = 24
  private var requestedPage = 1
  private var task: Task<Void, Never>?
  private var cache: [NeoRecordingQuery: (result: NeoRecords, stored: Date)] = [:]
  private var cacheOrder: [NeoRecordingQuery] = []
  private var lateThumbnails: Set<URL> = []
  private var locatedUserID: Int?, focusedRecordingID: Int?
  private var userFilterExplicit = false, users: [NeoViewer] = []
  private let userButton = NeoRecordedUserSelector()
  private var usersTask: Task<Void, Never>?, observers: [NSObjectProtocol] = []
  private var returnRecordingID: Int?, returnOffset: CGPoint?, highlightID: Int?, highlightGeneration = 0
  private(set) var lastFadeDuration: TimeInterval = 0
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let message = NeoStyle.label(size: 14, muted: true)
  private let refresh = UIRefreshControl()
  // Card xs/sm changes at 600; pagination uses a separate 500px query in Web.
  var mobile: Bool { collection.bounds.width < 600 }
  var cardHeight: CGFloat { mobile ? 108 : floor(itemWidth * 9 / 16) + 106 }
  private var itemWidth: CGFloat {
    let width = max(0, collection.bounds.width - 8)
    if mobile { return width }
    let columns = max(1, Int((width + 8) / 288))
    return min(300, floor((width - CGFloat(columns - 1) * 8) / CGFloat(columns)))
  }
  init(shell: NeoShell, keyword: String = "", reverse: Bool = false) {
    let layout = UICollectionViewFlowLayout(); collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    self.filters.keyword = keyword; self.reverse = reverse
    self.locatedUserID = shell.api.flatMap { Int($0.viewer) }.flatMap { $0 > 0 ? $0 : nil }
    pageLength = shell.api?.recordedLength ?? 24
    super.init(title: "録画済み", shell: shell)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); collection.backgroundColor = NeoStyle.background
    collection.dataSource = self; collection.delegate = self; collection.alwaysBounceVertical = true
    collection.register(NeoRecordedCard.self, forCellWithReuseIdentifier: "card")
    collection.register(NeoPaginationFooter.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "pages")
    refresh.tintColor = NeoStyle.accent; refresh.addTarget(self, action: #selector(refreshList), for: .valueChanged)
    collection.refreshControl = refresh; body.addSubview(collection); body.addSubview(message); body.addSubview(spinner)
    message.numberOfLines = 0; message.textAlignment = .center
    headerAccessory = userButton
    userButton.accessibilityIdentifier = "recorded-user-filter"; userButton.showsMenuAsPrimaryAction = true
    loadUsers()
    observers.append(NotificationCenter.default.addObserver(forName: .neoAccountChanged, object: nil, queue: .main) { [weak self] note in
      guard let self, let api = note.object as? NeoAPI, self.shell?.api === api else { return }
      if !self.userFilterExplicit {
        let id = Int(api.viewer).flatMap { $0 > 0 ? $0 : nil }
        if id != self.locatedUserID { self.locatedUserID = id; self.clearCache(); self.reload(targetPage: 1) }
      }
      self.loadUsers()
    })
    observers.append(NotificationCenter.default.addObserver(forName: .neoRecordingPreferencesChanged, object: nil, queue: .main) { [weak self] note in
      guard let self, let api = note.object as? NeoAPI, self.shell?.api === api else { return }
      if !api.highlightRecorded { self.clearHighlight() }
      if self.pageLength != api.recordedLength { self.pageLength = api.recordedLength; self.clearCache(); self.reload(targetPage: 1) }
    })
    actions = [NeoStyle.iconButton("SearchOutlined", label: "録画検索") { [weak self] in self?.search() },
      NeoStyle.iconButton("MoreVert", label: "録画一覧メニュー") { [weak self] in self?.showOptions() }]
    reload()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let frame = body.bounds
    let changed = collection.bounds.size != frame.size; collection.frame = frame
    if changed { collection.collectionViewLayout.invalidateLayout() }
    message.frame = body.bounds.insetBy(dx: 24, dy: 48); spinner.center = CGPoint(x: body.bounds.midX, y: 70)
  }
  func reloadLabels() { collection.reloadData() }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard let id = returnRecordingID else { return }
    returnRecordingID = nil
    collection.layoutIfNeeded()
    if let offset = returnOffset { collection.setContentOffset(offset, animated: false) }; returnOffset = nil
    if let index = records.firstIndex(where: { $0.id == id }) {
      let path = IndexPath(item: index, section: 0)
      if !collection.indexPathsForVisibleItems.contains(path) { collection.scrollToItem(at: path, at: .centeredVertically, animated: false) }
      showHighlight(id)
    }
  }
  func rememberDetail(_ id: Int) { returnRecordingID = id; returnOffset = collection.contentOffset; clearHighlight() }
  private func showHighlight(_ id: Int) {
    clearHighlight(); guard shell?.api?.highlightRecorded == true else { return }
    highlightID = id; updateHighlights(); let generation = highlightGeneration
    DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in
      guard let self, generation == self.highlightGeneration else { return }; self.clearHighlight()
    }
  }
  private func clearHighlight() { highlightGeneration += 1; highlightID = nil; updateHighlights() }
  private func updateHighlights() {
    for cell in collection.visibleCells {
      guard let cell = cell as? NeoRecordedCard, let index = collection.indexPath(for: cell), records.indices.contains(index.item) else { continue }
      cell.setFocused(records[index.item].id == highlightID)
    }
  }
  private func clearCache() { cache.removeAll(); cacheOrder.removeAll() }
  private func loadUsers() {
    usersTask?.cancel(); updateUserMenu()
#if targetEnvironment(simulator)
    if shell?.smokeStage.isEmpty == false { users = [.init(id: 7, name: "サンプルユーザー"), .init(id: 8, name: "ユーザー2")]; updateUserMenu(); return }
#endif
    guard let api = shell?.api else { return }
    usersTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await api.viewers(); guard !Task.isCancelled, self.shell?.api === api else { return }
        self.users = result.users; self.updateUserMenu()
      } catch { if !Task.isCancelled {
        self.userButton.menu = UIMenu(children: [UIAction(title: "ユーザーを取得できません。再試行") { [weak self] _ in self?.loadUsers() }])
      } }
    }
  }
  private func updateUserMenu() {
    let name = locatedUserID.map { id in users.first { $0.id == id }?.name ?? shell?.account?.currentName ?? String(id) } ?? "master（すべて）"
    userButton.setValue(name)
    userButton.menu = UIMenu(children: [UIAction(title: "master（すべて）", state: locatedUserID == nil ? .on : .off) { [weak self] _ in self?.selectUser(nil) }] + users.filter { $0.id > 0 }.map { user in
      UIAction(title: user.name, state: user.id == locatedUserID ? .on : .off) { [weak self] _ in self?.selectUser(user.id) }
    })
  }
  private func selectUser(_ id: Int?) {
    userFilterExplicit = true; guard id != locatedUserID else { return }
    locatedUserID = id; updateUserMenu(); clearCache(); reload(targetPage: 1)
  }
  func locate(_ id: Int, page: Int, userID: Int?) {
    userFilterExplicit = true; locatedUserID = userID.flatMap { $0 > 0 ? $0 : nil }; focusedRecordingID = id; filters = NeoRecordedFilters(); reverse = false
    returnRecordingID = nil; returnOffset = nil; updateUserMenu()
    cache.removeAll(); cacheOrder.removeAll(); reload(targetPage: max(1, page))
  }
  func returnToFirstPage() {
    if page != 1 || requestedPage != 1 { reload(targetPage: 1) }
    else { collection.setContentOffset(CGPoint(x: 0, y: -collection.adjustedContentInset.top), animated: false) }
  }
  @objc private func refreshList() { cache.removeAll(); cacheOrder.removeAll(); reload() }
  private func reload(targetPage: Int? = nil) {
    task?.cancel(); spinner.startAnimating(); message.text = nil
    clearHighlight()
    let requestedPage = targetPage ?? page, query = keyword, oldest = reverse
    self.requestedPage = requestedPage
    let userID = locatedUserID
    let search = filters, limit = pageLength
    let key = NeoRecordingQuery(page: requestedPage, keyword: query, reverse: oldest, userID: userID, filters: search, limit: limit)
    let entry = cache[key]
    let cached = entry.flatMap { Date().timeIntervalSince($0.stored) < 30 ? $0.result : nil }
    collection.layer.removeAllAnimations(); collection.alpha = 0
    let api = shell?.api
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result: NeoRecords
        if let cached { result = cached }
        else {
#if targetEnvironment(simulator)
        if self.shell?.smokeStage.isEmpty == false { result = Self.fixtures }
        else { guard let api else { return }; result = try await api.recordings(page: requestedPage, reverse: oldest, userID: userID, filters: search) }
#else
        guard let api else { return }; result = try await api.recordings(page: requestedPage, reverse: oldest, userID: userID, filters: search)
#endif
          self.cache[key] = (result, Date()); self.cacheOrder.removeAll { $0 == key }; self.cacheOrder.append(key)
          if self.cacheOrder.count > 12 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
        }
        try Task.checkCancellation()
        let lastPage = max(1, Int(ceil(Double(result.total) / Double(limit))))
        if requestedPage > lastPage { self.reload(targetPage: lastPage); return }
        let urls = result.records.compactMap { $0.thumbnails?.first.flatMap { api?.url("/thumbnails/\($0)") } }
        let late = try await NeoThumbnail.prepare(urls)
        try Task.checkCancellation()
        guard self.shell?.api === api else { return }
        self.page = requestedPage; self.records = result.records; self.total = result.total
        self.lateThumbnails = late
        self.message.text = result.records.isEmpty ? "録画がありません" : nil
        self.collection.reloadData(); self.collection.setContentOffset(.zero, animated: false)
        self.collection.layoutIfNeeded()
        if let id = self.focusedRecordingID, let index = result.records.firstIndex(where: { $0.id == id }) {
          self.collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
          self.showHighlight(id)
          self.focusedRecordingID = nil
        }
        self.lastFadeDuration = UIAccessibility.isReduceMotionEnabled ? 0 : cached == nil ? 0.5 : 0.32
        // CSS `ease` in RecordedPage.tsx, applied once to the entire list/footer.
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        fade.duration = self.lastFadeDuration; fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        self.collection.alpha = 1
        if self.lastFadeDuration > 0 { self.collection.layer.add(fade, forKey: "recorded-list-fade-in") }
      } catch {
        if Task.isCancelled { return }
        guard self.shell?.api === api else { return }
        self.collection.alpha = 1
        if self.records.isEmpty && requestedPage == 1 && search.isEmpty
          && self.navigationController?.viewControllers.first === self && self.shell?.smokeStage.isEmpty == true {
          self.shell?.showConnection(message: error.localizedDescription)
        } else { self.alert(error.localizedDescription) }
      }
      self.spinner.stopAnimating(); self.refresh.endRefreshing()
    }
  }
  private func selectPage(_ value: Int) {
    guard value != page, (1...max(1, Int(ceil(Double(total) / Double(pageLength))))).contains(value) else { return }
    reload(targetPage: value)
  }
#if targetEnvironment(simulator)
  var smokeCurrentPage: Int { page }
  var smokeSelectorAligned: Bool {
    view.layoutIfNeeded()
    return userButton.superview === header && userButton.frame.size == CGSize(width: 160, height: 40)
      && userButton.frame.minX >= titleLabel.frame.maxX && userButton.frame.maxX <= (actions.first?.frame.minX ?? 0)
      && collection.frame == body.bounds && userButton.showsMenuAsPrimaryAction && userButton.menu?.children.count == 3
  }
  var smokeLoadSettled: Bool { isViewLoaded && total > 0 && !spinner.isAnimating && requestedPage == page }
  var smokeRequestedPage: Int { requestedPage }
  func smokePageSeven() { selectPage(7) }
  func smokePageOne() { selectPage(1) }
  var renderedPages: [String] {
    collection.layoutIfNeeded()
    return collection.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter).flatMap { footer in
      footer.subviews.compactMap { ($0 as? UIButton)?.title(for: .normal) }
    }
  }
#endif
  private func search() {
    guard let shell, let api = shell.api else { return }
    let dialog = NeoRecordedSearch(api: api, channels: shell.channels, userID: locatedUserID, filters: filters)
#if targetEnvironment(simulator)
    dialog.smokeFixtures = !shell.smokeStage.isEmpty
#endif
    dialog.onApply = { [weak self] value in self?.applySearch(value) }
    let nav = UINavigationController(rootViewController: dialog); nav.overrideUserInterfaceStyle = .dark
    nav.modalPresentationStyle = .pageSheet; nav.sheetPresentationController?.detents = [.large()]
    present(nav, animated: true)
  }
  private func applySearch(_ value: NeoRecordedFilters) {
    guard let shell, value != filters else { return }
    let root = navigationController?.viewControllers.first as? NeoRecordedPage
    if value.isEmpty, let root {
      navigationController?.popToRootViewController(animated: true)
      if !root.filters.isEmpty { root.filters = value; root.reload(targetPage: 1) }; return
    }
    if self === root {
      let result = NeoRecordedPage(shell: shell, reverse: reverse)
      result.filters = value; result.locatedUserID = locatedUserID; result.userFilterExplicit = true
      navigationController?.pushViewController(result, animated: true)
    } else { filters = value; clearCache(); reload(targetPage: 1) }
  }
  private func showOptions() {
    guard let anchor = actions.last else { return }
    let items = [("編集", "EditOutlined"), ("クリーンアップ", "DeleteSweepOutlined"), ("アップロード", "UploadOutlined")]
    shell?.showPopup(anchor: anchor, entries: items.map { title, icon in
      NeoMenuEntry(title: title, icon: icon) { [weak self] in self?.alert("\(title) の操作は準備中です。") }
    }, appearance: .pageActions)
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { records.count }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! NeoRecordedCard
    let item = records[indexPath.item]
    let thumbnailURL = item.thumbnails?.first.flatMap { shell?.api?.url("/thumbnails/\($0)") }
    cell.configure(item, channelName: item.channelName ?? item.channelId.flatMap { shell?.channels[$0] } ?? "", api: shell?.api,
      mobile: mobile, fadeThumbnail: thumbnailURL.map { lateThumbnails.contains($0) } ?? false)
    cell.setFocused(item.id == highlightID)
#if targetEnvironment(simulator)
    if shell?.smokeStage.isEmpty == false { cell.thumbnail.showFixture(item.id) }
#endif
    cell.onMore = { [weak self] anchor in self?.showRecordingMenu(item, anchor: anchor, detail: false) }; return cell
  }
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { shell?.openDetail(records[indexPath.item]) }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { CGSize(width: itemWidth, height: cardHeight) }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
    let columns = max(1, Int((collectionView.bounds.width - 8 + 8) / (itemWidth + 8)))
    let side = mobile ? 4 : max(4, (collectionView.bounds.width - CGFloat(columns) * itemWidth - CGFloat(columns - 1) * 8) / 2)
    return UIEdgeInsets(top: 4, left: side, bottom: 0, right: side)
  }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { mobile ? 4 : 8 }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { mobile ? 4 : 8 }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
    CGSize(width: collectionView.bounds.width, height: total > pageLength ? 72 : 0)
  }
  func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
    let footer = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "pages", for: indexPath) as! NeoPaginationFooter
    footer.configure(page: page, count: max(1, Int(ceil(Double(total) / Double(pageLength)))), mobile: collection.bounds.width <= 500) { [weak self] value in self?.selectPage(value) }
    return footer
  }
  deinit { task?.cancel(); usersTask?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
#if targetEnvironment(simulator)
  func smokeOpenSearch() { search() }
  func smokeListFeatures() async -> Bool {
    guard let shell, let api = shell.api else { return false }
    let oldLength = api.recordedLength, oldHighlight = api.highlightRecorded, oldViewer = api.viewer
    defer { api.recordedLength = oldLength; api.highlightRecorded = oldHighlight; selectUser(nil) }
    func settled() async {
      for _ in 0..<100 { if smokeLoadSettled { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
    }
    api.recordedLength = 25; await settled()
    guard pageLength == 25, page == 1 else { return false }
    selectPage(7); await settled(); let originalPage = page
    NotificationCenter.default.post(name: .neoAccountChanged, object: api)
    let sameIdentityKeptPage = page == originalPage && requestedPage == originalPage
    api.highlightRecorded = true
    locate(1, page: 7, userID: 7); await settled(); collection.layoutIfNeeded()
    let located = page == 7 && highlightID == 1 && locatedUserID == 7
      && (collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NeoRecordedCard)?.contentView.layer.borderWidth == 2
    api.highlightRecorded = false
    let disabled = highlightID == nil
    api.highlightRecorded = true
    rememberDetail(1); viewDidAppear(false)
    let returned = highlightID == 1
    try? await Task.sleep(nanoseconds: 1_100_000_000)
    let expired = highlightID == nil
    let card = NeoRecordedCard(frame: .zero); card.setFocused(true); card.prepareForReuse()
    let reused = card.contentView.layer.borderWidth == 0
    selectUser(nil); await settled()
    let all = locatedUserID == nil && page == 1 && api.viewer == oldViewer
    var search = NeoRecordedFilters(); search.genre = 7; search.encodeModes = ["__ts__", "AV1 / MKV"]
    applySearch(search); await Task.yield()
    let child = navigationController?.topViewController as? NeoRecordedPage
    let preserved = child !== self && child?.filters == search && child?.locatedUserID == nil
    navigationController?.popToViewController(self, animated: false)
    return sameIdentityKeptPage && located && disabled && returned && expired && reused && all && preserved
  }
  func smokeOpenListMenu() { showOptions() }
  func smokeOpenFirstMenu() {
    collection.layoutIfNeeded()
    if let cell = collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NeoRecordedCard,
      let button = cell.contentView.subviews.compactMap({ $0 as? UIButton }).first { cell.onMore?(button) }
  }
  static let fixtures = NeoRecords(records: (1...4).map { index in
    NeoRecording(id: index, name: ["サンプル番組 第12話「新しい朝」", "週末の映画劇場「旅のはじまり」", "ニュースと天気", "音楽の時間"][index - 1],
      startAt: 1791021600000 - Double(index - 1) * 3600000, endAt: 1791023400000 - Double(index - 1) * 3600000,
      isRecording: false, description: "録画カードのレイアウト確認用データです。長い説明は一行で省略します。", extended: "番組内容\n詳細画面の表示確認用データです。",
      channelId: 1, channelName: "サンプル放送 BS", thumbnails: nil,
      videoFiles: [.init(id: index, name: "TS", type: "ts", size: 1073741824, filename: nil),
        .init(id: index + 10, name: "AV1 / MKV", type: "encoded", size: 352200000, filename: nil)],
      ruleId: 1, dropLogFile: .init(id: index, errorCnt: 0, dropCnt: 2, scramblingCnt: 0))
  }, total: 300)
#endif
}
