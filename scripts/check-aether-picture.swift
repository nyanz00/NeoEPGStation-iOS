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
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
