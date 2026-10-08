import Foundation

// Bounded, opt-in export. Callers supply only numeric state and fixed event
// names: never URLs, headers, titles, comment text or localized errors.
@objc(NeoPlaybackDiagnostics)
final class NeoPlaybackDiagnostics: NSObject {
  private static let lock = NSLock()
  private static var events: [[String: Any]] = []
  private static var started = ProcessInfo.processInfo.systemUptime
  private static var currentSeek = 0
  @objc static var seekID: Int { lock.lock(); defer { lock.unlock() }; return currentSeek }
  @objc static func begin() {
    lock.lock(); events.removeAll(); started = ProcessInfo.processInfo.systemUptime; currentSeek = 0; lock.unlock()
    record("session.start", fields: ["rewindSeconds": NeoPlaybackCache.savedSeconds,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
  }
  @objc static func beginSeek(_ identifier: Int) {
    lock.lock(); currentSeek = identifier; lock.unlock()
  }
  @objc(record:fields:) static func record(_ event: String, fields: [String: Any]) {
    lock.lock(); defer { lock.unlock() }
    var row = fields
    row["event"] = event; row["elapsed"] = ProcessInfo.processInfo.systemUptime - started; row["seek"] = currentSeek
    events.append(row)
    if events.count > 4096 { events.removeFirst(256) }
  }
  @objc static func exportURL() -> URL? {
    lock.lock(); let snapshot = events; lock.unlock()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeoPlaybackDiagnostics", isDirectory: true)
    let url = directory.appendingPathComponent("playback-diagnostics.json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "events": snapshot], options: [.prettyPrinted, .sortedKeys])
      try data.write(to: url, options: .atomic); return url
    } catch { return nil }
  }
}
