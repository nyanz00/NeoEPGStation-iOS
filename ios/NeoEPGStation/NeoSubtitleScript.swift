import Foundation

enum NeoSubtitleScript {
  // Preserve ASS styles verbatim. The server can also extract SRT/WebVTT;
  // convert those text formats into the same libass presentation pipeline.
  static func ass(_ text: String) -> String {
    if text.contains("[Events]") { return text }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    var events: [String] = []
    func seconds(_ value: String) -> Double? {
      let pieces = value.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
      guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
      let result = pieces.reduce(0) { $0*60+$1 }
      return result.isFinite && result < 100_000_000 ? result : nil
    }
    func time(_ seconds: Double) -> String {
      let cs = Int((max(0,seconds)*100).rounded())
      return String(format: "%d:%02d:%02d.%02d", cs/360000, cs/6000%60, cs/100%60, cs%100)
    }
    for block in normalized.components(separatedBy: "\n\n") {
      let lines = block.components(separatedBy: "\n")
      guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
      let parts = lines[index].components(separatedBy: "-->")
      guard parts.count == 2, let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)),
        let end = seconds(String(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")), end > start else { continue }
      var body = lines.dropFirst(index+1).joined(separator: "\\N")
      body = body.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
      for (tag, command) in [("b","b"),("i","i"),("u","u")] {
        body = body.replacingOccurrences(of: "<\(tag)>", with: "{\\\(command)1}", options: .caseInsensitive)
          .replacingOccurrences(of: "</\(tag)>", with: "{\\\(command)0}", options: .caseInsensitive)
      }
      body = body.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
      events.append("Dialogue: 0,\(time(start)),\(time(end)),Default,,0,0,0,,\(body)")
    }
    return """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 384
    PlayResY: 288
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    \(events.joined(separator: "\n"))
    """
  }

  // Web CanvasSubtitleLayout / CanvasSubtitleRenderer: ordinary captions use
  // the native ARIB font chain, independent backgrounds, no drop shadow, and
  // square-pixel reflow for unpositioned captions. Comment scripts never enter.
  static func presentation(_ source: String, font: String, aspect: Double) -> [String] {
    let text = ass(source).replacingOccurrences(of:"\r\n",with:"\n")
    let positioned = text.range(of:#"\\(?:pos|move)\s*\("#,options:.regularExpression) != nil
    let styleFormat = "name,fontname,fontsize,primarycolour,secondarycolour,outlinecolour,backcolour,bold,italic,underline,strikeout,scalex,scaley,spacing,angle,borderstyle,outline,shadow,alignment,marginl,marginr,marginv,encoding".components(separatedBy:",")
    var format = styleFormat, eventFormat = "layer,start,end,style,name,marginl,marginr,marginv,effect,text".components(separatedBy:","), section = "", height = 288.0
    var factors: [String:Double] = [:], main: [String] = [], bands: [String] = []
    for line in text.components(separatedBy:"\n") {
      if line.lowercased().hasPrefix("playresy:"), let number = Double(line.components(separatedBy:":").last!.trimmingCharacters(in:.whitespaces)), number > 0 { height = number }
    }
    for raw in text.components(separatedBy:"\n") {
      let line = raw.trimmingCharacters(in:.whitespaces), lower = line.lowercased()
      if line.hasPrefix("[") { section = lower }
      if lower.hasPrefix("playresx:"), !positioned, aspect.isFinite, aspect > 0 {
        let value = "PlayResX: \(max(1,Int((height*aspect).rounded())))"; main.append(value); bands.append(value); continue
      }
      if section == "[v4+ styles]", lower.hasPrefix("format:") { format = line.dropFirst(7).lowercased().components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespaces) } }
      if section == "[events]", lower.hasPrefix("format:") { eventFormat = line.dropFirst(7).lowercased().components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespaces) } }
      if section == "[v4+ styles]", lower.hasPrefix("style:") {
        var values = line.dropFirst(6).components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespaces) }
        if values.count < format.count { main.append(raw); bands.append(raw); continue }
        func get(_ key: String) -> String { format.firstIndex(of:key).map { values[$0] } ?? "" }
        func set(_ key: String, _ value: String) { if let index = format.firstIndex(of:key) { values[index] = value } }
        let size = Double(get("fontsize")) ?? 20
        let adjusted = get("fontname").lowercased() == "yu gothic" && size == 46 && Double(get("spacing")) == 4 && Double(get("marginl")) == 0 && Double(get("marginv")) == 0
        factors[get("name").lowercased()] = adjusted ? 36/46 : 1
        set("fontname",font); set("shadow","0"); set("borderstyle","1")
        if adjusted { set("fontsize","36"); set("bold","0"); set("outline","2") }
        main.append("Style: "+values.joined(separator:","))
        var background = get("backcolour")
        let backgroundValue = UInt64(background.uppercased().replacingOccurrences(of:"&H",with:"").replacingOccurrences(of:"&",with:""),radix:16)
        if background.isEmpty || backgroundValue == 0 { background = "&H80000000" }
        set("borderstyle","3"); set("outline",String(max(1,(adjusted ? 36 : size)*0.08)))
        set("outlinecolour",background); set("primarycolour","&HFF000000"); set("secondarycolour","&HFF000000")
        bands.append("Style: "+values.joined(separator:",")); continue
      }
      if section == "[events]", lower.hasPrefix("dialogue:") {
        // Dialogue text is the final field and may itself contain commas.
        var fields = line.dropFirst(9).split(separator:",",maxSplits:max(0,eventFormat.count-1),omittingEmptySubsequences:false).map(String.init)
        guard fields.count == eventFormat.count, eventFormat.last == "text", let styleIndex = eventFormat.firstIndex(of:"style") else { main.append(raw); bands.append(raw); continue }
        let textIndex = fields.count-1
        var body = fields[textIndex]
        body = body.replacingOccurrences(of:#"\\fn[^\\}]*"#,with:NSRegularExpression.escapedTemplate(for:"\\fn"+font),options:.regularExpression)
        body = body.replacingOccurrences(of:#"\\(?:xshad|yshad|shad)[-+\d.]+"#,with:"",options:.regularExpression)
        let factor = factors[fields[styleIndex].trimmingCharacters(in:.whitespaces).lowercased()] ?? 1
        if factor != 1, let regex = try? NSRegularExpression(pattern:#"\\fs(\d+(?:\.\d+)?)"#) {
          for match in regex.matches(in:body,range:NSRange(body.startIndex...,in:body)).reversed() {
            guard let numberRange = Range(match.range(at:1),in:body), let fullRange = Range(match.range,in:body), let size = Double(body[numberRange]) else { continue }
            body.replaceSubrange(fullRange,with:"\\fs"+String(size*factor))
          }
        }
        fields[textIndex] = body; main.append("Dialogue:"+fields.joined(separator:","))
        body = body.replacingOccurrences(of:#"\\(?:[123]c|c)&H[0-9A-Fa-f]+&?"#,with:"",options:.regularExpression)
          .replacingOccurrences(of:#"\\[12]a&H[0-9A-Fa-f]+&?"#,with:"",options:.regularExpression)
          .replacingOccurrences(of:#"\\(?:xbord|ybord|bord)[-+\d.]+"#,with:"",options:.regularExpression)
          .replacingOccurrences(of:"\\4c",with:"\\3c").replacingOccurrences(of:"\\4a",with:"\\3a")
          .replacingOccurrences(of:"\\alpha",with:"\\3a")
        fields[textIndex] = "{\\1a&HFF&}"+body; bands.append("Dialogue:"+fields.joined(separator:",")); continue
      }
      main.append(raw); bands.append(raw)
    }
    return [main.joined(separator:"\n"),bands.joined(separator:"\n")]
  }
  static func positionedIntervals(_ text: String) -> [[Double]] {
    var format = "layer,start,end,style,name,marginl,marginr,marginv,effect,text".components(separatedBy:","), events = false
    func time(_ text: String) -> Double? { let parts = text.trimmingCharacters(in:.whitespaces).split(separator:":").compactMap { Double($0) }; return parts.count == 3 ? parts[0]*3600+parts[1]*60+parts[2] : nil }
    return text.components(separatedBy:.newlines).compactMap { raw in
      let line = raw.trimmingCharacters(in:.whitespaces), lower = line.lowercased()
      if line.hasPrefix("[") { events = lower == "[events]" }
      if events && lower.hasPrefix("format:") { format = line.dropFirst(7).lowercased().components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespaces) } }
      guard events, lower.hasPrefix("dialogue:") else { return nil }
      let values = line.dropFirst(9).split(separator:",",maxSplits:max(0,format.count-1),omittingEmptySubsequences:false).map(String.init)
      func field(_ key: String) -> String { guard let index = format.firstIndex(of:key), values.indices.contains(index) else { return "" }; return values[index] }
      guard let start = time(field("start")), let end = time(field("end")), end > start else { return nil }
      return [start,end,Double(field("layer").trimmingCharacters(in:.whitespaces)) ?? 0,field("text").contains("\\pos(") && !field("text").contains("\\move(") ? 1 : 0]
    }
  }
}

#if canImport(ObjectiveC)
@objc(NeoCaptionStyle) final class NeoCaptionStyle: NSObject {
  @objc static func scripts(_ text: String, font: String, aspect: Double) -> [String] {
    NeoSubtitleScript.presentation(text,font:font,aspect:aspect)
  }
  @objc static func intervals(_ text: String) -> [[Double]] { NeoSubtitleScript.positionedIntervals(NeoSubtitleScript.ass(text)) }
}
#endif
