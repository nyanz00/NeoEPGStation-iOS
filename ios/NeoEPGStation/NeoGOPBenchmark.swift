import Foundation

enum NeoGOPBenchmark {
  struct Profile: Codable {
    let label: String, bytes: Int64, duration: Double, fps: Double, keys: [Double]
    func key(before target: Double) -> Double? {
      var low = 0, high = keys.count
      while low < high { let mid = (low+high)/2; if keys[mid] <= target { low = mid+1 } else { high = mid } }
      return low > 0 ? keys[low-1] : nil
    }
  }
  struct Plan: Codable {
    let schema: Int, targets: [Double], profiles: [Profile]
    var valid: Bool {
      schema == 1 && (1...100).contains(targets.count) && (1...12).contains(profiles.count) &&
      targets.allSatisfy { $0.isFinite && $0 >= 20 } && Set(profiles.map(\.bytes)).count == profiles.count &&
      profiles.allSatisfy { p in p.bytes > 0 && p.duration.isFinite && p.duration > 60 && p.fps.isFinite && p.fps > 0 && p.keys.count >= 2 && p.keys.count < 100000 &&
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
