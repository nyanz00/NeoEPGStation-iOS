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
