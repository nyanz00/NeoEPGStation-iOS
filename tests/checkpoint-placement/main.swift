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
