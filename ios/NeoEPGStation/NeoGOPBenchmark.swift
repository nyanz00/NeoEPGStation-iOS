import Foundation

enum NeoGOPBenchmark {
  struct Reference: Codable {
    let target: Double, pts: Double, luma: Data
  }
  struct Profile: Codable {
    let label: String, bytes: Int64, duration: Double, fps: Double, keys: [Double]
    var references: [Reference]? = nil
    var targets: [Double]? = nil
    var points: [Point]? = nil
    func key(before target: Double) -> Double? {
      var low = 0, high = keys.count
      while low < high { let mid = (low+high)/2; if keys[mid] <= target { low = mid+1 } else { high = mid } }
      return low > 0 ? keys[low-1] : nil
    }
  }
  struct Point: Codable {
    let target: Double, group: String, section: Int, key: Double, nextKey: Double
  }
  // Colour conversion/readback can introduce a few quantisation levels. Keep a
  // strict absolute bound and a structural match; flat/duplicate images cannot
  // prove a changed picture and are deliberately excluded by the caller.
  static func imageScore(_ a: Data, _ b: Data) -> Double {
    guard a.count == 576, b.count == 576 else { return .infinity }
    return zip(a,b).reduce(0) { $0+abs(Double($1.0)-Double($1.1)) }/576
  }
  static func imageMatches(_ a: Data, _ b: Data) -> Bool {
    if imageMatchesUpright(a,b) { return true }
    guard a.count == 576 else { return false }
    // Core Image and raw-video buffers use different row-origin conventions.
    var flipped = Data(capacity:576)
    for row in (0..<18).reversed() { flipped.append(a.subdata(in:row*32..<(row+1)*32)) }
    return imageMatchesUpright(flipped,b)
  }
  private static func imageMatchesUpright(_ a: Data, _ b: Data) -> Bool {
    guard imageScore(a,b) <= 9 else { return false }
    let av = a.map(Double.init), bv = b.map(Double.init)
    let am = av.reduce(0,+)/576, bm = bv.reduce(0,+)/576
    var covariance = 0.0, aa = 0.0, bb = 0.0
    for i in av.indices { let x = av[i]-am, y = bv[i]-bm; covariance += x*y; aa += x*x; bb += y*y }
    return aa > 100 && bb > 100 && covariance/sqrt(aa*bb) >= 0.985
  }
  struct Plan: Codable {
    let schema: Int, targets: [Double], profiles: [Profile]
    func targets(for profile: Profile) -> [Double] { schema == 2 ? (profile.targets ?? []) : targets }
    var valid: Bool {
      guard schema == 1 || schema == 2, (1...12).contains(profiles.count), Set(profiles.map(\.bytes)).count == profiles.count else { return false }
      return profiles.allSatisfy { profile in
        let positions = self.targets(for:profile)
        guard (1...100).contains(positions.count), Set(positions).count == positions.count,
          profile.bytes > 0, profile.duration.isFinite, profile.duration > 60, profile.fps.isFinite, profile.fps > 0,
          (2..<100000).contains(profile.keys.count) else { return false }
        guard positions.allSatisfy({ $0.isFinite && $0 >= 20 && $0+15 < profile.duration }),
          profile.keys.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < profile.duration }),
          zip(profile.keys,profile.keys.dropFirst()).allSatisfy({ $0 < $1 }) else { return false }
        if let references = profile.references {
          guard references.count < 20000, references.allSatisfy({ $0.luma.count == 576 && $0.target.isFinite && $0.pts.isFinite && abs($0.target-$0.pts)<=max(0.03,2/profile.fps)+0.000001 }) else { return false }
        }
        if let points = profile.points {
          guard points.count == positions.count, Set(points.map(\.target)) == Set(positions), points.allSatisfy({
            ["near","middle","far"].contains($0.group) && $0.section > 0 && $0.key.isFinite && $0.nextKey.isFinite && $0.key < $0.target && $0.target < $0.nextKey
          }) else { return false }
        }
        return true
      }
    }
  }
  struct Step: Codable, Equatable {
    let target: Double, forward: Bool, round: Int
    var stage: Double { target+(forward ? -10 : 10) }
  }
  static func steps(_ targets: [Double], rounds: Int) -> [Step] {
    (0..<rounds).flatMap { round in targets.enumerated().flatMap { index,target in
      let directions = (index+round)%2 == 0 ? [true,false] : [false,true]
      return directions.map { Step(target:target,forward:$0,round:round+1) }
    } }
  }
  static func shouldReadNativePicture(fresh: Bool, ready: Bool, seeking: Bool) -> Bool { fresh || !ready || seeking }
  static func canContinue(after status: String) -> Bool { ["completed","completed-with-failures","failed"].contains(status) }
  static func completionStatus(_ rows: [[String:Any]]) -> String {
    rows.allSatisfy { $0["status"] as? String == "verified" } ? "completed" : "completed-with-failures"
  }
  // Bounded metadata only. Preserve the first polls, latest polls and closest
  // verified display timestamp even when a landing is skipped or times out.
  struct SeekTrace {
    let serial: Int, target: Double, began: Double
    private(set) var polls = 0, copied = 0, copiedWithoutNew = 0, maximumGapMs = 0.0
    private var lastHost: Double?, first: [[String:Any]] = [], tail: [[String:Any]] = [], closest: [String:Any]?
    private var closestDistance = Double.infinity
    init(serial: Int, target: Double, began: Double) { self.serial = serial; self.target = target; self.began = began }
    mutating func record(host: Double, pts: Double?, itemTime: Double? = nil, fresh: Bool? = nil, verified: Bool = true) {
      guard host.isFinite, host >= began else { return }
      if let lastHost { maximumGapMs = max(maximumGapMs,(host-lastHost)*1000) }; lastHost = host
      polls += 1
      var sample: [String:Any] = ["afterMs":(host-began)*1000,"copied":pts != nil,"verifiedTime":verified]
      if let fresh { sample["hasNew"] = fresh }
      if let itemTime, itemTime.isFinite { sample["itemTime"] = itemTime }
      if let pts, pts.isFinite {
        copied += 1; if fresh == false { copiedWithoutNew += 1 }; sample["pts"] = pts
        let distance = abs(pts-target)
        if verified, distance < closestDistance { closestDistance = distance; closest = sample }
      }
      if first.count < 8 { first.append(sample) }
      tail.append(sample); if tail.count > 24 { tail.removeFirst(tail.count-24) }
    }
    var dictionary: [String:Any] {
      var result: [String:Any] = ["serial":serial,"target":target,"polls":polls,"copied":copied,
        "copiedWithoutNew":copiedWithoutNew,"maximumGapMs":maximumGapMs,"first":first,"latest":tail]
      result["closest"] = closest
      if closestDistance.isFinite { result["closestDistanceSeconds"] = closestDistance }
      return result
    }
  }
  static func summary(_ rows: [[String:Any]]) -> [String:Any] {
    func stats(_ rows: [[String:Any]]) -> [String:Any] {
      let values = rows.filter { $0["status"] as? String == "verified" }.compactMap { $0["displayMs"] as? Double }.sorted()
      guard !values.isEmpty else { return ["count":0,"attempts":rows.count,"failedCount":rows.count] }
      let count = values.count
      return ["count":count,"attempts":rows.count,"failedCount":rows.count-count,"medianMs":count%2 == 0 ? (values[count/2-1]+values[count/2])/2 : values[count/2],
        "p90Ms":values[max(0,Int(ceil(Double(count)*0.9))-1)],"worstMs":values.last!,"meanMs":values.reduce(0,+)/Double(count)]
    }
    return ["all":stats(rows),"forward":stats(rows.filter { $0["forward"] as? Bool == true }),"backward":stats(rows.filter { $0["forward"] as? Bool == false })]
  }
}
