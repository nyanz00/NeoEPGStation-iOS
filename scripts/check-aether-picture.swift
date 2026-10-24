import AppKit
import Foundation

// Inspect actual output pixels with the macOS SDK; no optional Python packages.
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let image = NSBitmapImageRep(data: data) else { fatalError("Invalid output image") }
var samples = [Double]()
for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 32)) {
  for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 32)) {
    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
      samples += [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }
  }
}
guard !samples.isEmpty else { fatalError("No output pixels") }
let mean = samples.reduce(0, +) / Double(samples.count)
let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
let result: [String: Any] = ["mean": mean, "stddev": sqrt(variance), "nonBlack": mean > 0.04 && variance > 0.002]
var report = result
if CommandLine.arguments.count == 5 {
  let directory = URL(fileURLWithPath: CommandLine.arguments[2])
  let fixture = CommandLine.arguments[3], expected = Int(CommandLine.arguments[4])!
  // The source clips contain a burned-in counter. Consecutive requested
  // targets have different tens digits, so a retained old picture cannot pass.
  let roi: [Double] = fixture.hasPrefix("av1") ? [0.145, 0, 0.185, 0.09] : [0.74, 0.33, 0.79, 0.67]
  func mask(_ bitmap: NSBitmapImageRep) -> [Bool] {
    var pixels = [Bool]()
    for y in 0..<64 {
      for x in 0..<48 {
        let nx = roi[0] + (Double(x)+0.5)/48*(roi[2]-roi[0])
        let ny = roi[1] + (Double(y)+0.5)/64*(roi[3]-roi[1])
        let color = bitmap.colorAt(x: min(bitmap.pixelsWide-1, Int(nx*Double(bitmap.pixelsWide))),
                                  y: min(bitmap.pixelsHigh-1, Int(ny*Double(bitmap.pixelsHigh))))?.usingColorSpace(.deviceRGB)
        // The AV1 counter is yellow on a black panel. Its green component
        // shifts during P010-to-BGRA/sRGB conversion; red preserves the glyph.
        let red = (color?.redComponent ?? 0) > 150.0/255
        pixels.append(fixture.hasPrefix("av1") ? red : red && (color?.greenComponent ?? 0) > 150.0/255)
      }
    }
    return pixels
  }
  let actual = mask(image)
  var scores = [Int: Double]()
  for target in [20, 30, 40] {
    let data = try Data(contentsOf: directory.appendingPathComponent("\(fixture)-\(target).png"))
    guard let reference = NSBitmapImageRep(data: data) else { fatalError("Invalid reference") }
    let mismatch = zip(actual, mask(reference)).filter { $0.0 != $0.1 }.count
    scores[target] = Double(mismatch)/Double(actual.count)
  }
  let wanted = scores[expected]!, other = scores.filter { $0.key != expected }.map { $0.value }.min()!
  report["targetMatches"] = wanted < 0.06 && wanted+0.008 < other
  report["scores"] = Dictionary(uniqueKeysWithValues: scores.map { (String($0.key), $0.value) })
}
print(String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
