import UIKit
import UniformTypeIdentifiers

@MainActor final class NeoGOPTrialController: UIViewController, UIDocumentPickerDelegate {
  private var plan: NeoGOPBenchmark.Plan?, files: [(URL,NeoGOPBenchmark.Profile)] = []
  private var reports: [[String:Any]] = [], next = 0, running = false, latest: [String:Any]?
  private let status = NeoStyle.label("測定計画JSONと比較する動画を「ファイル」から選択してください。動画はアプリ内へコピーされます。",size:15)
  private let rounds = UIStepper(), roundLabel = NeoStyle.label(), startButton = UIButton(type:.system)
  private let stack = UIStackView()
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
  private func refresh() { roundLabel.text = "各動画 \(Int(rounds.value)*(plan?.targets.count ?? 24)*2)回＋ウォームアップ2回"; startButton.isEnabled = !files.isEmpty && plan != nil && !running }
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
  private func begin() { guard plan != nil, !files.isEmpty else { return }; files.shuffle(); reports = []; next = 0; running = true; refresh(); playNext() }
  private func playNext() {
    guard running, next < files.count, let plan else { running = false; status.text = "測定終了。結果を共有できます。"; refresh(); return }
    let (url,profile) = files[next]
    let owner = NeoPlayerController(url:url,title:"GOP シーク測定 · "+profile.label,username:"",password:"",networkCaching:5000)
    owner.aetherOptions = ["checkpointEnabled":false,"gopBenchmark":true,"gopTolerance":max(0.03,2/profile.fps)]
    owner.recordingContext = ["videoFileType":"encoded","disableHistory":true]
    let object = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(profile))) as? [String:Any] ?? [:]
    owner.gopBenchmarkConfiguration = ["profile":object,"targets":plan.targets,"rounds":Int(rounds.value)]
    latest = nil
    owner.onGOPBenchmarkResult = { [weak self] result in self?.latest = result }
    owner.onClose = { [weak self,weak owner] in
      guard let self else { return }
      if let latest = self.latest { self.reports.append(latest); self.save() }
      let complete = self.latest?["status"] as? String == "completed"
      self.next += 1
      Task { [weak self,weak owner] in
        for _ in 0..<100 { if owner?.presentingViewController == nil { break }; try? await Task.sleep(nanoseconds:20_000_000) }
        guard let self else { return }
        if complete { self.playNext() } else { self.running = false; self.status.text = "測定を中断しました。途中結果を共有できます。"; self.refresh() }
      }
    }
    owner.modalPresentationStyle = .fullScreen; present(owner,animated:true)
  }
  private func save() {
    if let data = try? JSONSerialization.data(withJSONObject:["schema":1,"runs":reports],options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:Self.resultURL,options:.atomic) }
  }
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
  @objc(initWithPlayer:configuration:) init(player: NeoPlayerController,configuration: [String:Any]) { self.player = player; self.configuration = configuration; super.init() }
  @objc func observe(_ event: [String:Any]) { if !done { events.append(event); if events.count > 16 { events.removeFirst(events.count-16) } } }
  @objc func start() {
    guard task == nil, let player else { return }
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
    guard !done, s["closing"] as? Bool != true, s["foreground"] as? Bool == true, s["pip"] as? Bool != true, s["failed"] as? Bool != true, s["playing"] as? Bool == true else { throw error("interrupted-or-not-foreground") }
  }
  private func error(_ message: String) -> NSError { NSError(domain:"GOP",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
  private func run() async {
    do {
      let data = try JSONSerialization.data(withJSONObject:configuration["profile"] ?? [:]), profile = try JSONDecoder().decode(NeoGOPBenchmark.Profile.self,from:data)
      let targets = configuration["targets"] as? [Double] ?? [], rounds = configuration["rounds"] as? Int ?? 1
      guard (1...3).contains(rounds), NeoGOPBenchmark.Plan(schema:1,targets:targets,profiles:[profile]).valid else { throw error("invalid-plan") }
      report = ["schema":1,"label":profile.label,"bytes":profile.bytes,"fps":profile.fps,"keys":profile.keys,
        "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "","os":UIDevice.current.systemVersion,"device":UIDevice.current.model,
        "local":true,"checkpoint":false,"audio":true,"comments":false,"subtitles":false,"pollIntervalMs":1000/60.0,"targetToleranceSeconds":max(0.03,2/profile.fps),
        "timing":"normal-controller-seek-entry-to-displayed-target-picture","engineCompletionMeaning":"engine seek return, independent of displayed picture"]
      report["startedAt"] = ISO8601DateFormatter().string(from:Date())
      badge.text = "GOP測定：再生準備中…"
      for _ in 0..<1500 {
        try Task.checkCancellation()
        let s = state()
        if s["ready"] as? Bool == true && s["seekable"] as? Bool == true && player?.view.window != nil { break }
        try await Task.sleep(nanoseconds:20_000_000)
      }
      try check(); let s = state()
      guard s["ready"] as? Bool == true, s["seekable"] as? Bool == true, s["checkpointEnabled"] as? Bool == false,
        let duration = s["duration"] as? Double, abs(duration-profile.duration)<1 else { throw error("media-duration-or-route-mismatch") }
      report["initialState"] = s
      let measured = NeoGOPBenchmark.steps(targets,rounds:rounds), warmup = Array(measured.prefix(2)), steps = warmup+measured
      var failures = 0
      for (index,step) in steps.enumerated() {
        try check(); badge.text = index < warmup.count ? "GOP測定：ウォームアップ" : "GOP測定 \(index-warmup.count+1)/\(measured.count) · \(step.forward ? "送り" : "戻し")"
        let staging = try await seek(step.stage)
        guard staging["status"] as? String == "verified" else { throw error("preparation-picture-not-verified") }
        try await Task.sleep(nanoseconds:300_000_000); try check()
        var row = try await seek(step.target)
        row["forward"] = step.forward; row["round"] = step.round; row["sampleKind"] = index < warmup.count ? "warmup" : "measured"
        row["keySeconds"] = profile.key(before:step.target); row["distanceFromKey"] = profile.key(before:step.target).map { step.target-$0 }
        row["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        row["viewportWidth"] = state()["width"]; row["viewportHeight"] = state()["height"]
        rows.append(row); save("running")
        failures = row["status"] as? String == "verified" ? 0 : failures+1
        if failures >= 3 { throw error("three-unverified-results") }
        try await Task.sleep(nanoseconds:300_000_000)
      }
      finish("completed",reason:nil); player?.gopBenchmarkFinish()
    } catch {
      finish("cancelled",reason:error.localizedDescription)
      if player?.view.window != nil { player?.gopBenchmarkFinish() }
    }
  }
  private func seek(_ target: Double) async throws -> [String:Any] {
    try check(); events = []
    let invoked = CACurrentMediaTime(), from = state()["time"] as? Double ?? -1
    player?.gopBenchmarkSeek(Int64((target*1000).rounded()))
    let serial = events.first(where: { $0["event"] as? String == "started" })?["serial"] as? Int
    guard let serial else { throw error("seek-rejected") }
    var picture: [String:Any]?, engine: [String:Any]?
    for _ in 0..<800 {
      try check()
      picture = events.first { $0["serial"] as? Int == serial && $0["event"] as? String == "picture" }
      engine = events.first { $0["serial"] as? Int == serial && $0["event"] as? String == "engineCompletion" }
      if let picture, engine != nil || CACurrentMediaTime()-(picture["host"] as? Double ?? 0)>0.25 { break }
      try await Task.sleep(nanoseconds:10_000_000)
    }
    var row: [String:Any] = ["target":target,"from":from,"route":state()["route"] ?? "unknown","status":"timeout"]
    if let picture, let host = picture["host"] as? Double {
      let verified = picture["verified"] as? Bool == true
      row["status"] = verified ? "verified" : "unverified-picture-time"; row["picturePTS"] = picture["pts"]
      row["verification"] = picture["verification"]
      row[verified ? "displayMs" : "decodedPictureMs"] = (host-invoked)*1000
    }
    if let host = engine?["host"] as? Double { row["engineCompletionMs"] = (host-invoked)*1000 }
    return row
  }
  private func save(_ status: String) {
    report["status"] = status; report["rows"] = rows
    report["summary"] = NeoGOPBenchmark.summary(rows.filter { $0["sampleKind"] as? String == "measured" })
    if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:Self.partialURL,options:.atomic) }
  }
  private func finish(_ status: String,reason: String?) {
    guard !done else { return }; done = true; report["reason"] = reason; save(status); badge.removeFromSuperview(); UIApplication.shared.isIdleTimerDisabled = oldIdle
    player?.onGOPBenchmarkResult?(report)
  }
  @objc func cancel(_ reason: String) { guard !done else { return }; task?.cancel(); finish("cancelled",reason:reason) }
}
