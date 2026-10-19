import Foundation

// HLS PCR preroll and pause->play can briefly expose an obsolete native timer
// point, even after a target picture is decoded. Keep the confirmed content
// position until the native clock enters the physically reachable interval.
// This is a bounded transition guard, not an independent playback clock.
@objc(NeoStreamingClock)
final class NeoStreamingClock: NSObject {
  private let lock = NSLock()
  private var target = 0.0, began = -100.0, stable = 0.0
  @objc(resetAt:host:)
  func reset(at milliseconds: Int64, host: Double) {
    lock.lock(); defer { lock.unlock() }
    target = Double(max(0, milliseconds)); stable = target; began = host
  }
  @objc(positionAt:host:running:rate:)
  func position(at milliseconds: Int64, host: Double, running: Bool, rate: Double) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    let value = Double(milliseconds), elapsed = max(0, host-began)
    guard elapsed < 5 else { return milliseconds }
    let reachable = target+(running ? elapsed*1000*max(0, rate) : 0)+500
    guard value >= target-250, value <= reachable, value >= stable-100 else { return Int64(stable) }
    stable = max(stable, value); return Int64(stable)
  }
}

// Server VOD HLS: encoded=4s, TS=180 frames at 30000/1001 fps.
// Store segment counts, not rounded display seconds.
enum NeoStreamBuffer {
  static let aheadChoices = [1, 2, 3, 5, 10]
  static let rewindChoices = [0, 1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 75]
  static func interval(ts: Bool) -> Double { ts ? 6.006 : 4 }
  static func key(ts: Bool, rewind: Bool) -> String { "player.streaming.\(ts ? "ts" : "encoded").\(rewind ? "rewind" : "ahead")" }
  static func count(ts: Bool, rewind: Bool) -> Int {
    let value = UserDefaults.standard.object(forKey: key(ts: ts, rewind: rewind)) as? Int
    let choices = rewind ? rewindChoices : aheadChoices
    return value.flatMap { choices.contains($0) ? $0 : nil } ?? (rewind ? (ts ? 10 : 15) : 2)
  }
  static func save(_ value: Int, ts: Bool, rewind: Bool) {
    guard (rewind ? rewindChoices : aheadChoices).contains(value) else { return }
    UserDefaults.standard.set(value, forKey: key(ts: ts, rewind: rewind))
  }
  static func label(_ count: Int, ts: Bool) -> String {
    if count == 0 { return "オフ" }
    return "\(ts ? "約" : "")\(Int((Double(count)*interval(ts: ts)).rounded()))秒"
  }
}

struct NeoHLSManifest {
  struct Segment { let url: URL; let start: Double; let duration: Double }
  let lines: [String], segments: [Segment]
  var duration: Double { segments.last.map { $0.start+$0.duration } ?? 0 }
  init(text: String, source: URL) throws {
    lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard lines.first == "#EXTM3U", lines.contains("#EXT-X-ENDLIST") else { throw NeoError("録画用HLSを読み取れません。") }
    var items: [Segment] = [], pending: Double?, position = 0.0
    for line in lines {
      // NeoEPGStation emits muxed MPEG-TS VOD; reject other formats rather
      // than forwarding an unproxied key/init resource with lost credentials.
      guard !line.hasPrefix("#EXT-X-KEY:"), !line.hasPrefix("#EXT-X-MAP:"), !line.hasPrefix("#EXT-X-BYTERANGE:") else { throw NeoError("このHLS形式には対応していません。") }
      if line.hasPrefix("#EXTINF:") { pending = Double(line.dropFirst(8).split(separator: ",")[0]); continue }
      if line.hasPrefix("#") { continue }
      guard let duration = pending, duration > 0, duration.isFinite,
        let url = URL(string: line, relativeTo: source)?.absoluteURL,
        url.scheme == source.scheme, url.host == source.host, url.port == source.port,
        url.user == nil, url.password == nil else { throw NeoError("HLSの区間情報が不正です。") }
      items.append(Segment(url: url, start: position, duration: duration)); position += duration; pending = nil
    }
    guard !items.isEmpty, pending == nil else { throw NeoError("HLSの区間がありません。") }
    segments = items
  }
  func index(at time: Double) -> Int { segments.lastIndex(where: { $0.start <= max(0, time) }) ?? 0 }
  func localPlaylist(route: String) -> Data {
    var index = 0
    return Data((lines.map { line in
      guard !line.hasPrefix("#") else { return line }
      defer { index += 1 }; return "\(route)/segments/\(index).ts"
    }.joined(separator: "\n")+"\n").utf8)
  }
}
