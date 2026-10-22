import Foundation

// Diagnostics' cache preference dependency; no network, VLC or UIKit is used.
final class NeoPlaybackCache { static let savedSeconds = 60 }

func pump(_ seconds: Double) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
func require(_ value: @autoclosure () -> Bool, _ message: String) {
  precondition(value(), message)
}

// Keep the same lifetime as the controller's strongly owned production helper.
let updates = NeoBufferingUpdates()
var received: [(Float, Int, Double)] = []
updates.onUpdate = { received.append(($0, $1, ProcessInfo.processInfo.systemUptime)) }
updates.submit(0)
pump(0.02)
require(received.count == 1 && received[0].0 == 0, "Buffer start must be immediate")
updates.submit(0.5)
let completed = ProcessInfo.processInfo.systemUptime
updates.submit(1)
pump(0.04)
require(received.last?.0 == 1, "Completion must replace the pending percentage update")
require(received.last!.2-completed < 0.04, "Completion must bypass the 100ms progress throttle")
let delivered = received.count
pump(0.12)
require(received.count == delivered, "A cancelled percentage must not overwrite completion")
require(received.reduce(0, { $0+$1.1 }) == 3, "Coalescing must retain all notification counts")

updates.submit(0)
updates.reset()
pump(0.12)
require(received.count == delivered, "Reset must invalidate queued deliveries")
updates.submit(0)
pump(0.02)
require(received.last?.0 == 0, "Buffering can restart immediately after reset")
updates.reset()
received.removeAll()
for value in 0..<2000 { updates.submit(Float(value)/2000) }
updates.submit(1)
pump(0.15)
require(received.count <= 3 && received.last?.0 == 1, "Percentage storms must remain coalesced")
require(received.reduce(0, { $0+$1.1 }) == 2001, "Storm notifications must be counted")
print("PASS: immediate buffering boundaries, stale delivery rejection, reset, and storm coalescing")

NeoPlaybackDiagnostics.begin()
NeoPlaybackDiagnostics.nativeDecoder("using video decoder module \"videotoolbox\"")
NeoPlaybackDiagnostics.nativeDecoder("using video decoder module \"dav1d\"")
NeoPlaybackDiagnostics.nativeDecoder("using video decoder module \"avcodec\"")
NeoPlaybackDiagnostics.nativeDecoder("using audio decoder module \"private-server-token\"")
NeoPlaybackDiagnostics.nativeDecoder("HTTP https://private.invalid/secret")
NeoPlaybackDiagnostics.nativeDecoder("looking for video decoder module matching \"videotoolbox,any\"")
for _ in 0..<4200 { NeoPlaybackDiagnostics.record("test.sample", fields: [:]) }
let diagnosticData = try Data(contentsOf: NeoPlaybackDiagnostics.exportURL()!)
let diagnostic = try JSONSerialization.jsonObject(with: diagnosticData) as! [String: Any]
let selections = diagnostic["decoders"] as! [[String: Any]]
require(selections.count == 4, "Only actual selection messages may be recorded")
require(selections.map { $0["acceleration"] as! String } == ["hardware", "software", "unknown", "unknown"], "Do not infer hardware acceleration from avcodec's name")
require(selections.last?["module"] as? String == "other", "Unknown native names must be redacted")
let exported = String(decoding: diagnosticData, as: UTF8.self)
require(!exported.contains("private") && !exported.contains("matching"), "Never export raw debug messages")
require(selections.count == 4, "Long playback must preserve decoder choices outside the event ring")
NeoPlaybackDiagnostics.begin()
let reset = try JSONSerialization.jsonObject(with: Data(contentsOf: NeoPlaybackDiagnostics.exportURL()!)) as! [String: Any]
require((reset["decoders"] as! [[String: Any]]).isEmpty, "A new playback session must discard old decoder choices")
print("PASS: actual decoder selection, acceleration evidence, private-data redaction, retention and reset")
