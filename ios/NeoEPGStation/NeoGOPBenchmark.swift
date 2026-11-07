import Foundation

enum NeoGOPBenchmark {
  struct Reference: Codable {
    let target: Double, pts: Double, luma: Data
  }
  struct Profile: Codable {
    let label: String, bytes: Int64, duration: Double, fps: Double, keys: [Double]
    var references: [Reference]? = nil
    func key(before target: Double) -> Double? {
      var low = 0, high = keys.count
      while low < high { let mid = (low+high)/2; if keys[mid] <= target { low = mid+1 } else { high = mid } }
      return low > 0 ? keys[low-1] : nil
    }
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
    var valid: Bool {
      schema == 1 && (1...100).contains(targets.count) && (1...12).contains(profiles.count) &&
      targets.allSatisfy { $0.isFinite && $0 >= 20 } && Set(profiles.map(\.bytes)).count == profiles.count &&
      profiles.allSatisfy { p in p.bytes > 0 && p.duration.isFinite && p.duration > 60 && p.fps.isFinite && p.fps > 0 && p.keys.count >= 2 && p.keys.count < 100000 &&
        (p.references == nil || (p.references!.count < 20000 && p.references!.allSatisfy { $0.luma.count == 576 && $0.target.isFinite && $0.pts.isFinite && abs($0.target-$0.pts)<=max(0.03,2/p.fps)+0.000001 })) &&
        p.keys.allSatisfy { $0.isFinite && $0 >= 0 && $0 < p.duration } && zip(p.keys,p.keys.dropFirst()).allSatisfy { $0 < $1 } &&
        targets.allSatisfy { $0+15 < p.duration } }
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
  static func summary(_ rows: [[String:Any]]) -> [String:Any] {
    func stats(_ rows: [[String:Any]]) -> [String:Any] {
      let values = rows.filter { $0["status"] as? String == "verified" }.compactMap { $0["displayMs"] as? Double }.sorted()
      guard !values.isEmpty else { return ["count":0,"attempts":rows.count] }
      let count = values.count
      return ["count":count,"attempts":rows.count,"medianMs":count%2 == 0 ? (values[count/2-1]+values[count/2])/2 : values[count/2],
        "p90Ms":values[max(0,Int(ceil(Double(count)*0.9))-1)],"worstMs":values.last!,"meanMs":values.reduce(0,+)/Double(count)]
    }
    return ["all":stats(rows),"forward":stats(rows.filter { $0["forward"] as? Bool == true }),"backward":stats(rows.filter { $0["forward"] as? Bool == false })]
  }
}
