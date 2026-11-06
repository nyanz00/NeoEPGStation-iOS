import Foundation
var count = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) { count += 1; guard condition() else { fatalError(name) } }
let fixture = #"{"fileName":"Fixture","formatName":"Matroska / WebM","size":1073741824,"duration":1440,"videoCodec":"av1","videoProfile":"Main","width":1440,"height":1080,"frameRate":23.976,"pixelFormat":"yuv420p10le","bitDepth":10,"hdr":null,"streams":[{"index":1,"type":"audio","codec":"aac","language":"jpn","channels":2},{"index":2,"type":"subtitle","codec":"ass","language":"jpn","title":"Comments"}],"ts":{"networkId":1,"transportStreamId":2,"serviceId":3,"pmtPid":4,"pcrPid":5,"videoPid":6,"audioPid":7,"subtitlePid":8},"analyzedAt":1700000000000,"analysisError":null,"keyframes":{"status":"ready","stale":false,"averageInterval":4,"minInterval":2,"maxInterval":6,"sampledDuration":60,"sampleWindows":[{"start":0,"end":20,"keyframeCount":5}],"keyframeCount":15,"intervalCount":14,"analyzedAt":1700000005000,"error":null}}"#
let info = try JSONDecoder().decode(NeoVideoInfo.self,from:Data(fixture.utf8))
check("all Web primary labels",info.rows.map(\.0) == ["File","Format","Size","Duration","Video","Resolution","Frame rate","Pixel / HDR","Audio","Subtitle","TS IDs","TS PIDs"])
check("all Web keyframe labels",info.keyRows.map(\.0) == ["Average interval","Minimum interval","Maximum interval","Sample windows","Sampled duration","Keyframes","Intervals"])
check("codec and depth",info.rows[4].1 == "av1 / Main" && info.rows[7].1.contains("10 bit"))
check("audio and subtitle fields",info.rows[8].1 == "1: aac jpn 2ch" && info.rows[9].1 == "2: ass jpn Comments")
check("all TS IDs",info.rows[10].1 == "network=1 transport=2 service=3")
check("all TS PIDs",info.rows[11].1 == "PMT=4 PCR=5 video=6 audio=7 subtitle=8")
check("Web formatting",info.rows[2].1 == "1.00 GB" && info.rows[3].1 == "1440.000 sec" && info.rows[6].1 == "23.976 fps")
check("ready status",info.status == "OK" && info.analyzed != "-")
var object = try JSONSerialization.jsonObject(with:Data(fixture.utf8)) as! [String:Any]
var keys = object["keyframes"] as! [String:Any]
keys["status"] = "analyzing"; keys["stale"] = true; object["keyframes"] = keys
let stale = try JSONDecoder().decode(NeoVideoInfo.self,from:JSONSerialization.data(withJSONObject:object))
check("stale results retained during analysis",stale.keyRows.count == 7 && stale.status.contains("Analyzing (stale results available)"))
keys["stale"] = false; keys["status"] = "error"; keys["error"] = "fixture error"; object["keyframes"] = keys
let error = try JSONDecoder().decode(NeoVideoInfo.self,from:JSONSerialization.data(withJSONObject:object))
check("analysis errors visible",error.keyRows.isEmpty && error.status.contains("Error: fixture error"))
object.removeValue(forKey:"keyframes"); object["analysisError"] = "video fixture"
let legacy = try JSONDecoder().decode(NeoVideoInfo.self,from:JSONSerialization.data(withJSONObject:object))
check("old server information retained",legacy.rows.count == 12 && legacy.keyRows.isEmpty && legacy.status.contains("Video error: video fixture") && legacy.status.contains("unavailable"))
object["ts"] = NSNull(); object["streams"] = []; object["width"] = NSNull()
let empty = try JSONDecoder().decode(NeoVideoInfo.self,from:JSONSerialization.data(withJSONObject:object))
check("missing optional values",empty.rows[5].1 == "-" && empty.rows[8].1 == "-" && empty.rows[10].1 == "-")
let defaults = UserDefaults.standard
check("Web half-width Latin and punctuation",NeoProgramText.halfWidth("ＡＢＣ１２３！～　”’‘￥〜") == "ABC123!~ \"'`\\~")
check("half-width preserves Japanese and kana",NeoProgramText.halfWidth("ガラス ｶﾞ ①㍿ 第４話") == "ガラス ｶﾞ ①㍿ 第4話")
let textRecord = NeoRecording(id:101,name:"第４話　テスト！",startAt:0,endAt:1,isRecording:false,description:"ＡＢＣ",extended:"＃４",channelId:nil,channelName:nil,thumbnails:nil,videoFiles:nil)
check("half-width off preserves source",textRecord.displayed(halfWidth:false).name == "第４話　テスト！")
check("half-width applied to all detail text",textRecord.displayed(halfWidth:true).name == "第4話 テスト!" && textRecord.displayed(halfWidth:true).description == "ABC" && textRecord.displayed(halfWidth:true).extended == "#4")
check("missing drop is never zero",NeoProgramText.dropSummary(textRecord).contains("drop: —"))
var zeroRecord = textRecord; zeroRecord.dropLogFile = .init(id:1,errorCnt:0,dropCnt:0,scramblingCnt:0)
check("known zero remains zero",NeoProgramText.dropSummary(zeroRecord).contains("drop: 0") && zeroRecord.dropLogFile?.hasErrors == false)
let names = ["annict.autoWatchMode","annict.threshold","annict.markFinal","annict.disableFinalRules"]
let old = names.map { defaults.object(forKey:$0) }; names.forEach { defaults.removeObject(forKey:$0) }
defer { for (name,value) in zip(names,old) { if let value { defaults.set(value,forKey:name) } else { defaults.removeObject(forKey:name) } } }
check("Web Annict defaults",NeoAnnictPreferences.mode == "disabled" && NeoAnnictPreferences.threshold == 90 && NeoAnnictPreferences.markFinal && NeoAnnictPreferences.disableFinalRules)
check("disabled never records",!NeoAnnictPreferences.shouldRecord(started:true,watched:100,duration:100))
NeoAnnictPreferences.mode = "start"
check("start requires real playback",!NeoAnnictPreferences.shouldRecord(started:false,watched:0,duration:100) && NeoAnnictPreferences.shouldRecord(started:true,watched:0,duration:100))
NeoAnnictPreferences.mode = "progress"
check("progress below threshold",!NeoAnnictPreferences.shouldRecord(started:true,watched:89,duration:100))
check("progress at threshold",NeoAnnictPreferences.shouldRecord(started:true,watched:90,duration:100))
check("unknown duration never marks progress",!NeoAnnictPreferences.shouldRecord(started:true,watched:100,duration:0))
NeoAnnictPreferences.threshold = 1000; check("threshold upper bound",NeoAnnictPreferences.threshold == 100)
NeoAnnictPreferences.threshold = 0; check("threshold lower bound",NeoAnnictPreferences.threshold == 1)
NeoAnnictPreferences.markFinal = false
check("final rule option gated by work option",NeoAnnictPreferences.watchOptions["markWorkWatchedOnFinalEpisode"] as? Bool == false && NeoAnnictPreferences.watchOptions["disableRulesOnFinalEpisode"] as? Bool == false)
NeoAnnictPreferences.mode = "invalid"; check("invalid mode falls back off",NeoAnnictPreferences.mode == "disabled")
var clock = NeoWatchClock()
clock.sample(position:0,duration:100,running:true,seeking:false,rate:1,now:0)
clock.sample(position:95,duration:100,running:true,seeking:true,rate:1,now:0.5)
check("seek excluded",clock.total == 0)
clock.sample(position:95.5,duration:100,running:true,seeking:false,rate:1,now:1)
check("actual playback accumulates",clock.total == 0.5)
clock.sample(position:96,duration:100,running:false,seeking:false,rate:1,now:1.5)
check("pause excluded",clock.total == 0.5)
print("Recording feature model checks: \(count) passed")
