import Foundation
import Darwin

// Only the log sink is stubbed. The packet store, producer, coverage and seek
// implementation below are the actual patched engine sources used by the app.
enum EngineLog {
  enum Category { case swPlayback }
  static func emit(_ message: String, category: Category) {}
}
enum QoSClass { static func name(_ value: qos_class_t) -> String { "test" } }
func expect(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
  assert(value, message, file: file, line: line)
}

final class Input: @unchecked Sendable {
  let packets: [SoftwareStoredPacket]
  let lock = NSLock()
  private var count = 0
  init(audio: Bool) {
    var result: [SoftwareStoredPacket] = []
    for ms in stride(from: 0, to: 60000, by: 20) {
      if ms % 40 == 0 {
        result.append(.init(pts: Int64(ms), dts: Int64(ms), duration: 40, position: Int64(ms*2), streamIndex: 0,
          flags: [0,22280,47320].contains(ms) ? 1 : 0, timeBaseNumerator: 1, timeBaseDenominator: 1000,
          bytes: Data([UInt8(ms % 251),0,255]), sideData: [.init(type: 7, bytes: Data([3,8]))]))
      }
      if audio {
        result.append(.init(pts: Int64(ms), dts: Int64(ms), duration: 20, position: Int64(ms*2+1), streamIndex: 1,
          flags: 1, timeBaseNumerator: 1, timeBaseDenominator: 1000, bytes: Data([1,2,3]), sideData: []))
      }
    }
    packets = result
  }
  func next() -> SoftwareStoredPacket? {
    lock.lock(); defer { lock.unlock() }
    defer { count += 1 }
    return count < packets.count ? packets[count] : nil
  }
  var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
}

func fixture(audio: Bool = true, independent: Bool = true, preroll: Double? = 0.1)
    throws -> (SoftwarePacketReadAhead, Input) {
  let input = Input(audio: audio)
  let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64*1024, retainConsumed: true)
  let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
    audio: audio ? .init(index: 1, numerator: 1, denominator: 1000) : nil,
    byteBudget: 8*1024*1024, forwardSeconds: 100, initialSourceClock: 0, fifo: fifo,
    independentVideoKeys: independent, audioSeekPrerollSeconds: preroll) { _ in input.next() }
  source.start()
  let deadline = Date().addingTimeInterval(10)
  while !source.snapshot.sourceEnded, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
  expect(source.snapshot.sourceEnded, "Producer must have actually retained the input")
  return (source,input)
}

func firstPackets(_ source: SoftwarePacketReadAhead, target: Double, audio: Bool = true)
    throws -> (video: SoftwareStoredPacket, audio: SoftwareStoredPacket?) {
  let token = source.beginSeek(to: target)
  expect(try source.prepareSeek(token, to: target), "Must use retained data")
  source.endSeek(token, sourceClock: target)
  var video: SoftwareStoredPacket?, sound: SoftwareStoredPacket?
  for _ in 0..<5000 {
    guard let packet = try source.read() else { break }
    if packet.streamIndex == 0, video == nil { video = packet }
    if packet.streamIndex == 1, sound == nil { sound = packet }
    if video != nil && (!audio || sound != nil) { break }
  }
  expect(video != nil && (!audio || sound != nil))
  return (video!,sound)
}

do {
  let (source,input) = try fixture()
  defer { source.close() }
  let reads = input.reads
  for target in [47.84,47.32,23.0,47.84,0.52] {
    let result = try firstPackets(source, target: target)
    let key = target >= 47.32 ? 47320 : target >= 22.28 ? 22280 : 0
    expect(result.video.pts == key && result.video.flags & 1 != 0,
      "Video must start from the nearest independent key, never the preceding GOP")
    expect(result.video == input.packets.first { $0.streamIndex == 0 && $0.pts == key }, "Envelope bytes and side data survive")
    if key > 0 {
      let audioStart = Double(result.audio!.pts)/1000
      expect(audioStart <= Double(key)/1000-0.1+0.00001 && audioStart >= Double(key)/1000-0.15,
        "AAC warm-up must be bounded independently of a 25-second video GOP")
    }
  }
  expect(input.reads == reads && source.snapshot.cacheSeekMisses == 0, "Cached seeks must not reopen/refetch")
  let obsolete = source.beginSeek(to: 47.84)
  let current = source.beginSeek(to: 23)
  do { _ = try source.prepareSeek(obsolete, to: 47.84); assertionFailure("Obsolete seek accepted") }
  catch SoftwarePacketReadAhead.ReadError.interrupted {}
  expect(try source.prepareSeek(current, to: 23))
  source.endSeek(current, sourceClock: 23)
  do { _ = try source.read(isCurrent: { false }); assertionFailure("Stale consumer accepted") }
  catch SoftwarePacketReadAhead.ReadError.interrupted {}
  expect(try firstPackets(source, target: 47.84).video.pts == 47320, "Cancellation must not leak an earlier gate")
}
do {
  let (source,_) = try fixture(audio: false)
  defer { source.close() }
  expect(try firstPackets(source, target: 47.84, audio: false).video.pts == 47320)
}
do {
  let (source,_) = try fixture(preroll: nil)
  defer { source.close() }
  let result = try firstPackets(source, target: 47.84)
  expect(result.video.pts == 47320 && result.audio!.pts < 23000,
    "Unknown audio keeps conservative preroll while earlier video never reaches the decoder")
}
do {
  let (source,_) = try fixture(independent: false)
  defer { source.close() }
  expect(try firstPackets(source, target: 47.84).video.pts == 22280,
    "Do not change open-GOP policy for other codecs")
}
print("PASS: actual retained FIFO; nearest AV1 keys; bounded AAC warm-up; unknown audio; legacy open GOP; repeated seeks; cancellation; packet fidelity; zero source reads")
