import Foundation

var watch = NeoWatchClock()
watch.sample(position: 0, duration: 120, running: true, seeking: false, rate: 1, now: 0)
watch.sample(position: 1, duration: 120, running: true, seeking: false, rate: 1, now: 1)
assert(watch.total == 1)
watch.sample(position: 90, duration: 120, running: true, seeking: true, rate: 1, now: 2)
watch.sample(position: 90, duration: 120, running: false, seeking: false, rate: 1, now: 3)
watch.sample(position: 91, duration: 120, running: true, seeking: false, rate: 1, now: 4)
assert(watch.total == 2 && watch.position == 91)
watch.sample(position: 10, duration: 120, running: true, seeking: false, rate: 1, now: 5)
assert(watch.total == 2, "Backward seek must not add watched time")

func be(_ n: UInt64, _ size: Int = 4) -> Data { Data((0..<size).reversed().map { UInt8((n >> ($0*8)) & 255) }) }
func atom(_ name: String, _ body: Data) -> Data { be(UInt64(body.count+8))+Data(name.utf8)+body }
let stco = atom("stco", be(0)+be(2)+be(100)+be(1100))
let stsc = atom("stsc", be(0)+be(1)+be(1)+be(1)+be(1))
let stsz = atom("stsz", be(0)+be(1000)+be(2))
let stts = atom("stts", be(0)+be(1)+be(2)+be(1000))
let mdhd = atom("mdhd", be(0)+be(0)+be(0)+be(1000)+be(2000))
let moov = atom("trak", atom("mdia", mdhd+atom("minf", atom("stbl", stco+stsc+stsz+stts))))
var byteClock = NeoMediaByteClock()
assert(byteClock.loadMP4Moov(moov))
assert(byteClock.timeRange(offset: 100, count: 1000) == 0...1)
assert(byteClock.timeRange(offset: 1100, count: 1000) == 1...2)
assert(byteClock.timeRange(offset: 0, count: 50) == nil)
assert(NeoMediaByteClock.mergedDownloadedRanges([10...20, 0...5, 5...12, 40...50]) == [0...20, 40...50],
  "Downloaded ranges merge overlaps but preserve unread gaps")
assert(NeoMediaByteClock.mergedDownloadedRanges([]).isEmpty)
assert(NeoMediaByteClock.mergedDownloadedRanges([1...1, 2...Double.infinity]).isEmpty,
  "Empty and invalid download intervals are not painted")
assert(!byteClock.loadMP4Moov(Data([0,1,2])))
func tsPacket(_ seconds: UInt64) -> Data {
  let ticks = seconds*90000
  var packet = [UInt8](repeating: 0xff, count: 188)
  packet[0] = 0x47; packet[1] = 0; packet[2] = 0x10; packet[3] = 0x20; packet[4] = 7; packet[5] = 0x10
  packet[6] = UInt8((ticks>>25)&255); packet[7] = UInt8((ticks>>17)&255); packet[8] = UInt8((ticks>>9)&255)
  packet[9] = UInt8((ticks>>1)&255); packet[10] = UInt8((ticks&1)<<7)
  return Data(packet)
}
assert(byteClock.observeTS(tsPacket(100)+tsPacket(130), offset: 0) == 0...31)
var mkvClock = NeoMediaByteClock()
let cluster0 = Data([0x1f,0x43,0xb6,0x75,0xff,0xe7,0x82,0,0]) + Data(repeating: 0, count: 20)
let cluster60 = Data([0x1f,0x43,0xb6,0x75,0xff,0xe7,0x82,0xea,0x60]) + Data(repeating: 0, count: 20)
assert(mkvClock.observeMatroska(cluster0+cluster60, offset: 0) == 0...70)

let header = """
[Script Info]
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, Italic, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
Style: Default,Hiragino Sans,64,&H00FFFFFF,&H00000000,&H80000000,0,0,100,100,0,0,1,2,0,7,0,0,0
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
func ass(_ lines: String) -> String { header + "\n" + lines }
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}
func rejects(_ text: String, _ message: String, timing: CommentTiming = .ass) {
  do { _ = try NeoASSComments.parse(text, timing: timing); fatalError(message) }
  catch is CommentParseError {} catch { fatalError("Unexpected error: \(error)") }
}

let timeline = try NeoASSComments.parse(ass(#"""
Dialogue: 0,0:00:10.00,0:00:18.00,Default,,0,0,0,,{\move(1920,100,-400,100)\c&H0000FF&\fs80}赤いコメント,カンマ付き
Dialogue: 1,0:00:02.00,0:00:06.00,Default,,0,0,0,,{\pos(960,100)\an8\1a&H80&}固定\N二行
Dialogue: 0,0:00:05.00,0:00:15.00,Default,,0,0,0,,{\move(100,200,300,400,1000,3000)}時間指定
"""#))
check(timeline.width == 1920 && timeline.height == 1080, "Script dimensions")
check(timeline.comments.count == 3 && timeline.comments[0].start == 2, "Sorted events")
check(timeline.visible(at: 0).isEmpty, "Nothing before the first comment")
check(timeline.visible(at: 2).count == 1 && timeline.visible(at: 6).count == 1, "Start inclusive, end exclusive")
check(timeline.visible(at: 11).count == 2, "Overlapping events")
check(timeline.visible(at: 18).isEmpty, "Ended comments cleared")
check(timeline.visible(at: 3).count == 1, "Seeking backwards restores active comments")
let moving = timeline.comments[2]
check(moving.text == "赤いコメント,カンマ付き", "Text commas retained")
check(moving.style.color.red == 1 && moving.style.color.blue == 0 && moving.style.size == 80, "BGR color and inline size")
check(moving.motion!.point(elapsed: 4) == CommentPoint(x: 760, y: 100), "ASS movement interpolation")
let fixed = timeline.comments[0]
let sourceStyle = CommentStyle(color: CommentColor(red: 1, green: 0, blue: 0, alpha: 143.0/255), outlineColor: CommentColor(red: 0, green: 0, blue: 1, alpha: 143.0/255))
check(sourceStyle.withAbsoluteOpacity(nil) == sourceStyle, "ASS opacity must be preserved before override")
let opaque = sourceStyle.withAbsoluteOpacity(1)
check(opaque.color.alpha == 1 && opaque.outlineColor.alpha == 1 && opaque.color.red == 1 && opaque.outlineColor.blue == 1, "Absolute opacity preserves RGB")
let flowStyle = CommentStyle(size: 20, alignment: 7)
let flow = CommentTimeline(width: 640, height: 360, comments: (0..<3).map {
  NativeComment(id: $0, layer: 0, start: 0, end: CommentTiming.scrollingDuration, text: "flow", style: flowStyle,
    motion: CommentMotion(from: CommentPoint(x: 640, y: 20), to: CommentPoint(x: -100, y: 20), start: 0, end: CommentTiming.scrollingDuration), usesDanmakuTiming: true)
})
let measure: (NativeComment) -> CommentExtent = { _ in CommentExtent(width: 100, height: 30) }
let lanes = CommentLanePlan.build(flow, size: 2, measure: measure)
check(lanes.count == 3, "Three enlarged comments must fit")
let tops = lanes.values.sorted()
check(zip(tops, tops.dropFirst()).allSatisfy { $1-$0 >= 61 && $1-$0 <= 61.001 }, "Enlarged lanes use a one-pixel gap without overlapping")
check(lanes == CommentLanePlan.build(flow, size: 2, measure: measure), "Seek must produce deterministic lanes")
check(CommentLanePlan.build(flow, size: 2, cancelled: { true }, measure: measure).isEmpty, "Superseded layout can be cancelled")
check(fixed.text == "固定\n二行" && fixed.style.alignment == 8, "Newlines and alignment")
check(abs(fixed.style.color.alpha - (1 - 128.0 / 255)) < 0.0001, "ASS inverse alpha")
let timed = timeline.comments[1].motion!
check(timed.point(elapsed: 0) == CommentPoint(x: 100, y: 200), "Before move time")
check(timed.point(elapsed: 2) == CommentPoint(x: 200, y: 300), "Relative move time")
check(timed.point(elapsed: 5) == CommentPoint(x: 300, y: 400), "After move time")
rejects(ass(#"Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,{\t(0,100,\fs90)}effect"#), "Do not silently strip ASS transforms")
rejects(ass(#"Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,{\p1}m 0 0 l 1 1"#), "Do not treat ASS drawings as text")
rejects(ass(#"Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,first{\c&H00FF00&}second"#), "Do not flatten mid-text styling")
rejects(ass("Dialogue: 0,broken,0:00:08.00,Default,,0,0,0,,invalid"), "Invalid timestamps")
let emptyIntervals = try NeoASSComments.parse(ass(#"""
Dialogue: 0,0:00:10.00,0:00:10.00,Default,,0,0,0,,{\move(1920,100,-400,100)}表示時間なし
Dialogue: 0,0:00:12.00,0:00:11.00,Default,,0,0,0,,{\t(0,100,\fs90)}逆転した区間
Dialogue: 0,0:00:10.00,0:00:18.00,Default,,0,0,0,,{\move(1920,100,-400,100)}表示するコメント
"""#))
check(emptyIntervals.comments.count == 1 && emptyIntervals.comments[0].text == "表示するコメント", "Empty intervals do not reject the whole track")
check(emptyIntervals.visible(at: 10).count == 1 && emptyIntervals.visible(at: 18).isEmpty, "Valid comments keep their original timing")
do {
  _ = try NeoASSComments.parse(ass("Dialogue: 0,0:00:10.00,0:00:10.00,Default,,0,0,0,,表示時間なし"))
  fatalError("A track containing only empty intervals must not report success")
} catch CommentParseError.empty {} catch { fatalError("Expected an empty track: \(error)") }
rejects(ass("Dialogue: 0,broken,broken,Default,,0,0,0,,invalid"), "Malformed timestamps are not empty intervals")
let cutComments = try NeoASSComments.parse(ass(#"""
Dialogue: 0,0:00:10.00,0:00:18.00,Default,,0,0,0,,{\move(1920,100,-400,100)}通常
Dialogue: 0,0:00:10.00,0:00:10.01,Default,,0,0,0,,{\move(1920,100,-400,100,0,10)}CM直前
Dialogue: 0,0:00:10.00,0:00:10.00,Default,,0,0,0,,{\move(1920,100,-400,100)}表示時間ゼロ
Dialogue: 0,0:00:10.00,unused,Default,,0,0,0,,{\pos(960,100)\an8}固定
"""#), timing: .danmaku)
check(cutComments.comments.count == 4 && cutComments.comments.allSatisfy(\.usesDanmakuTiming), "CM-cut comments are retained in danmaku mode")
check(cutComments.comments.prefix(3).allSatisfy { $0.end == 15.25 && $0.motion?.end == 5.25 && $0.motion?.start == 0 }, "Scrolling comments use the requested 5.25-second travel time")
check(cutComments.comments[3].end == 14.5, "Fixed comments use the DPlayer full-screen lifetime")
check(cutComments.visible(at: 12).count == 4 && cutComments.visible(at: 15).count == 3 && cutComments.visible(at: 15.25).isEmpty, "Comments remain across the cut and expire at the new end")
let scroll = cutComments.comments[2]
check(scroll.scrollingX(viewportWidth: 1000, textWidth: 200, elapsed: 0) == 1000, "Enter at the right edge")
check(scroll.scrollingX(viewportWidth: 1000, textWidth: 200, elapsed: 2.625) == 400, "Normal-speed midpoint after a zero-duration cut")
check(scroll.scrollingX(viewportWidth: 1000, textWidth: 400, elapsed: 5.25) == -400, "Leave completely using actual resized text width")
check(cutComments.visible(at: 11).count == 4, "Backward seek restores cut comments")
rejects(ass("Dialogue: 0,broken,0:00:18.00,Default,,0,0,0,,invalid"), "Danmaku still requires a valid emission time", timing: .danmaku)
rejects(ass(#"Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,{\an1e300}invalid"#), "Huge alignment must not trap an Int conversion")
rejects(header.replacingOccurrences(of: "BorderStyle, Outline", with: "Name, Outline"), "Duplicate Format fields must not crash")
check(NeoASSComments.isCommentName("NicoJK-1080T") && !NeoASSComments.isCommentName("日本語字幕"), "Comment metadata classification")
let spaced = try NeoASSComments.parse(ass("Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,  空白  "))
check(spaced.comments[0].text == "  空白  ", "Intentional text whitespace retained")
let metadata = Data(#"{"subtitleIndex":0,"streamIndex":2,"codecName":"ass","displayName":"字幕1 / NicoJK-1080T"}"#.utf8)
let track = try JSONDecoder().decode(NativeCommentTrack.self, from: metadata)
check(track.isComment && track.subtitleIndex == 0, "Server metadata identifies ASS comments")
let loader = NeoCommentLoader(source: URL(string: "https://example.com/neo/api/videos/7")!, username: "", password: "")
check(loader.permitsRedirect(to: URL(string: "https://example.com/neo/api/videos/7/subtitles/0/text/")!), "Same-origin subtitle redirect")
check(!loader.permitsRedirect(to: URL(string: "https://other.example/neo/api/videos/7/subtitles")!), "Do not redirect credentials to another host")
check(!loader.permitsRedirect(to: URL(string: "http://example.com/neo/api/videos/7/subtitles")!), "Do not downgrade HTTPS")
check(!loader.permitsRedirect(to: URL(string: "https://example.com/neo/api/videos/7/subtitles-other")!), "Keep redirects in the subtitle API")
loader.close()

let jikkyoData = Data(##"{"isSuccess":true,"source":"jikkyo","timeBase":"video","comments":[{"time":1.25,"text":"{\\pos(1,2)} literal","color":"#123456","position":"right","size":"big"},{"time":2,"text":"top","color":"#FF0000","position":"top","size":"small"},{"time":3,"text":"bottom","color":"#00FF00","position":"bottom","size":"medium"}]}"##.utf8)
let jikkyo = try NeoCommentLoader.parseJikkyo(jikkyoData)
check(jikkyo.comments.count == 3 && jikkyo.comments[0].text == #"{\pos(1,2)} literal"#, "JSON text is literal, not ASS commands")
check(jikkyo.comments[0].start == 1.25 && jikkyo.comments[0].end == 6.5 && jikkyo.comments[0].motion != nil, "Jikkyo uses video seconds and 5.25-second movement")
check(jikkyo.comments[0].style.size == 96 && abs(jikkyo.comments[0].style.color.red - 18.0/255) < 0.001, "Jikkyo big size and RGB command color")
check(jikkyo.comments[1].style.alignment == 8 && jikkyo.comments[1].motion == nil && jikkyo.comments[1].style.size == 48, "Top small comments retain fixed layout")
check(jikkyo.comments[2].style.alignment == 2 && jikkyo.comments[2].motion == nil, "Bottom comments retain fixed layout")
check(jikkyo.visible(at: 5).count == 3 && jikkyo.visible(at: 2).count == 2, "Seeking restores the correct JSON comments")
let jikkyoLoader = NeoCommentLoader(source: URL(string: "https://example.com/neo/api/videos/7")!, username: "", password: "")
check(jikkyoLoader.permitsRedirect(to: URL(string: "https://example.com/neo/api/videos/7/comments")!), "Allow the same-origin TS comment API")
check(!jikkyoLoader.permitsRedirect(to: URL(string: "https://example.com/neo/api/videos/8/comments")!), "Never redirect comments to another recording")
jikkyoLoader.close()
let aribPackets = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/arib-timing-meta.ts"))
var aribTiming = NeoARIBTiming()
for offset in stride(from: 0, to: aribPackets.count, by: 321) {
  aribTiming.observe(aribPackets.subdata(in: offset..<min(offset+321, aribPackets.count)), offset: Int64(offset))
}
func aribVisible(_ time: Double) -> Bool? { aribTiming.schedule.last(where: { $0.0 <= time })?.1 }
check(aribVisible(0.5) == nil && aribVisible(2) == true && aribVisible(4) == true, "ARIB indefinite caption survives until the next presentation")
check(aribVisible(6.5) == true && aribVisible(8) == true, "ARIB wait without clear does not expire a caption")
check(aribVisible(10) == true && aribVisible(12) == false && aribVisible(14) == true && aribVisible(17) == false, "ARIB delayed and standalone clears retain their exact schedule")
aribTiming.observe(aribPackets, offset: 0)
check(aribTiming.schedule.count == 6 && aribVisible(4) == true, "Cached TS replay deduplicates ARIB timing events")
do {
  _ = try NeoCommentLoader.parseJikkyo(Data(String(decoding: jikkyoData, as: UTF8.self).replacingOccurrences(of: #""timeBase":"video""#, with: #""timeBase":"absolute""#).utf8))
  check(false, "Reject a non-video time base")
} catch { check(true, "Reject a non-video time base") }

// Long-duration comments must survive binary-search pruning, including after seeks.
var many = (0..<20000).map { NativeComment(id: $0, layer: 0, start: Double($0), end: Double($0) + 8,
  text: "comment", style: CommentStyle()) }
many.append(NativeComment(id: 20000, layer: 0, start: 0, end: 30000, text: "fixed", style: CommentStyle()))
let longTimeline = CommentTimeline(width: 1920, height: 1080, comments: many)
check(longTimeline.visible(at: 10000).count == 9, "Long fixed comment remains visible")
check(longTimeline.visible(at: 4).count == 6, "Seek into an earlier overlapping window")

var cursor = CommentFrameCursor()
var gate = CommentSeekResumeGate()
check(!gate.allows(media: 5, running: false, wantsPlayback: true), "Seek waits through buffering")
check(!gate.allows(media: 5, running: true, wantsPlayback: true), "Seek does not display frozen comments at the first sample")
check(gate.allows(media: 5.02, running: true, wantsPlayback: true), "Seek resumes after the clock advances")
gate.reset()
check(gate.allows(media: 5, running: false, wantsPlayback: false), "Explicitly paused seeks display the destination comments")
for time in [0.0, 1, 2, 2.01, 3, 4, 5, 5.01, 6, 11, 18, 2, 10000, 4] {
  let expected = timeline.visible(at: time).sorted { $0.layer == $1.layer ? $0.id < $1.id : $0.layer < $1.layer }.map(\.id)
  check(cursor.visible(timeline, at: time).map(\.id) == expected, "Frame cursor matches timeline boundaries and backward seeks")
}
cursor.reset()
check(cursor.visible(longTimeline, at: 10000).count == 9, "Frame cursor retains long overlapping comments")
let subtitleKey = "player.subtitle.name", oldSubtitle = UserDefaults.standard.object(forKey: "player.subtitle.name")
UserDefaults.standard.removeObject(forKey: subtitleKey)
check(NeoSubtitlePreference.savedName == nil, "Unset subtitle preference preserves default selection")
NeoSubtitlePreference.save("")
check(NeoSubtitlePreference.savedName == "" && NeoSubtitlePreference.preferredIndex(["日本語", "English"]) == -1, "Subtitle off persists")
NeoSubtitlePreference.save("English")
check(NeoSubtitlePreference.preferredIndex(["English", "日本語"]) == 0 && NeoSubtitlePreference.preferredIndex(["日本語", "English"]) == 1, "Restore subtitle by name, independent of track index")
check(NeoSubtitlePreference.preferredIndex(["日本語"]) == -1, "Missing saved subtitle does not select an unrelated track")
if let oldSubtitle { UserDefaults.standard.set(oldSubtitle, forKey: subtitleKey) } else { UserDefaults.standard.removeObject(forKey: subtitleKey) }
print("Native ASS parser, timeline, clock, packing, subtitle preferences: all checks passed")
let commentKey = NeoCommentPreference.key, oldComment = UserDefaults.standard.object(forKey: NeoCommentPreference.key)
let commentTracks = ["実況 少数", "実況 全体"].enumerated().map { i, name in
  NativeCommentTrack(subtitleIndex: i, streamIndex: i+2, codecName: "ass", displayName: name, title: name, language: "jpn")
}
UserDefaults.standard.removeObject(forKey: commentKey)
check(NeoCommentPreference.preferred(commentTracks)?.subtitleIndex == 0, "Comments default to the first available track")
NeoCommentPreference.save(commentTracks[1].displayName)
check(NeoCommentPreference.preferred(commentTracks)?.subtitleIndex == 1, "Restore the chosen dense commentary track")
check(NeoCommentPreference.preferred(Array(commentTracks.reversed()))?.displayName == commentTracks[1].displayName, "Comment preference survives reordered tracks")
check(NeoCommentPreference.preferred([commentTracks[0]])?.subtitleIndex == 0 && UserDefaults.standard.string(forKey: commentKey) == commentTracks[1].displayName, "Missing commentary uses a fallback without replacing preference")
if let oldComment { UserDefaults.standard.set(oldComment, forKey: commentKey) } else { UserDefaults.standard.removeObject(forKey: commentKey) }
let allDropped = NeoVideoRecovery(); allDropped.begin(100, timeout: 10)
_ = allDropped.evaluate(["outputID": 1, "samples": 1, "arrivalAge": 0.05, "scheduledInMs": -80, "nativeDecoded": 278, "nativeLost": 0], mediaMs: 1000, now: 100)
check(allDropped.evaluate(["outputID": 1, "samples": 40, "arrivalAge": 0.05, "scheduledInMs": -80, "nativeDecoded": 350, "nativeLost": 72], mediaMs: 4000, now: 103) == 2, "Fresh repeated callbacks cannot hide all decoded pictures being dropped")
let staticPicture = NeoVideoRecovery(); staticPicture.begin(100, timeout: 10)
_ = staticPicture.evaluate(["outputID": 1, "samples": 1, "arrivalAge": 0.05, "scheduledInMs": 0, "nativeDecoded": 278, "nativeLost": 0], mediaMs: 1000, now: 100)
check(staticPicture.evaluate(["outputID": 1, "samples": 73, "arrivalAge": 0.05, "scheduledInMs": 0, "nativeDecoded": 350, "nativeLost": 0], mediaMs: 4000, now: 103) == 0, "A correctly decoded static picture stays healthy")

var presentationClock = CommentPresentationClock()
_ = presentationClock.time(media: 10, running: true, now: 100, videoHost: 100)
let beforeStall = presentationClock.time(media: 10.1, running: true, now: 100.1, videoHost: 100.1)
for step in 1...100 {
  let host = 100.5 + Double(step) / 10
  check(presentationClock.time(media: host - 90, running: true, now: host, videoHost: 100.1) == beforeStall,
    "Video stall freezes comments even when VLC time advances for more than 1.5 seconds")
}
check(presentationClock.time(media: 40, running: false, now: 112, videoHost: 112) == beforeStall,
  "Buffering notification freezes comments despite fresh queued frames and advancing media time")
check(presentationClock.time(media: 22, running: true, now: 112.1, videoHost: 112.1) == beforeStall && presentationClock.schedulingTime == 22,
  "Fresh video updates new emissions without jumping the active motion clock")
check(abs(presentationClock.time(media: 22.1, running: true, now: 112.2, videoHost: 112.2)-beforeStall-0.1) < 0.00001,
  "Active comments resume at constant speed after real buffering")
presentationClock.reset()
check(presentationClock.time(media: 3, running: false, now: 113, videoHost: 0) == 3,
  "Explicitly paused seek shows destination after reset")
check(presentationClock.time(media: 3.1, running: true, now: 113.1, videoHost: 120) == 3,
  "Future enqueued frames do not count as displayed video")
print("Video-stall-aware comment clock: all checks passed")

var obscuredClock = CommentPresentationClock()
_ = obscuredClock.time(media: 10, running: true, now: 100, videoHost: 100)
_ = obscuredClock.time(media: 10.1, running: true, now: 100.1, videoHost: 100.1)
check(abs(obscuredClock.time(media: 13, running: true, now: 103, videoHost: 100, decodedHost: 103)-13) < 0.00001,
  "Fresh decoded video keeps comments running when PiP or inline surface is obscured")
check(abs(obscuredClock.time(media: 14, running: false, now: 104, videoHost: 100, decodedHost: 104)-13) < 0.00001,
  "Real buffering still freezes comments even with fresh decoded frames")
check(abs(obscuredClock.time(media: 20, running: true, now: 110, videoHost: 100, decodedHost: 104)-13) < 0.00001,
  "Both decode and presentation stalled must freeze comments")

var emissionClock = CommentPresentationClock()
_ = emissionClock.time(media: 0, running: false, now: 100, videoHost: 100)
_ = emissionClock.time(media: 0, running: true, now: 100.01, videoHost: 100.01)
check(!emissionClock.ready, "Fresh startup frames do not emit stationary comments before native time advances")
_ = emissionClock.time(media: 0.1, running: true, now: 100.1, videoHost: 100.1)
check(emissionClock.ready && emissionClock.schedulingTime == 0.1, "Initial emissions anchor to advancing native media time")
var priorMotion = 0.1
for frame in 1...180 {
  let now = 100.1+Double(frame)/60
  let raw = frame < 60 ? now-100 : now-100-0.1
  let motion = emissionClock.time(media: raw, running: true, now: now, videoHost: now)
  check(abs(motion-priorMotion-1/60.0) < 0.000001, "A backwards 100ms native correction never freezes or speeds active comments")
  check(abs(emissionClock.schedulingTime-raw) < 0.000001, "New emissions follow the corrected media time")
  priorMotion = motion
}
check(abs(emissionClock.time(media: 3.2, running: true, now: 103.35, rate: 2, videoHost: 103.35)-priorMotion-0.5) < 0.000001,
  "Explicit playback speed still applies to active trajectories")
emissionClock.reset()
check(!emissionClock.ready && emissionClock.time(media: 50, running: false, now: 104) == 50,
  "A true seek resets to the requested position, including paused seeks")

var movingStyle = CommentStyle(); movingStyle.alignment = 7
let activeEvent = NativeComment(id: 300, layer: 0, start: 0, end: 5.25, text: "active", style: movingStyle,
  motion: CommentMotion(from: CommentPoint(x: 1920, y: 0), to: CommentPoint(x: -1400, y: 0), start: 0, end: 5.25), usesDanmakuTiming: true)
var arriving = activeEvent; arriving.id = 301; arriving.start = 1; arriving.end = 6.25
let movementTimeline = CommentTimeline(width: 1920, height: 1080, comments: [activeEvent, arriving])
var scheduler = CommentMotionScheduler()
let originalMoving = scheduler.visible(movementTimeline, media: 0.2, motion: 0.2)[0]
let corrected = scheduler.visible(movementTimeline, media: 0.9, motion: 1.1)
check(corrected.count == 1 && corrected[0].start == originalMoving.start && corrected[0].end == originalMoving.end,
  "Backward correction leaves the current event's presentation lifetime unchanged")
let newEmissions = scheduler.visible(movementTimeline, media: 1.01, motion: 1.21)
check(newEmissions.count == 2 && newEmissions[0].start == originalMoving.start && abs(newEmissions[1].start-1.2) < 0.00001,
  "Only a newly emitted event receives the corrected scheduling offset")
scheduler.replaceTimeline()
check(scheduler.visible(movementTimeline, media: 1.1, motion: 1.3).map(\.start) == newEmissions.map(\.start),
  "Preview handoff preserves actual active trajectories")
check(scheduler.visible(movementTimeline, media: 4, motion: 7).isEmpty,
  "Expired events are not emitted again while native media time lags")
scheduler.reset()
check(scheduler.visible(movementTimeline, media: 2, motion: 2).count == 2,
  "An explicit backwards seek permits destination events to be emitted again")
let actualPlan = CommentLanePlan.build(CommentTimeline(width: 1920, height: 1080, comments: newEmissions), size: 1, fixedPositions: [300: 0]) {
  _ in CommentExtent(width: 1400, height: 60)
}
check(actualPlan[300] == 0 && actualPlan[301] != nil && actualPlan[301]! >= 61,
  "Collision avoidance reserves the actual remaining presentation lifetime of active comments")
print("Initial emission gate and correction-independent active motion: all checks passed")

// Preview-to-full identities, duplicate events and terminal text entry.
let previewRange = NeoCommentLoader.previewRange(at: 100)
check(previewRange.startAt == 70 && previewRange.duration == 210, "Preview matches Web look-behind and 3.5-minute span")
check(NeoCommentLoader.previewRange(at: 0).startAt == 0, "Initial preview never requests negative time")
let previewEvent = NativeComment(id: 0, layer: 0, start: 50, end: 55.25, text: "same", style: CommentStyle(),
  motion: CommentMotion(from: CommentPoint(x: 1920,y: 80), to: CommentPoint(x: -100,y: 80), start: 0,end: 5.25), usesDanmakuTiming: true)
var previewDuplicate = previewEvent; previewDuplicate.id = 1
let previewTimeline = CommentTimeline(width: 1920,height: 1080,comments: [previewEvent,previewDuplicate])
var earlier = previewEvent; earlier.id = 0; earlier.start = 1; earlier.end = 6.25
var fullEvent = previewEvent; fullEvent.id = 1
var fullDuplicate = previewDuplicate; fullDuplicate.id = 2
var later = previewEvent; later.id = 3; later.start = 500; later.end = 505.25
let expanded = CommentTimeline(width: 1920,height: 1080,comments: [earlier,fullEvent,fullDuplicate,later]).preservingIDs(from: previewTimeline)
check(expanded.visible(at: 51).map(\.id) == [0,1], "Moving preview IDs survive extra earlier full-file events and exact duplicates")
check(Set(expanded.comments.map(\.id)).count == 4, "Full swap never duplicates IDs")
let pinned = CommentLanePlan.build(expanded, size: 1, fixedPositions: [0: 80,1: 160]) { _ in CommentExtent(width: 100,height: 40) }
check(pinned[0] == 80 && pinned[1] == 160, "Full layout retains moving preview lanes")
var tail = previewEvent; tail.id = 20; tail.start = 600; tail.end = 605.25
let terminal = CommentTimeline(width: 1920,height: 1080,comments: [earlier,tail]).fittingEnd(duration: 600) { _ in 500 }
let adjustedTail = terminal.comments.first(where: { $0.id == 20 })!
check(adjustedTail.start < 600 && abs(adjustedTail.end-adjustedTail.start-5.25) < 0.00001, "Terminal correction retains the requested scrolling speed")
let terminalX = adjustedTail.scrollingX(viewportWidth: 1920,textWidth: 500,elapsed: 600-adjustedTail.start)!
check(terminalX+500 <= 1920 && terminalX >= 0, "Last timestamp comment enters the screen fully before EOF")
check(terminal.comments.first(where: { $0.id == earlier.id })!.start == earlier.start, "Ordinary comment timestamps remain unchanged")
print("Preview handoff and terminal timing: all checks passed")

func outputStats(_ id: Int = 1, samples: Int, changes: Int, age: Double, scheduled: Double = 0) -> [String: NSNumber] {
  ["outputID": NSNumber(value: id), "samples": NSNumber(value: samples), "changes": NSNumber(value: changes),
   "contentAge": NSNumber(value: age), "scheduledInMs": NSNumber(value: scheduled), "layerStatus": 1]
}
let recovery = NeoVideoRecovery()
recovery.begin(100, timeout: 10)
_ = recovery.evaluate(outputStats(samples: 0, changes: 1, age: 0), mediaMs: 5000, now: 100)
check(recovery.evaluate(outputStats(samples: 36, changes: 1, age: 3), mediaMs: 8000, now: 103) == 2,
  "Repeated paused pictures with advancing audio initiate a queue flush")
check(recovery.evaluate(outputStats(samples: 48, changes: 1, age: 4), mediaMs: 9000, now: 104) == 0,
  "A track-selected callback or more identical pictures never confirms recovery")
check(recovery.evaluate(outputStats(samples: 72, changes: 1, age: 6), mediaMs: 11000, now: 106) == 3,
  "Failed flush escalates to video-track restart once")
check(recovery.evaluate(outputStats(2, samples: 1, changes: 1, age: 0), mediaMs: 12000, now: 107) == 0,
  "Newly created output and its first fingerprint are not recovery evidence")
check(recovery.evaluate(outputStats(2, samples: 24, changes: 3, age: 0, scheduled: 4200), mediaMs: 13000, now: 108) == 0,
  "Changing frames scheduled far in the future do not confirm displayed-video recovery")
check(recovery.evaluate(outputStats(2, samples: 48, changes: 4, age: 0), mediaMs: 14000, now: 109) == 1,
  "A new output confirms recovery only after changing pictures become due")

recovery.begin(200, timeout: 10)
_ = recovery.evaluate([:], mediaMs: 10000, now: 200)
check(recovery.evaluate([:], mediaMs: 13000, now: 203) == 2, "Missing output is detected after the observation window")
check(recovery.evaluate([:], mediaMs: 16000, now: 206) == 3, "Missing output still escalates")
check(recovery.evaluate(outputStats(3, samples: 0, changes: 0, age: -1), mediaMs: 25000, now: 215) == 0,
  "Layer recreation does not restart the repair deadline")
check(recovery.evaluate([:], mediaMs: 28000, now: 218) == 4, "Restart without actual pictures falls back to position-preserving input recovery")
check(recovery.evaluate([:], mediaMs: 45000, now: 235) == 5, "Recovery timeout is bounded")
recovery.hold(240)
check(recovery.evaluate([:], mediaMs: 50000, now: 260) == 0, "A failed recovery never loops through whole-player reloads")

recovery.begin(300, timeout: 10)
_ = recovery.evaluate(outputStats(samples: 0, changes: 1, age: 0), mediaMs: 0, now: 300)
check(recovery.evaluate(outputStats(samples: 72, changes: 1, age: 3), mediaMs: 3000, now: 303) == 0,
  "A normally delivered 24fps static scene does not trigger recovery")
_ = recovery.evaluate(outputStats(samples: 108, changes: 1, age: 6), mediaMs: 6000, now: 306)
recovery.hold(350)
check(recovery.evaluate(outputStats(samples: 108, changes: 1, age: 50), mediaMs: 6000, now: 350) == 0,
  "Paused or buffering time never consumes a repair deadline")
check(recovery.evaluate(outputStats(samples: 132, changes: 3, age: 0), mediaMs: 7000, now: 351) == 1,
  "A held repair still verifies actual picture recovery")
print("Video-output identity, confirmed recovery and bounded escalation: all checks passed")
let continuousRecovery = NeoVideoRecovery()
continuousRecovery.begin(100, timeout: 10)
_ = continuousRecovery.evaluate(["outputID": 1, "samples": 10, "arrivalAge": 0, "scheduledInMs": 0], mediaMs: 1000, now: 200)
check(continuousRecovery.evaluate(["outputID": 1, "samples": 10, "arrivalAge": 4, "scheduledInMs": -4000], mediaMs: 5000, now: 204) == 2,
  "Video starvation is detected even more than 45 seconds after foregrounding")
continuousRecovery.begin(300, timeout: 10)
_ = continuousRecovery.evaluate(["outputID": 1, "samples": 100, "arrivalAge": 0.1, "scheduledInMs": 0, "nativeDecodeAge": 0], mediaMs: 1000, now: 300)
check(continuousRecovery.evaluate(["outputID": 1, "samples": 200, "arrivalAge": 0.1, "scheduledInMs": 0, "nativeDecodeAge": 9], mediaMs: 10000, now: 309) == 2,
  "Repeating a paused image cannot conceal a stopped decoder behind fresh output timestamps")
let networkPlayback = NeoNetworkPlaybackFlow()
func networkStep(_ waiting: Bool, _ delivery: Int64, _ video: UInt64, _ age: Double, wants: Bool = true, eligible: Bool = true) -> Int {
  networkPlayback.update(waiting: waiting, delivery: delivery, video: video, videoAge: age, staleAfter: 1.5, eligible: eligible, wantsPlayback: wants)
}
check(networkStep(true, 1, 50, 0.1) == 0, "Slow prefetch never pauses healthy video")
check(networkStep(false, 1, 50, 3) == 0, "Decoder-only faults are not classified as starved HTTP reads")
check(networkStep(true, 1, 50, 3) == 1 && networkPlayback.holding, "Starved output and a pending read hold presentation")
check(networkStep(true, 1, 50, 4) == 0 && networkPlayback.holding, "A 100% callback without available bytes cannot release presentation")
check(networkStep(true, 2, 50, 4) == 2 && !networkPlayback.holding && networkPlayback.verifying, "Available bytes permit input resynchronisation even while the next read is pending")
check(networkStep(false, 2, 50, 0.1) == 0 && networkPlayback.verifying, "A repeated paused frame does not confirm decoded video recovery")
check(networkStep(false, 2, 51, 0.1) == 3 && !networkPlayback.verifying, "New video plus fresh output confirms recovery")
_ = networkStep(true, 3, 52, 3)
check(networkStep(true, 4, 52, 3, wants: false) == 2 && !networkPlayback.verifying, "Explicit pause during a stalled read remains paused on byte recovery")
check(networkStep(true, 4, 52, 3, eligible: false) == 0, "Audio-only background playback is excluded")
print("Network starvation, byte availability and video confirmation: all checks passed")

func ebml(_ id: [UInt8], _ body: Data) -> Data {
  Data(id + [0x10, UInt8((body.count >> 16)&255), UInt8((body.count >> 8)&255), UInt8(body.count&255)]) + body
}
func ebmlNumber(_ number: UInt64) -> Data {
  Data((0..<8).reversed().map { UInt8((number >> ($0*8))&255) })
}
let mkvInfo = ebml([0x2a,0xd7,0xb1], ebmlNumber(1_000_000))
let mkvTracks = ebml([0xae], ebml([0xd7], ebmlNumber(1)) + ebml([0x83], ebmlNumber(1)))
func cue(_ time: UInt64, _ position: UInt64) -> Data {
  ebml([0xbb], ebml([0xb3], ebmlNumber(time)) + ebml([0xb7], ebml([0xf7], ebmlNumber(1)) + ebml([0xf1], ebmlNumber(position))))
}
let mkvCues = cue(0, 50) + cue(80_000, 800) + cue(90_000, 900)
let mkv = NeoMatroskaSeekIndex(cues: mkvCues, info: mkvInfo, tracks: mkvTracks, segment: 100, length: 1200)
check(mkv?.nearest(85)?.offset == 900 && mkv?.nearest(85)?.time == 80, "MKV seek uses the preceding video Cue and Segment-relative offset")
check(NeoMatroskaSeekIndex(cues: cue(1, 2000), info: mkvInfo, tracks: mkvTracks, segment: 100, length: 1200) == nil,
  "Out-of-file MKV Cues never enable trusted demuxing")
check(NeoMatroskaSeekIndex(cues: cue(1, 900)+cue(2, 50), info: mkvInfo, tracks: mkvTracks, segment: 100, length: 1200) == nil,
  "Backwards MKV Cue offsets are rejected")
check(NeoMatroskaSeekIndex(cues: mkvCues.dropLast(), info: mkvInfo, tracks: mkvTracks, segment: 100, length: 1200) == nil,
  "Truncated EBML metadata is rejected")
let audioOnly = ebml([0xae], ebml([0xd7], ebmlNumber(1)) + ebml([0x83], ebmlNumber(2)))
check(NeoMatroskaSeekIndex(cues: mkvCues, info: mkvInfo, tracks: audioOnly, segment: 100, length: 1200) == nil,
  "Audio-only Cues cannot masquerade as a video index")
check(NeoMatroskaSeekIndex.header(Data([0x18,0x53,0x80,0x67,0xff]))?.size == nil,
  "Unknown-size Segment headers are handled without integer overflow")
var measured = 0
_ = CommentLanePlan.build(expanded, size: 1, fixedPositions: [0: 80, 1: 160]) { _ in measured += 1; return CommentExtent(width: 100, height: 40) }
check(measured == expanded.comments.count, "Pinned comments are measured once, without re-running candidate packing")
print("MKV Cue validation and incremental comment packing: all checks passed")
check(NeoPlaybackHistory.observedMilliseconds(Date(timeIntervalSince1970: 1700000000.1234)) == 1700000000123,
  "Playback observedAt is an integer millisecond value accepted by OpenAPI")
check(NeoPlaybackHistory.errorMessage(URLError(.timedOut)).contains("接続できませんでした"), "Timeout gets connection message")
check(NeoPlaybackHistory.errorMessage(nil) == "視聴履歴の送信中にエラーが発生しました。", "HTTP rejection gets generic message")
