import UIKit

private final class NeoOnAirCell: UICollectionViewCell {
  private let logo = UIImageView(), station = NeoStyle.label(size:16,bold:true)
  private let wave = NeoStyle.label(size:12,muted:true), force = NeoStyle.label(size:12,bold:true)
  private let fallback = NeoStyle.label(size:12,bold:true,muted:true)
  private let fire = UIImageView(), title = NeoStyle.label(size:16,bold:true)
  private let times = NeoStyle.label(size:12,muted:true), summary = NeoStyle.label(size:13,muted:true)
  private let info = UIButton(type:.custom), watch = UIButton(type:.custom), pin = UIButton(type:.system)
  private let track = UIView(), progress = UIView()
  private var imageTask: URLSessionDataTask?, imageID = 0, fraction = 0.0
  private var logoChannel = -1
  var onWatch: (() -> Void)?, onInfo: (() -> Void)?, onPin: (() -> Void)?
  override init(frame: CGRect) {
    super.init(frame:frame)
    contentView.backgroundColor = NeoStyle.paper; contentView.layer.cornerRadius = 6
    contentView.layer.borderWidth = 1; contentView.layer.borderColor = NeoStyle.border.cgColor; contentView.clipsToBounds = true
    logo.contentMode = .scaleAspectFit; fallback.textAlignment = .center
    [logo,fallback,station,wave,force,fire,title,times,summary,info,watch,pin,track].forEach(contentView.addSubview)
    [logo,station,wave,force,fire,title,times,summary].forEach { $0.isUserInteractionEnabled = false }
    title.numberOfLines = 1; summary.numberOfLines = 2
    track.backgroundColor = NeoStyle.border; progress.backgroundColor = NeoStyle.accent; track.addSubview(progress)
    pin.addAction(UIAction { [weak self] _ in self?.onPin?() },for:.touchUpInside)
    info.addAction(UIAction { [weak self] _ in self?.onInfo?() },for:.touchUpInside)
    watch.addAction(UIAction { [weak self] _ in self?.onWatch?() },for:.touchUpInside)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func prepareForReuse() { super.prepareForReuse(); imageTask?.cancel(); imageTask = nil; imageID += 1; logo.image = nil; logoChannel = -1 }
  func configure(_ schedule: NeoLiveSchedule, force amount: Int?, pinned: Bool, api: NeoAPI, now: Double) {
    fallback.text = schedule.channel.waveLabel; fallback.isHidden = schedule.channel.hasLogoData == true
    station.text = schedule.channel.name
    wave.text = schedule.channel.waveLabel+(schedule.channel.remoteControlKeyId.map { " \($0)" } ?? "")
    force.text = (amount.map { NumberFormatter.localizedString(from:NSNumber(value:$0),number:.decimal) } ?? "--")+" コメ/分"
    // OnAirPage.forceColor, MUI dark warning.main orange[400], error.main red[500].
    let color: UIColor = (amount ?? 0) < 100 ? NeoStyle.muted : amount! < 200 ? NeoStyle.accent : amount! < 500 ?
      UIColor(red:255/255,green:167/255,blue:38/255,alpha:1) : UIColor(red:244/255,green:67/255,blue:54/255,alpha:1)
    force.textColor = color; fire.tintColor = color; fire.image = NeoIcon.image("LocalFireDepartmentOutlined")
    pin.setImage(NeoIcon.image(pinned ? "PushPin" : "PushPinOutlined"),for:.normal); pin.tintColor = pinned ? NeoStyle.accent : NeoStyle.muted
    pin.accessibilityLabel = schedule.channel.name+(pinned ? "のピン留めを解除" : "をピン留め")
    watch.accessibilityLabel = schedule.channel.name+"を視聴"; info.accessibilityLabel = schedule.channel.name+"の番組詳細を開く"
    if let program = schedule.program {
      title.text = program.name; summary.text = program.description; times.text = NeoOnAirPage.programTime(program)
      fraction = program.progress(now); info.isEnabled = true
    } else {
      let hour = Calendar(identifier:.gregorian).dateComponents(in:TimeZone(identifier:"Asia/Tokyo")!,from:Date(timeIntervalSince1970:now/1000)).hour ?? 12
      let paused = hour >= 23 || hour < 7
      title.text = paused ? "放送休止" : "番組情報を取得できません"
      summary.text = paused ? "この時間は放送を休止しています" : "放送局を選択して視聴できます"
      times.text = nil; fraction = 0; info.isEnabled = false
    }
    if logoChannel != schedule.channel.id {
    logoChannel = schedule.channel.id; imageTask?.cancel(); imageID += 1; let version = imageID; logo.image = nil
    if schedule.channel.hasLogoData == true {
      imageTask = api.session.dataTask(with:api.url("/channels/\(schedule.channel.id)/logo")) { [weak self] data,response,_ in
        guard let data, (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data:data) else { return }
        DispatchQueue.main.async { guard let self, self.imageID == version else { return }; self.logo.image = image }
      }; imageTask?.resume()
    }
    }
    setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews(); let tablet = bounds.height >= 250, inset: CGFloat = tablet ? 16 : 10
    title.numberOfLines = tablet ? 2 : 1; summary.numberOfLines = tablet ? 3 : 2
    let head: CGFloat = tablet ? 62 : 54, logoWidth: CGFloat = tablet ? 68 : 58
    logo.frame = CGRect(x:inset,y:12,width:logoWidth,height:tablet ? 38 : 34)
    fallback.frame = logo.frame
    let x = inset+logoWidth+8, available = max(0,bounds.width-x-42)
    station.frame = CGRect(x:x,y:5,width:available,height:22)
    wave.sizeToFit(); let waveWidth = min(available,wave.intrinsicContentSize.width)
    wave.frame = CGRect(x:x,y:28,width:waveWidth,height:18)
    fire.frame = CGRect(x:x+waveWidth+6,y:29,width:15,height:15)
    force.frame = CGRect(x:fire.frame.maxX+2,y:28,width:max(0,bounds.width-fire.frame.maxX-12),height:18)
    pin.frame = CGRect(x:bounds.width-42,y:9,width:34,height:34)
    title.frame = CGRect(x:inset,y:head,width:bounds.width-2*inset,height:min(tablet ? 44 : 23,title.sizeThatFits(CGSize(width:bounds.width-2*inset,height:.greatestFiniteMagnitude)).height))
    times.frame = CGRect(x:inset,y:title.frame.maxY+3,width:title.bounds.width,height:18)
    summary.frame = CGRect(x:inset,y:times.frame.maxY+3,width:title.bounds.width,height:min(tablet ? 64 : 40,summary.sizeThatFits(CGSize(width:title.bounds.width,height:.greatestFiniteMagnitude)).height))
    info.frame = CGRect(x:0,y:0,width:bounds.width-43,height:head)
    watch.frame = CGRect(x:0,y:head,width:bounds.width,height:max(0,bounds.height-head-4))
    track.frame = CGRect(x:0,y:bounds.height-4,width:bounds.width,height:4)
    progress.frame = CGRect(x:0,y:0,width:track.bounds.width*fraction,height:4)
  }
}

final class NeoOnAirPage: NeoPage, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  private let tabs = UIScrollView(), tabLine = UIView(), indicator = UIView()
  private let list = UICollectionView(frame:.zero,collectionViewLayout:UICollectionViewFlowLayout())
  private let message = NeoStyle.label(size:14,muted:true), spinner = UIActivityIndicatorView(style:.medium)
  private let refresh = UIRefreshControl()
  private var task: Task<Void,Never>?, timer: Timer?, progressTimer: Timer?
  private var schedules: [NeoLiveSchedule] = [], forces: [Int:Int] = [:], buttons: [UIButton] = []
  private var visible: [NeoLiveSchedule] = [], waves: [String] = [], wave = "", active = false
  private var pins = Set<Int>()
  private var pinKey: String { "onair.pins."+(shell?.api?.base.absoluteString ?? "") }
  init(shell: NeoShell) { super.init(title:"放映中",shell:shell) }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); pins = Set(UserDefaults.standard.array(forKey:pinKey) as? [Int] ?? [])
    body.addSubview(tabs); body.addSubview(list); body.addSubview(message); body.addSubview(spinner)
    tabs.showsHorizontalScrollIndicator = false; tabs.backgroundColor = NeoStyle.paper
    tabLine.backgroundColor = NeoStyle.border; tabs.addSubview(tabLine); indicator.backgroundColor = NeoStyle.accent; tabs.addSubview(indicator)
    list.backgroundColor = .clear; list.dataSource = self; list.delegate = self; list.alwaysBounceVertical = true
    list.register(NeoOnAirCell.self,forCellWithReuseIdentifier:"onair"); list.accessibilityIdentifier = "onair-list"
    list.refreshControl = refresh; refresh.tintColor = NeoStyle.accent
    refresh.addAction(UIAction { [weak self] _ in self?.reload() },for:.valueChanged)
    message.textAlignment = .center; message.numberOfLines = 0; message.isHidden = true
    actions = [NeoStyle.iconButton("Refresh",label:"放映中を更新") { [weak self] in self?.reload() }]
    reload()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated); active = true; reload()
    timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in self?.reload() }
    progressTimer?.invalidate(); progressTimer = Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in self?.updateCards() }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated); active = false; timer?.invalidate(); timer = nil; progressTimer?.invalidate(); progressTimer = nil
  }
  func reload() {
    guard task == nil, let api = shell?.api else { return }
    if schedules.isEmpty { spinner.startAnimating() }
    task = Task { [weak self, api] in
      guard let self else { return }; defer { self.task = nil; self.spinner.stopAnimating(); self.refresh.endRefreshing() }
      do {
        async let schedule = api.broadcasting()
        async let status = try? api.liveForces()
        if self.shell?.serverConfig == nil { await self.shell?.refreshServerConfig() }
        let result = try await schedule, forceValues = await status
        try Task.checkCancellation(); guard self.shell?.api === api else { return }
        self.schedules = result; self.forces = Dictionary((forceValues ?? []).compactMap { item in item.force.map { (item.channelId,$0) } },uniquingKeysWith: { _,new in new })
        self.rebuild()
      } catch { if self.schedules.isEmpty { self.message.text = "番組情報を取得できませんでした。"; self.message.isHidden = false } }
    }
  }
  private func rebuild() {
    let config = shell?.serverConfig
    schedules = schedules.filter { config?.broadcast?[$0.channel.channelType] != false && $0.channel.defaultVisible }
    let order = ["GR","GR-ALT1","GR-ALT2","GR-ALT3","BS","CS","SKY","BS4K"]
    waves = Array(Set(schedules.map { $0.channel.channelType })).sorted {
      let a = order.firstIndex(of:$0) ?? 100, b = order.firstIndex(of:$1) ?? 100
      return a == b ? $0.localizedCompare($1) == .orderedAscending : a < b
    }
    if schedules.contains(where: { pins.contains($0.channel.id) }) { waves.insert("PINNED",at:0) }
    if !waves.contains(wave) { wave = waves.first ?? "" }
    buttons.forEach { $0.removeFromSuperview() }
    buttons = waves.map { id in
      let button = UIButton(type:.system); button.setTitle(id == "PINNED" ? "Pinned" : id.hasPrefix("GR-ALT") ? String(id.dropFirst(3)) : id,for:.normal)
      button.titleLabel?.font = .systemFont(ofSize:14,weight:.medium)
      button.accessibilityIdentifier = "onair-wave-"+id
      button.addAction(UIAction { [weak self] _ in self?.wave = id; self?.filter() },for:.touchUpInside)
      tabs.addSubview(button); return button
    }
    filter()
  }
  private func filter() {
    visible = schedules.filter { wave == "PINNED" ? pins.contains($0.channel.id) : $0.channel.channelType == wave }
    message.text = "表示できる放送局がありません。"; message.isHidden = !visible.isEmpty
    for (index,button) in buttons.enumerated() {
      button.tintColor = waves[index] == wave ? NeoStyle.accent : NeoStyle.muted
      button.accessibilityTraits = waves[index] == wave ? [.button,.selected] : .button
    }
    list.reloadData(); view.setNeedsLayout()
  }
  private func updateCards() {
    for path in list.indexPathsForVisibleItems { if let cell = list.cellForItem(at:path) as? NeoOnAirCell, visible.indices.contains(path.item) { configure(cell,at:path) } }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); let tabHeight: CGFloat = waves.isEmpty ? 0 : 48
    tabs.frame = CGRect(x:0,y:0,width:body.bounds.width,height:tabHeight)
    var x: CGFloat = 0
    for button in buttons { let width = max(90,(button.titleLabel?.intrinsicContentSize.width ?? 0)+32); button.frame = CGRect(x:x,y:0,width:width,height:48); x += width }
    tabs.contentSize = CGSize(width:x,height:48); tabLine.frame = CGRect(x:0,y:47,width:max(x,tabs.bounds.width),height:1)
    if let index = waves.firstIndex(of:wave), buttons.indices.contains(index) { let frame = buttons[index].frame; indicator.frame = CGRect(x:frame.minX,y:46,width:frame.width,height:2) }
    list.frame = CGRect(x:0,y:tabHeight,width:body.bounds.width,height:body.bounds.height-tabHeight)
    message.frame = CGRect(x:16,y:tabHeight+30,width:max(0,body.bounds.width-32),height:180)
    spinner.center = CGPoint(x:body.bounds.midX,y:tabHeight+130)
    list.collectionViewLayout.invalidateLayout()
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { visible.count }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier:"onair",for:indexPath) as! NeoOnAirCell; configure(cell,at:indexPath); return cell
  }
  private func configure(_ cell: NeoOnAirCell, at path: IndexPath) {
    guard visible.indices.contains(path.item), let api = shell?.api else { return }; let schedule = visible[path.item]
    cell.configure(schedule,force:forces[schedule.channel.id],pinned:pins.contains(schedule.channel.id),api:api,now:Date().timeIntervalSince1970*1000)
    cell.onWatch = { [weak self] in self?.watch(schedule) }
    cell.onInfo = { [weak self] in self?.program(schedule) }
    cell.onPin = { [weak self] in guard let self else { return }; if !self.pins.insert(schedule.channel.id).inserted { self.pins.remove(schedule.channel.id) }; UserDefaults.standard.set(Array(self.pins),forKey:self.pinKey); self.rebuild() }
  }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt path: IndexPath) -> CGSize {
    let columns: CGFloat = collectionView.bounds.width >= 1536 ? 4 : collectionView.bounds.width >= 1200 ? 3 : collectionView.bounds.width >= 600 ? 2 : 1
    let inset: CGFloat = collectionView.bounds.width >= 1200 ? 20 : columns == 1 ? 8 : 16, gap: CGFloat = columns == 1 ? 8 : 14
    return CGSize(width:floor((collectionView.bounds.width-2*inset-(columns-1)*gap)/columns),height:columns == 1 ? 188 : 270)
  }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
    let value: CGFloat = collectionView.bounds.width >= 1200 ? 20 : collectionView.bounds.width >= 600 ? 16 : 8; return UIEdgeInsets(top:value,left:value,bottom:value,right:value)
  }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { collectionView.bounds.width >= 600 ? 14 : 8 }
  func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { collectionView.bounds.width >= 600 ? 14 : 8 }
  static func programTime(_ program: NeoLiveProgram) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier:"ja_JP"); formatter.timeZone = TimeZone(identifier:"Asia/Tokyo"); formatter.dateFormat = "HH:mm"
    let start = formatter.string(from:Date(timeIntervalSince1970:program.startAt/1000)), end = formatter.string(from:Date(timeIntervalSince1970:program.endAt/1000))
    return "\(start) - \(end)（\(max(0,Int(((program.endAt-program.startAt)/60000).rounded())))分）"
  }
  private func program(_ schedule: NeoLiveSchedule) {
    guard let program = schedule.program else { return }
    let dialog = NeoLiveDialog(title:program.name)
    dialog.addText(schedule.channel.name,bold:true); dialog.addText(Self.programTime(program)); dialog.addText(program.description ?? "")
    if let extended = program.extended { dialog.addText(extended) }
    dialog.addAction("閉じる") { [weak dialog] in dialog?.dismiss(animated:true) }
    dialog.addAction("視聴",filled:true) { [weak self, weak dialog] in dialog?.dismiss(animated:true) { self?.watch(schedule) } }
    present(dialog,animated:true)
  }
  private func watch(_ schedule: NeoLiveSchedule) {
    guard let shell, let api = shell.api else { return }
    guard let config = shell.serverConfig else { alert("配信設定を取得できませんでした。更新して再試行してください。"); return }
    let options = NeoLiveOption.available(config)
    let dialog = NeoLiveStreamDialog(title:schedule.channel.name,options:options)
    dialog.onWatch = { [weak self, weak shell] selected, external in
      guard let self else { return }
      if external, let scheme = config.urlscheme?["m2ts"]?["ios"] {
        let url = selected.url(api:api,channel:schedule.channel.id), raw = String(url.absoluteString.dropFirst((url.scheme?.count ?? 0)+3))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-_.!~*'()"))
        let address = scheme.contains("vlc-x-callback") ? raw.addingPercentEncoding(withAllowedCharacters:allowed) ?? raw : raw
        let value = scheme.replacingOccurrences(of:"PROTOCOL",with:url.scheme ?? "http").replacingOccurrences(of:"ADDRESS",with:address)
        if let target = URL(string:value) { UIApplication.shared.open(target) }
      } else { shell?.playLive(schedule,option:selected,options:options,schedules:self.schedules,api:api) }
    }
    present(dialog,animated:true)
  }
#if targetEnvironment(simulator)
  func runLiveUIProbe(_ completion: @escaping ([String:Bool]) -> Void) {
    var checks = ["liveRoute":!visible.isEmpty,"waveTabs":waves.contains("GR") && waves.contains("BS"),
      "forceFetched":forces.values.contains(220),"streamModes":shell?.serverConfig.map { NeoLiveOption.available($0).count >= 3 } ?? false]
    view.layoutIfNeeded(); list.layoutIfNeeded()
    checks["cardsInsideViewport"] = list.visibleCells.allSatisfy { $0.bounds.width > 0 && $0.bounds.width <= list.bounds.width }
    guard let item = visible.first else { completion(checks); return }
    let renderer = UIGraphicsImageRenderer(bounds:view.bounds)
    try? renderer.image { _ in view.drawHierarchy(in:view.bounds,afterScreenUpdates:true) }.pngData()?.write(to:NeoPiPSmoke.directory.appendingPathComponent("live-onair.png"))
    watch(item)
    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
      guard let self, let dialog = self.presentedViewController as? NeoLiveDialog else { checks["dialogPresented"] = false; completion(checks); return }
      dialog.view.layoutIfNeeded(); checks["dialogCompact"] = dialog.smokeCompact
      let image = UIGraphicsImageRenderer(bounds:dialog.view.bounds).image { _ in dialog.view.drawHierarchy(in:dialog.view.bounds,afterScreenUpdates:true) }
      try? image.pngData()?.write(to:NeoPiPSmoke.directory.appendingPathComponent("live-dialog.png"))
      dialog.dismiss(animated:false) { completion(checks) }
    }
  }
#endif
  deinit { task?.cancel(); timer?.invalidate(); progressTimer?.invalidate() }
}

// Same compact, centered outlined dialog surface as the mobile Web player.
class NeoLiveDialog: UIViewController {
  private let card = UIView(), scroll = UIScrollView(), stack = UIStackView(), actions = UIStackView()
  private let headingLabel = NeoStyle.label(size:20,bold:true), contentFill = UIView(), topLine = UIView(), bottomLine = UIView()
  private let heading: String
  init(title: String) { heading = title; super.init(nibName:nil,bundle:nil); modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve }
  required init?(coder: NSCoder) { fatalError() }
#if targetEnvironment(simulator)
  var smokeCompact: Bool { card.bounds.height < 400 && card.bounds.width <= 444 && card.frame.minY > 0 }
#endif
  override func loadView() {
    view = UIView(); view.backgroundColor = .black.withAlphaComponent(0.5)
    card.backgroundColor = NeoStyle.paper; card.layer.cornerRadius = 12; card.layer.borderColor = NeoStyle.border.cgColor; card.layer.borderWidth = 1
    card.clipsToBounds = true; contentFill.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    topLine.backgroundColor = NeoStyle.border; bottomLine.backgroundColor = NeoStyle.border
    view.addSubview(card); [contentFill,scroll,headingLabel,actions,topLine,bottomLine].forEach(card.addSubview); scroll.addSubview(stack)
    stack.axis = .vertical; stack.spacing = 14; actions.spacing = 12; actions.alignment = .center; actions.addArrangedSubview(UIView())
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor)])
    headingLabel.text = heading; headingLabel.numberOfLines = 0
  }
  func addText(_ text: String, bold: Bool = false) {
    loadViewIfNeeded(); guard !text.isEmpty else { return }; let label = NeoStyle.label(text,size:bold ? 20 : 14,bold:bold,muted:!bold); label.numberOfLines = 0; stack.addArrangedSubview(label)
  }
  func addView(_ value: UIView) { loadViewIfNeeded(); stack.addArrangedSubview(value) }
  @discardableResult func addChoice(_ label: String, container: UIStackView? = nil) -> UIButton {
    loadViewIfNeeded(); let field = UIStackView(); field.axis = .vertical; field.spacing = 3
    field.addArrangedSubview(NeoStyle.label(label,size:14,muted:true))
    let button = UIButton(type:.system); button.contentHorizontalAlignment = .left; button.titleLabel?.font = .systemFont(ofSize:18); button.tintColor = .white; button.showsMenuAsPrimaryAction = true
    button.heightAnchor.constraint(equalToConstant:38).isActive = true; field.addArrangedSubview(button)
    let line = UIView(); line.backgroundColor = NeoStyle.muted; line.heightAnchor.constraint(equalToConstant:1).isActive = true; field.addArrangedSubview(line); (container ?? stack).addArrangedSubview(field); return button
  }
  func addAction(_ title: String, filled: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
    loadViewIfNeeded(); let button = NeoStyle.button(title,filled:filled,action:action); button.isEnabled = enabled
    if !filled { button.tintColor = .white; button.layer.borderWidth = 1; button.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor }
    button.heightAnchor.constraint(equalToConstant:42).isActive = true; button.widthAnchor.constraint(greaterThanOrEqualToConstant:74).isActive = true; actions.addArrangedSubview(button)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); let width = min(444,max(0,view.bounds.width-24))
    let content = stack.systemLayoutSizeFitting(CGSize(width:width-48,height:UIView.layoutFittingCompressedSize.height),withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height
    let header = max(40,headingLabel.sizeThatFits(CGSize(width:width-48,height:.greatestFiniteMagnitude)).height+16)
    let height = min(max(200,header+content+92),max(200,view.bounds.height-view.safeAreaInsets.top-view.safeAreaInsets.bottom-32))
    card.frame = CGRect(x:(view.bounds.width-width)/2,y:(view.bounds.height-height)/2,width:width,height:height)
    headingLabel.frame = CGRect(x:24,y:8,width:width-48,height:header-16)
    contentFill.frame = CGRect(x:0,y:header,width:width,height:height-header-60)
    topLine.frame = CGRect(x:0,y:header,width:width,height:1); bottomLine.frame = CGRect(x:0,y:height-60,width:width,height:1)
    scroll.frame = CGRect(x:24,y:header+16,width:width-48,height:max(0,height-header-92)); actions.frame = CGRect(x:12,y:height-54,width:width-24,height:48)
  }
}

private final class NeoLiveStreamDialog: NeoLiveDialog {
  private let options: [NeoLiveOption]
  private var selected: NeoLiveOption?
  private var stream: UIButton!, quality: UIButton!
  private let external = UISwitch()
  var onWatch: ((NeoLiveOption,Bool) -> Void)?
  init(title: String, options: [NeoLiveOption]) {
    self.options = options
    selected = options.first { $0.type == UserDefaults.standard.string(forKey:"live.type") && $0.mode == UserDefaults.standard.integer(forKey:"live.mode") } ?? options.first
    super.init(title:title)
    let fields = UIStackView(); fields.spacing = 14; fields.distribution = .fillEqually
    stream = addChoice("ストリーム",container:fields); quality = addChoice("画質",container:fields); addView(fields)
    let row = UIStackView(arrangedSubviews:[external,NeoStyle.label("外部アプリで開く")]); row.alignment = .center; row.spacing = 10
    external.onTintColor = NeoStyle.accent; addView(row)
    external.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      if self.external.isOn { self.selected = self.options.first { $0.type == "m2ts" } }
      self.updateChoices()
    },for:.valueChanged)
    if options.isEmpty { addText("利用できる視聴設定がありません。") }
    addAction("キャンセル") { [weak self] in self?.dismiss(animated:true) }
    addAction("視聴",filled:true,enabled:!options.isEmpty) { [weak self] in
      guard let self, let value = self.selected else { return }
      UserDefaults.standard.set(value.type,forKey:"live.type"); UserDefaults.standard.set(value.mode,forKey:"live.mode")
      let callback = self.onWatch, outside = self.external.isOn
      self.dismiss(animated:true) { callback?(value,outside) }
    }
    updateChoices()
  }
  required init?(coder: NSCoder) { fatalError() }
  private func updateChoices() {
    stream.setTitle((selected?.label ?? "")+" ▾",for:.normal); quality.setTitle((selected?.quality ?? "")+" ▾",for:.normal)
    let types = ["m2ts","m2tsll"].filter { type in options.contains { $0.type == type } && (!external.isOn || type == "m2ts") }
    stream.menu = UIMenu(children:types.map { type in UIAction(title:type == "m2tsll" ? "M2TS-LL" : "M2TS",state:type == selected?.type ? .on : .off) { [weak self] _ in
      guard let self else { return }; self.selected = self.options.first { $0.type == type }; self.updateChoices()
    } })
    quality.menu = UIMenu(children:options.filter { $0.type == selected?.type }.map { value in UIAction(title:value.quality,state:value == selected ? .on : .off) { [weak self] _ in self?.selected = value; self?.updateChoices() } })
  }
}
