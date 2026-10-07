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

// Long-duration comments must survive binary-search pruning, including after seeks.
var many = (0..<20000).map { NativeComment(id: $0, layer: 0, start: Double($0), end: Double($0) + 8,
  text: "comment", style: CommentStyle()) }
many.append(NativeComment(id: 20000, layer: 0, start: 0, end: 30000, text: "fixed", style: CommentStyle()))
let longTimeline = CommentTimeline(width: 1920, height: 1080, comments: many)
check(longTimeline.visible(at: 10000).count == 9, "Long fixed comment remains visible")
check(longTimeline.visible(at: 4).count == 6, "Seek into an earlier overlapping window")

var clock = CommentPlaybackClock()
check(clock.time(media: 10, running: true, now: 100) == 10, "Initial media anchor")
check(abs(clock.time(media: 10, running: true, now: 100.02) - 10.02) < 0.0001, "Between-sample smoothing")
check(clock.time(media: 10, running: true, now: 102) == 11.5, "A stalled clock stops after the bounded grace period")
check(clock.time(media: 10, running: false, now: 102) == 10, "Pause freezes time")
check(clock.time(media: 3, running: true, now: 103) == 3, "Backward seek resets anchor")
check(clock.time(media: 90, running: true, now: 104) == 90, "Forward seek resets anchor")
clock.reset()
var previousClock = clock.time(media: 0, running: true, now: 0)
for frame in 1...240 {
  let now = Double(frame)/60
  let value = clock.time(media: floor(now), running: true, now: now)
  check(value >= previousClock && value-previousClock < 0.04, "Coarse native samples do not freeze or jump each second")
  previousClock = value
}
clock.reset()
_ = clock.time(media: 3, running: true, now: 0, rate: 2)
check(abs(clock.time(media: 3, running: true, now: 0.25, rate: 2)-3.5) < 0.001, "Playback-rate interpolation")
check(clock.time(media: .nan, running: true, now: 1) == 0, "Invalid clock input is rejected")
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
