import Foundation

// Snapshot at player creation; changing this never replaces a running engine.
enum NeoPlaybackExperiment: String, CaseIterable {
  case vlc, aether, avplayer, decodeTrial
  var title: String {
    switch self {
    case .vlc: return "標準：VLC"
    case .aether: return "試験用：AetherEngine"
    case .avplayer: return "試験用：AVPlayer直接再生"
    case .decodeTrial: return "診断用：AV1復号比較"
    }
  }
  static var selected: Self {
    get { selection(in: .standard) }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "player.experiment.engine") }
  }
  static func selection(in defaults: UserDefaults) -> Self {
    if let stored = defaults.string(forKey: "player.experiment.engine") { return Self(rawValue: stored) ?? .vlc }
    return defaults.bool(forKey: "player.experiment.aether") ? .aether : .vlc
  }
  func applies(fileType: String, streaming: Bool, recording: Bool) -> Bool {
    self != .vlc && fileType == "encoded" && !streaming && !recording
  }
}
