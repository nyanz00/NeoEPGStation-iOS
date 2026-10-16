import Foundation

// Timing-only ARIB adapter. Glyphs, colors and DRCS remain rendered by VLC.
// Read already downloaded TS packets; never perform another media request.
struct NeoARIBTiming {
  private var nextOffset: Int64 = -1, carry = Data()
  private var origin: Double?
  private var packets: [Int: Data] = [:], counters: [Int: Int] = [:]
  private var events: [Int64: Bool] = [:]
  var schedule: [(Double, Bool)] { events.sorted { $0.key < $1.key }.map { (Double($0.key)/1000, $0.value) } }

  mutating func observe(_ data: Data, offset: Int64) {
    if offset != nextOffset { carry.removeAll(); packets.removeAll(); counters.removeAll() }
    let carryCount = carry.count
    var bytes = Array(carry); bytes.append(contentsOf: data); carry.removeAll()
    let absolute = offset-Int64(carryCount)
    var at = Int((188-absolute%188)%188)
    while at+188 <= bytes.count {
      defer { at += 188 }
      guard bytes[at] == 0x47, bytes[at+1] & 0x80 == 0 else { continue }
      let pid = Int(bytes[at+1]&31)*256+Int(bytes[at+2]), flags = bytes[at+3]
      var payload = at+4
      if flags & 0x20 != 0 {
        let count = Int(bytes[payload]); payload += 1
        guard payload+count <= at+188 else { continue }
        if count >= 7, bytes[payload] & 0x10 != 0, origin == nil, absolute+Int64(at) < 1024*1024 {
          let p = payload+1
          let base = UInt64(bytes[p])<<25 | UInt64(bytes[p+1])<<17 | UInt64(bytes[p+2])<<9 | UInt64(bytes[p+3])<<1 | UInt64(bytes[p+4]>>7)
          origin = Double(base)/90000
        }
        payload += count
      }
      guard flags & 0x10 != 0, payload < at+188 else { continue }
      let cc = Int(flags & 15)
      if let old = counters[pid], old == cc { continue }
      if let old = counters[pid], (old+1)%16 != cc { packets[pid] = nil }
      counters[pid] = cc
      if bytes[at+1] & 0x40 != 0 {
        packets[pid] = nil
        guard payload+14 <= at+188, Array(bytes[payload..<payload+4]) == [0,0,1,0xbd],
              bytes[payload+7]&0x80 != 0 else { continue }
        packets[pid] = Data()
      }
      guard var packet = packets[pid], packet.count < 256*1024 else { continue }
      packet.append(contentsOf: bytes[payload..<at+188])
      if packet.count >= 6 {
        let size = 6+Int(packet[4])*256+Int(packet[5])
        if size > 6, packet.count >= size {
          parsePES(Array(packet.prefix(size))); packets[pid] = nil
        } else { packets[pid] = packet }
      } else { packets[pid] = packet }
    }
    if at < bytes.count { carry = Data(bytes[at...]) }
    nextOffset = offset+Int64(data.count)
  }
  private mutating func parsePES(_ pes: [UInt8]) {
    guard let origin, pes.count >= 17, pes[8] >= 5 else { return }
    let p = 9
    let pts = UInt64(pes[p]>>1&7)<<30 | UInt64(pes[p+1])<<22 | UInt64(pes[p+2]>>1)<<15 | UInt64(pes[p+3])<<7 | UInt64(pes[p+4]>>1)
    var seconds = Double(pts)/90000-origin
    if seconds < -40000 { seconds += Double(UInt64(1)<<33)/90000 }
    let begin = 9+Int(pes[8])
    guard begin+8 <= pes.count, pes[begin] == 0x80, pes[begin+1] == 0xff else { return }
    let group = begin+3+Int(pes[begin+2]&15)
    guard group+9 <= pes.count, (pes[group]>>2)&15 != 0 else { return } // not language management
    let end = group+5+Int(pes[group+3])*256+Int(pes[group+4])
    var unit = group+5
    guard end <= pes.count, pes[unit]>>6 == 0 else { return } // unsupported absolute-time mode stays with VLC
    unit += 1
    let loop = Int(pes[unit])<<16 | Int(pes[unit+1])<<8 | Int(pes[unit+2]); unit += 3
    guard unit+loop <= end else { return }
    let limit = unit+loop
    var elapsed = 0.0
    while unit+5 <= limit {
      let count = Int(pes[unit+2])<<16 | Int(pes[unit+3])<<8 | Int(pes[unit+4])
      let start = unit+5; unit = start+count
      guard unit <= limit else { return }
      if pes[start-4] == 0x20 { parseText(pes, start: start, end: unit, seconds: seconds, elapsed: &elapsed) }
    }
    if events.count > 20000 { for key in events.keys.sorted().prefix(events.count-20000) { events[key] = nil } }
  }
  private mutating func parseText(_ bytes: [UInt8], start: Int, end: Int, seconds: Double, elapsed: inout Double) {
    var at = start
    func key(_ elapsed: Double) -> Int64 { Int64(((seconds+elapsed)*1000).rounded()) }
    while at < end {
      let code = bytes[at]; at += 1
      if code == 0x0c { events[key(elapsed)] = false }
      else if code == 0x9d {
        guard at+1 < end, bytes[at] == 0x20 else { return }
        elapsed += Double(bytes[at+1]&63)/10; at += 2
      } else if code == 0x9b { // CSI parameters and final byte
        while at < end && bytes[at] != 0x20 { at += 1 }
        at = min(end, at+2)
      } else if code == 0x1b {
        while at < end && (0x20...0x2f).contains(bytes[at]) { at += 1 }
        at = min(end, at+1)
      } else if code == 0x19 { events[key(elapsed)] = true; at = min(end, at+1) }
      else if [0x16,0x1d,0x8b,0x91,0x93,0x94,0x97,0x98].contains(code) {
        at = min(end, at+1)
      } else if code == 0x1c { at = min(end, at+2) }
      else if code == 0x90 || code == 0x92 {
        if at < end && bytes[at] == 0x20 { at += 1 }; at = min(end, at+1)
      } else if code == 0x95 { return } // macro definitions: do not guess their display lifetime
      else if code >= 0x20 && code != 0x7f && code != 0xff && !(0x80...0x9f).contains(code) {
        events[key(elapsed)] = true
      }
    }
  }
}

@objc(NeoARIBCaptionClock)
final class NeoARIBCaptionClock: NSObject {
  private var parser = NeoARIBTiming()
  private let queue = DispatchQueue(label: "neo.arib.timing", qos: .userInitiated)
  private let lock = NSLock()
  private var events: [(Double, Bool)] = []
  @objc(observeData:offset:)
  func observe(_ data: Data, offset: Int64) {
    queue.async { [weak self] in
      guard let self else { return }
      self.parser.observe(data, offset: offset)
      let schedule = self.parser.schedule
      self.lock.lock(); self.events = schedule; self.lock.unlock()
    }
  }
  // -1 = unknown, 0 = explicit clear, 1 = active, 2 = before the first known cue.
  // A renderer can submit that first cue slightly before the player clock reaches its PTS.
  @objc func state(at seconds: Double) -> Int {
    guard seconds.isFinite else { return -1 }
    lock.lock(); defer { lock.unlock() }
    var low = 0, high = events.count
    while low < high { let mid = (low+high)/2; if events[mid].0 <= seconds { low = mid+1 } else { high = mid } }
    return low == 0 ? (events.isEmpty ? -1 : 2) : events[low-1].1 ? 1 : 0
  }
}

// Read only EBML metadata, never infer seek positions from bitrate or scan
// encoded frames. Offsets in Cues/SeekHead are relative to Segment's body.
struct NeoMatroskaSeekIndex {
  struct Element { let id: UInt64; let body: Int; let size: Int? }
  struct Cue { let time: Double; let offset: Int64 }
  let cues: [Cue]
  func nearest(_ time: Double) -> Cue? { cues.last { $0.time <= time } ?? cues.first }
  static func header(_ data: Data, at offset: Int = 0) -> Element? {
    let bytes = [UInt8](data)
    func vint(_ at: Int, id: Bool) -> (UInt64, Int, Bool)? {
      guard at >= 0, at < bytes.count, bytes[at] != 0 else { return nil }
      var width = 1, mask: UInt8 = 0x80
      while bytes[at]&mask == 0 && width < 8 { width += 1; mask >>= 1 }
      guard width <= (id ? 4 : 8), at+width <= bytes.count else { return nil }
      var value = UInt64(id ? bytes[at] : bytes[at]&(~mask))
      if width > 1 { for byte in bytes[(at+1)..<(at+width)] { value = (value<<8)|UInt64(byte) } }
      return (value, at+width, !id && value == (UInt64(1) << (7*width))-1)
    }
    guard let id = vint(offset, id: true), let size = vint(id.1, id: false), size.0 <= UInt64(Int.max) else { return nil }
    return Element(id: id.0, body: size.1, size: size.2 ? nil : Int(size.0))
  }
  static func children(_ data: Data) -> [(UInt64, Data)]? {
    var offset = 0, result: [(UInt64, Data)] = []
    while offset < data.count {
      guard let element = header(data, at: offset), let size = element.size,
        size <= data.count-element.body else { return nil }
      result.append((element.id, data.subdata(in: element.body..<(element.body+size))))
      offset = element.body+size
    }
    return result
  }
  static func unsigned(_ data: Data) -> UInt64? {
    guard !data.isEmpty, data.count <= 8 else { return nil }
    return data.reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
  }
  static func seeks(_ data: Data, segment: Int64, length: Int64) -> [UInt64: Int64] {
    var positions: [UInt64: Int64] = [:]
    for (id, body) in children(data) ?? [] where id == 0x4dbb {
      let fields = children(body) ?? []
      guard let target = fields.first(where: { $0.0 == 0x53ab }).flatMap({ unsigned($0.1) }),
        let relative = fields.first(where: { $0.0 == 0x53ac }).flatMap({ unsigned($0.1) }),
        relative < UInt64(max(0, length-segment)) else { continue }
      positions[target] = segment+Int64(relative)
    }
    return positions
  }
  init?(cues data: Data, info: Data, tracks: Data, segment: Int64, length: Int64) {
    guard let infoFields = Self.children(info), let trackFields = Self.children(tracks),
      let points = Self.children(data), segment >= 0, segment < length else { return nil }
    let scale = infoFields.first(where: { $0.0 == 0x2ad7b1 }).flatMap { Self.unsigned($0.1) } ?? 1_000_000
    guard scale > 0, scale <= 1_000_000_000 else { return nil }
    var videoTracks: Set<UInt64> = []
    for (id, body) in trackFields where id == 0xae {
      let fields = Self.children(body) ?? []
      if fields.first(where: { $0.0 == 0x83 }).flatMap({ Self.unsigned($0.1) }) == 1,
        let number = fields.first(where: { $0.0 == 0xd7 }).flatMap({ Self.unsigned($0.1) }) { videoTracks.insert(number) }
    }
    guard !videoTracks.isEmpty else { return nil }
    var result: [Cue] = []
    for (id, body) in points where id == 0xbb {
      guard let fields = Self.children(body),
        let ticks = fields.first(where: { $0.0 == 0xb3 }).flatMap({ Self.unsigned($0.1) }) else { return nil }
      let time = Double(ticks)*Double(scale)/1_000_000_000
      guard time.isFinite, time >= 0, time <= 24*60*60 else { return nil }
      for (id, track) in fields where id == 0xb7 {
        guard let values = Self.children(track) else { return nil }
        guard let number = values.first(where: { $0.0 == 0xf7 }).flatMap({ Self.unsigned($0.1) }),
          let relative = values.first(where: { $0.0 == 0xf1 }).flatMap({ Self.unsigned($0.1) }),
          relative < UInt64(length-segment) else { return nil }
        if videoTracks.contains(number) { result.append(Cue(time: time, offset: segment+Int64(relative))) }
      }
    }
    guard !result.isEmpty, result.count <= 100_000 else { return nil }
    result.sort { $0.time == $1.time ? $0.offset < $1.offset : $0.time < $1.time }
    guard zip(result, result.dropFirst()).allSatisfy({ $0.0.offset <= $0.1.offset }) else { return nil }
    cues = result
  }
}

// Source-byte/media-time mapping. TS uses PCR rather than average bitrate;
// MP4 uses each track's chunk offsets, sample sizes and decode-time table.
// Container indexes/headers are retained separately from watched media bytes.
struct NeoMediaByteClock {
  struct Span { let offset: Int64; let count: Int64; let start: Double; let end: Double }
  private(set) var spans: [Span] = []
  private var pcrOrigin: Double?, pcrPID: Int?
  private(set) var isMP4 = false
  private var matroskaScale = 0.001
  private var clusters: [(offset: Int64, time: Double)] = []
  mutating func observeMatroska(_ data: Data, offset: Int64) -> ClosedRange<Double>? {
    let bytes = [UInt8](data)
    guard bytes.count >= 16 else { return nil }
    func vint(_ i: Int) -> (value: UInt64, next: Int)? {
      guard i < bytes.count, bytes[i] != 0 else { return nil }
      var length = 1, mask: UInt8 = 0x80
      while bytes[i]&mask == 0 && length < 8 { length += 1; mask >>= 1 }
      guard i+length <= bytes.count else { return nil }
      var value = UInt64(bytes[i]&(~mask))
      if length > 1 { for j in i+1..<i+length { value = (value<<8)|UInt64(bytes[j]) } }
      return (value, i+length)
    }
    func unsigned(_ i: Int, _ n: Int) -> UInt64? {
      guard n > 0, n <= 8, i+n <= bytes.count else { return nil }
      return bytes[i..<i+n].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
    }
    for i in 0..<bytes.count-12 {
      if offset == 0, bytes[i] == 0x2a, bytes[i+1] == 0xd7, bytes[i+2] == 0xb1,
        let length = vint(i+3), length.value <= 8, let value = unsigned(length.next, Int(length.value)), value > 0, value <= 1_000_000_000 {
        matroskaScale = Double(value)/1_000_000_000
      }
      guard bytes[i] == 0x1f, bytes[i+1] == 0x43, bytes[i+2] == 0xb6, bytes[i+3] == 0x75,
        let length = vint(i+4) else { continue }
      var child = length.next
      // A cluster's first fields are its timestamp and optionally a CRC.
      if bytes[child] == 0xbf, let crc = vint(child+1), crc.value == 4 { child = crc.next+4 }
      guard child+2 <= bytes.count, bytes[child] == 0xe7, let size = vint(child+1), size.value <= 8,
        let ticks = unsigned(size.next, Int(size.value)), ticks < 86_400_000_000 else { continue }
      let point = (offset: offset+Int64(i), time: Double(ticks)*matroskaScale)
      if !clusters.contains(where: { $0.offset == point.offset }) { clusters.append(point) }
    }
    clusters.sort { $0.offset < $1.offset }
    let within = clusters.filter { $0.offset >= offset && $0.offset < offset+Int64(data.count) }
    let previous = clusters.last { $0.offset < offset }
    guard let first = within.first ?? previous, let last = within.last ?? previous else { return nil }
    // Cluster duration/keyframe preroll can extend beyond its timestamp.
    return max(0, first.time)...(last.time+10)
  }
  mutating func observeTS(_ data: Data, offset: Int64) -> ClosedRange<Double>? {
    let bytes = [UInt8](data), first = Int((188-offset%188)%188)
    guard bytes.count > first+188, bytes[first] == 0x47, bytes[first+188] == 0x47 else { return nil }
    var times: [Double] = []
    for i in stride(from: first, through: bytes.count-188, by: 188) {
      guard bytes[i] == 0x47, bytes[i+3]&0x20 != 0, bytes[i+4] >= 7, bytes[i+5]&0x10 != 0 else { continue }
      let pid = (Int(bytes[i+1]&0x1f)<<8)|Int(bytes[i+2])
      if pcrPID == nil { pcrPID = pid }; guard pid == pcrPID else { continue }
      let base = (UInt64(bytes[i+6])<<25)|(UInt64(bytes[i+7])<<17)|(UInt64(bytes[i+8])<<9)|(UInt64(bytes[i+9])<<1)|UInt64(bytes[i+10]>>7)
      let raw = Double(base)/90000
      if pcrOrigin == nil && offset == 0 { pcrOrigin = raw }
      guard let origin = pcrOrigin else { continue }
      let wrap = Double(UInt64(1)<<33)/90000
      times.append(raw >= origin ? raw-origin : raw+wrap-origin)
    }
    guard let first = times.min(), let last = times.max() else { return nil }
    return max(0, first-1)...(last+1)
  }
  func timeRange(offset: Int64, count: Int) -> ClosedRange<Double>? {
    // Binary search by source offset; a block may overlap multiple audio/video
    // chunks and is retained until the latest of those media times expires.
    var low = 0, high = spans.count
    while low < high { let mid = (low+high)/2; if spans[mid].offset < offset { low = mid+1 } else { high = mid } }
    var i = max(0, low-1), begin = Double.infinity, end = -Double.infinity
    while i < spans.count && spans[i].offset < offset+Int64(count) {
      let span = spans[i]
      if span.offset+span.count > offset { begin = min(begin, span.start); end = max(end, span.end) }
      i += 1
    }
    return begin.isFinite ? max(0, begin)...max(0, end) : nil
  }
  // Only already-downloaded payload intervals are merged. No extra parsing or
  // reads are required to paint the approximate buffered track.
  static func mergedDownloadedRanges(_ values: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
    let sorted = values.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound }
      .sorted { $0.lowerBound < $1.lowerBound }
    var result: [ClosedRange<Double>] = []
    for range in sorted {
      if let last = result.last, range.lowerBound <= last.upperBound {
        result[result.count-1] = last.lowerBound...max(last.upperBound, range.upperBound)
      } else { result.append(range) }
    }
    return result
  }
  static func number(_ data: Data, _ index: Int, bytes: Int = 4) -> UInt64? {
    guard index >= 0, index+bytes <= data.count else { return nil }
    return data[index..<index+bytes].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
  }
  private struct Atom { let kind: String; let body: Data }
  private static func atoms(_ data: Data) -> [Atom] {
    var output: [Atom] = [], i = 0
    while i+8 <= data.count {
      guard let short = number(data, i) else { break }
      let header = short == 1 ? 16 : 8
      let raw = short == 1 ? number(data, i+8, bytes: 8) ?? 0 : short == 0 ? UInt64(data.count-i) : short
      guard raw >= header, raw <= data.count-i else { break }
      let size = Int(raw)
      let kind = String(data: data.subdata(in: i+4..<i+8), encoding: .ascii) ?? ""
      output.append(Atom(kind: kind, body: data.subdata(in: i+header..<i+size))); i += size
    }; return output
  }
  mutating func loadMP4Moov(_ data: Data) -> Bool {
    var result: [Span] = []
    for trak in Self.atoms(data) where trak.kind == "trak" {
      guard let mdia = Self.atoms(trak.body).first(where: { $0.kind == "mdia" }) else { continue }
      let media = Self.atoms(mdia.body)
      guard let mdhd = media.first(where: { $0.kind == "mdhd" }),
        let scale = Self.number(mdhd.body, mdhd.body.first == 1 ? 20 : 12), scale > 0,
        let minf = media.first(where: { $0.kind == "minf" }),
        let stbl = Self.atoms(minf.body).first(where: { $0.kind == "stbl" }) else { continue }
      let tables = Self.atoms(stbl.body)
      guard let offsets = tables.first(where: { ["stco", "co64"].contains($0.kind) }),
        let stsc = tables.first(where: { $0.kind == "stsc" }), let stts = tables.first(where: { $0.kind == "stts" }),
        let stsz = tables.first(where: { $0.kind == "stsz" }),
        let chunks = Self.number(offsets.body, 4), chunks < 2_000_000,
        let runs = Self.number(stsc.body, 4), runs > 0, runs < 2_000_000,
        let timeRuns = Self.number(stts.body, 4), timeRuns > 0,
        let defaultSize = Self.number(stsz.body, 4), let samples = Self.number(stsz.body, 8), samples < 20_000_000 else { continue }
      var sample: UInt64 = 0, run = 0, timeRun = 0, remaining: UInt64 = 0, delta: UInt64 = 0, ticks: UInt64 = 0
      var valid = true, track: [Span] = []
      for chunk in 1...max(1, Int(chunks)) {
        if chunks == 0 { break }
        while run+1 < Int(runs), let next = Self.number(stsc.body, 8+(run+1)*12), next <= chunk { run += 1 }
        guard let perChunk = Self.number(stsc.body, 12+run*12), perChunk > 0, perChunk <= samples-sample,
          let offset = Self.number(offsets.body, 8+(chunk-1)*(offsets.kind == "co64" ? 8 : 4), bytes: offsets.kind == "co64" ? 8 : 4), offset <= Int64.max else { valid = false; break }
        let start = Double(ticks)/Double(scale); var count: UInt64 = 0
        for _ in 0..<Int(perChunk) {
          if remaining == 0 {
            guard timeRun < Int(timeRuns), let n = Self.number(stts.body, 8+timeRun*8), n > 0,
              let d = Self.number(stts.body, 12+timeRun*8) else { valid = false; break }
            remaining = n; delta = d; timeRun += 1
          }
          guard let bytes = defaultSize > 0 ? defaultSize : Self.number(stsz.body, 12+Int(sample)*4) else { valid = false; break }
          count += bytes; ticks += delta; remaining -= 1; sample += 1
        }
        guard valid, count <= UInt64(Int64.max)-offset else { valid = false; break }
        track.append(Span(offset: Int64(offset), count: Int64(count), start: start, end: Double(ticks)/Double(scale)))
      }
      if valid && sample == samples { result += track }
    }
    spans = result.sorted { $0.offset < $1.offset }; isMP4 = !spans.isEmpty
    return isMP4
  }
}
