import Foundation

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
func rejects(_ text: String, _ message: String) {
  do { _ = try NeoASSComments.parse(text); fatalError(message) }
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
check(clock.time(media: 10, running: true, now: 102) <= 10.051, "A stalled clock cannot keep advancing")
check(clock.time(media: 10, running: false, now: 102) == 10, "Pause freezes time")
check(clock.time(media: 3, running: true, now: 103) == 3, "Backward seek resets anchor")
check(clock.time(media: 90, running: true, now: 104) == 90, "Forward seek resets anchor")
print("Native ASS parser, timeline, clock: all checks passed")
