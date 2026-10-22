import Foundation

// Bounded, opt-in export. Numeric state, fixed event names and font metadata
// only: never URLs, headers, titles, comment text or localized errors.
@objc(NeoPlaybackDiagnostics)
final class NeoPlaybackDiagnostics: NSObject {
  private static let lock = NSLock()
  private static var events: [[String: Any]] = []
  private static var commentFonts: [[String: Any]] = []
  private static var fontKeys = Set<String>()
  private static var decoders: [[String: Any]] = []
  private static var started = ProcessInfo.processInfo.systemUptime
  private static var currentSeek = 0
  private static var awaitingVideo = false
  private static var nativeErrors: [Int: Int] = [:]
  private static var nativeErrorPending = false, nativeErrorGeneration = 0
  @objc static var seekID: Int { lock.lock(); defer { lock.unlock() }; return currentSeek }
  @objc static func begin() {
    lock.lock(); events.removeAll(); started = ProcessInfo.processInfo.systemUptime; currentSeek = 0; awaitingVideo = false
    nativeErrors.removeAll(); nativeErrorPending = false; nativeErrorGeneration += 1
    commentFonts.removeAll(); fontKeys.removeAll(); decoders.removeAll(); lock.unlock()
    record("session.start", fields: ["rewindSeconds": NeoPlaybackCache.savedSeconds,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
  }
  // Requested policy is not proof of actual hardware use. Retain only module
  // selection messages and fixed names, never raw native messages or URLs.
  @objc(nativeDecoder:) static func nativeDecoder(_ message: String) {
    let kinds = ["video decoder", "audio decoder", "spu decoder", "decoder", "hw decoder"]
    guard let kind = kinds.first(where: { message.hasPrefix("using \($0) module \"") }),
          message.hasSuffix("\"") else { return }
    let name = String(message.dropFirst("using \(kind) module \"".count).dropLast())
    let software: Set<String> = ["dav1d", "aom", "vpx", "libmpeg2", "mpeg2", "theora", "rawvideo",
      "faad", "a52", "mpg123", "mpeg_audio", "flac", "vorbis", "opus", "aribsub", "aribcaption",
      "subsdec", "libass", "spudec", "dvbsub", "dummy"]
    let module = software.contains(name) || ["videotoolbox", "avcodec"].contains(name) ? name : "other"
    // avcodec can use an accelerator, so its module name is inconclusive.
    // VideoToolbox is configured hardware-only by the controller.
    let acceleration = module == "videotoolbox" ? "hardware" : software.contains(module) ? "software" : "unknown"
    lock.lock()
    let row: [String: Any] = ["kind": kind, "module": module, "acceleration": acceleration,
      "elapsed": ProcessInfo.processInfo.systemUptime-started, "seek": currentSeek]
    if decoders.count < 64 { decoders.append(row) }
    lock.unlock()
    record("vlc.decoderSelected", fields: row)
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
  static func commentFont(requested: String, bold: Bool, italic: Bool, base: String,
                          actual: String, family: String, actualBold: Bool, actualItalic: Bool,
                          weight: Double, script: String) {
    // Preserve samples separately from the event ring, so long playback cannot
    // evict them. Deduplicate across comments, sizes and raster cache rebuilds.
    let names = [requested, base, actual, family].map { String($0.prefix(128)) }
    let key = names.joined(separator: "\u{1f}")+"|\(bold)|\(italic)|\(actualBold)|\(actualItalic)|\(script)"
    lock.lock(); defer { lock.unlock() }
    guard commentFonts.count < 64, fontKeys.insert(key).inserted else { return }
    commentFonts.append(["requestedFont": names[0], "requestedBold": bold, "requestedItalic": italic,
      "resolvedBasePostScript": names[1], "actualPostScript": names[2], "actualFamily": names[3],
      "actualBold": actualBold, "actualItalic": actualItalic, "weight": weight,
      "script": script, "elapsed": ProcessInfo.processInfo.systemUptime-started])
  }
  // Fixed categories only: 0 other, 1 seek, 2 EOF, 3 read, 4 connection,
  // 5 decoder, 6 demux, 7 clock/PCR, 8 late/drop, 9 VideoToolbox.
  // Counts preserve storms without flooding the UI/log.
  @objc(nativeError:level:) static func nativeError(_ kind: Int, level: Int) {
    lock.lock()
    let key = kind*10+level
    nativeErrors[key, default: 0] += 1
    guard !nativeErrorPending else { lock.unlock(); return }
    nativeErrorPending = true; let token = nativeErrorGeneration; lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+0.1) {
      lock.lock()
      guard token == nativeErrorGeneration else { lock.unlock(); return }
      let counts = nativeErrors; nativeErrors.removeAll(); nativeErrorPending = false; lock.unlock()
      for (key, count) in counts { record("vlc.inputWarning", fields: ["kind": key/10, "level": key%10, "notifications": count]) }
    }
  }
  @objc static func exportURL() -> URL? {
    lock.lock(); let snapshot = events, fonts = commentFonts, selections = decoders; lock.unlock()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeoPlaybackDiagnostics", isDirectory: true)
    let url = directory.appendingPathComponent("playback-diagnostics.json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "events": snapshot, "commentFonts": fonts, "decoders": selections], options: [.prettyPrinted, .sortedKeys])
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
  private var buffering = false
  private var count = 0, generation = 0
  private var lastDelivery = -Double.infinity
  @objc var onUpdate: ((Float, Int) -> Void)?
  @objc func submit(_ progress: Float) {
    guard progress.isFinite else { return }
    lock.lock()
    latest = min(1, max(0, progress)); count += 1
    let nextBuffering = latest < 1
    let boundary = nextBuffering != buffering
    buffering = nextBuffering
    // Progress percentages may be coalesced. Starting/completing buffering
    // changes playback state: replace the pending percentage update now.
    if boundary { generation += 1; pending = false }
    guard !pending else { lock.unlock(); return }
    pending = true
    let token = generation
    let delay = boundary ? 0 : max(0, 0.1 - (ProcessInfo.processInfo.systemUptime-lastDelivery))
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
    lock.lock(); generation += 1; pending = false; count = 0; buffering = false; lastDelivery = -Double.infinity; lock.unlock()
  }
}
