import Foundation

let file = CommandLine.arguments[1]
let root = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:Any]
let cases = root["cases"] as! [[String:Any]]
var checked = 0
for fixture in cases {
  let doc = NeoCaptionLayout.parse(fixture["text"] as! String), time = fixture["time"] as! Double
  let frame = NeoCaptionLayout.frame(doc.active(time),width:doc.width,height:doc.height,time:time) { event,width in
    NeoCaptionLayout.lines(event,maxWidth:width) { _,style in let em = style.fontSize*style.factor; return .init(width:em*0.6,ascent:em*0.75,descent:em*0.15) }
  }
  var ops: [[String:Any]] = []
  for layer in Array(Set(doc.active(time).map(\.layer))).sorted() {
    var groups: [String:[NeoCaptionLayout.Band]] = [:], order: [String] = []
    for band in frame.bands where band.event.layer == layer {
      let key = "\(band.opacity):\(band.color)"; if groups[key] == nil { order.append(key) }; groups[key,default:[]].append(band)
    }
    for key in order { let boxes = groups[key]!, first = boxes[0]; ops.append(["kind":"band","boxes":boxes.map { [$0.left,$0.top,$0.right-$0.left,$0.bottom-$0.top] },"color":first.color,"opacity":first.opacity]) }
    for row in frame.lines where row.layer == layer {
      var x = row.x
      for glyph in row.line.glyphs {
        let s = glyph.style
        ops.append(["kind":"text","text":glyph.text,"x":x,"y":row.baseline,"sx":s.scaleX,"sy":s.scaleY,"color":s.color,"outlineColor":s.outlineColor,"outline":s.outline,"opacity":row.opacity,"bold":s.bold,"italic":s.italic]); x += glyph.advance
      }
    }
  }
  func compare(_ a: Any, _ b: Any, _ path: String) {
    if let a = a as? [String:Any], let b = b as? [String:Any] { precondition(Set(a.keys) == Set(b.keys),path); for k in a.keys { compare(a[k]!,b[k]!,path+"."+k) } }
    else if let a = a as? [Any], let b = b as? [Any] { precondition(a.count == b.count,"\(path) count: \(a.count)/\(b.count)"); for i in a.indices { compare(a[i],b[i],path+"[\(i)]") } }
    else if let a = a as? NSNumber, let b = b as? NSNumber { precondition(abs(a.doubleValue-b.doubleValue)<0.0000001,"\(path): \(a)/\(b)") }
    else { precondition(String(describing:a) == String(describing:b),"\(path): \(a)/\(b)") }
  }
  compare(ops,fixture["ops"]!,fixture["name"] as! String); checked += 1
}
let srt = NeoCaptionLayout.parse(NeoSubtitleScript.ass("1\n00:00:00,000 --> 00:00:03,000\n字幕"))
precondition(!srt.positioned && srt.width == 384 && srt.height == 288 && srt.active(1).count == 1 && srt.active(3).isEmpty)
print("Caption Web layout oracle: \(checked) cases passed; SRT plane and cue boundaries passed")
