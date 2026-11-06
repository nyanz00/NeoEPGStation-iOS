import Foundation

// Native port of client/src/core/player/CanvasSubtitleLayout.ts. Ordinary
// captions only: the comment worker and TS/live ARIB never enter this layout.
enum NeoCaptionLayout {
  struct Style: Hashable {
    var fontSize = 20.0, scaleX = 1.0, scaleY = 1.0, spacing = 0.0
    var bold = false, italic = false, underline = false, strikeout = false
    var color = "#ffffff", outlineColor = "#000000", background = "#00000080"
    var outline = 1.0, factor = 1.0
    var alignment = 2, marginL = 10.0, marginR = 10.0, marginV = 10.0
  }
  struct Run { var text: String; var style: Style }
  struct Event {
    var start: Double, end: Double, layer: Double, order: Int, runs: [Run] = []
    var position: [Double]?, move: [Double]?, fade: [Double]?
    var alignment: Int, wrap: Double, marginL: Double, marginR: Double, marginV: Double
  }
  struct Document {
    var width: Double, height: Double, events: [Event], ends: [Double]
    var positioned: Bool { events.contains { $0.position != nil || $0.move != nil } }
    func active(_ time: Double) -> [Event] {
      var low = 0, high = ends.count
      while low < high { let mid = (low+high)/2; if ends[mid] <= time { low = mid+1 } else { high = mid } }
      var result: [Event] = []
      while low < events.count && events[low].start <= time {
        if events[low].end > time { result.append(events[low]) }; low += 1
      }
      return result.sorted { $0.layer == $1.layer ? $0.order < $1.order : $0.layer < $1.layer }
    }
  }
  struct Metrics { var width: Double, ascent: Double, descent: Double }
  struct Glyph { var text: String, style: Style, width: Double, advance: Double, ascent: Double, descent: Double }
  struct Line { var glyphs: [Glyph] = []; var width = 0.0, ascent = 0.0, descent = 0.0 }
  struct Band {
    var left: Double, top: Double, right: Double, bottom: Double, cell: Double
    var color: String, opacity: Double, event: Event
  }
  struct PaintedLine { var line: Line, baseline: Double, x: Double, opacity: Double, layer: Double }
  struct Frame { var bands: [Band], lines: [PaintedLine] }
  static func matches(_ pattern: String, _ text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern:pattern) else { return [] }
    return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).map { match in
      (0..<match.numberOfRanges).map { Range(match.range(at:$0),in:text).map { String(text[$0]) } ?? "" }
    }
  }
  static func number(_ text: String?, _ fallback: Double) -> Double {
    guard let value = text.flatMap({ Double($0.trimmingCharacters(in:.whitespaces)) }), value.isFinite else { return fallback }; return value
  }
  static func fields(_ body: String, _ format: [String]) -> [String:String] {
    let values = body.split(separator:",",maxSplits:max(0,format.count-1),omittingEmptySubsequences:false).map(String.init)
    return Dictionary(uniqueKeysWithValues:format.enumerated().map { ($0.element,values.indices.contains($0.offset) ? values[$0.offset] : "") })
  }
  static func alpha(_ color: String, _ opacity: Double) -> String {
    String(color.prefix(7))+String(format:"%02x",Int((max(0,min(1,opacity))*255).rounded()))
  }
  static func color(_ text: String?, _ fallback: String) -> String {
    guard let text, let hex = matches(#"(?i)^&H([\da-f]{1,8})&?$"#,text.trimmingCharacters(in:.whitespaces)).first?[1] else { return fallback }
    let padded = String(repeating:"0",count:max(0,6-hex.count))+hex, rgb = String(padded.suffix(6))
    let channels = stride(from:0,to:6,by:2).map { i -> String in let start = rgb.index(rgb.startIndex,offsetBy:i); return String(rgb[start..<rgb.index(start,offsetBy:2)]) }
    let result = "#"+channels.reversed().joined().lowercased()
    return padded.count > 6 ? alpha(result,1-Double(UInt64(padded.dropLast(6),radix:16) ?? 0)/255) : result+String(fallback.dropFirst(7))
  }
  static func parseStyle(_ f: [String:String]) -> Style {
    var s = Style()
    s.fontSize = max(1,number(f["fontsize"],20)); s.scaleX = max(0,number(f["scalex"],100))/100; s.scaleY = max(0,number(f["scaley"],100))/100
    s.spacing = number(f["spacing"],0); s.bold = number(f["bold"],0) != 0; s.italic = number(f["italic"],0) != 0
    s.underline = number(f["underline"],0) != 0; s.strikeout = number(f["strikeout"],0) != 0
    s.color = color(f["primarycolour"],s.color); s.outlineColor = color(f["outlinecolour"],s.outlineColor); s.background = color(f["backcolour"],s.background)
    s.outline = max(0,number(f["outline"],1)); s.alignment = Int(max(1,min(9,number(f["alignment"],2))))
    s.marginL = max(0,number(f["marginl"],10)); s.marginR = max(0,number(f["marginr"],10)); s.marginV = max(0,number(f["marginv"],10))
    if f["fontname"]?.trimmingCharacters(in:.whitespaces).lowercased() == "yu gothic" && s.fontSize == 46 && s.spacing == 4 && s.marginL == 0 && s.marginV == 0 {
      s.factor = 36/46; s.bold = false; s.outline = 2
    }
    return s
  }
  static func parse(_ text: String) -> Document {
    var section = "", width = 0.0, height = 0.0, wrap = 0.0
    var styleFormat = "name,fontname,fontsize,primarycolour,secondarycolour,outlinecolour,backcolour,bold,italic,underline,strikeout,scalex,scaley,spacing,angle,borderstyle,outline,shadow,alignment,marginl,marginr,marginv,encoding".components(separatedBy:",")
    var eventFormat = "layer,start,end,style,name,marginl,marginr,marginv,effect,text".components(separatedBy:",")
    var styles = ["default":Style()], rawEvents: [[String:String]] = []
    for raw in text.replacingOccurrences(of:"\u{FEFF}",with:"").components(separatedBy:.newlines) {
      let line = raw.trimmingCharacters(in:.whitespaces)
      if let header = matches(#"^\[([^\]]+)\]$"#,line).first { section = header[1].lowercased(); continue }
      guard let colon = line.firstIndex(of:":") else { continue }
      let key = line[..<colon].lowercased(), body = String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
      func format() -> [String] { body.lowercased().components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespaces) } }
      if section == "script info" {
        if key == "playresx" { width = max(0,number(body,0)) }; if key == "playresy" { height = max(0,number(body,0)) }; if key == "wrapstyle" { wrap = number(body,0) }
      } else if section == "v4+ styles" {
        if key == "format" { styleFormat = format() }
        if key == "style" { let f = fields(body,styleFormat), name = f["name"]?.trimmingCharacters(in:.whitespaces).lowercased() ?? ""; if !name.isEmpty { styles[name] = parseStyle(f) } }
      } else if section == "events" {
        if key == "format" { eventFormat = format() }; if key == "dialogue" { rawEvents.append(fields(body,eventFormat)) }
      }
    }
    if width <= 0 && height <= 0 { width = 384; height = 288 } else if width <= 0 { width = height*4/3 } else if height <= 0 { height = width*3/4 }
    func time(_ text: String?) -> Double? {
      guard let text, let m = matches(#"^(\d+):(\d{1,2}):(\d{1,2}(?:\.\d+)?)$"#,text.trimmingCharacters(in:.whitespaces)).first else { return nil }
      return number(m[1],0)*3600+number(m[2],0)*60+number(m[3],0)
    }
    var events: [Event] = []
    for f in rawEvents {
      guard let start = time(f["start"]), let end = time(f["end"]), end > start else { continue }
      let base = styles[f["style"]?.trimmingCharacters(in:.whitespaces).lowercased() ?? ""] ?? styles["default"]!
      func margin(_ key: String, _ fallback: Double) -> Double { let value = number(f[key],0); return value == 0 ? fallback : value }
      var event = Event(start:start,end:end,layer:number(f["layer"],0),order:events.count,alignment:base.alignment,wrap:wrap,marginL:margin("marginl",base.marginL),marginR:margin("marginr",base.marginR),marginV:margin("marginv",base.marginV))
      var current = base, drawing = false
      for part in matches(#"\{[^}]*\}|[^\{]+|\{"#,f["text"] ?? "").map({ $0[0] }) {
        if !part.hasPrefix("{") {
          if !drawing && !part.isEmpty { event.runs.append(Run(text:part.replacingOccurrences(of:"\\N",with:"\n").replacingOccurrences(of:"\\n",with:event.wrap == 2 ? "\n" : " ").replacingOccurrences(of:"\\h",with:"\u{00a0}"),style:current)) }; continue
        }
        for tag in matches(#"(?i)\\(fscx|fscy|fsp|bord|shad|alpha|[134]a|[134]c|pos|move|fad|an|fs|[cbiusprq])([^\\]*)"#,String(part.dropFirst().dropLast())) {
          let key = tag[1].lowercased(), arg = tag[2].trimmingCharacters(in:.whitespaces), value = number(arg,.nan)
          let args = arg.trimmingCharacters(in:CharacterSet(charactersIn:"()")).components(separatedBy:",").map { number($0,.nan) }
          if key == "r" { current = styles[arg.lowercased()] ?? base; continue }
          if key == "pos" && args.count == 2 && args.allSatisfy(\.isFinite) { event.position = args }
          if key == "move" && [4,6].contains(args.count) && args.allSatisfy(\.isFinite) { event.move = Array(args.prefix(4))+[args.count == 6 ? args[4]/1000 : 0,args.count == 6 ? args[5]/1000 : end-start] }
          if key == "fad" && args.count == 2 && args.allSatisfy(\.isFinite) { event.fade = args.map { max(0,$0)/1000 } }
          if ["c","1c"].contains(key) { current.color = arg.isEmpty ? base.color : color(arg,current.color) }
          if key == "3c" { current.outlineColor = arg.isEmpty ? base.outlineColor : color(arg,current.outlineColor) }
          if key == "4c" { current.background = arg.isEmpty ? base.background : color(arg,current.background) }
          if key == "alpha" || ["1a","3a","4a"].contains(key), let h = matches(#"(?i)^&H([\da-f]{1,2})&?$"#,arg).first?[1] {
            let opacity = 1-Double(Int(h,radix:16) ?? 0)/255
            if key == "alpha" || key == "1a" { current.color = alpha(current.color,opacity) }
            if key == "alpha" || key == "3a" { current.outlineColor = alpha(current.outlineColor,opacity) }
            if key == "alpha" || key == "4a" { current.background = alpha(current.background,opacity) }
          }
          guard value.isFinite else { continue }
          switch key {
          case "fs": current.fontSize = max(1,value)
          case "fscx": current.scaleX = max(0,value)/100
          case "fscy": current.scaleY = max(0,value)/100
          case "fsp": current.spacing = value
          case "bord": current.outline = max(0,value)
          case "b": current.bold = value != 0
          case "i": current.italic = value != 0
          case "u": current.underline = value != 0
          case "s": current.strikeout = value != 0
          case "p": drawing = value != 0
          case "an": if value >= 1 && value <= 9 { event.alignment = Int(value) }
          case "q": event.wrap = value
          default: break
          }
        }
      }
      if !event.runs.isEmpty { events.append(event) }
    }
    events.sort { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
    var maxEnd = 0.0
    return Document(width:width,height:height,events:events,ends:events.map { maxEnd = max(maxEnd,$0.end); return maxEnd })
  }
  static func lines(_ event: Event, maxWidth: Double, measure: (String,Style)->Metrics) -> [Line] {
    var result: [Line] = [], line = Line()
    func finish() { if let last = line.glyphs.last { line.width -= last.advance-last.width }; result.append(line); line = Line() }
    for run in event.runs {
      let s = run.style
      if s.scaleX <= 0 || s.scaleY <= 0 { continue }
      for character in run.text {
        let text = String(character)
        if text == "\n" { finish(); continue }
        let m = measure(text,s), em = s.fontSize*s.factor
        let glyph = Glyph(text:text,style:s,width:m.width*s.scaleX,advance:(m.width+s.spacing)*s.scaleX,ascent:max(m.ascent,em*0.8)*s.scaleY,descent:max(m.descent,em*0.2)*s.scaleY)
        if event.wrap != 2 && event.position == nil && event.move == nil && !line.glyphs.isEmpty && line.width+glyph.width > maxWidth { finish() }
        line.glyphs.append(glyph); line.width += glyph.advance; line.ascent = max(line.ascent,glyph.ascent); line.descent = max(line.descent,glyph.descent)
      }
    }
    if !line.glyphs.isEmpty { finish() }; return result
  }
  static func frame(_ events: [Event], width: Double, height: Double, time: Double, lines: (Event,Double)->[Line]) -> Frame {
    var occupied: [(Double,Double,Double,Double,Double)] = [], bands: [Band] = [], painted: [PaintedLine] = []
    for event in events {
      let rows = lines(event,max(1,width-event.marginL-event.marginR)); if rows.isEmpty { continue }
      let horizontal = Double((event.alignment-1)%3), vertical = (event.alignment-1)/3
      var x = horizontal == 0 ? event.marginL : horizontal == 1 ? width/2 : width-event.marginR
      var y = vertical == 0 ? height-event.marginV : vertical == 1 ? height/2 : event.marginV
      if let m = event.move { let p = max(0,min(1,(time-event.start-m[4])/max(0.001,m[5]-m[4]))); x = m[0]+(m[2]-m[0])*p; y = m[1]+(m[3]-m[1])*p }
      else if let p = event.position { x = p[0]; y = p[1] }
      let h = rows.reduce(0) { $0+$1.ascent+$1.descent }, w = rows.map(\.width).max() ?? 0, left = x-w*horizontal/2
      var top = y-(vertical == 0 ? h : vertical == 1 ? h/2 : 0)
      if event.position == nil && event.move == nil {
        while let collision = occupied.first(where: { $0.4 == event.layer && left < $0.2 && left+w > $0.0 && top < $0.3 && top+h > $0.1 }) { top = vertical == 2 ? collision.3+2 : collision.1-h-2 }
        occupied.append((left,top,left+w,top+h,event.layer))
      }
      var opacity = 1.0
      if let f = event.fade { opacity = max(0,min(1,f[0] > 0 ? (time-event.start)/f[0] : 1,f[1] > 0 ? (event.end-time)/f[1] : 1)) }
      for line in rows {
        let baseline = top+line.ascent
        var cursor = x-line.width*horizontal/2, lineBands: [Band] = [], paddings: [Double] = []
        for glyph in line.glyphs {
          let s = glyph.style, padding = max(1,s.fontSize*s.factor*min(s.scaleX,s.scaleY)*0.08), cell = s.fontSize*s.factor*s.scaleY
          let background = s.background == "#000000ff" ? "#00000080" : s.background
          if let last = lineBands.indices.last, lineBands[last].color == background && lineBands[last].cell == cell {
            lineBands[last].right = cursor+glyph.width; lineBands[last].top = min(lineBands[last].top,baseline-glyph.ascent); lineBands[last].bottom = max(lineBands[last].bottom,baseline+glyph.descent)
          } else {
            lineBands.append(Band(left:cursor,top:baseline-glyph.ascent,right:cursor+glyph.width,bottom:baseline+glyph.descent,cell:cell,color:background,opacity:opacity,event:event)); paddings.append(padding)
          }
          cursor += glyph.advance
        }
        for i in lineBands.indices { var box = lineBands[i]; let p = paddings[i]; box.left -= p; box.right += p; box.top -= p; box.bottom += p; bands.append(box) }
        painted.append(PaintedLine(line:line,baseline:baseline,x:x-line.width*horizontal/2,opacity:opacity,layer:event.layer)); top += line.ascent+line.descent
      }
    }
    // Match Web's pairwise interval/layer/color checks. An unrelated simultaneous
    // subtitle must not disable joining a valid body/ruby pair.
    for i in bands.indices {
      let ruby = bands[i]; guard ruby.event.position != nil && ruby.event.move == nil else { continue }
      var bodyTop = Double.infinity
      for body in bands where body.event.order != ruby.event.order && body.event.position != nil && body.event.move == nil && body.event.start == ruby.event.start && body.event.end == ruby.event.end && body.event.layer == ruby.event.layer && body.color == ruby.color && body.opacity == ruby.opacity && ruby.cell <= body.cell*0.65 && ruby.left < body.right && ruby.right > body.left && body.top >= ruby.bottom && body.top-ruby.bottom <= body.cell { bodyTop = min(bodyTop,body.top) }
      if bodyTop.isFinite { bands[i].bottom = bodyTop }
    }
    return Frame(bands:bands,lines:painted)
  }
}
