import Foundation

// Bounded, opt-in export. Callers supply only numeric state and fixed event
// names: never URLs, headers, titles, comment text or localized errors.
@objc(NeoPlaybackDiagnostics)
final class NeoPlaybackDiagnostics: NSObject {
  private static let lock = NSLock()
  private static var events: [[String: Any]] = []
  private static var started = ProcessInfo.processInfo.systemUptime
  private static var currentSeek = 0
  private static var awaitingVideo = false
  @objc static var seekID: Int { lock.lock(); defer { lock.unlock() }; return currentSeek }
  @objc static func begin() {
    lock.lock(); events.removeAll(); started = ProcessInfo.processInfo.systemUptime; currentSeek = 0; awaitingVideo = false; lock.unlock()
    record("session.start", fields: ["rewindSeconds": NeoPlaybackCache.savedSeconds,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
  }
  @objc static func beginSeek(_ identifier: Int) {
    lock.lock(); currentSeek = identifier; awaitingVideo = true; lock.unlock()
  }
  static func decodedFrame(host: Double, presentation: Double) {
    lock.lock()
    guard awaitingVideo else { lock.unlock(); return }
    awaitingVideo = false
    let seek = currentSeek
    lock.unlock()
    record("seek.firstDecodedFrame", fields: ["originSeek": seek, "scheduledInMs": (presentation-host)*1000])
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

// Coalesce on the calling thread, before dispatching to UIKit. A notification
// storm must not produce thousands of main-queue blocks or JSON rows.
@objc(NeoBufferingUpdates)
final class NeoBufferingUpdates: NSObject {
  private let lock = NSLock()
  private var pending = false, latest: Float = 1
  private var count = 0, generation = 0
  private var lastDelivery = -Double.infinity
  @objc var onUpdate: ((Float, Int) -> Void)?
  @objc func submit(_ progress: Float) {
    guard progress.isFinite else { return }
    lock.lock()
    latest = min(1, max(0, progress)); count += 1
    guard !pending else { lock.unlock(); return }
    pending = true
    let token = generation
    let delay = max(0, 0.1 - (ProcessInfo.processInfo.systemUptime-lastDelivery))
    lock.unlock()
    DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      guard self.generation == token else { self.lock.unlock(); return }
      let progress = self.latest, count = self.count
      self.pending = false; self.count = 0
      self.lastDelivery = ProcessInfo.processInfo.systemUptime
      self.lock.unlock()
      self.onUpdate?(progress, count)
    }
  }
  @objc func reset() {
    lock.lock(); generation += 1; pending = false; count = 0; lastDelivery = -Double.infinity; lock.unlock()
  }
}
