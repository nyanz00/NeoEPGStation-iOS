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
    self != .vlc && fileType == "encoded" && !streaming && !recording
  }
}

enum NeoCheckpointMode: String, CaseIterable {
  case automatic, forced, off
  var title: String { switch self { case .automatic: return "自動"; case .forced: return "強制"; case .off: return "オフ" } }
}

// Optional fields preserve compatibility with servers predating keyframe analysis.
struct NeoCheckpointVideoInfo: Decodable {
  let videoCodec: String?
  let width, height: Int?
  let keyframes: Keyframes?
  struct Keyframes: Decodable {
    let status: String?
    let version, currentVersion: Int?
    let stale: Bool?
    let averageInterval, minInterval, maxInterval: Double?
    let intervalCount, keyframeCount: Int?
    var usable: Bool {
      guard status == "ready", stale == false, version == 1, currentVersion == 1,
        let count = intervalCount, count > 0, let keys = keyframeCount, keys >= 2,
        let low = minInterval, let mean = averageInterval, let high = maxInterval else { return false }
      return low.isFinite && mean.isFinite && high.isFinite && low > 0 && low <= mean && mean <= high
    }
  }
}
struct NeoCheckpointDecision {
  let mode: NeoCheckpointMode
  let enabled: Bool
  let reason: String
  let maximum: Double?
  static func choose(_ mode: NeoCheckpointMode, info: NeoCheckpointVideoInfo?) -> Self {
    let maximum = info?.keyframes?.usable == true ? info?.keyframes?.maxInterval : nil
    if mode == .off { return Self(mode: mode, enabled: false, reason: "disabled", maximum: maximum) }
    if mode == .forced { return Self(mode: mode, enabled: true, reason: "forced", maximum: maximum) }
    guard let info, info.videoCodec?.lowercased() == "av1",
      let width = info.width, let height = info.height, width > 0, height > 0, width <= 1920, height <= 1080 else {
      return Self(mode: mode, enabled: false, reason: "missing-or-ineligible-video", maximum: maximum)
    }
    guard let maximum else { return Self(mode: mode, enabled: false, reason: "analysis-unavailable", maximum: nil) }
    return Self(mode: mode, enabled: maximum >= 10, reason: maximum >= 10 ? "long-gop" : "short-gop", maximum: maximum)
  }
}
