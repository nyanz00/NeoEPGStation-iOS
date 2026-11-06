import UIKit
import CoreText

// UIKit/CoreText counterpart of Web Canvas2D. Background geometry is generated
// by NeoCaptionLayout, never libass's opaque-box glyph images.
@objc(NeoCanvasCaptionRenderer)
final class NeoCanvasCaptionRenderer: NSObject {
  private typealias Layout = NeoCaptionLayout
  private struct Key: Hashable { let text: String; let size: Double; let bold: Bool; let italic: Bool }
  private struct Measured { let line: CTLine; let metrics: Layout.Metrics }
  private let lock = NSRecursiveLock()
  private var document: Layout.Document?, image: UIImage?, key = "", aspect = 0.0
  private var measurements: [Key:Measured] = [:], lineCache: [Int:[Layout.Line]] = [:]
  private let family = (UIFont(name:"HiraginoMaruGothicProN-W4",size:20) ?? UIFont(name:"HiraginoSans-W3",size:20) ?? UIFont.systemFont(ofSize:20)).familyName
  @objc func clear() { lock.withLock { document = nil; image = nil; key = ""; measurements.removeAll(); lineCache.removeAll(); aspect = 0 } }
  @objc func loadText(_ text: String) -> Bool {
    lock.withLock { clear(); document = Layout.parse(NeoSubtitleScript.ass(text)); return document?.events.isEmpty == false }
  }
  private func measured(_ text: String, _ style: Layout.Style) -> Measured {
    let key = Key(text:text,size:style.fontSize*style.factor,bold:style.bold,italic:style.italic)
    if let cached = measurements[key] { return cached }
    let descriptor = UIFontDescriptor(fontAttributes:[.family:family])
    var traits = UIFontDescriptor.SymbolicTraits()
    if style.bold { traits.insert(.traitBold) }; if style.italic { traits.insert(.traitItalic) }
    let font = UIFont(descriptor:descriptor.withSymbolicTraits(traits) ?? descriptor,size:CGFloat(key.size))
    let attrs: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attrs)), ink = CTLineGetImageBounds(line,nil)
    let value = Measured(line:line,metrics:Layout.Metrics(width:CTLineGetTypographicBounds(line,nil,nil,nil),ascent:Double(max(0,ink.maxY)),descent:Double(max(0,-ink.minY))))
    measurements[key] = value; return value
  }
  private func color(_ text: String) -> CGColor {
    let hex = String(text.dropFirst()), value = UInt64(hex,radix:16) ?? 0, rgba = hex.count > 6 ? value : (value<<8)|255
    return UIColor(red:CGFloat((rgba>>24)&255)/255,green:CGFloat((rgba>>16)&255)/255,blue:CGFloat((rgba>>8)&255)/255,alpha:CGFloat(rgba&255)/255).cgColor
  }
  @objc(imageAtMilliseconds:size:)
  func image(atMilliseconds milliseconds: Int64, size: CGSize) -> UIImage? {
    lock.withLock {
      guard let doc = document, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
      let ratio = Double(size.width/size.height), time = Double(milliseconds)/1000, events = doc.active(time)
      let animated = events.contains { $0.move != nil || $0.fade != nil }
      let nextKey = events.map { String($0.order) }.joined(separator:",")+(animated ? ":\(milliseconds)" : "")
      if abs(ratio-aspect) < 0.001 && key == nextKey { return image }
      if abs(ratio-aspect) >= 0.001 { lineCache.removeAll() }
      key = nextKey; aspect = ratio; image = nil
      guard !events.isEmpty else { return nil }
      if measurements.count > 4096 { measurements.removeAll() }
      let width = doc.positioned ? doc.width : doc.height*ratio
      let frame = Layout.frame(events,width:width,height:doc.height,time:time) { event,maxWidth in
        if let lines = self.lineCache[event.order] { return lines }
        let rows = Layout.lines(event,maxWidth:maxWidth) { self.measured($0,$1).metrics }
        self.lineCache[event.order] = rows; return rows
      }
      let active = Set(events.map(\.order)); lineCache = lineCache.filter { active.contains($0.key) }
      let output = CGSize(width:round(min(1920,1080*ratio)),height:round(min(1080,1920/ratio)))
      let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false; format.preferredRange = .standard
      image = UIGraphicsImageRenderer(size:output,format:format).image { target in
        let ctx = target.cgContext; ctx.scaleBy(x:output.width/CGFloat(width),y:output.height/CGFloat(doc.height)); ctx.setLineJoin(.round)
        for layer in Array(Set(events.map(\.layer))).sorted() {
          var groups: [String:[Layout.Band]] = [:], order: [String] = []
          for box in frame.bands where box.event.layer == layer {
            let id = "\(box.opacity):\(box.color)"; if groups[id] == nil { order.append(id) }; groups[id,default:[]].append(box)
          }
          for id in order {
            guard let boxes = groups[id], let first = boxes.first else { continue }
            ctx.setAlpha(CGFloat(first.opacity)); ctx.setFillColor(self.color(first.color)); ctx.beginPath()
            for b in boxes { ctx.addRect(CGRect(x:b.left,y:b.top,width:b.right-b.left,height:b.bottom-b.top)) }; ctx.fillPath()
          }
          for row in frame.lines where row.layer == layer {
            var cursor = row.x
            for glyph in row.line.glyphs {
              let s = glyph.style, line = self.measured(glyph.text,s).line
              ctx.saveGState(); ctx.setAlpha(CGFloat(row.opacity)); ctx.translateBy(x:CGFloat(cursor),y:CGFloat(row.baseline)); ctx.scaleBy(x:CGFloat(s.scaleX),y:-CGFloat(s.scaleY))
              ctx.textMatrix = .identity; ctx.textPosition = .zero; ctx.setLineWidth(CGFloat(s.outline*2)); ctx.setStrokeColor(self.color(s.outlineColor)); ctx.setFillColor(self.color(s.color))
              if s.outline > 0 { ctx.setTextDrawingMode(.stroke); CTLineDraw(line,ctx) }
              ctx.textPosition = .zero; ctx.setTextDrawingMode(.fill); CTLineDraw(line,ctx)
              let em = s.fontSize*s.factor, thickness = max(1,em/18)
              if s.underline { ctx.fill(CGRect(x:0,y:-em*0.12-thickness,width:glyph.advance/s.scaleX,height:thickness)) }
              if s.strikeout { ctx.fill(CGRect(x:0,y:em*0.3-thickness,width:glyph.advance/s.scaleX,height:thickness)) }
              ctx.restoreGState(); cursor += glyph.advance
            }
          }
        }
      }
      return image
    }
  }
}
