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
  precondition(!engine.applies(fileType: "encoded", streaming: true, recording: false))
  precondition(!engine.applies(fileType: "encoded", streaming: false, recording: true))
  precondition(engine.applies(fileType: "encoded", streaming: false, recording: false) == (engine != .vlc))
}
// Unknown values fall back safely even when the old experiment flag remains enabled.
defaults.set("unknown", forKey: "player.experiment.engine")
precondition(NeoPlaybackExperiment.selection(in: defaults) == .vlc)
print("Comparison preference migration and encoded-only routing passed")
