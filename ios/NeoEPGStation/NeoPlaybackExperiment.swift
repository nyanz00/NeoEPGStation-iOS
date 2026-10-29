import Foundation

// Snapshot at player creation; changing this never replaces a running engine.
enum NeoPlaybackExperiment: String, CaseIterable {
  case vlc, aether, avplayer, decodeTrial, checkpointTrial, checkpointPlayer
  var title: String {
    switch self {
    case .vlc: return "標準：VLC"
    case .aether: return "試験用：AetherEngine"
    case .avplayer: return "試験用：AVPlayer直接再生"
    case .decodeTrial: return "診断用：AV1復号比較"
    case .checkpointTrial: return "診断用：AV1状態復元"
    case .checkpointPlayer: return "試験用：Aether＋AV1チェックポイント"
    }
  }
  static var selected: Self {
    get { selection(in: .standard) }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "player.experiment.engine") }
  }
  static var checkpointMode: NeoCheckpointMode {
    get { checkpointMode(in: .standard) }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "player.experiment.checkpoint.mode") }
  }
  static func checkpointMode(in defaults: UserDefaults) -> NeoCheckpointMode {
    if let stored = defaults.string(forKey: "player.experiment.checkpoint.mode") {
      return NeoCheckpointMode(rawValue: stored) ?? .automatic
    }
    if let old = defaults.object(forKey: "player.experiment.checkpoint.enabled") as? Bool {
      return old ? .forced : .off
    }
    return .automatic
  }
  static func selection(in defaults: UserDefaults) -> Self {
    if let stored = defaults.string(forKey: "player.experiment.engine") { return Self(rawValue: stored) ?? .vlc }
    return defaults.bool(forKey: "player.experiment.aether") ? .aether : .vlc
  }
  func applies(fileType: String, streaming: Bool, recording: Bool) -> Bool {
    guard self != .vlc, fileType == "encoded", !recording else { return false }
    return !streaming || self == .aether || self == .checkpointPlayer
  }
}

enum NeoCheckpointMode: String, CaseIterable {
  case automatic, forced, off
  var title: String { switch self { case .automatic: return "自動"; case .forced: return "強制"; case .off: return "オフ" } }
}

// Optional fields preserve compatibility with servers predating keyframe analysis.
struct NeoCheckpointVideoInfo: Decodable, Sendable {
  let videoCodec: String?
  let width, height: Int?
  let keyframes: Keyframes?
  struct Keyframes: Decodable, Sendable {
    let status: String?
    let version, currentVersion: Int?
    let stale: Bool?
    let averageInterval, minInterval, maxInterval: Double?
    let intervalCount, keyframeCount: Int?
    var usable: Bool {
      guard status == "ready", stale == false, let version, let currentVersion,
        version > 0, version == currentVersion,
        let count = intervalCount, count > 0, let keys = keyframeCount, keys >= 2,
        let low = minInterval, let mean = averageInterval, let high = maxInterval else { return false }
      return low.isFinite && mean.isFinite && high.isFinite && low > 0 && low <= mean && mean <= high
    }
    var rejectionReason: String {
      if status == "pending" || status == "analyzing" { return "analysis-\(status!)" }
      if status == "error" || status == "unavailable" { return "analysis-\(status!)" }
      if stale == true { return "analysis-stale" }
      if let version, let currentVersion, version != currentVersion { return "analysis-version-mismatch" }
      return "analysis-invalid"
    }
    var needsCompletion: Bool {
      var outdated = false
      if let version, let currentVersion { outdated = version > 0 && currentVersion > 0 && version != currentVersion }
      return status == "pending" || status == "analyzing" ||
        status == "ready" && (stale == true || outdated)
    }
  }
}
struct NeoCheckpointDecision {
  let mode: NeoCheckpointMode
  let enabled: Bool
  let reason: String
  let maximum: Double?
  var analysisStatus = "missing"
  var analysisVersion = -1, analysisCurrentVersion = -1
  var analysisStale = false
  var analysisRequests = 0, analysisWaitMs = 0.0
  var diagnosticFields: [String:Any] {
    ["mode":mode.rawValue,"enabled":enabled,"reason":reason,"maximumInterval":maximum ?? -1,"thresholdSeconds":10,
     "analysisStatus":analysisStatus,"analysisVersion":analysisVersion,"analysisCurrentVersion":analysisCurrentVersion,
     "analysisStale":analysisStale,"analysisRequests":analysisRequests,"analysisWaitMs":analysisWaitMs]
  }
  func recording(_ result: NeoCheckpointAnalysis.Result) -> Self {
    var value = self
    value.analysisStatus = result.info?.keyframes?.status ?? "missing"
    value.analysisVersion = result.info?.keyframes?.version ?? -1
    value.analysisCurrentVersion = result.info?.keyframes?.currentVersion ?? -1
    value.analysisStale = result.info?.keyframes?.stale ?? false
    value.analysisRequests = result.requests; value.analysisWaitMs = result.waitMs
    return value
  }
  static func choose(_ mode: NeoCheckpointMode, info: NeoCheckpointVideoInfo?) -> Self {
    let maximum = info?.keyframes?.usable == true ? info?.keyframes?.maxInterval : nil
    if mode == .off { return Self(mode: mode, enabled: false, reason: "disabled", maximum: maximum) }
    if mode == .forced { return Self(mode: mode, enabled: true, reason: "forced", maximum: maximum) }
    guard let info, info.videoCodec?.lowercased() == "av1",
      let width = info.width, let height = info.height, width > 0, height > 0, width <= 1920, height <= 1080 else {
      return Self(mode: mode, enabled: false, reason: "missing-or-ineligible-video", maximum: maximum)
    }
    guard let maximum else { return Self(mode: mode, enabled: false, reason: info.keyframes?.rejectionReason ?? "analysis-missing", maximum: nil) }
    return Self(mode: mode, enabled: maximum >= 10, reason: maximum >= 10 ? "long-gop" : "short-gop", maximum: maximum)
  }
}

enum NeoCheckpointAnalysis {
  struct Result: Sendable {
    let info: NeoCheckpointVideoInfo?
    let outcome: String
    let requests: Int
    let waitMs: Double
    var decision: NeoCheckpointDecision {
      let value = outcome == "complete" ? NeoCheckpointDecision.choose(.automatic, info: info) :
        NeoCheckpointDecision(mode: .automatic, enabled: false, reason: outcome, maximum: nil)
      return value.recording(self)
    }
  }
  /// GET schedules missing/outdated analysis on the server. Only pending results
  /// are polled; a forced POST on every poll would keep restarting the work.
  @MainActor static func resolve(
    fetch: @MainActor () async throws -> NeoCheckpointVideoInfo,
    isCurrent: @MainActor () -> Bool = { true },
    progress: @MainActor (NeoCheckpointVideoInfo) -> Void = { _ in },
    timeout: Double = 120,
    now: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
    wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
  ) async throws -> Result {
    let start = now(); var requests = 0
    var latest: NeoCheckpointVideoInfo?
    @MainActor func finish(_ outcome: String) -> Result {
      Result(info: latest, outcome: outcome, requests: requests, waitMs: max(0, now()-start)*1000)
    }
    while true {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      if now()-start >= timeout { return finish("analysis-timeout") }
      requests += 1
      do { latest = try await fetch() }
      catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        return finish("analysis-request-failed")
      }
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      guard let info = latest, let keys = info.keyframes else { return finish("analysis-unsupported-server") }
      if let codec = info.videoCodec, codec.lowercased() != "av1" { return finish("ineligible-video") }
      if let width = info.width, width > 1920 { return finish("ineligible-video") }
      if let height = info.height, height > 1080 { return finish("ineligible-video") }
      if keys.usable { return finish("complete") }
      guard keys.needsCompletion else { return finish(keys.rejectionReason) }
      progress(info)
      try await wait()
    }
  }
}
