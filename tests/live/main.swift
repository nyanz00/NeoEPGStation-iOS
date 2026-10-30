import Foundation
var failures = 0, count = 0
func check(_ label: String, _ ok: @autoclosure () -> Bool) { count += 1; if !ok() { failures += 1; print("FAIL \(label)") } }
let config = try JSONDecoder().decode(NeoServerConfig.self,from:Data(#"{"encode":[],"isEnableTSLiveStream":true,"broadcast":{"GR":true,"CS":false},"streamConfig":{"live":{"ts":{"m2ts":[{"name":"1080p","isUnconverted":false},{"name":"無変換","isUnconverted":true}],"m2tsll":["720p"]}}}}"#.utf8))
let options = NeoLiveOption.available(config)
check("live modes preserve server indices",options.count == 3 && options[1].mode == 1 && options[1].unconverted && options[2].type == "m2tsll")
let api = NeoAPI(base:URL(string:"https://example.invalid/prefix")!)
let url = options[1].url(api:api,channel:123)
check("server defaults are not overridden",url.path == "/prefix/api/streams/live/123/m2ts" && !url.absoluteString.contains("encoder") && !url.absoluteString.contains("hevc"))
check("mode and quality",URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.contains { $0.name == "mode" && $0.value == "1" })
let disabled = try JSONDecoder().decode(NeoServerConfig.self,from:Data(#"{"encode":[],"isEnableTSLiveStream":false}"#.utf8))
check("disabled capability",NeoLiveOption.available(disabled).isEmpty)
check("default video visible",NeoLiveChannel(id:1,name:"局",channelType:"GR").defaultVisible)
check("guide hidden",!NeoLiveChannel(id:2,name:"ＮＨＫデータ１",channelType:"GR").defaultVisible)
check("unknown service hidden",!NeoLiveChannel(id:3,name:"局",channelType:"GR",type:0xc0).defaultVisible)
let program = NeoLiveProgram(id:2,name:"番組",startAt:100,endAt:200)
check("program progress clamps",program.progress(0) == 0 && program.progress(150) == 0.5 && program.progress(300) == 1)
let context = NeoLiveSchedule(channel:NeoLiveChannel(id:1,name:"局",channelType:"GR"),programs:[program]).context(base:api.base)
check("live context never creates recording history",context["live"] as? Bool == true && context["id"] == nil && context["videoFileId"] == nil)
func packet(_ ticks: UInt64) -> Data {
 var p = [UInt8](repeating:255,count:188); p[0] = 0x47; p[1] = 1; p[2] = 0; p[3] = 0x20; p[4] = 183; p[5] = 0x10
 p[6] = UInt8(truncatingIfNeeded:ticks>>25); p[7] = UInt8(truncatingIfNeeded:ticks>>17); p[8] = UInt8(truncatingIfNeeded:ticks>>9); p[9] = UInt8(truncatingIfNeeded:ticks>>1); p[10] = UInt8(truncatingIfNeeded:ticks<<7)|0x7e; p[11] = 0; return Data(p)
}
let clock = NeoLivePCRClock(), first = packet(900000), next = packet(1800000)
clock.observe(Data(first.prefix(99))); clock.observe(Data(first.dropFirst(99))+next)
check("fragmented PCR spans",abs(clock.span-10) < 0.001 && abs(clock.delay(playback:7)-3) < 0.001)
clock.reset(); clock.observe(packet(8589934592-90000)); clock.observe(packet(90000))
check("PCR wrap",abs(clock.span-2) < 0.001)
clock.reset(); check("new input resets delay",clock.span == 0 && clock.delay(playback:50) == 0)
let row = NeoLiveCommentCommand.row(["content":"実況","mail":"ue red big"],at:4)!
check("commands match Web",row["position"] as? String == "top" && row["color"] as? String == "#F02840" && row["size"] as? String == "big")
check("operator command hidden",NeoLiveCommentCommand.row(["content":"/info 3 test","premium":3],at:0) == nil)
print("Live model checks: \(count), failures: \(failures)")
if failures > 0 { exit(1) }
