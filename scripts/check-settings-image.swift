import AppKit

// Detect the reported visual regression, not the private/hidden subviews of
// UIKit controls. The white switch/thumb or accent must not reach the edge.
func edgeForeground(_ image: NSBitmapImageRep, logicalWidth: Double) -> Int {
  let width = image.pixelsWide, height = image.pixelsHigh
  let margin = max(1,Int((Double(width)/logicalWidth*8).rounded()))
  var count = 0
  for y in Int(Double(height)*0.2)..<Int(Double(height)*0.88) {
    for x in width-margin..<width {
      guard let color = image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
      let r = color.redComponent*255, g = color.greenComponent*255, b = color.blueComponent*255
      if min(r,g,b) >= 220 || (g > 100 && b > 80 && r < g*0.8 && b < g*1.2) { count += 1 }
    }
  }
  return count
}
if CommandLine.arguments[1] == "--self-test" {
  let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:402,pixelsHigh:600,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  image.bitmapData!.initialize(repeating:0,count:image.bytesPerRow*image.pixelsHigh)
  precondition(edgeForeground(image,logicalWidth:402) == 0)
  image.setColor(.white,atX:401,y:300)
  precondition(edgeForeground(image,logicalWidth:402) == 1)
  print("Rendered settings edge detector: positive and negative controls passed")
} else {
  let image = NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))!
  let width = CommandLine.arguments[2] == "pad" ? 1032.0 : 402.0
  let count = edgeForeground(image,logicalWidth:width)
  let result: [String:Any] = ["success":count == 0,"rightEdgeForeground":count,"width":image.pixelsWide,"height":image.pixelsHigh,"marginPoints":8]
  print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
}
