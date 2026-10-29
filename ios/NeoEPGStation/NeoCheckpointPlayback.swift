import Foundation
import AetherEngine
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

private struct NeoCheckpointPacketID: Equatable, Sendable {
  let pts, dts, position: Int64
  let size: Int
  init(_ packet: UnsafeMutablePointer<AVPacket>) {
    pts = packet.pointee.pts; dts = packet.pointee.dts
    position = packet.pointee.pos; size = Int(packet.pointee.size)
  }
  init(_ packet: NeoAV1PacketData) {
    pts = packet.pts; dts = packet.dts; position = packet.position; size = packet.bytes.count
  }
}
private final class NeoCheckpointPoint: @unchecked Sendable {
  var state: OpaquePointer?
  let packet: NeoCheckpointPacketID, seconds: Double
  let slot: NeoCheckpointPlacement.Slot
  var bytes = 0
  init(state: OpaquePointer, packet: NeoCheckpointPacketID, seconds: Double, slot: NeoCheckpointPlacement.Slot) {
    self.state = state; self.packet = packet; self.seconds = seconds; self.slot = slot
  }
  deinit { neo_av1_saved_free(&state) }
}

/// Player-local cache. No pointer or snapshot can cross a recording/session.
final class NeoCheckpointPlayback: @unchecked Sendable {
  static let budget = 128 * 1024 * 1024
  let enabled: Bool
  fileprivate let session = UInt64.random(in: 1...UInt64.max)
  private let lock = NSLock()
  private let compression = DispatchQueue(label: "neo.checkpoint.compress", qos: .utility)
  private let ahead = DispatchQueue(label: "neo.checkpoint.ahead", qos: .utility)
  private var points: [NeoCheckpointPoint] = []
  private var leased: NeoCheckpointPoint?
  private var position = 0.0, stopped = false, compressionBusy = false, aheadBusy = false
  private var pausedUntil = 0.0, revision: UInt64 = 0
  private var keys: [Double] = []
  private var costs: [NeoCheckpointPlacement.CostSample] = []
  private var saved = 0, savedAhead = 0, hits = 0, misses = 0, evicted = 0
  private var extra = Data(), timeBase = 0.001
  // Owned exclusively by the ahead queue; shutdown is queued behind work.
  private var aheadDecoder: NeoCheckpointDecoder?
  private var lastAheadPacket: NeoCheckpointPacketID?
  private var runtimeDisabled = false
  private var failure: (@Sendable (Int32) -> Void)?
  private var recovery: (@Sendable (Double) -> Void)?
  private var skipNextSelection = false
  private var recoveries = 0, rejected = 0, recreated = 0, hitsAfterRecovery = 0
#if targetEnvironment(simulator)
  private var probeRejectRestore = false
  func probeRejectNextRestore() { lock.lock(); probeRejectRestore = true; lock.unlock() }
  fileprivate func takeProbeRejection() -> Bool {
    lock.lock(); defer { lock.unlock() }
    let result = probeRejectRestore; probeRejectRestore = false; return result
  }
#endif
  init(enabled: Bool) { self.enabled = enabled }
  func onFailure(_ callback: @escaping @Sendable (Int32) -> Void) {
    lock.lock(); failure = callback; lock.unlock()
  }
  func onRecovery(_ callback: @escaping @Sendable (Double) -> Void) {
    lock.lock(); recovery = callback; lock.unlock()
  }
  fileprivate func fail(_ code: Int32) {
    lock.lock()
    guard !runtimeDisabled, !stopped else { lock.unlock(); return }
    runtimeDisabled = true; revision &+= 1; leased = nil; points.removeAll()
    let callback = failure; lock.unlock()
    NeoPlaybackDiagnostics.record("checkpoint.fallback", fields: ["code": code])
    callback?(code)
  }
  func makeDecoder() -> any NeoAV1PlaybackDecoding {
    NeoCheckpointDecoder(owner: self, foreground: true)
  }
  fileprivate func configure(extra: Data, timeBase: Double) {
    lock.lock(); self.extra = extra; self.timeBase = timeBase; lock.unlock()
  }
  fileprivate func key(_ seconds: Double) {
    observeKeys([seconds])
  }
  private func observeKeys(_ values: [Double]) {
    guard enabled else { return }
    lock.lock()
    let observed = NeoCheckpointPlacement.normalized(keys+values).filter { $0 >= position-180 && $0 <= position+120 }
    guard observed != keys, !stopped else { lock.unlock(); return }
    keys = observed
    let plan = NeoCheckpointPlacement.slots(keyframes: keys, in: (position-60)...(position+20))
    lock.unlock()
    NeoPlaybackDiagnostics.record("checkpoint.placement", fields: ["keyframesMs": observed.map { $0*1000 },
      "plannedMs": plan.filter { !$0.provisional }.map { $0.seconds*1000 },
      "provisionalMs": plan.filter(\.provisional).map { $0.seconds*1000 }, "targetGapMs": 6000])
  }
  fileprivate func reserve(at seconds: Double) -> NeoCheckpointPlacement.Slot? {
    lock.lock(); defer { lock.unlock() }
    guard enabled, !runtimeDisabled, !stopped, !compressionBusy, ProcessInfo.processInfo.systemUptime >= pausedUntil,
          seconds >= position - 60, seconds <= position + 20,
          let slot = NeoCheckpointPlacement.adaptiveCandidate(at: seconds, keyframes: keys, saved: points.map(\.seconds), costs: costs) else { return nil }
    compressionBusy = true; return slot
  }
  fileprivate func canStore(_ slot: NeoCheckpointPlacement.Slot, at seconds: Double) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return !stopped && !runtimeDisabled && seconds >= position-60 && seconds <= position+20 &&
      NeoCheckpointPlacement.canStore(slot, at: seconds, keyframes: keys, saved: points.map(\.seconds))
  }
  fileprivate func cancelReservation() { lock.lock(); compressionBusy = false; lock.unlock() }
  fileprivate func measuredCost(from start: Double, to end: Double, milliseconds: Double) {
    guard start.isFinite, end.isFinite, end > start, milliseconds.isFinite, milliseconds >= 0 else { return }
    lock.lock()
    guard !stopped else { lock.unlock(); return }
    // A rewind can measure the same interval again; replace overlapping old
    // observations instead of counting the decoding work twice.
    costs.removeAll { $0.end > start && $0.start < end || $0.end < position-180 || $0.start > position+120 }
    costs.append(.init(start: start, end: end, milliseconds: milliseconds))
    if costs.count > 640 { costs.removeFirst(costs.count-640) }
    lock.unlock()
    NeoPlaybackDiagnostics.record("checkpoint.decodeCost", fields: ["startMs": start*1000, "endMs": end*1000, "decodeMs": milliseconds])
  }
  fileprivate func compress(_ point: NeoCheckpointPoint, foreground: Bool) {
    compression.async { [self, point] in
      let began = ProcessInfo.processInfo.systemUptime
      let result = neo_av1_saved_encode(point.state)
      let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
      point.bytes = result == 0 ? Int(neo_av1_saved_bytes(point.state)) : 0
      lock.lock()
      compressionBusy = false
      var stored = false
      let nearestSavedGap = points.map { abs($0.seconds-point.seconds) }.min()
      if !stopped, !runtimeDisabled, result == 0, point.bytes <= Self.budget,
         point.seconds >= position - 60, point.seconds <= position + 20,
         ProcessInfo.processInfo.systemUptime >= pausedUntil,
         NeoCheckpointPlacement.canStore(point.slot, at: point.seconds, keyframes: keys, saved: points.map(\.seconds)),
         !points.contains(where: { $0.packet == point.packet }) {
        points.append(point); saved += 1
        stored = true
        if !foreground { savedAhead += 1 }
        pruneLocked()
      }
      lock.unlock()
      NeoPlaybackDiagnostics.record("checkpoint.saved", fields: ["status": result,
        "source": foreground ? "playback" : "lookahead", "positionMs": point.seconds*1000,
        "heldBytes": point.bytes, "compressionMs": elapsed, "stored": stored,
        "plannedMs": point.slot.seconds*1000, "keyframeMs": point.slot.keyframe*1000,
        "nextKeyframeMs": point.slot.nextKeyframe.map { $0*1000 } ?? -1,
        "provisional": point.slot.provisional, "basis": point.slot.basis, "decodeMs": point.slot.decodeMs,
        "decodeBudgetMs": NeoCheckpointPlacement.decodeBudgetMs,
        "nearestSavedGapMs": nearestSavedGap.map { $0*1000 } ?? -1,
        "minimumSpacingMs": NeoCheckpointPlacement.minimumSpacing*1000])
    }
  }
  private func pruneLocked() {
    let old = points.count
    points.removeAll { $0 !== leased && ($0.seconds < position - 60 || $0.seconds > position + 20) }
    while points.reduce(0, { $0 + $1.bytes }) > Self.budget {
      guard let index = points.indices.filter({ points[$0] !== leased }).max(by: {
        abs(points[$0].seconds-position) < abs(points[$1].seconds-position)
      }) else { break }
      points.remove(at: index)
    }
    evicted += old - points.count
  }
  fileprivate func select(target: Double, keyframe: Double) -> NeoCheckpointPoint? {
    lock.lock(); defer { lock.unlock() }
    leased = nil; position = target; revision &+= 1; pruneLocked()
    guard enabled, !runtimeDisabled, !stopped else { return nil }
    if skipNextSelection { skipNextSelection = false; misses += 1; return nil }
    // A real keyframe closer to the target wins. Captures are after the anchor
    // packet, so the target must follow every frame drained at that boundary.
    leased = points.filter { $0.seconds > keyframe && $0.seconds + 0.05 < target && target - $0.seconds <= 60 }
      .max { $0.seconds < $1.seconds }
    if leased == nil { misses += 1 }
    return leased
  }
  fileprivate func restored(_ point: NeoCheckpointPoint, result: Int32, elapsed: Double, info: NeoAV1RestoreInfo) {
    lock.lock()
    if result == 0 { hits += 1; if recoveries > 0 { hitsAfterRecovery += 1 } }
    recreated += Int(info.recreated); leased = nil; pruneLocked(); lock.unlock()
    NeoPlaybackDiagnostics.record("checkpoint.restored", fields: ["status": result,
      "checkpointMs": point.seconds*1000, "restoreMs": elapsed, "reason": info.reason,
      "stage": info.stage, "attempts": info.attempts, "decoderRecreated": info.recreated != 0,
      "initialBoundary": info.initial_boundary, "preparedBoundary": info.prepared_boundary,
      "retryBoundary": info.retry_boundary])
  }
  fileprivate func recover(_ point: NeoCheckpointPoint, target: Double, code: Int32, reason: Int32) {
    // A bad snapshot is local to that point. Readiness/resource failures do not
    // implicate other points, and the recovery seek must bypass checkpoints once.
    lock.lock()
    guard !stopped, !runtimeDisabled else { lock.unlock(); return }
    if reason == Int32(NEO_AV1_RESTORE_SNAPSHOT) || reason == Int32(NEO_AV1_RESTORE_UNENCODED) ||
       reason == Int32(NEO_AV1_RESTORE_ANCHOR) {
      let old = points.count; points.removeAll { $0 === point }; rejected += old-points.count
    }
    leased = nil; skipNextSelection = true; revision &+= 1; recoveries += 1
    let callback = recovery; lock.unlock()
    NeoPlaybackDiagnostics.record("checkpoint.recovery", fields: ["code": code, "reason": reason,
      "checkpointMs": point.seconds*1000, "targetMs": target*1000, "action": "ordinary-seek-once"])
    callback?(target)
  }
  fileprivate func releaseLease() { lock.lock(); leased = nil; pruneLocked(); lock.unlock() }
  var needsAheadRun: Bool {
    lock.lock(); defer { lock.unlock() }
    return enabled && !runtimeDisabled && !stopped && !aheadBusy && ProcessInfo.processInfo.systemUptime >= pausedUntil
      && !points.contains(where: { $0.seconds >= position + 14 })
  }
  func updatePosition(_ seconds: Double) {
    guard seconds.isFinite else { return }
    lock.lock(); position = seconds; pruneLocked(); lock.unlock()
  }
  func offer(_ run: NeoAV1PacketRun) {
    guard enabled else { return }
    // Publish all already-known boundaries before feeding the first packet.
    // A future key timestamp is useful even when its payload lies beyond 20s.
    observeKeys(run.keyframes)
    lock.lock()
    guard enabled, !runtimeDisabled, !stopped, !aheadBusy else { lock.unlock(); return }
    position = run.sourcePosition; timeBase = run.secondsPerTick; pruneLocked()
    let config = extra, stamp = revision
    aheadBusy = true; lock.unlock()
    ahead.async { [self, run] in
      if aheadDecoder == nil {
        let decoder = NeoCheckpointDecoder(owner: self, foreground: false)
        decoder.configure(timeBase: run.secondsPerTick, extra: config)
        aheadDecoder = decoder
      }
      var begin = 0
      if let lastAheadPacket, let index = run.packets.firstIndex(where: { NeoCheckpointPacketID($0) == lastAheadPacket }) {
        begin = index + 1
      } else {
        aheadDecoder?.resetForAhead(); lastAheadPacket = nil
        lock.lock()
        let seed = points.filter { point in run.packets.contains(where: { NeoCheckpointPacketID($0) == point.packet }) }
          .max { $0.seconds < $1.seconds }
        lock.unlock()
        if let seed, let index = run.packets.firstIndex(where: { NeoCheckpointPacketID($0) == seed.packet }),
           aheadDecoder?.seedAhead(seed) == true {
          begin = index + 1; lastAheadPacket = seed.packet
        }
      }
      processAhead(run, index: begin, revision: stamp)
    }
  }
  private func processAhead(_ run: NeoAV1PacketRun, index start: Int, revision stamp: UInt64) {
    let began = ProcessInfo.processInfo.systemUptime
    var index = start
    while index < run.packets.count {
      lock.lock(); let valid = !stopped && !runtimeDisabled && revision == stamp && ProcessInfo.processInfo.systemUptime >= pausedUntil
      let frontier = position + 20, waitingForCompression = compressionBusy; lock.unlock()
      guard valid else { finishAhead(); return }
      if waitingForCompression {
        // Let the single compressor finish before racing beyond the next slot.
        // Foreground playback never waits on this utility-only pacing.
        let next = index
        ahead.asyncAfter(deadline: .now()+0.015) { [self, run] in processAhead(run, index: next, revision: stamp) }
        return
      }
      let packet = run.packets[index]
      if Double(packet.pts) * run.secondsPerTick > frontier { finishAhead(); return }
      if aheadDecoder?.feedAhead(packet) != 0 { aheadDecoder?.resetForAhead(); lastAheadPacket = nil; finishAhead(); return }
      lastAheadPacket = NeoCheckpointPacketID(packet); index += 1
      // Bound each utility burst; never spawn a second lookahead decoder or queue.
      if ProcessInfo.processInfo.systemUptime - began > 0.025 {
        let next = index
        ahead.asyncAfter(deadline: .now()+0.015) { [self, run] in processAhead(run, index: next, revision: stamp) }
        return
      }
    }
    finishAhead()
  }
  private func finishAhead() { lock.lock(); aheadBusy = false; lock.unlock() }
  func report() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    pruneLocked()
    return ["enabled": enabled, "points": points.count, "heldBytes": points.reduce(0) { $0+$1.bytes },
      "budgetBytes": Self.budget, "playheadMs": position*1000, "saved": saved, "lookaheadSaved": savedAhead,
      "hits": hits, "misses": misses, "evicted": evicted, "compressionBusy": compressionBusy,
      "recoveries": recoveries, "rejected": rejected, "decoderRecreations": recreated, "hitsAfterRecovery": hitsAfterRecovery,
      "aheadBusy": aheadBusy, "fallback": runtimeDisabled, "oldestMs": (points.map(\.seconds).min() ?? position)*1000,
      "newestMs": (points.map(\.seconds).max() ?? position)*1000,
      "processFootprintBytes": neo_checkpoint_lab_footprint()]
  }
  func memoryWarning() {
    lock.lock(); pausedUntil = ProcessInfo.processInfo.systemUptime + 15; revision &+= 1
    points.removeAll { $0 !== leased }; lock.unlock()
    ahead.async { [self] in aheadDecoder?.close(); aheadDecoder = nil; lastAheadPacket = nil }
  }
  func stop() {
    lock.lock(); stopped = true; revision &+= 1; leased = nil; points.removeAll(); lock.unlock()
    ahead.async { [self] in aheadDecoder?.close(); aheadDecoder = nil; lastAheadPacket = nil }
  }
}

private final class NeoCheckpointDecoder: NeoAV1PlaybackDecoding, @unchecked Sendable {
  private let owner: NeoCheckpointPlayback, foreground: Bool
  private var decoder: OpaquePointer?
  private var frame = av_frame_alloc()
  private var secondsPerTick = 0.001, largestOutput = -Double.infinity, captureRetryAfter = -Double.infinity
  private var extradata = Data()
  private var emit: (@Sendable (UnsafeMutablePointer<AVFrame>) -> Void)?
  private var planned: NeoCheckpointPoint?, skipped = 0
  private var plannedTarget = 0.0, awaitingRecovery = false
  private var costStart = -Double.infinity, costMilliseconds = 0.0
  private var recentCostRates: [Double] = []
  private var seekSkipCount: UInt64 = 0
  init(owner: NeoCheckpointPlayback, foreground: Bool) { self.owner = owner; self.foreground = foreground }
  func open(stream: UnsafeMutablePointer<AVStream>) throws {
    guard let par = stream.pointee.codecpar, par.pointee.codec_id == AV_CODEC_ID_AV1,
          par.pointee.width <= 1920, par.pointee.height <= 1080 else {
      throw NSError(domain: "NeoCheckpointPlayback", code: 1)
    }
    let tb = stream.pointee.time_base
    var extra = Data()
    if let bytes = par.pointee.extradata, par.pointee.extradata_size > 4 {
      let count = Int(par.pointee.extradata_size)
      extra = bytes[0] & 0x80 != 0 ? Data(bytes: bytes+4, count: count-4) : Data(bytes: bytes, count: count)
    }
    configure(timeBase: Double(tb.num)/Double(tb.den), extra: extra)
    guard decoder != nil else { throw NSError(domain: "NeoCheckpointPlayback", code: 2) }
    if foreground { owner.configure(extra: extra, timeBase: secondsPerTick) }
  }
  func configure(timeBase: Double, extra: Data) {
    secondsPerTick = timeBase; extradata = extra; decoder = neo_av1_playback_open(owner.session)
    feedExtra()
  }
  private func feedExtra() {
    guard !extradata.isEmpty else { return }
    extradata.withUnsafeBytes { data in
      _ = neo_av1_playback_feed(decoder, data.bindMemory(to: UInt8.self).baseAddress, data.count, Int64.min, 0, -1, nil, nil)
    }
  }
  fileprivate func deliver(_ picture: NeoAV1Frame) {
    let seconds = Double(picture.timestamp) * secondsPerTick
    if picture.timestamp != Int64.min { largestOutput = max(largestOutput, seconds) }
    if foreground, plannedTarget > 0, seconds >= plannedTarget {
      let count = neo_av1_playback_skipped(decoder)
      NeoPlaybackDiagnostics.record("checkpoint.preroll", fields: ["targetMs": plannedTarget*1000,
        "firstOutputMs": seconds*1000, "skippedFrames": count >= seekSkipCount ? count-seekSkipCount : count])
      plannedTarget = 0
    }
    guard foreground, let frame, let emit else { return }
    frame.pointee.width = Int32(picture.width); frame.pointee.height = Int32(picture.height)
    frame.pointee.format = picture.depth > 8 ? AV_PIX_FMT_YUV420P10LE.rawValue : AV_PIX_FMT_YUV420P.rawValue
    frame.pointee.pts = picture.timestamp; frame.pointee.duration = picture.duration
    frame.pointee.data.0 = UnsafeMutablePointer(mutating: picture.plane.0)
    frame.pointee.data.1 = UnsafeMutablePointer(mutating: picture.plane.1)
    frame.pointee.data.2 = UnsafeMutablePointer(mutating: picture.plane.2)
    frame.pointee.linesize.0 = Int32(picture.stride.0)
    frame.pointee.linesize.1 = Int32(picture.stride.1); frame.pointee.linesize.2 = Int32(picture.stride.1)
    frame.pointee.color_primaries = AVColorPrimaries(rawValue: numericCast(picture.primaries))
    frame.pointee.color_trc = AVColorTransferCharacteristic(rawValue: numericCast(picture.transfer))
    frame.pointee.colorspace = AVColorSpace(rawValue: numericCast(picture.matrix))
    frame.pointee.color_range = picture.full_range != 0 ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
    emit(frame)
    // The planes remain borrowed: av_frame_unref must never own/free them.
    frame.pointee.data.0 = nil; frame.pointee.data.1 = nil; frame.pointee.data.2 = nil
  }
  func decode(packet: UnsafeMutablePointer<AVPacket>?, emit: @escaping @Sendable (UnsafeMutablePointer<AVFrame>) -> Void) -> Int32 {
    self.emit = emit; defer { self.emit = nil }
    if awaitingRecovery { return 0 }
    guard let packet else {
      if let point = planned { recoverMissingAnchor(point); return 0 }
      return neo_av1_playback_drain(decoder, neoCheckpointOutput, Unmanaged.passUnretained(self).toOpaque())
    }
    let result = feed(bytes: packet.pointee.data, count: Int(packet.pointee.size), pts: packet.pointee.pts,
                duration: packet.pointee.duration, position: packet.pointee.pos, flags: packet.pointee.flags,
                id: NeoCheckpointPacketID(packet))
    if result < 0 { owner.fail(result) }
    return result
  }
  func feedAhead(_ packet: NeoAV1PacketData) -> Int32 {
    packet.bytes.withUnsafeBytes { bytes in
      feed(bytes: bytes.bindMemory(to: UInt8.self).baseAddress, count: bytes.count, pts: packet.pts,
           duration: packet.duration, position: packet.position, flags: packet.flags, id: NeoCheckpointPacketID(packet))
    }
  }
  private func feed(bytes: UnsafePointer<UInt8>?, count: Int, pts: Int64, duration: Int64,
                    position: Int64, flags: Int32, id: NeoCheckpointPacketID) -> Int32 {
    guard decoder != nil else { return -22 }
    if let point = planned {
      skipped += 1
      if point.packet == id {
        let began = ProcessInfo.processInfo.systemUptime
        var info = NeoAV1RestoreInfo()
        var result: Int32
#if targetEnvironment(simulator)
        if owner.takeProbeRejection() {
          result = -22; info.reason = Int32(NEO_AV1_RESTORE_SNAPSHOT)
          NeoPlaybackDiagnostics.record("checkpoint.probeRejection", fields: ["checkpointMs": point.seconds*1000])
        } else { result = neo_av1_playback_restore_detailed(decoder, point.state, &info) }
#else
        result = neo_av1_playback_restore_detailed(decoder, point.state, &info)
#endif
        owner.restored(point, result: result, elapsed: (ProcessInfo.processInfo.systemUptime-began)*1000, info: info)
        planned = nil; skipped = 0; largestOutput = point.seconds
        if result != 0 {
          // Hold all obsolete packets until the host's single recovery seek
          // flushes this decoder. Never decode a suffix with a failed state.
          awaitingRecovery = true
          if info.reason == Int32(NEO_AV1_RESTORE_ARGUMENT) || info.reason == Int32(NEO_AV1_RESTORE_SESSION) ||
             info.reason == Int32(NEO_AV1_RESTORE_SETUP) { owner.fail(result) }
          else { owner.recover(point, target: plannedTarget, code: result, reason: info.reason) }
        }
        return 0
      }
      if skipped > 4096 { recoverMissingAnchor(point) }
      return 0
    }
    if flags & 1 != 0 { owner.key(Double(pts)*secondsPerTick) }
    if !foreground, !costStart.isFinite, pts != Int64.min { costStart = Double(pts)*secondsPerTick }
    let began = ProcessInfo.processInfo.systemUptime
    let result = neo_av1_playback_feed(decoder, bytes, count, pts, duration, position,
                                      neoCheckpointOutput, Unmanaged.passUnretained(self).toOpaque())
    if !foreground {
      costMilliseconds += (ProcessInfo.processInfo.systemUptime-began)*1000
      if largestOutput-costStart >= 0.5 {
        let span = largestOutput-costStart
        recentCostRates.append(costMilliseconds/span)
        if recentCostRates.count > 3 { recentCostRates.removeFirst() }
        let rates = recentCostRates.sorted()
        owner.measuredCost(from: costStart, to: largestOutput, milliseconds: rates[rates.count/2]*span)
        costStart = largestOutput; costMilliseconds = 0
      }
    }
    guard result == 0, position >= 0, largestOutput.isFinite, largestOutput >= captureRetryAfter,
          let slot = owner.reserve(at: largestOutput) else { return result }
    let drainBegan = ProcessInfo.processInfo.systemUptime
    let drained = neo_av1_playback_drain(decoder, neoCheckpointOutput, Unmanaged.passUnretained(self).toOpaque())
    if !foreground { costMilliseconds += (ProcessInfo.processInfo.systemUptime-drainBegan)*1000 }
    guard drained == 0, owner.canStore(slot, at: largestOutput), let state = neo_av1_playback_capture(decoder) else {
      captureRetryAfter = largestOutput+0.5; owner.cancelReservation()
      NeoPlaybackDiagnostics.record("checkpoint.captureMiss", fields: ["status": drained])
      return drained
    }
    captureRetryAfter = -.infinity
    owner.compress(NeoCheckpointPoint(state: state, packet: id, seconds: largestOutput, slot: slot), foreground: foreground)
    return 0
  }
  func prepareCheckpointSeek(to sourceSeconds: Double, afterKeyframe: Double) {
    planned = owner.select(target: sourceSeconds, keyframe: afterKeyframe); plannedTarget = sourceSeconds; skipped = 0
    seekSkipCount = neo_av1_playback_skipped(decoder)
    let ticks = ceil(sourceSeconds/secondsPerTick)
    if ticks.isFinite, ticks >= Double(Int64.min)+2048, ticks < Double(Int64.max)-2048 {
      neo_av1_playback_set_target(decoder, Int64(ticks))
    }
    NeoPlaybackDiagnostics.record("checkpoint.seekPlan", fields: ["hit": planned != nil, "targetMs": sourceSeconds*1000,
      "keyframeMs": afterKeyframe*1000, "checkpointMs": planned.map { $0.seconds*1000 } ?? -1])
  }
  private func recoverMissingAnchor(_ point: NeoCheckpointPoint) {
    planned = nil; skipped = 0; awaitingRecovery = true
    owner.recover(point, target: plannedTarget, code: -22, reason: Int32(NEO_AV1_RESTORE_ANCHOR))
  }
  func flush() {
    planned = nil; skipped = 0; awaitingRecovery = false; if foreground { owner.releaseLease() }
    largestOutput = -.infinity; captureRetryAfter = -.infinity
    costStart = -.infinity; costMilliseconds = 0; plannedTarget = 0; seekSkipCount = 0
    recentCostRates.removeAll(keepingCapacity: true)
    neo_av1_playback_flush(decoder); feedExtra()
  }
  func resetForAhead() { flush() }
  func seedAhead(_ point: NeoCheckpointPoint) -> Bool {
    guard neo_av1_playback_restore(decoder, point.state) == 0 else { resetForAhead(); return false }
    largestOutput = point.seconds; captureRetryAfter = -.infinity; return true
  }
  func close() { planned = nil; neo_av1_playback_close(&decoder) }
  deinit { close(); av_frame_free(&frame) }
}
private func neoCheckpointOutput(_ cookie: UnsafeMutableRawPointer?, _ picture: UnsafePointer<NeoAV1Frame>?) {
  guard let cookie, let picture else { return }
  Unmanaged<NeoCheckpointDecoder>.fromOpaque(cookie).takeUnretainedValue().deliver(picture.pointee)
}
