import UIKit

// The common player calls this for both VLC and Aether, including PiP. A seek
// never adds watched time. With history enabled, use the server's cumulative
// watchedSeconds, exactly as RecordedWatchPage does after each history PUT.
@MainActor @objc(NeoAnnictPlayback)
final class NeoAnnictPlayback: NSObject {
  private let api: NeoAPI, recordingID: Int, revision: Int, historyEnabled: Bool
  private let user: String, headers: [String:String]
  private var clock = NeoWatchClock(), started = false, finished = false
  private var drainOnFinish = false, acknowledgedLocal = 0.0
  private var cumulative = 0.0, duration = 0.0, baseline = 0.0
  private var lastAttempt = -Double.infinity
  private let retryDelay: UInt64
  private var episode: NeoAnnictEpisode?
  private var task: Task<Void,Never>?, baselineTask: Task<Void,Never>?
  private var observer: NSObjectProtocol?
  @objc private(set) var status = ""
  @objc var onChange: (() -> Void)?
  init(api: NeoAPI, recordingID: Int, retryDelay: UInt64 = 60_000_000_000) {
    self.api = api; self.recordingID = recordingID; revision = api.identityRevision; historyEnabled = !api.disablePlaybackHistory
    user = api.viewer; headers = api.profileHeaders
    self.retryDelay = retryDelay
    super.init()
    observer = NotificationCenter.default.addObserver(forName:.neoAccountChanged,object:nil,queue:.main) { [weak self] _ in self?.invalidate() }
    if NeoAnnictPreferences.mode == "progress" {
      baselineTask = Task { [weak self] in
        guard let self, current else { return }
        if let saved = try? await api.playback(recordingID,user:user), current {
          baseline = saved.watchedSeconds; cumulative = max(cumulative,saved.watchedSeconds); duration = max(duration,saved.duration); attempt()
        }
      }
    }
  }
  private var current: Bool { (!finished || drainOnFinish) && api.accountReady && api.identityRevision == revision }
  private var eligible: Bool {
    let watched = historyEnabled ? cumulative+max(0,clock.total-acknowledgedLocal) : cumulative
    return current && NeoAnnictPreferences.shouldRecord(started:started,watched:watched,duration:duration)
  }
  @objc func sample(_ position: Double, duration: Double, running: Bool, seeking: Bool, rate: Double) {
    guard current else { return }
    clock.sample(position:position,duration:duration,running:running,seeking:seeking,rate:rate,now:ProcessInfo.processInfo.systemUptime)
    started = started || (running && !seeking)
    self.duration = max(self.duration,clock.duration)
    if !historyEnabled { cumulative = baseline+clock.total }
    attempt()
  }
  @objc func historyProgress(_ watched: Double, duration: Double, sessionWatched: Double = 0) {
    guard current, watched.isFinite, duration.isFinite else { return }
    cumulative = max(cumulative,watched); acknowledgedLocal = max(acknowledgedLocal,sessionWatched); self.duration = duration; attempt()
  }
  private func attempt() {
    guard eligible, task == nil, !(episode?.watched ?? false), ProcessInfo.processInfo.systemUptime-lastAttempt >= 60 else { return }
    lastAttempt = ProcessInfo.processInfo.systemUptime
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil; drainOnFinish = false; if finished { removeObserver() } }
      while eligible && !Task.isCancelled {
        do {
          let value = try await api.annictEpisode(recordingID,user:user,headers:headers)
          guard eligible, !Task.isCancelled else { return }; episode = value
          guard value.state == "matched", value.writeConfigured, !value.watched else { return }
          let result = try await api.annictEpisode(recordingID,method:"PUT",user:user,headers:headers)
          guard current, !Task.isCancelled else { return }; episode = result; status = ""; onChange?()
          NotificationCenter.default.post(name:.neoAnnictChanged,object:api,userInfo:["recordingID":recordingID]); return
        } catch {
          guard current, !Task.isCancelled else { return }
          status = "Annictへ自動記録できませんでした。"; onChange?()
          if finished { return }
          // Match the Web's bounded retry cadence; playback remains independent.
          try? await Task.sleep(nanoseconds:retryDelay)
        }
      }
    }
  }
  @objc func finish() {
    // Like fetch keepalive on the Web, an already eligible write may complete
    // when closing the player. A user/profile switch always cancels it instead.
    drainOnFinish = eligible && task != nil; finished = true; baselineTask?.cancel(); onChange = nil
    if !drainOnFinish { task?.cancel(); removeObserver() }
  }
  private func invalidate() {
    drainOnFinish = false; finished = true; task?.cancel(); baselineTask?.cancel(); onChange = nil; removeObserver()
  }
  private func removeObserver() {
    if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
  }
  deinit { task?.cancel(); baselineTask?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}

// RecordedDetailPage's compact episode/mark pair. Matching, record ownership,
// final-episode handling and rule ownership remain enforced by the server.
@MainActor final class NeoAnnictHeader: UIView {
  private let api: NeoAPI, recordingID: Int
  private weak var host: UIViewController?
  private let episodeButton = UIButton(type:.system), markButton = UIButton(type:.system), divider = UIView()
  private var value: NeoAnnictEpisode?, task: Task<Void,Never>?, observers: [NSObjectProtocol] = []
  private var revision = -1
  var onVisibility: ((Bool) -> Void)?
  init(api: NeoAPI, recordingID: Int, host: UIViewController) {
    self.api = api; self.recordingID = recordingID; self.host = host; super.init(frame:.zero)
    layer.cornerRadius = 6; layer.borderWidth = 1; clipsToBounds = true
    episodeButton.titleLabel?.font = .systemFont(ofSize:14,weight:.medium)
    markButton.setImage(NeoIcon.image("CheckCircleOutlineOutlined"),for:.normal)
    episodeButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      if self.value?.state == "pending" || self.value == nil { self.load(method:"POST") }
      else if let id = self.value?.annictId { UIApplication.shared.open(URL(string:"https://annict.com/works/\(id)")!) }
    },for:.touchUpInside)
    markButton.addAction(UIAction { [weak self] _ in self?.markOrUnmark() },for:.touchUpInside)
    [episodeButton,markButton,divider].forEach(addSubview)
    for name in [Notification.Name.neoAccountChanged,.neoAnnictChanged] {
      observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
        guard let self else { return }
        if let changed = note.object as? NeoAPI, changed !== self.api { return }
        if name == .neoAccountChanged { self.task?.cancel(); self.value = nil; self.onVisibility?(false) }
        if self.host?.viewIfLoaded?.window != nil { self.load() }
      })
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews(); episodeButton.frame = CGRect(x:4,y:3,width:max(0,bounds.width-46),height:34)
    markButton.frame = CGRect(x:bounds.width-38,y:3,width:34,height:34); divider.frame = CGRect(x:bounds.width-42,y:4,width:1,height:32)
  }
  func load(method: String = "GET") {
    task?.cancel(); revision = api.identityRevision; let attempt = revision
    let user = api.viewer, headers = api.profileHeaders
    guard api.accountReady else { onVisibility?(false); return }
    if method == "GET", let cached = api.cachedAnnictEpisode(recordingID) {
      value = cached; render(); return
    }
    markButton.isEnabled = false
    task = Task { [weak self] in
      guard let self, !Task.isCancelled, api.identityRevision == attempt else { return }
      do {
        let info = try await api.annictEpisode(recordingID,method:method,user:user,headers:headers)
        guard !Task.isCancelled, api.identityRevision == attempt else { return }
        value = info; render()
        if method == "PUT" || method == "DELETE" { NotificationCenter.default.post(name:.neoAnnictChanged,object:api,userInfo:["recordingID":recordingID]) }
      } catch is CancellationError { return
      } catch {
        guard !Task.isCancelled, api.identityRevision == attempt else { return }
        if method != "GET" { render(); hostAlert("Annictの記録を更新できませんでした。"); return }
        episodeButton.setTitle("Annict ⚠",for:.normal); episodeButton.accessibilityLabel = "Annict連携情報を再取得"
        layer.borderColor = UIColor(red:1,green:167/255,blue:38/255,alpha:1).cgColor
        markButton.isEnabled = false; onVisibility?(true)
      }
    }
  }
  private func render() {
    guard let value else { onVisibility?(false); return }
    onVisibility?(value.state == "pending" || value.state == "matched")
    let pending = value.state == "pending"
    let main = pending ? UIColor(red:1,green:167/255,blue:38/255,alpha:1) : value.watched ? NeoStyle.success : UIColor(red:41/255,green:182/255,blue:246/255,alpha:1)
    let light = pending ? UIColor(red:1,green:183/255,blue:77/255,alpha:1) : value.watched ? UIColor(red:129/255,green:199/255,blue:132/255,alpha:1) : UIColor(red:79/255,green:195/255,blue:247/255,alpha:1)
    layer.borderColor = main.cgColor; divider.backgroundColor = main; episodeButton.tintColor = light; markButton.tintColor = light
    episodeButton.setTitle(value.state == "pending" ? "Annict 再照合" : value.label,for:.normal)
    episodeButton.accessibilityLabel = "Annict \(value.label) \(value.episodeTitle ?? "")"
    let reasons = ["program_not_found":"放送局と放送開始日時が一致するAnnictの放送予定がまだ見つかりません。",
      "program_ambiguous":"一致候補が複数あるため、安全のため自動確定していません。",
      "episode_unavailable":"放送予定は見つかりましたが、Annictにエピソードがまだ登録されていません。",
      "annict_unavailable":"Annict APIへ接続できなかったため照合を保留しています。"]
    episodeButton.accessibilityHint = pending ? reasons[value.pendingReason ?? ""] ?? "Annictエピソードとの照合を保留しています。" : value.episodeTitle
    markButton.accessibilityLabel = value.watched ? "Annictの視聴記録を削除" : "この話を見たとAnnictへ記録"
    markButton.isEnabled = value.state == "matched" && value.writeConfigured && (!value.watched || value.canUnwatch)
    markButton.isHidden = value.state != "matched"; divider.isHidden = markButton.isHidden
  }
  private func hostAlert(_ message: String) {
    let dialog = UIAlertController(title:nil,message:message,preferredStyle:.alert)
    dialog.addAction(UIAlertAction(title:"閉じる",style:.cancel)); host?.present(dialog,animated:true)
  }
  private func markOrUnmark() {
    guard let value, value.writeConfigured, api.identityRevision == revision else { return }
    if !value.watched { load(method:"PUT"); return }
    guard value.canUnwatch else { return }
    let confirm = UIAlertController(title:"Annictの視聴記録を削除",message:"この話を見ていない状態へ戻しますか？",preferredStyle:.alert)
    confirm.addAction(UIAlertAction(title:"キャンセル",style:.cancel))
    confirm.addAction(UIAlertAction(title:"削除",style:.destructive) { [weak self] _ in self?.load(method:"DELETE") })
    host?.present(confirm,animated:true)
  }
#if targetEnvironment(simulator)
  var smokeEpisode: NeoAnnictEpisode? { value }
  func smokeMark() { markOrUnmark() }
  func smokeUnmark() { if value?.canUnwatch == true { load(method:"DELETE") } }
  func smokeRematch() { episodeButton.sendActions(for:.touchUpInside) }
#endif
  deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}
