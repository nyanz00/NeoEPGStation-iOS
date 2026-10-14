import Foundation
import CoreGraphics
import ImageIO

// Inspect the rendered seek dot, not UISlider's optional currentThumbImage.
// The synthetic player image has a blue movie, white icons, and only the
// timeline/dot in NeoStyle.accent (32,168,154). The track is three points tall.
guard CommandLine.arguments.count == 3,
  let logicalWidth = Double(CommandLine.arguments[2]), logicalWidth > 0,
  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
  let space = CGColorSpace(name: CGColorSpace.sRGB) else { fatalError("Cannot read player screenshot") }
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width*height*4)
pixels.withUnsafeMutableBytes { raw in
  guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot render screenshot") }
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}
let band = height/6
var diameters: [Int] = []
// Bitmap row orientation is immaterial: inspect both edge bands.
for rows in [0..<band, (height-band)..<height] {
  var first = height, last = -1
  for y in rows {
    for x in 0..<width {
      let i = (y*width+x)*4
      if abs(Int(pixels[i])-32) <= 12 && abs(Int(pixels[i+1])-168) <= 12 &&
        abs(Int(pixels[i+2])-154) <= 12 && pixels[i+3] >= 240 {
        first = min(first,y); last = max(last,y)
      }
    }
  }
  if last >= first { diameters.append(last-first+1) }
}
let scale = Double(width)/logicalWidth
let diameter = Double(diameters.max() ?? 0)/scale
let result: [String: Any] = ["success": diameter >= 10 && diameter <= 16.5,
  "diameterPoints": diameter, "diameterPixels": diameters.max() ?? 0, "scale": scale]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
