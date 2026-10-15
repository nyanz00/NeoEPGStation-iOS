import Foundation

// Commands are issued once per stage. Re-selecting a track is not evidence
// of recovery: a new output must deliver changing, due pictures first.
@objc(NeoVideoRecovery)
final class NeoVideoRecovery: NSObject {
  @objc private(set) var stage = 0
  @objc private(set) var outputID = 0
  private var enabled = false, deadline = 0.0, repairTimeout = 10.0
  private var began = 0.0, media: Int64 = 0, samples = 0, changes = 0
  @objc func begin(_ now: Double, timeout: Double) {
    stage = 0; outputID = 0; enabled = true; deadline = 0
    // Recreated output can arrive late, with network-cache look-ahead still
    // queued. Give it time to become due before falling back to a new input.
    repairTimeout = min(20, max(12, timeout)); began = 0
  }
  @objc func hold(_ now: Double) {
    began = 0
    if (1...3).contains(stage) { deadline = now + (stage == 1 ? 3 : repairTimeout+(stage == 3 ? 5 : 0)) }
  }
  @objc func reset() { enabled = false; deadline = 0; began = 0; stage = 0; outputID = 0 }
  @objc func evaluate(_ stats: [String: NSNumber], mediaMs: Int64, now: Double) -> Int {
    guard enabled else { return 0 }
    let id = stats["outputID"]?.intValue ?? 0
    let count = stats["samples"]?.intValue ?? 0, change = stats["changes"]?.intValue ?? 0
    let age = stats["contentAge"]?.doubleValue ?? -1
    let scheduled = stats["scheduledInMs"]?.doubleValue ?? .infinity
    let failed = stats["layerStatus"]?.intValue == 2 || stats["requiresFlush"]?.boolValue == true
    if id != outputID || count < samples { outputID = id; began = 0 }
    if began == 0 { began = now; media = mediaMs; samples = count; changes = change }
    // Two different sampled pictures, recently delivered and due for display.
    if stage > 0 && id > 0 && change-changes >= 2 && age >= 0 && age < 0.5 &&
        scheduled <= 100 && scheduled >= -500 && !failed {
      stage = 0; deadline = 0; began = now; media = mediaMs; samples = count; changes = change
      return 1 // confirmed
    }
    if stage > 0 && now >= deadline {
      if stage == 1 { stage = 2; deadline = now+repairTimeout; began = 0; return 3 }
      if stage == 2 { stage = 3; deadline = now+repairTimeout+5; began = 0; return 4 }
      stage = 4; deadline = .infinity; return 5 // bounded failure, no reload loop
    }
    // A buffering clock may move backwards. Restart the media baseline rather
    // than waiting for it to catch up with an obsolete future timestamp.
    if mediaMs < media { media = mediaMs }
    guard stage == 0, now-began >= 3, mediaMs-media >= 1500 else { return 0 }
    let fps = Double(count-samples)/(now-began)
    let frozen: Bool
    if let arrival = stats["arrivalAge"]?.doubleValue {
      // Continuous health checks read existing timestamps only. Picture
      // fingerprinting stays limited to decoder-repair verification windows.
      let decoderStale = stats["nativeDecodeAge"].map { $0.doubleValue >= (stats["nativeDecodeStaleAfter"]?.doubleValue ?? 8) } ?? false
      frozen = id == 0 || failed || (arrival >= 2.5 && scheduled < -1000) || decoderStale
    } else {
      frozen = id == 0 || failed || (age < 0 && count == samples) ||
        (age >= 2.5 && (fps < 15 || scheduled > 500))
    }
    began = now; media = mediaMs; samples = count; changes = change
    if frozen { stage = 1; deadline = now+3; return 2 } // flush first
    return 0
  }
}

// Hold presentation at a confirmed point across a starved HTTP read, then
// resynchronise the same input when bytes arrive. A pause command cannot be
// assumed to execute while VLC's input thread is blocked inside that read.
@objc(NeoNetworkPlaybackFlow)
final class NeoNetworkPlaybackFlow: NSObject {
  @objc private(set) var holding = false
  @objc private(set) var verifying = false
  private var delivery: Int64 = 0, video: UInt64 = 0
  @objc func reset() { holding = false; verifying = false; delivery = 0; video = 0 }
  @objc func update(waiting: Bool, delivery: Int64, video: UInt64, videoAge: Double,
                    staleAfter: Double, eligible: Bool, wantsPlayback: Bool) -> Int {
    if !eligible {
      let active = holding || verifying; reset(); return active ? 2 : 0
    }
    if holding {
      if delivery != self.delivery || !waiting || !eligible {
        holding = false; verifying = eligible && wantsPlayback; return 2
      }
      return 0
    }
    if verifying && (!wantsPlayback || (video > self.video && videoAge >= 0 && videoAge < 0.5)) {
      verifying = false; return 3
    }
    // Do not resynchronise the same decoder again before it consumes bytes that
    // just arrived. A genuinely broken decoder is handled by video recovery.
    if verifying { return 0 }
    if eligible && wantsPlayback && waiting && video > 0 && videoAge >= staleAfter {
      holding = true; verifying = false; self.delivery = delivery; self.video = video; return 1
    }
    return 0
  }
}
