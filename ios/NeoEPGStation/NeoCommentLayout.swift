import Foundation
import CoreGraphics

// Display coordinates are local to each destination. Expanding the viewport
// changes travel/lane space, never the glyph scale or the shared source data.
struct CommentCanvasGeometry {
  let rect: CGRect, scale: Double, logicalSize: CGSize
  init(viewport: CGSize, reference: CGSize, video: CGSize, source: CGSize, expanded: Bool) {
    let ratio: CGFloat = video.width > 0 && video.height > 0 ? video.width/video.height : source.width/max(1, source.height)
    let basis: CGSize = expanded && reference.width > 0 && reference.height > 0 ? reference : viewport
    let width: CGFloat = min(basis.width, basis.height*ratio)
    let height: CGFloat = width/max(0.001, ratio)
    scale = max(0.001, Double(width)/max(1, Double(source.width)))
    if expanded { rect = CGRect(origin: .zero, size: viewport) }
    else {
      let x: CGFloat = (viewport.width-width)/2
      let y: CGFloat = (viewport.height-height)/2
      rect = CGRect(x: x, y: y, width: width, height: height)
    }
    logicalSize = expanded ? CGSize(width: Double(viewport.width)/scale, height: Double(viewport.height)/scale) : source
  }
}

struct CommentExtent { var width: Double; var height: Double }
enum CommentLanePlan {
  // Work happens when a track/size changes, never for every video frame.
  // Horizontal separation is checked at both ends of the shared lifetime:
  // linear trajectories cannot collide between two separated endpoints.
  static func build(_ timeline: CommentTimeline, size: Double,
                    cancelled: () -> Bool = { false }, fixedPositions: [Int: Double] = [:], measure: (NativeComment) -> CommentExtent) -> [Int: Double] {
    struct Active { let comment: NativeComment; let extent: CommentExtent; let top: Double }
    var active: [Active] = [], positions: [Int: Double] = [:]
    // Reserve moving comments before scheduling newly available full-file events.
    for c in timeline.comments where fixedPositions[c.id] != nil {
      let measured = measure(c)
      active.append(Active(comment: c, extent: CommentExtent(width: measured.width*c.style.scaleX*size,
        height: measured.height*c.style.scaleY*size), top: fixedPositions[c.id]!))
      positions[c.id] = fixedPositions[c.id]!
    }
    func left(_ c: NativeComment, _ e: CommentExtent, _ time: Double) -> Double {
      if let x = c.scrollingX(viewportWidth: timeline.width, textWidth: e.width, elapsed: time-c.start) { return x }
      let column = (c.style.alignment-1)%3
      let anchor = c.position?.x ?? (column == 0 ? c.style.marginL : column == 1 ? timeline.width/2 : timeline.width-c.style.marginR)
      return anchor - e.width * Double(column)/2
    }
    for (index, comment) in timeline.comments.enumerated() where comment.usesDanmakuTiming {
      if index % 128 == 0 && cancelled() { return [:] }
      // Existing trajectories are already reserved. Do not measure, generate
      // candidates and sort them again each time a single new comment arrives.
      if fixedPositions[comment.id] != nil { continue }
      active.removeAll { $0.comment.end <= comment.start }
      let measured = measure(comment)
      let extent = CommentExtent(width: measured.width * comment.style.scaleX * size,
                                 height: measured.height * comment.style.scaleY * size)
      guard extent.height <= timeline.height else { continue }
      let row = (comment.style.alignment-1)/3
      let anchor = comment.motion?.from.y ?? comment.position?.y ?? (row == 0 ? timeline.height-comment.style.marginV : row == 1 ? timeline.height/2 : comment.style.marginV)
      let preferred = min(timeline.height-extent.height, max(0, anchor-extent.height*Double(2-row)/2))
      var candidates = [preferred, 0, timeline.height-extent.height]
      for item in active { candidates += [item.top+item.extent.height+1, item.top-extent.height-1] }
      // Top/bottom comments pack from their screen edge rather than retaining
      // gaps baked into ASS lane coordinates. Centered comments retain anchor.
      if row == 2 { candidates.sort() }
      else if row == 0 { candidates.sort(by: >) }
      else { candidates.sort { abs($0-preferred) < abs($1-preferred) } }
      let top = fixedPositions[comment.id] ?? candidates.first { y in
        guard y >= 0, y+extent.height <= timeline.height else { return false }
        return !active.contains { item in
          guard item.comment.id != comment.id, comment.end > item.comment.start else { return false }
          guard y < item.top+item.extent.height+1, y+extent.height+1 > item.top else { return false }
          let end = min(comment.end, item.comment.end)
          let a0 = left(comment, extent, comment.start), a1 = left(comment, extent, end)
          let b0 = left(item.comment, item.extent, comment.start), b1 = left(item.comment, item.extent, end)
          let behind = a0 >= b0+item.extent.width+1 && a1 >= b1+item.extent.width+1
          let ahead = b0 >= a0+extent.width+1 && b1 >= a1+extent.width+1
          return !behind && !ahead
        }
      }
      // At densities exceeding the physical screen, suppress overflow rather
      // than paint unreadable overlapping text; later comments still get lanes.
      if let top { positions[comment.id] = top; if fixedPositions[comment.id] == nil { active.append(Active(comment: comment, extent: extent, top: top)) } }
    }
    return positions
  }
}

extension CommentStyle {
  func withAbsoluteOpacity(_ value: Float?) -> CommentStyle {
    guard let value else { return self }
    var result = self
    result.color.alpha = Double(value); result.outlineColor.alpha = Double(value); result.shadowColor.alpha = Double(value)
    return result
  }
}
