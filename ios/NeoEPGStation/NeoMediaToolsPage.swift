import UIKit

final class NeoMediaToolsPage: NeoPage {
  override var defersOpeningContent: Bool { true }
  private final class Pane {
    var recording: NeoRecording?, file: Int?, tracks: [NeoManagedTrack] = []
    var loading = false, error: String?, keyword = "", offset = 0, more = false
    var results: [NeoRecording] = []
    var read: Task<Void,Never>?, search: Task<Void,Never>?
    var generation = 0, searchGeneration = 0
  }
  private struct Pending {
    let side: Int, source: Int, target: Int, track: NeoManagedTrack
    var title: String
  }
  private let api: NeoAPI?, revision: Int, user: String, headers: [String:String]
  private let original: NeoRecording
  private let scroll = UIScrollView(), stack = UIStackView(), cards = UIStackView()
  private let notice = NeoStyle.label(size:14,muted:true), status = NeoStyle.label(size:14)
  private let statusSpinner = UIActivityIndicatorView(style:.medium)
  private let panes = [Pane(),Pane()]
  private lazy var views = [NeoTrackPane(),NeoTrackPane()]
  private let retry = NeoStyle.button("状態を再確認") {}, execute = NeoStyle.button("移植を実行",filled:true) {}
  private var pending: Pending?, job: NeoMediaJob?, kind: NeoMediaEditKind = .transfer
  private var starting = false, enabled = false, stopped = false
  private var channels: [NeoChannel] = [], observer: NSObjectProtocol?
  private var keyboardObserver: NSObjectProtocol?
  private var start: Task<Void,Never>?, bootstrap: Task<Void,Never>?
  private var affected: Set<Int> = [], lastNoticeJob: String?
  private var configured = false
  private var selectionRevision = 0
  private var noticeBox: UIView?, statusBox: UIView?
  private var gateError = false, statusError = false
  private var contentWidth: NSLayoutConstraint?, contentLeft: NSLayoutConstraint?, contentRight: NSLayoutConstraint?, contentTop: NSLayoutConstraint?

  init(recording: NeoRecording, shell: NeoShell) {
    original = recording; api = shell.api; revision = shell.api?.identityRevision ?? -1
    user = shell.api?.viewer ?? "master"; headers = shell.api?.profileHeaders ?? [:]
    super.init(title:"字幕移植",shell:shell)
  }
  required init?(coder: NSCoder) { fatalError() }
  private var current: Bool { !stopped && shell?.api === api && api?.identityRevision == revision && api?.accountReady == true }
  private var processing: Bool { starting || job?.status == "running" }
  override func viewDidLoad() {
    super.viewDidLoad()
  }
  private func configureContent() {
    body.addSubview(scroll); scroll.delaysContentTouches = false; scroll.keyboardDismissMode = .interactive
    stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
    let width = stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-24); width.priority = .defaultHigh; contentWidth = width
    let left = stack.leadingAnchor.constraint(greaterThanOrEqualTo:scroll.contentLayoutGuide.leadingAnchor,constant:12), right = stack.trailingAnchor.constraint(lessThanOrEqualTo:scroll.contentLayoutGuide.trailingAnchor,constant:-12), top = stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:12)
    contentLeft = left; contentRight = right; contentTop = top
    NSLayoutConstraint.activate([left,right,top,stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),width,stack.widthAnchor.constraint(lessThanOrEqualToConstant:1700),stack.centerXAnchor.constraint(equalTo:scroll.frameLayoutGuide.centerXAnchor),scroll.contentLayoutGuide.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor)])
    notice.numberOfLines = 0; notice.text = "読み込み中…"; let intro = banner(notice,icon:"SubtitlesOutlined"); noticeBox = intro; stack.addArrangedSubview(intro)
    cards.axis = .vertical; cards.spacing = 16; stack.addArrangedSubview(cards)
    for side in panes.indices {
      let pane = views[side]; pane.sourceIsLeft = side == 0; cards.addArrangedSubview(pane)
      pane.onSearch = { [weak self] in self?.search(side,keyword:$0,more:false) }
      pane.onMoreSearch = { [weak self] in guard let self else { return }; self.search(side,keyword:self.panes[side].keyword,more:true) }
      pane.onSelectRecording = { [weak self] in self?.select(side,recording:$0) }
      pane.onSelectFile = { [weak self] in self?.selectFile(side,$0) }
      pane.onQueue = { [weak self] in self?.queue(side,$0) }
      pane.onRename = { [weak self] track,title in self?.begin(.rename,side:side,track:track,title:title) }
      pane.onReorder = { [weak self] in self?.begin(.reorder,side:side,order:$0) }
      pane.onPendingTitle = { [weak self] in self?.pending?.title = $0; self?.updateExecute() }
      pane.onPendingCancel = { [weak self] in self?.pending = nil; self?.render() }
      pane.onRetry = { [weak self] in self?.loadTracks(side) }
      pane.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
    }
    status.numberOfLines = 0; let progress = banner(status); statusBox = progress; stack.addArrangedSubview(progress)
    statusSpinner.hidesWhenStopped = true; statusSpinner.color = UIColor(red:79/255,green:195/255,blue:247/255,alpha:1)
    statusSpinner.widthAnchor.constraint(equalToConstant:20).isActive = true; statusSpinner.heightAnchor.constraint(equalToConstant:20).isActive = true
    (progress as? UIStackView)?.insertArrangedSubview(statusSpinner,at:0)
    retry.addAction(UIAction { [weak self] _ in self?.resumeWatch() },for:.touchUpInside); stack.addArrangedSubview(retry)
    retry.isHidden = true
    let footer = UIStackView(); footer.spacing = 8; footer.addArrangedSubview(UIView())
    footer.addArrangedSubview(NeoStyle.button("戻る") { [weak self] in self?.shell?.goBack() })
    execute.addAction(UIAction { [weak self] _ in self?.transfer() },for:.touchUpInside)
    execute.setImage(NeoIcon.image("SubtitlesOutlined"),for:.normal); execute.titleEdgeInsets = UIEdgeInsets(top:0,left:8,bottom:0,right:0)
    execute.heightAnchor.constraint(equalToConstant:42).isActive = true; execute.widthAnchor.constraint(greaterThanOrEqualToConstant:112).isActive = true
    footer.addArrangedSubview(execute); stack.addArrangedSubview(footer)
    observer = NotificationCenter.default.addObserver(forName:.neoAccountChanged,object:nil,queue:.main) { [weak self] _ in
      guard let self, !self.current else { return }; self.stopped = true; self.cancelReads(); self.start?.cancel()
      self.notice.text = "アクティブユーザーが変更されました。録画詳細から開き直してください。"; self.enabled = false
      self.status.text = nil; self.retry.isHidden = true; self.pending = nil; self.render()
    }
    keyboardObserver = NotificationCenter.default.addObserver(forName:UIResponder.keyboardWillChangeFrameNotification,object:nil,queue:.main) { [weak self] note in self?.keyboardChanged(note) }
    render()
  }
  override func buildOpeningContent() async {
    if !configured { configureContent(); configured = true }
    await NeoContentFrame.next()
    guard let api, current, !Task.isCancelled else { return }
    do {
      let config = try await api.configuration(); guard current, !Task.isCancelled else { return }
      guard config.developerMode == true else { gateError = true; notice.text = "この機能はdeveloperModeでのみ利用できます。"; render(); return }
      enabled = true; notice.text = "映像・音声を再エンコードせず、選択した字幕トラックを別のMKVへコピーしたり、既存の字幕名や順序を変更したりできます。処理中は対象ファイルを再生・変更しないでください。"
      let record = try await api.recording(original.id,refresh:true); guard current, !Task.isCancelled else { return }
      select(0,recording:record)
      bootstrap = Task { [weak self] in
        if let channels = try? await api.channels(), let self, self.current, !Task.isCancelled {
          self.channels = channels
          for side in self.panes.indices where !self.panes[side].keyword.isEmpty { self.search(side,keyword:self.panes[side].keyword,more:false) }
        }
      }
    } catch { if current { gateError = true; notice.text = error.localizedDescription } }
    render()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); scroll.frame = body.bounds
    let viewport = view.window?.bounds.width ?? view.bounds.width, padding: CGFloat = viewport >= 900 ? 24 : 12
    contentLeft?.constant = padding; contentRight?.constant = -padding; contentTop?.constant = padding; contentWidth?.constant = -2*padding
    let axis: NSLayoutConstraint.Axis = viewport >= 1200 ? .horizontal : .vertical
    if cards.axis != axis { cards.axis = axis; cards.distribution = axis == .horizontal ? .fillEqually : .fill }
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    scroll.contentInset = .zero; scroll.verticalScrollIndicatorInsets = .zero
    if openingContentFinished, current, enabled { for side in panes.indices { loadTracks(side) } }
  }
  override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); cancelReads() }
  private func cancelReads() { bootstrap?.cancel(); for pane in panes { pane.read?.cancel(); pane.search?.cancel(); pane.generation += 1; pane.searchGeneration += 1; pane.loading = false } }
  private func render() {
    cards.isHidden = !enabled; execute.isHidden = !enabled
    styleBanner(noticeBox,label:notice,error:gateError)
    styleBanner(statusBox,label:status,error:statusError)
    if processing && !statusError { statusSpinner.startAnimating() } else { statusSpinner.stopAnimating() }
    statusBox?.isHidden = status.text?.isEmpty != false || (job?.status == "completed" && !starting && !statusError)
    for side in panes.indices {
      let pane = panes[side]
      let canQueue = enabled && current && !processing && pending == nil && pane.file != nil && panes[1-side].file != nil && pane.file != panes[1-side].file
      views[side].update(recording:pane.recording,fileID:pane.file,tracks:pane.tracks,loading:pane.loading,error:pane.error,processing:processing || !current,canQueue:canQueue,targetTitle:pending.flatMap { $0.side != side ? $0.title : nil })
    }
    updateExecute(); view.setNeedsLayout()
  }
  private func updateExecute() { execute.isEnabled = current && enabled && !processing && pending.map { NeoMediaTools.validTitle($0.title) } == true }
  private func select(_ side: Int, recording: NeoRecording?) {
    guard enabled, current else { return }
    selectionRevision += 1
    pending = nil; let pane = panes[side]; pane.recording = recording
    if !processing { job = nil; status.text = nil; retry.isHidden = true }
    pane.search?.cancel(); pane.searchGeneration += 1; pane.keyword = ""; pane.results = []; pane.more = false
    views[side].searchResults([],more:false,loading:false,error:nil,channels:[:])
    pane.file = NeoMediaTools.mkvFiles(recording).first?.id; pane.tracks = []; pane.error = nil
    loadTracks(side); render()
  }
  private func selectFile(_ side: Int, _ id: Int) {
    guard enabled, current, NeoMediaTools.mkvFiles(panes[side].recording).contains(where:{$0.id == id}) else { return }
    selectionRevision += 1
    if !processing { job = nil; status.text = nil; retry.isHidden = true }
    pending = nil; panes[side].file = id; panes[side].tracks = []; loadTracks(side); render()
  }
  private func loadTracks(_ side: Int) {
    let pane = panes[side]; pane.read?.cancel(); pane.generation += 1
    guard enabled, current, let api, let file = pane.file else { pane.loading = false; render(); return }
    let generation = pane.generation; pane.loading = true; pane.error = nil; render()
    let user = self.user, headers = self.headers
    pane.read = Task { [weak self] in
      do {
        let tracks = try await api.managedTracks(file,user:user,headers:headers)
        guard let self, self.current, !Task.isCancelled, pane.generation == generation, pane.file == file else { return }
        pane.tracks = tracks; pane.loading = false; self.render()
      } catch {
        guard let self, self.current, !Task.isCancelled, pane.generation == generation else { return }
        pane.loading = false; pane.error = "字幕一覧を取得できません: "+error.localizedDescription; self.render()
      }
    }
  }
  private func search(_ side: Int, keyword: String, more: Bool) {
    guard enabled, current, let api else { return }
    let pane = panes[side]
    if more && !pane.more { return }
    pane.search?.cancel(); pane.searchGeneration += 1; let generation = pane.searchGeneration
    if !more { pane.offset = 0; pane.results = []; pane.keyword = keyword }
    guard !keyword.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
      pane.more = false; views[side].searchResults([],more:false,loading:false,error:nil,channels:[:]); return
    }
    let offset = more ? pane.offset+30 : 0
    views[side].searchResults(pane.results,more:pane.more,loading:true,error:nil,channels:Dictionary(channels.map { ($0.id,$0.name) },uniquingKeysWith:{$1}))
    pane.search = Task { [weak self] in
      do {
        if !more { try await Task.sleep(nanoseconds:150_000_000) }
        guard let self, self.current, !Task.isCancelled else { return }
        let result = try await api.mediaSearch(keyword:keyword,offset:offset,channels:self.channels,user:self.user,headers:self.headers)
        guard self.current, !Task.isCancelled, pane.searchGeneration == generation else { return }
        var seen = Set<Int>(); pane.results = (pane.results+result.records).filter { seen.insert($0.id).inserted }.sorted { $0.startAt > $1.startAt }
        pane.more = result.more; pane.offset = offset
        self.views[side].searchResults(pane.results,more:result.more,loading:false,error:nil,channels:Dictionary(self.channels.map { ($0.id,$0.name) },uniquingKeysWith:{$1}))
      } catch {
        guard let self, self.current, !Task.isCancelled, pane.searchGeneration == generation else { return }
        if !more { pane.more = false }
        self.views[side].searchResults(pane.results,more:pane.more,loading:false,error:error.localizedDescription,channels:[:])
      }
    }
  }
  private func queue(_ side: Int, _ track: NeoManagedTrack) {
    guard current, !processing, pending == nil, let source = panes[side].file, let target = panes[1-side].file, source != target, panes[side].tracks.contains(track) else { return }
    job = nil; status.text = nil; statusError = false; retry.isHidden = true
    pending = Pending(side:side,source:source,target:target,track:track,title:track.name); render()
  }
  private func transfer() {
    guard let pending, panes[pending.side].file == pending.source, panes[1-pending.side].file == pending.target else { return }
    begin(.transfer,side:1-pending.side,track:pending.track,title:pending.title,source:pending.source)
  }
  private func begin(_ kind: NeoMediaEditKind, side: Int, track: NeoManagedTrack? = nil, title: String = "", order: [Int] = [], source: Int? = nil) {
    guard current, enabled, !processing, let api, let target = panes[side].file, let targetRecord = panes[side].recording else { return }
    if targetRecord.isProtected == true { showError("SubtitleTransferTargetIsProtected"); return }
    if kind == .reorder && !NeoMediaTools.validOrder(order,tracks:panes[side].tracks) { showError("SubtitleReorderTracksChanged"); return }
    if kind != .reorder && !NeoMediaTools.validTitle(title) { showError("字幕名を確認してください。"); return }
    self.kind = kind; affected = [targetRecord.id]
    if let sourceRecord = panes.first(where:{$0.file == source})?.recording { affected.insert(sourceRecord.id) }
    let checkedFile = source ?? target
    let expectedTracks = panes.first(where:{$0.file == checkedFile})?.tracks ?? []
    let selectionAtStart = selectionRevision
    starting = true; statusError = false; status.text = "処理を開始しています…"; retry.isHidden = true; render()
    start = Task { [self] in
      defer { starting = false; start = nil; if current { render() } }
      do {
        let fresh = try await api.managedTracks(checkedFile,user:user,headers:headers)
        guard current, !Task.isCancelled else { return }
        guard selectionRevision == selectionAtStart else { throw NeoError("選択が変更されたため、処理を開始しませんでした。") }
        guard fresh == expectedTracks, track.map({ fresh.contains($0) }) ?? true else {
          for side in panes.indices { loadTracks(side) }
          throw NeoError("字幕一覧が変更されました。一覧を確認してからもう一度操作してください。")
        }
        let accepted = try await api.startMediaEdit(kind,target:target,source:source,index:track?.subtitleIndex,title:title,order:order,user:user,headers:headers)
        // A server job survives navigation; the API owns its status watch.
        guard current, !Task.isCancelled else { for id in affected { api.recordingChanged(id) }; return }
        job = accepted; resumeWatch()
      } catch { if current, !Task.isCancelled { showError(error.localizedDescription) } }
    }
  }
  private func resumeWatch() {
    guard current, let api, let job else { return }; retry.isHidden = true
    api.watchMediaJob(job,recordings:affected,revision:revision,user:user,headers:headers) { [weak self] job,error in
      guard let self, self.current else { return }; self.job = job
      self.statusError = error != nil || job.status == "failed"
      if let error { self.status.text = "処理状況を取得できません: "+error+"\nサーバー側の処理は継続します。"; self.retry.isHidden = false }
      else if job.status == "running" { self.status.text = self.kind.progress+"するためMKVを再多重化しています。ファイルサイズによっては時間がかかります。この画面を閉じてもサーバー側の処理は継続します。" }
      else {
        self.retry.isHidden = true
        self.status.text = job.status == "completed" ? self.kind.completed : NeoMediaTools.errorMessage(job.error ?? "不明なエラー")
        if job.status == "completed" {
          if self.kind == .transfer { self.pending = nil }
          for side in self.panes.indices { self.loadTracks(side) }
        }
        if self.lastNoticeJob != job.id { self.lastNoticeJob = job.id; self.shell?.recordingNotice(self.status.text ?? "",error:job.status != "completed") }
      }
      self.render()
    }
  }
  private func showError(_ text: String) { statusError = true; status.text = NeoMediaTools.errorMessage(text); retry.isHidden = true; shell?.recordingNotice(status.text ?? "",error:true); render() }
  private func banner(_ label: UILabel, icon: String? = nil) -> UIView {
    let box = UIStackView(); box.spacing = 12; box.alignment = .top; box.isLayoutMarginsRelativeArrangement = true
    box.directionalLayoutMargins = NSDirectionalEdgeInsets(top:8,leading:16,bottom:8,trailing:16); box.layer.cornerRadius = 4
    if let icon { let image = UIImageView(image:NeoIcon.image(icon)); image.tintColor = UIColor(red:79/255,green:195/255,blue:247/255,alpha:1); image.widthAnchor.constraint(equalToConstant:22).isActive = true; image.heightAnchor.constraint(equalToConstant:22).isActive = true; box.addArrangedSubview(image) }
    box.addArrangedSubview(label); return box
  }
  private func styleBanner(_ box: UIView?, label: UILabel, error: Bool) {
    box?.backgroundColor = error ? UIColor(red:22/255,green:11/255,blue:11/255,alpha:1) : UIColor(red:7/255,green:19/255,blue:24/255,alpha:1)
    label.textColor = error ? UIColor(red:244/255,green:199/255,blue:199/255,alpha:1) : UIColor(red:184/255,green:231/255,blue:251/255,alpha:1)
  }
  private func keyboardChanged(_ note: Notification) {
    guard viewIfLoaded?.window != nil, let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
    let rect = view.convert(value.cgRectValue,from:nil), visible = scroll.convert(scroll.bounds,to:view)
    let overlap = visible.intersection(rect); let inset = overlap.isNull ? 0 : overlap.height
    scroll.contentInset.bottom = inset; scroll.verticalScrollIndicatorInsets.bottom = inset
    func focused(_ node: UIView) -> UIView? { if node.isFirstResponder { return node }; return node.subviews.lazy.compactMap { focused($0) }.first }
    if inset > 0, let field = focused(scroll) { scroll.scrollRectToVisible(field.convert(field.bounds,to:scroll).insetBy(dx:0,dy:-16),animated:true) }
  }
#if targetEnvironment(simulator)
  var smokeEnabled: Bool { enabled }
  var smokeBusy: Bool { processing }
  var smokeStatus: String { status.text ?? "" }
  var smokePanes: [NeoTrackPane] { views }
  func smokeTracks(_ side: Int) -> [NeoManagedTrack] { panes[side].tracks }
  func smokeExecute() { execute.sendActions(for:.touchUpInside) }
  var smokeCanExecute: Bool { execute.isEnabled }
#endif
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }; bootstrap?.cancel(); start?.cancel(); for pane in panes { pane.read?.cancel(); pane.search?.cancel() } }
}
