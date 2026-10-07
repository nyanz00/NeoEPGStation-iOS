import Foundation

// A deliberately bounded ASS subset for NicoJK comments, not a general ASS renderer.
// Unsupported effects fail the entire track so the user can keep using VLC/libass.
struct CommentColor: Hashable {
  var red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0
  static let black = CommentColor(red: 0, green: 0, blue: 0)

  static func ass(_ value: String) throws -> CommentColor {
    let hex = value.trimmingCharacters(in: .whitespaces).uppercased()
      .replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "")
    guard !hex.isEmpty, hex.count <= 8, let number = UInt32(hex, radix: 16) else {
      throw CommentParseError.invalid("色")
    }
    return CommentColor(red: Double(number & 255) / 255,
      green: Double((number >> 8) & 255) / 255, blue: Double((number >> 16) & 255) / 255,
      alpha: hex.count > 6 ? 1 - Double((number >> 24) & 255) / 255 : 1)
  }
}

struct CommentStyle: Hashable {
  var font = "Hiragino Sans", size = 64.0
  var bold = false, italic = false
  var color = CommentColor(), outlineColor = CommentColor.black, shadowColor = CommentColor.black
  var outline = 2.0, shadow = 0.0, scaleX = 1.0, scaleY = 1.0
  var alignment = 2, marginL = 20.0, marginR = 20.0, marginV = 20.0
}

struct CommentPoint: Equatable { var x: Double; var y: Double }
struct CommentMotion {
  var from: CommentPoint, to: CommentPoint
  var start: Double, end: Double
  func point(elapsed: Double) -> CommentPoint {
    let fraction = end > start ? min(1, max(0, (elapsed - start) / (end - start))) : (elapsed >= end ? 1.0 : 0.0)
    return CommentPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
  }
}

struct NativeComment {
  var id: Int, layer: Int
  var start: Double, end: Double
  var text: String, style: CommentStyle
  var position: CommentPoint?, motion: CommentMotion?
  var usesDanmakuTiming = false

  // Match DPlayer: right edge to completely off the left edge, using the
  // actual rendered text width even after font substitution or resizing.
  func scrollingX(viewportWidth: Double, textWidth: Double, elapsed: Double) -> Double? {
    guard usesDanmakuTiming, motion != nil else { return nil }
    let progress = min(1, max(0, elapsed / (end - start)))
    return viewportWidth - (viewportWidth + textWidth) * progress
  }
}

enum CommentTiming: Equatable {
  case ass, danmaku
  // App-specific travel time requested for both portrait and landscape.
  // Fixed comments retain their existing lifetime.
  static let scrollingDuration = 5.25, fixedDuration = 4.5
}

struct CommentTimeline {
  var width: Double, height: Double
  var comments: [NativeComment]
  private var endTree: [Double]
  private var leaves: Int

  init(width: Double, height: Double, comments: [NativeComment]) {
    self.width = width; self.height = height
    self.comments = comments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    leaves = 1
    while leaves < comments.count { leaves *= 2 }
    endTree = [Double](repeating: 0, count: leaves * 2)
    for (index, comment) in self.comments.enumerated() { endTree[leaves + index] = comment.end }
    if leaves > 1 {
      for node in stride(from: leaves - 1, through: 1, by: -1) { endTree[node] = max(endTree[node * 2], endTree[node * 2 + 1]) }
    }
  }

  // Interval tree also handles very long fixed comments without forcing a scan
  // of every earlier event on each display refresh or after seeking.
  func visible(at time: Double, lookAhead: Double = 0) -> [NativeComment] {
    guard time.isFinite else { return [] }
    var low = 0, high = comments.count
    while low < high {
      let middle = (low + high) / 2
      if comments[middle].start <= time + lookAhead { low = middle + 1 } else { high = middle }
    }
    let limit = low
    var result: [NativeComment] = []
    func visit(_ node: Int, _ first: Int, _ last: Int) {
      guard first < limit, endTree[node] > time else { return }
      if last - first == 1 { result.append(comments[first]); return }
      let middle = (first + last) / 2
      visit(node * 2, first, middle); visit(node * 2 + 1, middle, last)
    }
    visit(1, 0, leaves)
    return result
  }
}

enum CommentParseError: Error, LocalizedError {
  case invalid(String), unsupported(String), empty
  var errorDescription: String? {
    switch self {
    case .invalid(let field): return "ASSの\(field)を読み取れません。VLCの字幕表示を利用してください。"
    case .unsupported(let effect): return "このASSの\(effect)は専用描画で未対応です。VLCの字幕表示を利用してください。"
    case .empty: return "表示できるASSコメントがありません。"
    }
  }
}

enum NeoASSComments {
  static func isCommentName(_ value: String) -> Bool {
    value.range(of: #"nico[\s_-]*jk|jikkyo|danmaku|comments?|実況|弾幕|流れる"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func parse(_ ass: String, timing: CommentTiming = .ass) throws -> CommentTimeline {
    var section = "", width = 384.0, height = 288.0
    var styleFormat: [String] = [], eventFormat: [String] = []
    var styles: [String: CommentStyle] = [:], comments: [NativeComment] = []
    for raw in ass.components(separatedBy: .newlines) {
      let line = String(raw.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{feff}" }))
      let sectionLine = line.trimmingCharacters(in: .whitespaces)
      if sectionLine.hasPrefix("[") && sectionLine.hasSuffix("]") { section = String(sectionLine.dropFirst().dropLast()).lowercased(); continue }
      guard let separator = line.firstIndex(of: ":") else { continue }
      let name = line[..<separator].lowercased()
      let value = String(line[line.index(after: separator)...].drop(while: { $0 == " " || $0 == "\t" }))
      if section == "script info" {
        if name == "playresx" { width = try dimension(value) }
        if name == "playresy" { height = try dimension(value) }
        // In particular, do not mistake opaque-box outlines for ordinary text outlines.
      } else if section == "v4+ styles" {
        if name == "format" { styleFormat = format(value) }
        if name == "style" {
          let fields = try fields(value, format: styleFormat)
          guard let styleName = fields["name"] else { throw CommentParseError.invalid("スタイル") }
          var style = CommentStyle()
          style.font = fields["fontname"] ?? style.font
          style.size = try number(fields["fontsize"], default: style.size)
          style.bold = try number(fields["bold"], default: 0) != 0
          style.italic = try number(fields["italic"], default: 0) != 0
          style.color = try CommentColor.ass(fields["primarycolour"] ?? "&H00FFFFFF")
          style.outlineColor = try CommentColor.ass(fields["outlinecolour"] ?? "&H00000000")
          style.shadowColor = try CommentColor.ass(fields["backcolour"] ?? "&H00000000")
          style.outline = try number(fields["outline"], default: 2)
          style.shadow = try number(fields["shadow"], default: 0)
          style.scaleX = try number(fields["scalex"], default: 100) / 100
          style.scaleY = try number(fields["scaley"], default: 100) / 100
          style.alignment = try integer(fields["alignment"], default: 2, range: 1...9)
          style.marginL = try number(fields["marginl"], default: 20)
          style.marginR = try number(fields["marginr"], default: 20)
          style.marginV = try number(fields["marginv"], default: 20)
          if try number(fields["borderstyle"], default: 1) != 1 { throw CommentParseError.unsupported("BorderStyle") }
          for key in ["angle", "spacing", "underline", "strikeout"] {
            if try number(fields[key], default: 0) != 0 { throw CommentParseError.unsupported(key) }
          }
          try validate(style)
          styles[styleName.lowercased()] = style
        }
      } else if section == "events" {
        if name == "format" { eventFormat = format(value) }
        if name == "dialogue" {
          guard eventFormat.last == "text" else { throw CommentParseError.invalid("Textフィールド") }
          let fields = try fields(value, format: eventFormat)
          let start = try timestamp(fields["start"] ?? "")
          // Like the Web comment path, danmaku uses only the emission time.
          // CM cutting can shorten or erase the ASS duration; keep the comment
          // and let it travel at the normal rate across the cut boundary.
          let end: Double
          if timing == .danmaku { end = start + CommentTiming.scrollingDuration }
          else { end = try timestamp(fields["end"] ?? "") }
          if timing == .ass && end <= start { continue }
          guard let base = styles[(fields["style"] ?? "Default").lowercased()] else { throw CommentParseError.invalid("スタイル参照") }
          if !(fields["effect"] ?? "").isEmpty { throw CommentParseError.unsupported("Effect") }
          var comment = NativeComment(id: comments.count, layer: try integer(fields["layer"], default: 0, range: -100000...100000),
            start: start, end: end, text: "", style: base)
          for (field, update) in [("marginl", 0), ("marginr", 1), ("marginv", 2)] {
            let margin = try number(fields[field], default: 0)
            if margin > 0 {
              if update == 0 { comment.style.marginL = margin }
              if update == 1 { comment.style.marginR = margin }
              if update == 2 { comment.style.marginV = margin }
            }
          }
          try parseText(fields["text"] ?? "", comment: &comment)
          try validate(comment.style)
          if timing == .danmaku {
            comment.usesDanmakuTiming = true
            let duration = comment.motion == nil ? CommentTiming.fixedDuration : CommentTiming.scrollingDuration
            comment.end = start + duration
            if var motion = comment.motion {
              motion.start = 0; motion.end = duration; comment.motion = motion
            }
          }
          if !comment.text.isEmpty { comments.append(comment) }
        }
      } else if section == "v4 styles" { throw CommentParseError.unsupported("旧SSAスタイル") }
    }
    guard !comments.isEmpty else { throw CommentParseError.empty }
    return CommentTimeline(width: width, height: height, comments: comments)
  }

  private static func parseText(_ raw: String, comment: inout NativeComment) throws {
    var remaining = raw[...], text = ""
    while let open = remaining.firstIndex(of: "{") {
      text += remaining[..<open]
      guard let close = remaining[open...].firstIndex(of: "}") else { throw CommentParseError.invalid("装飾タグ") }
      let block = String(remaining[remaining.index(after: open)..<close])
      // Changing styles partway through a comment requires attributed runs, not one texture style.
      if !text.isEmpty && block.contains("\\") { throw CommentParseError.unsupported("文中の装飾変更") }
      for token in block.components(separatedBy: "\\").dropFirst() where !token.isEmpty {
        try apply(token, comment: &comment)
      }
      remaining = remaining[remaining.index(after: close)...]
    }
    text += remaining
    comment.text = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\h", with: "\u{00a0}")
  }

  private static func apply(_ token: String, comment: inout NativeComment) throws {
    let tags = ["fscx", "fscy", "alpha", "bord", "shad", "move", "pos", "an", "fs", "fn", "1c", "3c", "4c", "1a", "3a", "4a", "c", "b", "i", "q"]
    guard let tag = tags.first(where: { token.hasPrefix($0) }) else { throw CommentParseError.unsupported("装飾タグ \\" + token.prefix(12)) }
    let value = String(token.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
    switch tag {
    case "move", "pos":
      guard value.hasPrefix("("), value.hasSuffix(")") else { throw CommentParseError.invalid("位置") }
      let values = try value.dropFirst().dropLast().split(separator: ",").map { try number(String($0), default: 0) }
      if tag == "pos" {
        guard values.count == 2, comment.motion == nil, comment.position == nil else { throw CommentParseError.invalid("pos") }
        comment.position = CommentPoint(x: values[0], y: values[1])
      } else {
        guard [4, 6].contains(values.count), comment.motion == nil, comment.position == nil else { throw CommentParseError.invalid("move") }
        let start = values.count == 6 ? values[4] / 1000 : 0
        let end = values.count == 6 ? values[5] / 1000 : comment.end - comment.start
        guard start >= 0, end >= start else { throw CommentParseError.invalid("move時間") }
        comment.motion = CommentMotion(from: CommentPoint(x: values[0], y: values[1]),
          to: CommentPoint(x: values[2], y: values[3]), start: start, end: end)
      }
    case "fn": comment.style.font = value
    case "fs": comment.style.size = try number(value, default: comment.style.size)
    case "fscx": comment.style.scaleX = try number(value, default: 100) / 100
    case "fscy": comment.style.scaleY = try number(value, default: 100) / 100
    case "an": comment.style.alignment = try integer(value, default: 2, range: 1...9)
    case "bord": comment.style.outline = try number(value, default: 0)
    case "shad": comment.style.shadow = try number(value, default: 0)
    case "b", "i":
      let flag = try number(value, default: 1)
      guard [-1, 0, 1].contains(flag) else { throw CommentParseError.unsupported(tag + "ウェイト") }
      if tag == "b" { comment.style.bold = flag != 0 } else { comment.style.italic = flag != 0 }
    case "c", "1c", "3c", "4c":
      var color = try CommentColor.ass(value)
      if tag == "3c" { color.alpha = comment.style.outlineColor.alpha; comment.style.outlineColor = color }
      else if tag == "4c" { color.alpha = comment.style.shadowColor.alpha; comment.style.shadowColor = color }
      else { color.alpha = comment.style.color.alpha; comment.style.color = color }
    case "alpha", "1a", "3a", "4a":
      let hex = value.uppercased().replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "")
      guard hex.count <= 2, let byte = UInt8(hex, radix: 16) else { throw CommentParseError.invalid("透明度") }
      let alpha = 1 - Double(byte) / 255
      if tag == "alpha" || tag == "1a" { comment.style.color.alpha = alpha }
      if tag == "alpha" || tag == "3a" { comment.style.outlineColor.alpha = alpha }
      if tag == "alpha" || tag == "4a" { comment.style.shadowColor.alpha = alpha }
    case "q":
      guard value == "2" else { throw CommentParseError.unsupported("自動折り返し") }
    default: break
    }
  }

  private static func validate(_ style: CommentStyle) throws {
    guard style.size > 0, style.size <= 512, style.outline >= 0, style.outline <= 32,
      style.shadow >= 0, style.shadow <= 32, style.scaleX > 0, style.scaleX <= 10,
      style.scaleY > 0, style.scaleY <= 10, (1...9).contains(style.alignment) else { throw CommentParseError.invalid("文字スタイル") }
  }
  private static func dimension(_ value: String) throws -> Double {
    let result = try number(value, default: 0)
    guard result > 0, result <= 16384 else { throw CommentParseError.invalid("解像度") }; return result
  }
  private static func number(_ value: String?, default fallback: Double) throws -> Double {
    guard let text = value, !text.isEmpty else { return fallback }
    guard let result = Double(text.trimmingCharacters(in: .whitespaces)), result.isFinite else { throw CommentParseError.invalid("数値") }
    return result
  }
  private static func integer(_ value: String?, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
    let result = try number(value, default: Double(fallback))
    guard result >= Double(range.lowerBound), result <= Double(range.upperBound), result.rounded() == result else { throw CommentParseError.invalid("整数値") }
    return Int(result)
  }
  private static func format(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
  private static func fields(_ value: String, format: [String]) throws -> [String: String] {
    guard !format.isEmpty, Set(format).count == format.count else { throw CommentParseError.invalid("Format") }
    let values = value.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
    guard values.count == format.count else { throw CommentParseError.invalid("フィールド数") }
    return Dictionary(uniqueKeysWithValues: zip(format, values).map { ($0.0, $0.0 == "text" ? String($0.1) : String($0.1).trimmingCharacters(in: .whitespaces)) })
  }
  private static func timestamp(_ value: String) throws -> Double {
    let parts = value.split(separator: ":").map(String.init)
    guard parts.count == 3 else { throw CommentParseError.invalid("時刻") }
    let hours = try number(parts[0], default: 0), minutes = try number(parts[1], default: 0), seconds = try number(parts[2], default: 0)
    guard hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { throw CommentParseError.invalid("時刻") }
    let result = hours * 3600 + minutes * 60 + seconds
    guard result.isFinite else { throw CommentParseError.invalid("時刻") }; return result
  }
}

// Bridge coarse native time samples with a bounded monotonic playback clock.
// Seeks reset explicitly; pauses/buffering freeze immediately. Correct small
// sample phase errors gradually instead of jumping backwards each update.
struct CommentPlaybackClock {
  private var sample = -1.0, sampleHost = 0.0, anchor = 0.0, host = 0.0, last = 0.0
  private var wasRunning = false
  mutating func reset() { self = CommentPlaybackClock() }
  mutating func time(media: Double, running: Bool, now: Double, rate: Double = 1) -> Double {
    guard media.isFinite, media >= 0, now.isFinite else { reset(); return 0 }
    let speed = rate.isFinite ? min(4, max(0.25, rate)) : 1
    if sample < 0 || !running || !wasRunning || media < sample - 0.5 {
      sample = media; sampleHost = now; anchor = media; host = now; last = media; wasRunning = running
      return media
    }
    var predicted = anchor + max(0, now-host)*speed
    if media != sample {
      let difference = media-predicted
      if abs(difference) > 1.5*speed { predicted = media; last = media }
      else { predicted += min(0.02, max(-0.02, difference)) }
      sample = media; sampleHost = now; anchor = predicted; host = now
    }
    // A genuinely stalled native clock cannot advance indefinitely.
    let bounded = min(predicted, anchor + max(0, sampleHost+1.5-host)*speed)
    last = max(last, bounded); wasRunning = true
    return last
  }
}

// Do not show a stationary comment at the seek destination while VLC is still
// acquiring its first advancing playback timestamp. Explicit pause can show it.
struct CommentSeekResumeGate {
  private var anchor: Double?
  mutating func reset() { anchor = nil }
  mutating func allows(media: Double, running: Bool, wantsPlayback: Bool) -> Bool {
    if !wantsPlayback { return true }
    guard media.isFinite, media >= 0 else { return false }
    guard let anchor else { self.anchor = media; return false }
    return running && abs(media-anchor) > 0.001
  }
}

// Re-query and sort only at a comment start/end boundary or a backwards seek.
struct CommentFrameCursor {
  private var previous = -Double.infinity, next = -Double.infinity
  private var current: [NativeComment] = []
  mutating func reset() { self = CommentFrameCursor() }
  mutating func visible(_ timeline: CommentTimeline, at time: Double) -> [NativeComment] {
    if time >= previous && time < next { previous = time; return current }
    current = timeline.visible(at: time).sorted { $0.layer == $1.layer ? $0.id < $1.id : $0.layer < $1.layer }
    var low = 0, high = timeline.comments.count
    while low < high { let mid = (low+high)/2; if timeline.comments[mid].start <= time { low = mid+1 } else { high = mid } }
    next = min(low < timeline.comments.count ? timeline.comments[low].start : .infinity,
               current.map(\.end).min() ?? .infinity)
    previous = time; return current
  }
}
