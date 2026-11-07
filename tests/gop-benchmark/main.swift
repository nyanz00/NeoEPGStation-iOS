import Foundation
var count = 0
func check(_ value: Bool, _ name: String) { precondition(value,name); count += 1 }
let profile = NeoGOPBenchmark.Profile(label:"synthetic",bytes:1000,duration:100,fps:24,keys:[0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96])
let plan = NeoGOPBenchmark.Plan(schema:1,targets:[31.125,55.75],profiles:[profile])
check(plan.valid,"valid plan")
check(profile.key(before:31.125) == 28 && profile.key(before:32) == 32 && profile.key(before:0) == 0,"actual preceding key selection")
check(!NeoGOPBenchmark.Plan(schema:2,targets:plan.targets,profiles:[profile]).valid,"unknown schema")
check(!NeoGOPBenchmark.Plan(schema:1,targets:[90],profiles:[profile]).valid,"staging stays within clip")
check(!NeoGOPBenchmark.Plan(schema:1,targets:plan.targets,profiles:[profile,profile]).valid,"ambiguous file identity rejected")
let steps = NeoGOPBenchmark.steps(plan.targets,rounds:2)
check(steps.count == 8 && Set(steps.map(\.target)) == Set(plan.targets),"same target positions in every round")
check(steps.filter(\.forward).count == 4 && steps.filter { !$0.forward }.count == 4,"balanced forward and backward")
check(steps[0].forward && !steps[4].forward,"direction order alternates between rounds")
check(steps.allSatisfy { abs($0.stage-$0.target) == 10 },"10 second staging distance")
let rows: [[String:Any]] = [["status":"verified","displayMs":100.0,"forward":true],["status":"verified","displayMs":300.0,"forward":true],["status":"timeout","forward":false],["status":"unverified-picture-time","displayMs":1.0,"forward":false]]
let summary = NeoGOPBenchmark.summary(rows), all = summary["all"] as! [String:Any]
check(all["count"] as? Int == 2 && all["attempts"] as? Int == 4 && all["medianMs"] as? Double == 200,"unverified and failed samples excluded, counted as attempts")
check(all["p90Ms"] as? Double == 300 && all["worstMs"] as? Double == 300,"p90 and maximum")
check((summary["backward"] as? [String:Any])?["count"] as? Int == 0,"no false zero-latency success")
let pattern = Data((0..<576).map { UInt8(($0*31)%230+10) })
let noisy = Data(pattern.map { $0+2 })
check(NeoGOPBenchmark.imageMatches(pattern,pattern),"identical displayed reference")
check(NeoGOPBenchmark.imageMatches(pattern,noisy),"small display colour rounding allowed")
check(!NeoGOPBenchmark.imageMatches(pattern,Data(pattern.reversed())),"different image rejected")
check(!NeoGOPBenchmark.imageMatches(Data(repeating:0,count:576),Data(repeating:0,count:576)),"flat image cannot verify presentation")
check(!NeoGOPBenchmark.imageMatches(Data(),pattern),"invalid reference rejected")
check(NeoGOPBenchmark.imageScore(pattern,noisy)==2,"absolute luma distance")
var invalidReference = profile; invalidReference.references = [.init(target:31,pts:31,luma:Data())]
check(!NeoGOPBenchmark.Plan(schema:1,targets:plan.targets,profiles:[invalidReference]).valid,"invalid reference plan rejected")
print("GOP benchmark model checks: \(count) passed")
