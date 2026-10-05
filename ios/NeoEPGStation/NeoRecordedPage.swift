import UIKit

final class NeoRecordedCard: UICollectionViewCell {
  let thumbnail = NeoThumbnail(), title = NeoStyle.label(size: 14, bold: true)
  let channel = NeoStyle.label(size: 12, muted: true), time = NeoStyle.label(size: 12, muted: true)
  let descriptionLabel = NeoStyle.label(size: 12)
  var mobile = true
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
  override func prepareForReuse() { super.prepareForReuse(); thumbnail.load(nil); onMore = nil }
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
  private var total = 0, page = 1, keyword = "", reverse = false
  private var task: Task<Void, Never>?
  private var cache: [NeoRecordingQuery: (result: NeoRecords, stored: Date)] = [:]
  private var cacheOrder: [NeoRecordingQuery] = []
  private var lateThumbnails: Set<URL> = []
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
    self.keyword = keyword; self.reverse = reverse
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
    actions = [NeoStyle.iconButton("SearchOutlined", label: "録画検索") { [weak self] in self?.search() },
      NeoStyle.iconButton("MoreVert", label: "録画一覧メニュー") { [weak self] in self?.showOptions() }]
    reload()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let changed = collection.bounds.size != body.bounds.size; collection.frame = body.bounds
    if changed { collection.collectionViewLayout.invalidateLayout() }
    message.frame = body.bounds.insetBy(dx: 24, dy: 48); spinner.center = CGPoint(x: body.bounds.midX, y: 70)
  }
  func reloadLabels() { collection.reloadData() }
  @objc private func refreshList() { cache.removeAll(); cacheOrder.removeAll(); reload() }
  private func reload(targetPage: Int? = nil) {
    task?.cancel(); spinner.startAnimating(); message.text = nil
    let requestedPage = targetPage ?? page, query = keyword, oldest = reverse
    let key = NeoRecordingQuery(page: requestedPage, keyword: query, reverse: oldest)
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
        else { guard let api else { return }; result = try await api.recordings(page: requestedPage, keyword: query, reverse: oldest) }
#else
        guard let api else { return }; result = try await api.recordings(page: requestedPage, keyword: query, reverse: oldest)
#endif
          self.cache[key] = (result, Date()); self.cacheOrder.removeAll { $0 == key }; self.cacheOrder.append(key)
          if self.cacheOrder.count > 12 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
        }
        try Task.checkCancellation()
        let urls = result.records.compactMap { $0.thumbnails?.first.flatMap { api?.url("/thumbnails/\($0)") } }
        let late = try await NeoThumbnail.prepare(urls)
        try Task.checkCancellation()
        guard self.shell?.api === api else { return }
        self.page = requestedPage; self.records = result.records; self.total = result.total
        self.lateThumbnails = late
        self.message.text = result.records.isEmpty ? "録画がありません" : nil
        self.collection.reloadData(); self.collection.setContentOffset(.zero, animated: false)
        self.collection.layoutIfNeeded()
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
        if self.records.isEmpty && requestedPage == 1 && query.isEmpty && self.shell?.smokeStage.isEmpty == true {
          self.shell?.showConnection(message: error.localizedDescription)
        } else { self.alert(error.localizedDescription) }
      }
      self.spinner.stopAnimating(); self.refresh.endRefreshing()
    }
  }
  private func selectPage(_ value: Int) {
    guard value != page, (1...max(1, Int(ceil(Double(total) / 30)))).contains(value) else { return }
    reload(targetPage: value)
  }
#if targetEnvironment(simulator)
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
    let dialog = UIAlertController(title: "録画検索", message: "番組名・説明から検索", preferredStyle: .alert)
    dialog.addTextField { [keyword] field in field.placeholder = "キーワード"; field.text = keyword; field.clearButtonMode = .whileEditing }
    dialog.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    dialog.addAction(UIAlertAction(title: "検索", style: .default) { [weak self, weak dialog] _ in
      guard let self, let shell = self.shell else { return }
      let query = dialog?.textFields?.first?.text ?? ""
      guard query != self.keyword else { return }
      if query.isEmpty { self.navigationController?.popToRootViewController(animated: true) }
      else { self.navigationController?.pushViewController(NeoRecordedPage(shell: shell, keyword: query, reverse: self.reverse), animated: true) }
    }); present(dialog, animated: true)
  }
  private func showOptions() {
    let menu = UIAlertController(title: "録画済み", message: nil, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: reverse ? "新しい録画から表示" : "古い録画から表示", style: .default) { [weak self] _ in
      self?.reverse.toggle(); self?.page = 1; self?.reload()
    })
    let clearSearch = UIAlertAction(title: "検索を解除", style: .default) { [weak self] _ in self?.navigationController?.popToRootViewController(animated: true) }
    clearSearch.isEnabled = !keyword.isEmpty; menu.addAction(clearSearch)
    menu.addAction(UIAlertAction(title: "更新", style: .default) { [weak self] _ in self?.refreshList() })
    menu.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    menu.popoverPresentationController?.sourceView = actions.last; present(menu, animated: true)
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { records.count }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! NeoRecordedCard
    let item = records[indexPath.item]
    let thumbnailURL = item.thumbnails?.first.flatMap { shell?.api?.url("/thumbnails/\($0)") }
    cell.configure(item, channelName: item.channelName ?? item.channelId.flatMap { shell?.channels[$0] } ?? "", api: shell?.api,
      mobile: mobile, fadeThumbnail: thumbnailURL.map { lateThumbnails.contains($0) } ?? false)
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
    CGSize(width: collectionView.bounds.width, height: total > 30 ? 72 : 0)
  }
  func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
    let footer = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "pages", for: indexPath) as! NeoPaginationFooter
    footer.configure(page: page, count: max(1, Int(ceil(Double(total) / 30))), mobile: collection.bounds.width <= 500) { [weak self] value in self?.selectPage(value) }
    return footer
  }
  deinit { task?.cancel() }
#if targetEnvironment(simulator)
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
