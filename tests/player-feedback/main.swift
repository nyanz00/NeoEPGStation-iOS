import Foundation
var count = 0
func check(_ name: String, _ value: @autoclosure () -> Bool) { count += 1; guard value() else { fatalError(name) } }
let chat: [String:Any] = ["content":"Live text","date":1793404800,"date_usec":123456,"mail":"white"]
let row = NeoLiveCommentCommand.row(chat,at:23.75)!
check("video clock unchanged",row["time"] as? Double == 23.75)
check("post time retained",abs((row["postedAt"] as! Double)-1793404800.123456)<0.00001)
let data = try JSONSerialization.data(withJSONObject:["isSuccess":true,"source":"jikkyo","timeBase":"video","comments":[row]])
let parsed = try NeoCommentLoader.parseJikkyo(data)
check("metadata survives loader",parsed.comments.first?.postedAt == row["postedAt"] as? Double)
check("render clock remains relative",parsed.comments.first?.start == 23.75 && parsed.comments.first!.end < 40)
let copy = parsed.preservingIDs(from:parsed)
check("reconciliation preserves wall clock",copy.comments.first?.postedAt == parsed.comments.first?.postedAt)
var legacy = row; legacy.removeValue(forKey:"postedAt")
let old = try NeoCommentLoader.parseJikkyo(JSONSerialization.data(withJSONObject:["isSuccess":true,"source":"jikkyo","timeBase":"video","comments":[legacy]]))
check("recorded logs remain compatible",old.comments.first?.postedAt == nil && old.comments.first?.start == 23.75)
let textual = NeoLiveCommentCommand.row(["content":"text","date":"1793404800"],at:2)!
check("numeric string timestamp",textual["postedAt"] as? Double == 1793404800)
let bad = NeoLiveCommentCommand.row(["content":"text","date":-1],at:2)!
check("missing time never becomes elapsed display date",bad["postedAt"] == nil)
print("Player feedback model checks: \(count) passed")
