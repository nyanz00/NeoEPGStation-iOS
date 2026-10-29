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
    PlayResX: 1920
    PlayResY: 1080
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,54,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,30,30,35,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    \(events.joined(separator: "\n"))
    """
  }
}
