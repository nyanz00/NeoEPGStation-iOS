import CoreText
import MetalKit
import UIKit

private struct CommentTextureKey: Hashable { var text: String; var style: CommentStyle; var pixelScale: Double = 1 }
private struct CommentTexture {
  var texture: MTLTexture?, image: CGImage?, size: CGSize, cost: Int
  var used: UInt64
}
private struct CommentVertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }

// Output is an ordinary Metal render pass, independent of UIView. A future video
// compositor can call encode() against its own render target with the same timeline.
final class NeoDanmakuRenderer {
  let device: MTLDevice
  let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let textQueue = DispatchQueue(label: "neo.comments.text", qos: .userInitiated)
  private let lock = NSLock()
  private var cache: [CommentTextureKey: CommentTexture] = [:]
  private var pending: Set<CommentTextureKey> = []
  private var wanted: Set<CommentTextureKey> = []
  private var generation = 0, cost = 0, tick: UInt64 = 0
  private var failure: String?
  private let budget = 48 * 1024 * 1024
  private let cpuOnly: Bool

  init(device: MTLDevice, cpuOnly: Bool = false) throws {
    self.device = device
    self.cpuOnly = cpuOnly
    guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
      let vertex = library.makeFunction(name: "commentVertex"), let fragment = library.makeFunction(name: "commentFragment") else {
      throw CommentParseError.invalid("Metalシェーダー")
    }
    self.queue = queue
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
    let color = descriptor.colorAttachments[0]!
    color.pixelFormat = .bgra8Unorm
    color.isBlendingEnabled = true
    color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
    color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
  }

  func reset() {
    lock.lock(); defer { lock.unlock() }
    generation += 1; cache.removeAll(); pending.removeAll(); wanted.removeAll(); cost = 0; failure = nil
  }

  var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
  var cachedBytes: Int { lock.lock(); defer { lock.unlock() }; return cost }
  var hasPendingImages: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }

  // Only newly visible or imminent comments are rasterized, away from the main
  // thread. Textures stay immutable once published to the render thread.
  private func key(_ comment: NativeComment, pixelScale: Double) -> CommentTextureKey {
    CommentTextureKey(text: comment.text, style: comment.style, pixelScale: min(2, max(0.25, ceil(pixelScale * 4) / 4)))
  }

  func prepare(_ comments: [NativeComment], pixelScale: Double = 1) {
    lock.lock(); wanted = Set(comments.map { key($0, pixelScale: pixelScale) }); lock.unlock()
    for comment in comments {
      let key = self.key(comment, pixelScale: pixelScale)
      lock.lock()
      guard cache[key] == nil, !pending.contains(key), failure == nil else { lock.unlock(); continue }
      pending.insert(key)
      let version = generation
      lock.unlock()
      textQueue.async { [weak self] in
        guard let self = self else { return }
        self.lock.lock(); let current = self.generation == version && self.wanted.contains(key)
        if !current && self.generation == version { self.pending.remove(key) }
        self.lock.unlock()
        guard current else { return }
        autoreleasepool {
          do {
            let entry = try self.rasterize(key)
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.generation == version else { return }
            self.pending.remove(key)
            guard self.wanted.contains(key) else { return }
            self.tick += 1
            var saved = entry; saved.used = self.tick
            while self.cost + saved.cost > self.budget,
              let oldest = self.cache.filter({ !self.wanted.contains($0.key) }).min(by: { $0.value.used < $1.value.used }) {
              self.cost -= oldest.value.cost; self.cache.removeValue(forKey: oldest.key)
            }
            guard self.cost + saved.cost <= self.budget else {
              self.failure = "同時表示するコメントの画像がキャッシュ容量を超えました。VLCの字幕表示を利用してください。"; return
            }
            self.cache[key] = saved; self.cost += saved.cost
          } catch {
            self.lock.lock(); defer { self.lock.unlock() }
            if self.generation == version { self.pending.remove(key); self.failure = "文字画像を生成できません。VLCの字幕表示を利用してください。" }
          }
        }
      }
    }
  }

  // All comments are retained. Cache misses are requested, never converted into
  // a permanent density limit. The initial 1-second lookahead hides normal misses.
  func encode(timeline: CommentTimeline, time: Double, viewport: CGSize, videoRect: CGRect,
              sizeMultiplier: Double, opacity: Float, pixelScale: Double = 1, encoder: MTLRenderCommandEncoder) -> Int {
    let visible = timeline.visible(at: time).sorted { $0.layer == $1.layer ? $0.id < $1.id : $0.layer < $1.layer }
    guard viewport.width > 0, viewport.height > 0, videoRect.width > 0, videoRect.height > 0 else { return 0 }
    encoder.setRenderPipelineState(pipeline)
    var alpha = opacity
    encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
    // Clip to the fitted video, not to the entire window's letterbox bars.
    let clip = videoRect.intersection(CGRect(origin: .zero, size: viewport))
    guard !clip.isEmpty else { return 0 }
    encoder.setScissorRect(MTLScissorRect(x: Int(clip.minX), y: Int(clip.minY),
      width: max(1, Int(clip.maxX) - Int(clip.minX)), height: max(1, Int(clip.maxY) - Int(clip.minY))))
    var drawn = 0
    for comment in visible {
      let key = self.key(comment, pixelScale: pixelScale)
      lock.lock()
      var entry = cache[key]
      if entry != nil { tick += 1; entry!.used = tick; cache[key] = entry! }
      lock.unlock()
      guard let image = entry, let texture = image.texture else { continue }
      let rect = placement(comment, imageSize: image.size, timeline: timeline, time: time,
        videoRect: videoRect, sizeMultiplier: sizeMultiplier)
      if !rect.intersects(clip) { continue }
      let x = Double(rect.minX), y = Double(rect.minY), width = Double(rect.width), height = Double(rect.height)
      func point(_ x: Double, _ y: Double) -> SIMD2<Float> {
        SIMD2(Float(x / Double(viewport.width) * 2 - 1), Float(1 - y / Double(viewport.height) * 2))
      }
      var vertices = [
        CommentVertex(position: point(x, y), uv: SIMD2(0, 0)),
        CommentVertex(position: point(x, y + height), uv: SIMD2(0, 1)),
        CommentVertex(position: point(x + width, y), uv: SIMD2(1, 0)),
        CommentVertex(position: point(x + width, y), uv: SIMD2(1, 0)),
        CommentVertex(position: point(x, y + height), uv: SIMD2(0, 1)),
        CommentVertex(position: point(x + width, y + height), uv: SIMD2(1, 1)),
      ]
      vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      drawn += 1
    }
    return drawn
  }

  private func placement(_ comment: NativeComment, imageSize: CGSize, timeline: CommentTimeline,
                         time: Double, videoRect: CGRect, sizeMultiplier: Double) -> CGRect {
    let scaleX = Double(videoRect.width) / timeline.width, scaleY = Double(videoRect.height) / timeline.height
    let width = Double(imageSize.width) * comment.style.scaleX * sizeMultiplier * scaleX
    let height = Double(imageSize.height) * comment.style.scaleY * sizeMultiplier * scaleY
    let column = (comment.style.alignment - 1) % 3, row = (comment.style.alignment - 1) / 3
    let fallback = CommentPoint(x: column == 0 ? comment.style.marginL : column == 1 ? timeline.width / 2 : timeline.width - comment.style.marginR,
      y: row == 0 ? timeline.height - comment.style.marginV : row == 1 ? timeline.height / 2 : comment.style.marginV)
    let anchor = comment.motion?.point(elapsed: time - comment.start) ?? comment.position ?? fallback
    let x = Double(videoRect.minX) + (comment.scrollingX(viewportWidth: Double(videoRect.width),
      textWidth: width, elapsed: time - comment.start) ?? (anchor.x * scaleX - width * Double(column) / 2))
    let y = Double(videoRect.minY) + anchor.y * scaleY - height * Double(2 - row) / 2
    return CGRect(x: x, y: y, width: width, height: height)
  }

  // PiP may continue after the app loses foreground GPU access. Reuse the same
  // cached CoreText images and placement, without submitting Metal commands.
  func drawCPU(timeline: CommentTimeline, time: Double, viewport: CGSize, sizeMultiplier: Double,
               opacity: Float, pixelScale: Double, context: CGContext) -> Int {
    context.saveGState(); defer { context.restoreGState() }
    context.setAlpha(CGFloat(opacity)); context.interpolationQuality = .medium
    let videoRect = CGRect(origin: .zero, size: viewport)
    context.clip(to: videoRect)
    var drawn = 0
    for comment in timeline.visible(at: time).sorted(by: { $0.layer == $1.layer ? $0.id < $1.id : $0.layer < $1.layer }) {
      let key = key(comment, pixelScale: pixelScale)
      lock.lock()
      var image = cache[key]
      if image != nil { tick += 1; image!.used = tick; cache[key] = image! }
      lock.unlock()
      guard let image = image, let bitmap = image.image else { continue }
      var rect = placement(comment, imageSize: image.size, timeline: timeline, time: time,
        videoRect: videoRect, sizeMultiplier: sizeMultiplier)
      if !rect.intersects(videoRect) { continue }
      rect.origin.y = viewport.height - rect.maxY
      context.draw(bitmap, in: rect); drawn += 1
    }
    return drawn
  }

  func waitForPreparedImages() { textQueue.sync {} }

  private func rasterize(_ key: CommentTextureKey) throws -> CommentTexture {
    let style = key.style
    // Large ASS fonts are still positioned in script pixels; bound the raster's
    // resolution, not its displayed size. Size/opacity sliders reuse the textures.
    let rasterScale = min(key.pixelScale, 128 / style.size)
    let base = CTFontCreateWithName(style.font as CFString, CGFloat(style.size * rasterScale), nil)
    var traits: CTFontSymbolicTraits = []
    if style.bold { traits.insert(.traitBold) }; if style.italic { traits.insert(.traitItalic) }
    let font = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    let lines = key.text.components(separatedBy: "\n").map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes) as CFAttributedString) }
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    let lineHeight = ceil(ascent + descent + CTFontGetLeading(font))
    let padding = ceil((style.outline + style.shadow) * rasterScale) + 3
    let width = Int(ceil(lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0) + padding * 2)
    let height = Int(ceil(lineHeight * CGFloat(lines.count) + padding * 2))
    guard width > 0, height > 0, width <= 8192, height <= 8192, width * height * 4 <= budget else { throw CommentParseError.invalid("文字画像の大きさ") }
    let rowBytes = width * 4
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    try pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw CommentParseError.invalid("文字画像") }
      func color(_ value: CommentColor) -> CGColor { CGColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha) }
      context.setLineJoin(.round)
      for (index, line) in lines.enumerated() {
        let position = CGPoint(x: padding, y: CGFloat(height) - padding - ascent - CGFloat(index) * lineHeight)
        if style.shadow > 0 {
          context.textPosition = CGPoint(x: position.x + style.shadow * rasterScale, y: position.y - style.shadow * rasterScale)
          context.setTextDrawingMode(.fill); context.setFillColor(color(style.shadowColor)); CTLineDraw(line, context)
        }
        context.textPosition = position
        if style.outline > 0 {
          context.setTextDrawingMode(.stroke); context.setLineWidth(CGFloat(style.outline * rasterScale * 2))
          context.setStrokeColor(color(style.outlineColor)); CTLineDraw(line, context)
        }
        context.textPosition = position
        context.setTextDrawingMode(.fill); context.setFillColor(color(style.color)); CTLineDraw(line, context)
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw CommentParseError.invalid("文字画像") }
    var texture: MTLTexture?
    if !cpuOnly {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = .shaderRead; descriptor.storageMode = .shared
      guard let created = device.makeTexture(descriptor: descriptor) else { throw CommentParseError.invalid("文字テクスチャ") }
      pixels.withUnsafeBytes { created.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rowBytes) }
      texture = created
    }
    return CommentTexture(texture: texture, image: cpuOnly ? image : nil,
      size: CGSize(width: Double(width) / rasterScale, height: Double(height) / rasterScale), cost: rowBytes * height, used: 0)
  }

#if targetEnvironment(simulator)
  // GPU readback tests exercise the same shader/encoder as playback. They are
  // correctness tests, not a throughput claim for physical iPhones/iPads.
  static func smokeTest() -> [String: Any] {
    do {
      guard let device = MTLCreateSystemDefaultDevice() else { throw CommentParseError.invalid("Metalデバイス") }
      let renderer = try NeoDanmakuRenderer(device: device)
      let style = CommentStyle(size: 24, outline: 1)
      let comments = (0..<80).map { index in NativeComment(id: index, layer: 0, start: 0, end: 5.5,
        text: "コメント \(index)", style: style,
        position: nil, motion: CommentMotion(from: CommentPoint(x: 640, y: Double(index % 10) * 32 + 32),
          to: CommentPoint(x: -160, y: Double(index % 10) * 32 + 32), start: 0, end: 5.5), usesDanmakuTiming: true) }
      let timeline = CommentTimeline(width: 640, height: 360, comments: comments)
      renderer.prepare(comments); renderer.textQueue.sync {}
      if let failure = renderer.error { throw CommentParseError.invalid(failure) }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
      guard let target = device.makeTexture(descriptor: descriptor) else { throw CommentParseError.invalid("テスト出力") }
      func frame(time: Double, opacity: Float, size: Double = 1) throws -> ([UInt8], Int) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw CommentParseError.invalid("テスト描画") }
        let count = renderer.encode(timeline: timeline, time: time, viewport: CGSize(width: 640, height: 360),
          videoRect: CGRect(x: 0, y: 0, width: 640, height: 360), sizeMultiplier: size, opacity: opacity, encoder: encoder)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw CommentParseError.invalid("GPU実行") }
        var pixels = [UInt8](repeating: 0, count: 640 * 360 * 4)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0) }
        return (pixels, count)
      }
      let first = try frame(time: 3, opacity: 1), paused = try frame(time: 3, opacity: 1)
      let moved = try frame(time: 4, opacity: 1), hidden = try frame(time: 3, opacity: 0), ended = try frame(time: 9, opacity: 1)
      let larger = try frame(time: 3, opacity: 1, size: 1.5)
      guard first.1 == 80, first.0.contains(where: { $0 > 0 }), first.0 == paused.0,
        first.0 != moved.0, first.0 != larger.0, !hidden.0.contains(where: { $0 > 0 }), !ended.0.contains(where: { $0 > 0 }) else { throw CommentParseError.invalid("描画検証") }
      if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        let provider = CGDataProvider(data: Data(first.0) as CFData),
        let image = CGImage(width: 640, height: 360, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 640 * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
        try? UIImage(cgImage: image).pngData()?.write(to: directory.appendingPathComponent("danmaku-smoke.png"))
      }
      return ["success": true, "comments": first.1, "cacheBytes": renderer.cachedBytes,
        "checks": ["textRaster", "danmakuMovement", "pause", "size", "opacity", "endTime"]]
    } catch { return ["success": false, "error": error.localizedDescription] }
  }
#endif
}
