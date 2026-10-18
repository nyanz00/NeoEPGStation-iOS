import AppKit
import ImageIO

// Inspect the compositor's screen capture, not drawHierarchy's live-video
// snapshot. The synthetic test pattern must occupy the display center at 2x;
// a stale VLC layout leaves only a colored strip at the top.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width*height*4)
let count = pixels.withUnsafeMutableBytes { storage -> Int in
  let buffer = storage.bindMemory(to: UInt8.self)
  let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  var colored = 0
  for row in 0..<9 {
    for column in 0..<12 {
      let x = Int(Double(width)*(0.1+Double(column)*0.8/11))
      let y = Int(Double(height)*(0.4+Double(row)*0.2/8)), offset = (y*width+x)*4
      let rgb = [Int(buffer[offset]), Int(buffer[offset+1]), Int(buffer[offset+2])]
      if rgb.max()! > 80 && rgb.max()!-rgb.min()! > 40 { colored += 1 }
    }
  }
  return colored
}
guard count >= 8 else { fatalError("Zoomed video is missing from display center: \(count) colored sample points") }
print("Full-display video pixels verified: \(count) colored center samples")
