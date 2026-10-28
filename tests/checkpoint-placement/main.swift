import Foundation

func near(_ a: [Double], _ b: [Double]) -> Bool {
  a.count == b.count && zip(a,b).allSatisfy { abs($0.0-$0.1) < 0.00001 }
}
func times(_ keys: [Double], _ range: ClosedRange<Double>) -> [Double] {
  NeoCheckpointPlacement.slots(keyframes: keys, in: range).map(\.seconds)
}
assert(near(times([0,6,12,18], 0...17.9), [3,9,15]), "Short GOPs need midpoint checkpoints, not a global six-second grid")
assert(near(times([0,25], 0...24.9), [5,10,15,20]), "Long GOPs split into bounded gaps")
assert(near(times([9.276,15.282], 9.276...15.281), [12.279]), "Variable timestamps preserve the actual midpoint")
assert(near(times([100,106,112], 100...111.9), [103,109]), "Source clock offset is preserved")
assert(near(times([0,24], 0...23.9), [6,12,18]))
assert(times([], 0...20).isEmpty)
assert(near(times([.nan,6,0,0,12,.infinity], 0...11.9), [3,9]))
assert(near(times([0,0.5,1], 0...0.99), []), "Do not crowd sub-second GOPs")
assert(near(times([0,25], 7...16), [10,15]), "Only retain requested time window")

let unknown = NeoCheckpointPlacement.slots(keyframes: [0], in: 0...20)
assert(near(unknown.map(\.seconds), [6,12,18]) && unknown.allSatisfy(\.provisional))
let known = NeoCheckpointPlacement.slots(keyframes: [0,25], in: 0...20)
assert(near(known.map(\.seconds), [5,10,15,20]) && known.allSatisfy { !$0.provisional })
// A retained keyframe timestamp outside the packet horizon can define the
// midpoint without fetching or decoding those future packets.
assert(near(times([0,25], 0...12), [5,10]))
let slot = NeoCheckpointPlacement.candidate(at: 3.05, keyframes: [0,6,12], saved: [])!
assert(abs(slot.seconds-3) < 0.001 && NeoCheckpointPlacement.canStore(slot, at: 3.17, keyframes: [0,6,12]))
assert(NeoCheckpointPlacement.candidate(at: 3.2, keyframes: [0,6,12], saved: [3.15]) == nil, "One snapshot per slot")
assert(NeoCheckpointPlacement.candidate(at: 3.8, keyframes: [0,6,12], saved: []) == nil, "Do not capture far past a missed slot")
assert(!NeoCheckpointPlacement.canStore(slot, at: 3.1, keyframes: [0,3.08,6]), "An unexpected keyframe retires the old slot")
assert(!NeoCheckpointPlacement.canStore(slot, at: 6.1, keyframes: [0,6]))
print("Checkpoint placement: irregular/short/long GOPs, provisional refinement, bounds and source clock passed")

let heavy = [NeoCheckpointPlacement.CostSample(start: 0, end: 2, milliseconds: 110)]
let early = NeoCheckpointPlacement.adaptiveCandidate(at: 2, keyframes: [0,25], saved: [], costs: heavy)!
assert(early.basis == "decode-cost" && early.seconds == 2 && early.decodeMs == 110)
let light = [NeoCheckpointPlacement.CostSample(start: 0, end: 12, milliseconds: 40)]
assert(NeoCheckpointPlacement.adaptiveCandidate(at: 5, keyframes: [0,25], saved: [], costs: light) == nil)
let sparse = NeoCheckpointPlacement.adaptiveCandidate(at: 12, keyframes: [0,25], saved: [], costs: light)!
assert(sparse.basis == "maximum-gap" && sparse.seconds == 12)
let midpoint = NeoCheckpointPlacement.adaptiveCandidate(at: 3, keyframes: [0,6], saved: [],
  costs: [.init(start: 0, end: 3, milliseconds: 10)])!
assert(midpoint.basis == "midpoint")
assert(NeoCheckpointPlacement.adaptiveCandidate(at: 3.2, keyframes: [0,6], saved: [3.1], costs: heavy) == nil)
assert(NeoCheckpointPlacement.adaptiveCandidate(at: 5.8, keyframes: [0,6], saved: [], costs: heavy) == nil)
let fallback = NeoCheckpointPlacement.adaptiveCandidate(at: 5.1, keyframes: [0,25], saved: [], costs: [])!
assert(fallback.basis == "time" && fallback.seconds == 5)
assert(NeoCheckpointPlacement.adaptiveCandidate(at: .nan, keyframes: [0,25], saved: [], costs: heavy) == nil)
print("Adaptive decode-cost placement: heavy/light regions, minimum spacing, real-key boundaries, sparse-data fallback passed")
