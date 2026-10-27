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
  static var checkpointEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "player.experiment.checkpoint.enabled") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "player.experiment.checkpoint.enabled") }
  }
  static func selection(in defaults: UserDefaults) -> Self {
    if let stored = defaults.string(forKey: "player.experiment.engine") { return Self(rawValue: stored) ?? .vlc }
    return defaults.bool(forKey: "player.experiment.aether") ? .aether : .vlc
  }
  func applies(fileType: String, streaming: Bool, recording: Bool) -> Bool {
    self != .vlc && fileType == "encoded" && !streaming && !recording
  }
}
