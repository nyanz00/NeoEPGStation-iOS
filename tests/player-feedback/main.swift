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
var log = LiveCommentLog()
let seed = parsed.comments[0]
func batch(_ start: Int, _ count: Int) -> [NativeComment] {
  (start..<start+count).map { index in var c = seed; c.id = index; c.start = Double(index); c.end = Double(index)+5; return c }
}
log.append(batch(0,600)); check("normal history keeps latest500",log.comments.count == 500 && log.comments.first?.id == 100)
log.follow(false); log.append(batch(600,1000)); check("manual reading retains old rows beyond500",log.comments.count == 1500 && log.comments.first?.id == 100)
check("old rows keep post time and full text",log.comments.first?.postedAt == seed.postedAt && log.comments.first?.text == seed.text)
log.follow(true); check("follow resumes bounded history",log.comments.count == 500 && log.comments.first?.id == 1100)
log.reset(); check("new live history starts empty",log.comments.isEmpty && log.following)
do {
  let keys = ["watch.encoder","watch.quality","watch.hevc","watch.lowLatency","watch.bufferedStart","watch.subtitleKeywords","player.network.seconds","neoepgstation.navigation.labels","player.comments.size","player.comments.absoluteOpacity","player.comments.enabled"]
  let defaults = UserDefaults.standard, previous = keys.map { UserDefaults.standard.object(forKey:$0) }
  defer { for (key,value) in zip(keys,previous) { if let value { defaults.set(value,forKey:key) } else { defaults.removeObject(forKey:key) } } }
  keys.forEach(defaults.removeObject(forKey:))
  check("web defaults and legacy cache default",NeoViewingPreferences.encoder == "Config" && NeoViewingPreferences.lowLatency && !NeoViewingPreferences.hevc && NeoViewingPreferences.networkSeconds == 5)
  check("Config omits override",NeoViewingPreferences.streamQuery.isEmpty)
  NeoViewingPreferences.encoder = "NVEncC"; NeoViewingPreferences.hevc = true
  check("live and recorded request overrides",Dictionary(uniqueKeysWithValues:NeoViewingPreferences.streamQuery.map { ($0.name,$0.value!) }) == ["encoder":"NVEncC","hevc":"true"])
  NeoViewingPreferences.quality = "720p"
  check("global quality overrides remembered mode",NeoViewingPreferences.initialQuality(["1080p","720p"],saved:0) == 1)
  check("missing quality falls back safely",NeoViewingPreferences.initialQuality(["1080p"],saved:5) == 0)
  NeoViewingPreferences.subtitleKeywords = [" NicoJK ","日本語",""]
  let normal = NativeCommentTrack(subtitleIndex:1,streamIndex:1,codecName:"ass",displayName:"字幕",title:"日本語",language:"jpn")
  let comment = NativeCommentTrack(subtitleIndex:2,streamIndex:2,codecName:"ass",displayName:"NicoJK-1080T",title:nil,language:nil)
  check("priority sees metadata and orders keywords",NeoCommentPreference.priority([normal,comment])?.subtitleIndex == 2)
  check("normal tracks match independently",NeoCommentPreference.priority([normal])?.subtitleIndex == 1)
  NeoViewingPreferences.subtitleKeywords = ["NicoJK","",""]
  check("ordinary subtitle defaults off",NeoCommentPreference.priority([normal]) == nil && NeoSubtitlePreference.automaticIndex(["字幕"]) == -1)
  check("three priority rows by default",NeoViewingPreferences.subtitleKeywords.count == 3)
  NeoViewingPreferences.addSubtitlePriority(); NeoViewingPreferences.addSubtitlePriority()
  var priorities = NeoViewingPreferences.subtitleKeywords; priorities[3] = "日本語"; priorities[4] = "Last"; NeoViewingPreferences.subtitleKeywords = priorities
  check("additional priorities saved without truncation",defaults.stringArray(forKey:"watch.subtitleKeywords")?.count == 5 && NeoViewingPreferences.subtitleKeywords.last == "Last")
  check("fourth priority participates in selection",NeoCommentPreference.priority([normal])?.subtitleIndex == 1)
  NeoViewingPreferences.removeSubtitlePriority(at:3)
  check("additional priority removal preserves order",NeoViewingPreferences.subtitleKeywords.count == 4 && NeoViewingPreferences.subtitleKeywords[3] == "Last")
  NeoViewingPreferences.removeSubtitlePriority(at:0)
  check("first three priority fields cannot be removed",NeoViewingPreferences.subtitleKeywords.count == 4 && NeoViewingPreferences.subtitleKeywords[0] == "NicoJK")
  check("comment visibility defaults enabled",NeoViewingPreferences.commentsEnabled)
  NeoViewingPreferences.commentsEnabled = false
  check("comment visibility uses existing player key",defaults.object(forKey:"player.comments.enabled") as? Bool == false)
  defaults.set(1.25,forKey:"player.comments.size"); defaults.set(Float(0.65),forKey:"player.comments.absoluteOpacity")
  check("legacy comment keys retained",NeoViewingPreferences.commentSize == 1.25 && abs(NeoViewingPreferences.commentOpacity-0.65)<0.001)
  NeoViewingPreferences.networkSeconds = 7; check("network cache persisted and bounded",defaults.integer(forKey:"player.network.seconds") == 7)
  NeoViewingPreferences.networkSeconds = 999; check("network maximum",NeoViewingPreferences.networkSeconds == 30)
  let config = try JSONDecoder().decode(NeoServerConfig.self,from:Data(#"{"encode":[],"watchConfig":{"availableEncoders":["FFmpeg","NVEncC"],"liveQualities":["1080p","720p"]}}"#.utf8))
  check("server watch choices decoded",config.watchConfig?.availableEncoders == ["FFmpeg","NVEncC"] && config.watchConfig?.liveQualities?.last == "720p")
}
print("Player feedback model checks: \(count) passed")
