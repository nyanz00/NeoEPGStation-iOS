import Foundation

let name = "NeoPlaybackExperiment.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: name)!
defer { defaults.removePersistentDomain(forName: name) }
precondition(NeoPlaybackExperiment.selection(in: defaults) == .vlc)
defaults.set(true, forKey: "player.experiment.aether")
precondition(NeoPlaybackExperiment.selection(in: defaults) == .aether)
for engine in NeoPlaybackExperiment.allCases {
  defaults.set(engine.rawValue, forKey: "player.experiment.engine")
  precondition(NeoPlaybackExperiment.selection(in: defaults) == engine)
  precondition(!engine.applies(fileType: "ts", streaming: false, recording: false))
  precondition(engine.applies(fileType: "encoded", streaming: true, recording: false) == (engine == .aether || engine == .checkpointPlayer))
  precondition(!engine.applies(fileType: "ts", streaming: true, recording: false))
  precondition(!engine.applies(fileType: "encoded", streaming: false, recording: true))
  precondition(engine.applies(fileType: "encoded", streaming: false, recording: false) == (engine != .vlc))
}
// Unknown values fall back safely even when the old experiment flag remains enabled.
defaults.set("unknown", forKey: "player.experiment.engine")
precondition(NeoPlaybackExperiment.selection(in: defaults) == .vlc)
print("Comparison preference migration and encoded-only routing passed")

precondition(NeoPlaybackExperiment.checkpointMode(in: defaults) == .automatic)
defaults.set(false, forKey: "player.experiment.checkpoint.enabled")
precondition(NeoPlaybackExperiment.checkpointMode(in: defaults) == .off)
defaults.set(true, forKey: "player.experiment.checkpoint.enabled")
precondition(NeoPlaybackExperiment.checkpointMode(in: defaults) == .forced)
defaults.set("automatic", forKey: "player.experiment.checkpoint.mode")
precondition(NeoPlaybackExperiment.checkpointMode(in: defaults) == .automatic)
func info(_ maximum: Double, status: String = "ready", stale: Bool = false, version: Int = 1, currentVersion: Int? = nil, codec: String = "av1") -> NeoCheckpointVideoInfo {
  let payload: [String: Any] = ["videoCodec": codec, "width": 1440, "height": 1080,
    "keyframes": ["status": status, "stale": stale, "version": version, "currentVersion": currentVersion ?? version,
      "averageInterval": 4, "minInterval": 2, "maxInterval": maximum, "intervalCount": 8, "keyframeCount": 11]]
  return try! JSONDecoder().decode(NeoCheckpointVideoInfo.self, from: JSONSerialization.data(withJSONObject: payload))
}
for (seconds, expected) in [(6.006,false),(8.008,false),(9.999,false),(10,true),(25,true)] {
  precondition(NeoCheckpointDecision.choose(.automatic, info: info(seconds)).enabled == expected)
}
for unavailable in [info(25,status: "pending"), info(25,status: "analyzing"), info(25,status: "unavailable"),
  info(25,status: "error"), info(25,stale: true), info(25,version: 1,currentVersion: 2), info(25,codec: "hevc"), info(0)] {
  precondition(!NeoCheckpointDecision.choose(.automatic, info: unavailable).enabled)
}
let legacy = try! JSONDecoder().decode(NeoCheckpointVideoInfo.self, from: Data("{}".utf8))
precondition(!NeoCheckpointDecision.choose(.automatic, info: legacy).enabled)
precondition(!NeoCheckpointDecision.choose(.automatic, info: nil).enabled)
precondition(NeoCheckpointDecision.choose(.forced, info: nil).enabled)
precondition(!NeoCheckpointDecision.choose(.off, info: info(25)).enabled)
for version in [1,2,3,20] {
  precondition(NeoCheckpointDecision.choose(.automatic, info: info(25,version: version)).enabled)
}
print("Checkpoint modes: exact ten-second boundary, stale/pending/legacy/error fallback and preference migration passed")
