import Foundation

// Commands are issued once per stage. Re-selecting a track is not evidence
// of recovery: a new output must deliver changing, due pictures first.
@objc(NeoVideoRecovery)
final class NeoVideoRecovery: NSObject {
  @objc private(set) var stage = 0
  @objc private(set) var outputID = 0
  private var until = 0.0, deadline = 0.0, repairTimeout = 10.0
  private var began = 0.0, media: Int64 = 0, samples = 0, changes = 0
  @objc func begin(_ now: Double, timeout: Double) {
    stage = 0; outputID = 0; until = now+45; deadline = 0
    // Recreated output can arrive late, with network-cache look-ahead still
    // queued. Give it time to become due before falling back to a new input.
    repairTimeout = min(20, max(12, timeout)); began = 0
  }
  @objc func hold(_ now: Double) {
    began = 0
    if (1...3).contains(stage) { deadline = now + (stage == 1 ? 3 : repairTimeout+(stage == 3 ? 5 : 0)) }
  }
  @objc func reset() { until = 0; deadline = 0; began = 0; stage = 0; outputID = 0 }
  @objc func evaluate(_ stats: [String: NSNumber], mediaMs: Int64, now: Double) -> Int {
    guard until > 0 else { return 0 }
    if stage == 0 && now > until { return 0 }
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
    guard stage == 0, now-began >= 3, mediaMs-media >= 1500 else { return 0 }
    let fps = Double(count-samples)/(now-began)
    let frozen = id == 0 || failed || (age < 0 && count == samples) ||
      (age >= 2.5 && (fps < 15 || scheduled > 500))
    began = now; media = mediaMs; samples = count; changes = change
    if frozen { stage = 1; deadline = now+3; return 2 } // flush first
    return 0
  }
}
