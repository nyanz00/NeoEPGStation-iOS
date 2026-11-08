import UIKit
import UniformTypeIdentifiers

@MainActor final class NeoGOPTrialController: UIViewController, UIDocumentPickerDelegate {
  private var plan: NeoGOPBenchmark.Plan?, files: [(URL,NeoGOPBenchmark.Profile)] = []
  private var reports: [[String:Any]] = [], fileIndex = 0, running = false
  private let status = NeoStyle.label("測定計画JSONと比較する動画を「ファイル」から選択してください。動画はアプリ内へコピーされます。",size:15)
  private let rounds = UIStepper(), roundLabel = NeoStyle.label(), startButton = UIButton(type:.system)
  private let stack = UIStackView()
  private weak var activePlayer: NeoPlayerController?
  private var batchStatus = "idle", batchID = "", presentationCount = 0, inputLoadCount = 0
  private var onBatchFinished: (([String:Any]) -> Void)?
  static var resultURL: URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("gop-seek-benchmark.json") }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = NeoStyle.background; title = "GOP シーク測定"
    stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
    status.numberOfLines = 0
    rounds.minimumValue = 1; rounds.maximumValue = 3; rounds.value = 1
    rounds.addAction(UIAction { [weak self] _ in self?.refresh() },for:.valueChanged)
    startButton.setTitle("新しい測定を開始",for:.normal); startButton.addAction(UIAction { [weak self] _ in self?.begin() },for:.touchUpInside)
    let select = NeoStyle.button("動画と測定計画JSONを選択") { [weak self] in
      guard let self else { return }; let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.data],asCopy:true); picker.allowsMultipleSelection = true; picker.delegate = self; self.present(picker,animated:true)
    }
    let share = NeoStyle.button("測定結果を共有") { [weak self] in self?.export() }
    let close = NeoStyle.button("閉じる") { [weak self] in self?.dismiss(animated:true) }
    [NeoStyle.label("GOP シーク測定",size:22,bold:true),status,select,roundLabel,rounds,startButton,share,close].forEach(stack.addArrangedSubview)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:20)])
    if let data = try? Data(contentsOf:Self.resultURL), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { reports = object["runs"] as? [[String:Any]] ?? [] }
    refresh()
  }
  private func refresh() {
    var total = 0
    if let plan { for (_,profile) in files { total += plan.targets(for:profile).count*2*Int(rounds.value) } }
    roundLabel.text = "測定合計 \(total)回＋各動画ウォームアップ2回"
    startButton.isEnabled = !files.isEmpty && plan != nil && !running
  }
  func documentPicker(_ controller: UIDocumentPickerViewController,didPickDocumentsAt urls: [URL]) {
    do {
      if let json = urls.first(where: { $0.pathExtension.lowercased() == "json" }) {
        let data = try Data(contentsOf:json); guard data.count < 4*1024*1024 else { throw failure("測定計画が大きすぎます。") }
        let value = try JSONDecoder().decode(NeoGOPBenchmark.Plan.self,from:data); guard value.valid else { throw failure("測定計画が無効です。") }; plan = value
      }
      guard let plan else { throw failure("PCで作成した測定計画JSONも一緒に選択してください。") }
      var selected: [(URL,NeoGOPBenchmark.Profile)] = []
      for url in urls where url.pathExtension.lowercased() != "json" {
        let bytes = (try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let profile = plan.profiles.first(where: { $0.bytes == bytes }), !selected.contains(where: { $0.1.bytes == bytes }) else { throw failure("動画が測定計画と一致しないか、重複しています。") }
        selected.append((url,profile))
      }
      guard !selected.isEmpty else { throw failure("動画も一緒に選択してください。") }
      files = selected.sorted { ($0.1.keys.count,$0.1.label) > ($1.1.keys.count,$1.1.label) }
      status.text = files.map { $0.1.label }.joined(separator:"、")+"\n通常のエーテル画面・音声あり。字幕・コメントなし、チェックポイントなしで統一します。コピー時間と準備シークは測定に含めません。測定中はアプリを前面に置いてください。"
    } catch { status.text = error.localizedDescription; files = [] }
    refresh()
  }
  private func failure(_ message: String) -> NSError { NSError(domain:"GOP",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
  private func begin(shuffle: Bool = true) {
    guard plan != nil, !files.isEmpty, !running else { return }
    if shuffle { files.shuffle() }; reports = []; fileIndex = 0; running = true; batchStatus = "running"
    batchID = UUID().uuidString; presentationCount = 0; inputLoadCount = 0
    refresh(); playNext()
  }
  private func playNext() {
    guard running, let plan else { return }
    guard fileIndex < files.count else {
      running = false; batchStatus = "completed"; save()
      activePlayer?.gopBenchmarkClose(); refresh(); return
    }
    let (url,profile) = files[fileIndex]
    let object = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(profile))) as? [String:Any] ?? [:]
    let configuration: [String:Any] = ["profile":object,"targets":plan.targets(for:profile),"rounds":Int(rounds.value),"batchManaged":true,"batchID":batchID]
    inputLoadCount += 1
    if let owner = activePlayer { owner.gopBenchmarkLoad(url,configuration:configuration); return }
    let owner = NeoPlayerController(url:url,title:"GOP シーク測定 · "+profile.label,username:"",password:"",networkCaching:5000)
    owner.aetherOptions = ["checkpointEnabled":false,"gopBenchmark":true,"gopTolerance":max(0.03,2/profile.fps)]
    owner.recordingContext = ["videoFileType":"encoded","disableHistory":true]
    owner.gopBenchmarkConfiguration = configuration
    activePlayer = owner; presentationCount += 1
    owner.onGOPBenchmarkResult = { [weak self,weak owner] result in
      guard let self, let owner else { return }
      self.reports.append(result); self.fileIndex += 1
      if result["status"] as? String != "completed" { self.running = false; self.batchStatus = "cancelled" }
      self.save()
      let token = self.batchID
      DispatchQueue.main.async { [weak self,weak owner] in
        guard let self, let owner, self.batchID == token, self.activePlayer === owner else { return }
        if self.running { self.playNext() } else { owner.gopBenchmarkClose() }
      }
    }
    owner.onClose = { [weak self] in
      guard let self else { return }
      self.activePlayer = nil
      if self.running { self.batchStatus = "cancelled" }; self.running = false
      self.status.text = self.batchStatus == "completed" ? "測定終了。結果を共有できます。" : "測定を中断しました。途中結果を共有できます。"
      self.save(); self.refresh()
      let callback = self.onBatchFinished; self.onBatchFinished = nil; callback?(self.batchReport())
    }
    owner.modalPresentationStyle = .fullScreen; present(owner,animated:true)
  }
  private func batchReport() -> [String:Any] {
    ["schema":2,"status":batchStatus,"batchID":batchID,"runs":reports,"presentationCount":presentationCount,"inputLoadCount":inputLoadCount]
  }
  private func save() {
    if let data = try? JSONSerialization.data(withJSONObject:batchReport(),options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:Self.resultURL,options:.atomic) }
  }
#if targetEnvironment(simulator)
  func runSmokeImport(_ urls: [URL], completion: @escaping ([String:Any]) -> Void) {
    loadViewIfNeeded(); onBatchFinished = completion
    documentPicker(UIDocumentPickerViewController(forOpeningContentTypes:[.data],asCopy:true),didPickDocumentsAt:urls)
    guard !files.isEmpty else { completion(["status":"import-failed"]); return }
    // Reproduce the observed 1080p MP4 -> 1080p MKV -> small MKV handover.
    let order = ["synthetic-native-2","synthetic-native-1","synthetic-native-3"]
    files.sort { (order.firstIndex(of:$0.1.label) ?? 99) < (order.firstIndex(of:$1.1.label) ?? 99) }
    begin(shuffle:false)
  }
#endif
  private func export() {
    var urls = [URL](); if FileManager.default.fileExists(atPath:Self.resultURL.path) { urls.append(Self.resultURL) }
    if FileManager.default.fileExists(atPath:NeoGOPPlaybackRun.partialURL.path) { urls.append(NeoGOPPlaybackRun.partialURL) }
    guard !urls.isEmpty else { status.text = "まだ測定結果がありません。"; return }
    let share = UIActivityViewController(activityItems:urls,applicationActivities:nil); share.popoverPresentationController?.sourceView = stack; present(share,animated:true)
  }
}

@objc(NeoGOPPlaybackRun) @MainActor final class NeoGOPPlaybackRun: NSObject {
  @objc var active: Bool { !done }
  static var partialURL: URL { NeoGOPTrialController.resultURL.deletingLastPathComponent().appendingPathComponent("gop-seek-current.json") }
  private weak var player: NeoPlayerController?
  private let configuration: [String:Any]
  private var task: Task<Void,Never>?, done = false, events: [[String:Any]] = [], rows: [[String:Any]] = [], report: [String:Any] = [:]
  private let badge = UILabel()
  private var oldIdle = false
  private var references: [NeoGOPBenchmark.Reference] = []
  @objc(initWithPlayer:configuration:) init(player: NeoPlayerController,configuration: [String:Any]) { self.player = player; self.configuration = configuration; super.init() }
  @objc func observe(_ event: [String:Any]) { if !done { events.append(event); if events.count > 16 { events.removeFirst(events.count-16) } } }
  @objc func start() {
    guard task == nil, !done, let player else { return }
    oldIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
    player.gopBenchmarkPrepare()
    badge.textColor = .white; badge.backgroundColor = UIColor.black.withAlphaComponent(0.65); badge.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium); badge.numberOfLines = 2; badge.isUserInteractionEnabled = false; badge.translatesAutoresizingMaskIntoConstraints = false
    player.view.addSubview(badge)
    NSLayoutConstraint.activate([badge.centerXAnchor.constraint(equalTo:player.view.centerXAnchor),badge.topAnchor.constraint(equalTo:player.view.safeAreaLayoutGuide.topAnchor,constant:52),badge.widthAnchor.constraint(lessThanOrEqualTo:player.view.widthAnchor,multiplier:0.8)])
    task = Task { [weak self] in guard let self else { return }; await self.run() }
  }
  private func state() -> [String:Any] { player?.gopBenchmarkState() ?? [:] }
  private func check() throws {
    try Task.checkCancellation(); let s = state()
    var reason: String?
    if done || s["closing"] as? Bool == true { reason = "player-closing" }
    else if s["foreground"] as? Bool != true { reason = "not-foreground" }
    else if s["pip"] as? Bool == true { reason = "pip-entered" }
    else if s["failed"] as? Bool == true { reason = "playback-failed-or-recovering" }
    else if s["playing"] as? Bool != true { reason = "playback-paused" }
    if let reason { report["failureState"] = s; throw error(reason) }
  }
  private func error(_ message: String) -> NSError { NSError(domain:"GOP",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
  private func run() async {
    do {
      let data = try JSONSerialization.data(withJSONObject:configuration["profile"] ?? [:]), profile = try JSONDecoder().decode(NeoGOPBenchmark.Profile.self,from:data)
      let targets = configuration["targets"] as? [Double] ?? [], rounds = configuration["rounds"] as? Int ?? 1
      guard (1...3).contains(rounds), NeoGOPBenchmark.Plan(schema:1,targets:targets,profiles:[profile]).valid else { throw error("invalid-plan") }
      references = profile.references ?? []
      report = ["schema":1,"label":profile.label,"bytes":profile.bytes,"fps":profile.fps,"keys":profile.keys,
        "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "","os":UIDevice.current.systemVersion,"device":UIDevice.current.model,
        "local":true,"checkpoint":false,"audio":true,"comments":false,"subtitles":false,"pollIntervalMs":1000/60.0,"targetToleranceSeconds":max(0.03,2/profile.fps),
        "timing":"normal-controller-seek-entry-to-displayed-target-picture","engineCompletionMeaning":"engine seek return, independent of displayed picture",
        "referenceReadback":"32x18 luma; MAE <= 9/255, correlation >= 0.985; unchanged/flat pictures excluded"]
      report["startedAt"] = ISO8601DateFormatter().string(from:Date())
      report["batchID"] = configuration["batchID"]
      report["targets"] = targets
      report["referenceCount"] = references.count
      badge.text = "GOP測定：再生準備中…"
      for _ in 0..<1500 {
        try Task.checkCancellation()
        let s = state()
        if s["failed"] as? Bool == true { try check() }
        // The first startup picture may precede the audio/display clock being
        // settled. Confirm moving presentation before the first warmup seek;
        // startup itself is not part of the seek benchmark.
        let samples = s["displayedSamples"] as? Int ?? 0, time = s["time"] as? Double ?? 0
        if s["ready"] as? Bool == true && s["seekable"] as? Bool == true &&
          s["playing"] as? Bool == true && s["buffering"] as? Bool != true && samples >= 3 && time >= 0.25 && player?.view.window != nil { break }
        try await Task.sleep(nanoseconds:20_000_000)
      }
      try check(); let s = state()
      guard s["ready"] as? Bool == true, s["seekable"] as? Bool == true, s["checkpointEnabled"] as? Bool == false,
        (s["displayedSamples"] as? Int ?? 0) >= 3, (s["time"] as? Double ?? 0) >= 0.25,
        let duration = s["duration"] as? Double, abs(duration-profile.duration)<1 else { throw error("media-duration-or-route-mismatch") }
      report["initialState"] = s
      if references.isEmpty && s["displayTimestampAvailable"] as? Bool != true {
        throw error("displayed-timestamp-unavailable-on-this-route")
      }
      let measured = NeoGOPBenchmark.steps(targets,rounds:rounds), warmup = Array(measured.prefix(2)), steps = warmup+measured
      var failures = 0
      for (index,step) in steps.enumerated() {
        try check(); badge.text = index < warmup.count ? "GOP測定：ウォームアップ" : "GOP測定 \(index-warmup.count+1)/\(measured.count) · \(step.forward ? "送り" : "戻し")"
        let staging = try await seek(step.stage)
        if staging["status"] as? String == "ambiguous-image" {
          var skipped = staging; skipped["status"] = "ambiguous-preparation"; skipped["forward"] = step.forward
          skipped["round"] = step.round; skipped["sampleKind"] = index < warmup.count ? "warmup" : "measured"
          rows.append(skipped); save("running"); continue
        }
        guard staging["status"] as? String == "verified" else { report["preparationFailure"] = staging; report["failureState"] = state(); throw error("preparation-picture-not-verified") }
        try await Task.sleep(nanoseconds:300_000_000); try check()
        var row = try await seek(step.target)
        row["forward"] = step.forward; row["round"] = step.round; row["sampleKind"] = index < warmup.count ? "warmup" : "measured"
        row["keySeconds"] = profile.key(before:step.target); row["distanceFromKey"] = profile.key(before:step.target).map { step.target-$0 }
        row["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        row["viewportWidth"] = state()["width"]; row["viewportHeight"] = state()["height"]
        if let point = profile.points?.first(where: { abs($0.target-step.target)<0.0001 }) {
          row["group"] = point.group; row["section"] = point.section; row["nextKeySeconds"] = point.nextKey
        }
        rows.append(row); save("running")
        failures = ["verified","ambiguous-image"].contains(row["status"] as? String ?? "") ? 0 : failures+1
        if failures >= 3 { throw error("three-unverified-results") }
        try await Task.sleep(nanoseconds:300_000_000)
      }
      finish("completed",reason:nil); player?.gopBenchmarkFinish()
    } catch {
      report["failureState"] = state()
      finish("cancelled",reason:error.localizedDescription)
      if player?.view.window != nil { player?.gopBenchmarkFinish() }
    }
  }
  private func seek(_ target: Double) async throws -> [String:Any] {
    try check(); events = []
    let candidates = references.filter { abs($0.target-target)<0.0001 }
    let previous = candidates.isEmpty ? nil : player?.gopBenchmarkLuma()
    let flatReferences = !candidates.isEmpty && candidates.allSatisfy { !NeoGOPBenchmark.imageMatches($0.luma,$0.luma) }
    let unchanged = flatReferences || (previous.map { image in candidates.contains { NeoGOPBenchmark.imageMatches(image,$0.luma) } } ?? false)
    let invoked = CACurrentMediaTime(), from = state()["time"] as? Double ?? -1
    player?.gopBenchmarkSeek(Int64((target*1000).rounded()))
    let serial = events.first(where: { $0["event"] as? String == "started" })?["serial"] as? Int
    guard let serial else { throw error("seek-rejected") }
    var picture: [String:Any]?, engine: [String:Any]?
    var matched: NeoGOPBenchmark.Reference?, matchedHost = 0.0, bestScore = Double.infinity, readbackMs = 0.0
    var bestImage: Data?
    for _ in 0..<800 {
      try check()
      picture = events.first { $0["serial"] as? Int == serial && $0["event"] as? String == "picture" }
      engine = events.first { $0["serial"] as? Int == serial && $0["event"] as? String == "engineCompletion" }
      if let picture {
        if picture["verified"] as? Bool != true, !candidates.isEmpty, !unchanged {
          let readbackStart = CACurrentMediaTime()
          if let image = player?.gopBenchmarkLuma() {
            for reference in candidates {
              let score = NeoGOPBenchmark.imageScore(image,reference.luma)
              if score < bestScore { bestScore = score; bestImage = image }
              if NeoGOPBenchmark.imageMatches(image,reference.luma) { matched = reference; matchedHost = CACurrentMediaTime(); break }
            }
          }
          readbackMs += (CACurrentMediaTime()-readbackStart)*1000
        }
        if picture["verified"] as? Bool == true || matched != nil || unchanged {
          if engine != nil || CACurrentMediaTime()-(picture["host"] as? Double ?? 0)>0.25 { break }
        }
      }
      try await Task.sleep(nanoseconds:10_000_000)
    }
    var row: [String:Any] = ["target":target,"from":from,"route":state()["route"] ?? "unknown","status":"timeout"]
    if let picture, let host = picture["host"] as? Double {
      let verified = picture["verified"] as? Bool == true
      row["status"] = verified ? "verified" : "unverified-picture-time"; row["picturePTS"] = picture["pts"]
      row["verification"] = picture["verification"]
      row[verified ? "displayMs" : "decodedPictureMs"] = (host-invoked)*1000
    }
    if picture?["verified"] as? Bool != true {
      row.removeValue(forKey:"picturePTS") // Queue PTS is not a displayed PTS.
      row["referenceReadbackMs"] = readbackMs
      if bestScore.isFinite { row["referenceBestMAE"] = bestScore }
      if let matched {
        row["status"] = "verified"; row["verification"] = "displayed-picture-reference"
        row["referencePTS"] = matched.pts; row["displayMs"] = (matchedHost-invoked)*1000
      } else if unchanged { row["status"] = "ambiguous-image" }
      else { row["referenceDebugLuma"] = bestImage?.base64EncodedString() }
    }
    if let host = engine?["host"] as? Double { row["engineCompletionMs"] = (host-invoked)*1000 }
    return row
  }
  private func save(_ status: String) {
    report["status"] = status; report["rows"] = rows
    report["summary"] = NeoGOPBenchmark.summary(rows.filter { $0["sampleKind"] as? String == "measured" })
    var groups: [String:Any] = [:]
    for name in ["near","middle","far"] { groups[name] = NeoGOPBenchmark.summary(rows.filter { $0["sampleKind"] as? String == "measured" && $0["group"] as? String == name }) }
    report["summaryByGroup"] = groups
    if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:Self.partialURL,options:.atomic) }
  }
  private func finish(_ status: String,reason: String?) {
    guard !done else { return }; done = true; report["reason"] = reason; save(status); badge.removeFromSuperview(); UIApplication.shared.isIdleTimerDisabled = oldIdle
    player?.onGOPBenchmarkResult?(report)
  }
  @objc func cancel(_ reason: String) { guard !done else { return }; task?.cancel(); report["failureState"] = state(); finish("cancelled",reason:reason) }
}
