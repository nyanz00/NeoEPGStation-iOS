import Foundation

/// Uses source timestamps only. Planning never reads media or runs a decoder.
enum NeoCheckpointPlacement {
  struct Slot: Equatable, Sendable {
    let seconds: Double
    let keyframe: Double
    let nextKeyframe: Double?
    let spacing: Double
    var provisional: Bool { nextKeyframe == nil }
  }
  static let targetGap = 6.0
  static let captureTolerance = 0.5

  static func normalized(_ values: [Double]) -> [Double] {
    var result: [Double] = []
    for value in values.filter({ $0.isFinite }).sorted() {
      if result.last.map({ value-$0 > 0.001 }) ?? true { result.append(value) }
    }
    return result
  }
  private static func spacing(for span: Double) -> Double {
    // Always split a useful known interval at least once. A small timestamp
    // rounding error around an exact six-second multiple must not add a point.
    span / min(4096, max(2, ceil((span-0.05)/targetGap)))
  }
  static func slots(keyframes input: [Double], in range: ClosedRange<Double>) -> [Slot] {
    guard range.lowerBound.isFinite, range.upperBound.isFinite else { return [] }
    let keys = normalized(input)
    guard !keys.isEmpty else { return [] }
    var result: [Slot] = []
    for index in keys.indices {
      let start = keys[index]
      guard start < range.upperBound else { break }
      let end: Double? = index+1 < keys.count ? keys[index+1] : nil
      if let end, end <= range.lowerBound { continue }
      // Sub-second GOPs have too little useful space for a drained snapshot.
      if let end, end-start < 1 { continue }
      let intervals = zip(keys, keys.dropFirst()).map { $0.1-$0.0 }.filter { $0 >= 1 && $0 <= 120 }
      let recent = Array(intervals.suffix(8)).sorted()
      let estimate = recent.isEmpty ? 12 : recent[recent.count/2]
      let step = spacing(for: end.map { $0-start } ?? estimate)
      guard step.isFinite, step >= 0.5 else { continue }
      let ceiling = min(end ?? range.upperBound, range.upperBound)
      let first = max(1, Int(ceil((range.lowerBound-start)/step)))
      let last = Int(floor((ceiling-start)/step + 0.000001))
      guard first <= last else { continue }
      for ordinal in first...min(last, first+256) {
        let time = start+Double(ordinal)*step
        if time < range.lowerBound || time > range.upperBound { continue }
        if let end, time >= end-0.05 { continue }
        result.append(Slot(seconds: time, keyframe: start, nextKeyframe: end, spacing: step))
      }
    }
    return result
  }
  static func candidate(at seconds: Double, keyframes: [Double], saved: [Double]) -> Slot? {
    guard seconds.isFinite else { return nil }
    return slots(keyframes: keyframes, in: (seconds-captureTolerance)...seconds).last { slot in
      !saved.contains { abs($0-slot.seconds) <= captureTolerance }
    }
  }
  static func canStore(_ slot: Slot, at seconds: Double, keyframes: [Double]) -> Bool {
    guard seconds.isFinite, seconds >= slot.seconds, seconds-slot.seconds <= captureTolerance else { return false }
    return !keyframes.contains { $0 > slot.keyframe+0.001 && $0 <= seconds+0.05 }
  }
}
