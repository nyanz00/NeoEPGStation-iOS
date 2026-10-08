import AVKit
import MetalKit
import VideoToolbox

struct CommentCompositionState {
  var timeline: CommentTimeline?
  var version: Int
  var enabled: Bool
  var size: Double
  var opacity: Float
  var usesSourceOpacity = false
}

private struct CapturedVideoFrame {
  let sample: CMSampleBuffer
  let hostTime: Double
}

// Decode surfaces may carry VLC-specific color attachments. Do not ask vImage
// to construct an ICC color space from those attachments. VideoToolbox handles
// YUV conversion; the final BGRA image has an explicit, stable channel layout.
private final class PiPPixelOwner {
  let pixel: CVPixelBuffer
  init(_ pixel: CVPixelBuffer) { self.pixel = pixel }
  deinit { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
}

private final class PiPVideoConverter {
  private var session: VTPixelTransferSession?
  private var pool: CVPixelBufferPool?
  private var size = CGSize.zero

  deinit { if let session = session { VTPixelTransferSessionInvalidate(session) } }

  func image(_ source: CVPixelBuffer, outputSize: CGSize? = nil) throws -> CGImage {
    let target = outputSize ?? CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    let width = Int(target.width), height = Int(target.height)
    var pixel = source
    if CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_32BGRA ||
        width != CVPixelBufferGetWidth(source) || height != CVPixelBufferGetHeight(source) {
      if session == nil {
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr else {
          throw CommentParseError.invalid("PiP色変換セッション")
        }
      }
      let nextSize = CGSize(width: width, height: height)
      if pool == nil || nextSize != size {
        pool = try NeoCommentPiP.makePool(size: nextSize); size = nextSize
      }
      var output: CVPixelBuffer?
      guard let session = session, let pool = pool,
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
        let output = output else { throw CommentParseError.invalid("PiP色変換バッファ") }
      let result = VTPixelTransferSessionTransferImage(session, from: source, to: output)
      guard result == noErr else { throw CommentParseError.invalid("PiP映像の色変換（\(result)）") }
      pixel = output
    }
    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
      throw CommentParseError.invalid("PiP映像バッファの読み取り")
    }
    // The provider owns the locked surface until its last CGImage is released.
    // This avoids a full-frame Data copy without reusing a live image's memory.
    let owner = PiPPixelOwner(pixel)
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw CommentParseError.invalid("PiP画素") }
    let retained = Unmanaged.passRetained(owner).toOpaque()
    guard let provider = CGDataProvider(dataInfo: retained, data: base, size: stride * height, releaseData: { info, _, _ in
      if let info { Unmanaged<PiPPixelOwner>.fromOpaque(info).release() }
    }) else {
      Unmanaged<PiPPixelOwner>.fromOpaque(retained).release()
      throw CommentParseError.invalid("PiP画像データ")
    }
    guard
      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
      throw CommentParseError.invalid("PiPのBGRA映像")
    }
    return image
  }
}

final class NeoPiPSurface: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

// One decoded video stream: VLC keeps its normal output and audio clock. Only
// PiP receives the composed stream. No screenshots, network re-encode or JS.
@objc(NeoCommentPiP)
final class NeoCommentPiP: NSObject, NeoVideoFrameSink,
  AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
  @objc let view: UIView
  private let surface: NeoPiPSurface
  private let displayLayer: AVSampleBufferDisplayLayer
  private var pip: AVPictureInPictureController?
  private var observation: NSKeyValueObservation?
  private let work = DispatchQueue(label: "neo.pip.compose", qos: .userInitiated)
  private let frameLock = NSLock()
  private var frames: [CapturedVideoFrame] = []
  private var presentationTimes: [Double] = [], lastPresentedHost = 0.0
  private var closed = false, received = 0, composed = 0, consumed = 0
  private var capturing = false
  private var timer: DispatchSourceTimer?
  private var renderer: NeoDanmakuRenderer?
  private var state = CommentCompositionState(timeline: nil, version: -1, enabled: false, size: 1, opacity: 1)
  private var current: CapturedVideoFrame?
  private var image: CGImage?
  private let videoConverter = PiPVideoConverter()
  private var outputSize = CGSize.zero
  private var pool: CVPixelBufferPool?
  private var clock = CommentPresentationClock()
  private var resumeGate: CommentSeekResumeGate?
  private var seekTarget = 0.0
  private var composing = false, primed = false, dirty = true
  private var lastTime = -1.0
  private var errorReported = false
  private var lastMetrics = 0.0, compositionMilliseconds = 0.0, metricFrames = 0
  private var failed = false
  @objc private(set) var active = false
  @objc private(set) var possible = false
  @objc private(set) var status = "PiP · 映像待ち"
  @objc var onChange: (() -> Void)?
  @objc var timeProvider: (() -> Double)?
  @objc var lengthProvider: (() -> Double)?
  @objc var rateProvider: (() -> Double)?
  @objc var runningProvider: (() -> Bool)?
  @objc var wantsPlaybackProvider: (() -> Bool)?
  @objc var playAction: (() -> Void)?
  @objc var pauseAction: (() -> Void)?
  @objc var seekAction: ((Double, @escaping () -> Void) -> Void)?
  @objc var capturedFrameCount: Int { frameLock.lock(); defer { frameLock.unlock() }; return received }
  @objc var composedFrameCount: Int { frameLock.lock(); defer { frameLock.unlock() }; return composed }
  @objc var consumedFrameCount: Int { frameLock.lock(); defer { frameLock.unlock() }; return consumed }
  @objc var capturingForPiP: Bool { frameLock.lock(); defer { frameLock.unlock() }; return capturing }
  // VLC samples carry scheduled host presentation times, not arrival times.
  @objc var videoPresentationHostTime: Double {
    let now = CACurrentMediaTime()
    frameLock.lock(); defer { frameLock.unlock() }
    if let index = presentationTimes.lastIndex(where: { $0 <= now }) {
      lastPresentedHost = presentationTimes[index]; presentationTimes.removeFirst(index + 1)
    }
    return lastPresentedHost
  }

  @objc override init() {
    let surface = NeoPiPSurface(frame: .zero)
    self.surface = surface; view = surface; displayLayer = surface.displayLayer
    super.init()
    surface.backgroundColor = .black; surface.isUserInteractionEnabled = false
    displayLayer.videoGravity = .resizeAspect
    do {
      guard let device = MTLCreateSystemDefaultDevice() else { throw CommentParseError.invalid("Metalデバイス") }
      // CoreText images are cached; this instance never submits GPU commands.
      renderer = try NeoDanmakuRenderer(device: device, cpuOnly: true)
    } catch { status = "PiPのコメント描画を準備できません。"; return }
    if AVPictureInPictureController.isPictureInPictureSupported() {
      let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self; controller.canStartPictureInPictureAutomaticallyFromInline = false
      pip = controller
      observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
        DispatchQueue.main.async { self?.possible = controller.isPictureInPicturePossible && !(self?.failed ?? true); self?.onChange?() }
      }
    } else {
      status = "この環境ではPiPを利用できません。"
    }
    let timer = DispatchSource.makeTimerSource(queue: work)
    timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in
      guard let self = self, self.composing || !self.primed else { return }
      autoreleasepool { self.renderFrame() }
    }
    self.timer = timer; timer.resume()
  }

  @objc func receiveVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    guard pts.isFinite else { return }
    frameLock.lock(); defer { frameLock.unlock() }
    guard !closed else { return }
    received += 1
    presentationTimes.append(pts)
    if presentationTimes.count > 64 { presentationTimes.removeFirst(presentationTimes.count - 64) }
    frames.append(CapturedVideoFrame(sample: sampleBuffer, hostTime: pts))
    // Bound retained decoder surfaces and prefer recent frames after a stall.
    // VLC submits frames ahead of their display time. Keeping only the newest
    // frame could replace every due frame with a future frame and starve PiP.
    let capacity = 8
    if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
  }

  @objc func updateComments(from overlay: NeoCommentOverlay) {
    let snapshot = overlay.compositionState
    work.async { [weak self] in
      guard let self = self else { return }
      if self.state.version != snapshot.version { self.renderer?.reset() }
      self.state = snapshot; self.dirty = true
    }
  }

  @objc func start() {
    guard possible, !active else { return }
    work.async { [weak self] in self?.composing = true; self?.dirty = true }
    pip?.invalidatePlaybackState(); pip?.startPictureInPicture()
  }
  @objc func invalidatePlaybackState() { pip?.invalidatePlaybackState() }
  // A seek flushes stale samples without stopping the active PiP session.
  @objc func seekDiscontinuity(_ target: Double) {
    frameLock.lock(); frames.removeAll(); presentationTimes.removeAll(); lastPresentedHost = 0; frameLock.unlock()
    work.async { [weak self] in
      self?.current = nil; self?.image = nil; self?.clock = CommentPresentationClock()
      self?.resumeGate = CommentSeekResumeGate()
      self?.seekTarget = max(0, target)
      self?.lastTime = -1; self?.dirty = true; self?.renderer?.seekWindow(); self?.displayLayer.flush()
    }
    invalidatePlaybackState()
  }
  @objc func resetVideo() {
    pip?.stopPictureInPicture()
    work.async { [weak self] in
      guard let self = self else { return }
      self.frameLock.lock(); self.frames.removeAll(); self.presentationTimes.removeAll(); self.lastPresentedHost = 0; self.frameLock.unlock()
      self.current = nil; self.image = nil; self.primed = false; self.dirty = true
      self.clock = CommentPresentationClock(); self.lastTime = -1
      self.displayLayer.flushAndRemoveImage()
    }
  }
#if targetEnvironment(simulator)
  @objc func beginCompositionSmoke() {
    work.async { [weak self] in self?.composing = true; self?.dirty = true }
  }
  static func converterSmoke() throws -> Bool {
    let converter = PiPVideoConverter(), size = CGSize(width: 320, height: 180)
    let first = try converter.image(NeoPiPSmoke.colorPixel(kCVPixelFormatType_32BGRA), outputSize: size)
    guard let providerData = first.dataProvider?.data else { return false }
    let bytes = providerData as Data
    for _ in 0..<12 {
      let next = try converter.image(NeoPiPSmoke.colorPixel(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), outputSize: size)
      guard next.width == 320, next.height == 180 else { return false }
    }
    guard let stillRetained = first.dataProvider?.data else { return false }
    return first.width == 320 && first.height == 180 && bytes == stillRetained as Data
  }
#endif
  @objc func stop() {
    frameLock.lock(); closed = true; capturing = false; frames.removeAll(); frameLock.unlock()
    observation = nil; pip?.stopPictureInPicture(); pip?.delegate = nil; pip?.contentSource = nil; pip = nil
    active = false; possible = false; onChange = nil
    work.async { [weak self] in
      self?.timer?.cancel(); self?.timer = nil; self?.composing = false
      self?.current = nil; self?.image = nil; self?.pool = nil; self?.renderer?.reset()
      self?.displayLayer.flushAndRemoveImage()
    }
  }
  deinit { timer?.cancel() }

  private func renderFrame() {
    let now = CACurrentMediaTime()
    frameLock.lock()
    if closed { frameLock.unlock(); return }
    let due = frames.lastIndex(where: { $0.hostTime <= now })
    let next = due.map { frames[$0] }
    if let due = due { frames.removeFirst(due + 1) }
    frameLock.unlock()
    let running = runningProvider?() ?? false
    let media = timeProvider?() ?? 0
    var composition = state
    if var gate = resumeGate {
      let ready = gate.allows(media: media, running: running, wantsPlayback: wantsPlaybackProvider?() ?? running)
      resumeGate = ready ? nil : gate; composition.enabled = composition.enabled && ready; clock.reset()
    }
    let time = clock.time(media: media, running: running, now: now, rate: rateProvider?() ?? 1, videoHost: videoPresentationHostTime)
    guard next != nil || current != nil else { return }
    if next == nil && !running && !dirty && time == lastTime { return }
    do {
      if let next = next, let pixel = CMSampleBufferGetImageBuffer(next.sample) {
        frameLock.lock(); consumed += 1; frameLock.unlock()
        current = next
        guard let format = CMSampleBufferGetFormatDescription(next.sample) else { throw CommentParseError.invalid("PiP映像形式") }
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        guard presentation.width.isFinite, presentation.height.isFinite, presentation.width > 0, presentation.height > 0 else {
          throw CommentParseError.invalid("PiP映像サイズ")
        }
        let scale = min(1, min(1280 / presentation.width, 720 / presentation.height))
        let size = CGSize(width: max(2, floor(presentation.width * scale / 2) * 2),
          height: max(2, floor(presentation.height * scale / 2) * 2))
        if size != outputSize { outputSize = size; pool = try Self.makePool(size: size); displayLayer.flush() }
        image = try videoConverter.image(pixel, outputSize: size)
      }
      guard let image = image, let pool = pool, let renderer = renderer else { return }
      if resumeGate != nil, let timeline = state.timeline {
        let scale = max(Double(outputSize.width)/timeline.width, Double(outputSize.height)/timeline.height)
        renderer.prepareAhead(timeline, time: seekTarget, pixelScale: scale * max(1, state.size), opacity: state.usesSourceOpacity ? nil : state.opacity)
        renderer.prepareLayout(timeline, size: state.size, pixelScale: scale)
      }
      let layer = displayLayer
      if layer.status == .failed { layer.flush() }
      guard layer.isReadyForMoreMediaData else { return }
      guard let output = try Self.compose(image: image, size: outputSize, pool: pool, renderer: renderer, state: composition, time: time) else { return }
      let sample = try Self.makeSample(output, hostTime: now)
      layer.enqueue(sample)
      frameLock.lock(); composed += 1; frameLock.unlock()
      lastTime = time; dirty = renderer.hasPendingImages
      compositionMilliseconds += (CACurrentMediaTime() - now) * 1000; metricFrames += 1
      if now - lastMetrics >= 1 {
        NeoPlaybackDiagnostics.record("pip.sample", fields: ["width": outputSize.width, "height": outputSize.height,
          "frames": metricFrames, "meanComposeMs": compositionMilliseconds / Double(max(1, metricFrames)),
          "media": media, "commentTime": time, "videoAge": max(0, now - videoPresentationHostTime)])
        lastMetrics = now; metricFrames = 0; compositionMilliseconds = 0
      }
      if !primed {
        primed = true
        DispatchQueue.main.async { [weak self] in
          if self?.pip != nil { self?.status = "PiP · コメント合成" }
          self?.onChange?()
        }
      }
    } catch {
      if !errorReported {
        errorReported = true; composing = false; primed = true
        DispatchQueue.main.async { [weak self] in
          self?.failed = true; self?.possible = false; self?.status = error.localizedDescription
          self?.pip?.stopPictureInPicture(); self?.onChange?()
        }
      }
    }
  }

  static func compose(image: CGImage, size: CGSize, pool: CVPixelBufferPool, renderer: NeoDanmakuRenderer,
                      state: CommentCompositionState, time: Double) throws -> CVPixelBuffer? {
    var output: CVPixelBuffer?
    let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &output)
    if allocation == kCVReturnWouldExceedAllocationThreshold { return nil }
    guard allocation == kCVReturnSuccess, let output = output else { throw CommentParseError.invalid("PiP映像バッファ") }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(output), width: Int(size.width), height: Int(size.height),
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw CommentParseError.invalid("PiP合成") }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(origin: .zero, size: size))
    if state.enabled, let timeline = state.timeline {
      let scale = max(Double(size.width) / timeline.width, Double(size.height) / timeline.height)
      // Rasterize at the displayed text size; enlarging comments must not just
      // magnify a small bitmap. Placement/lane geometry remains unchanged.
      renderer.prepareAhead(timeline, time: time, pixelScale: scale * max(1, state.size), opacity: state.usesSourceOpacity ? nil : state.opacity)
      _ = renderer.drawCPU(timeline: timeline, time: time, viewport: size,
        sizeMultiplier: state.size, opacity: state.opacity, pixelScale: scale, rasterScale: scale * max(1, state.size), usesSourceOpacity: state.usesSourceOpacity, context: context)
      if let failure = renderer.error { throw CommentParseError.invalid(failure) }
    }
    return output
  }

  static func videoImage(_ pixel: CVPixelBuffer) throws -> CGImage {
    try PiPVideoConverter().image(pixel)
  }

  static func makePool(size: CGSize) throws -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let result = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
      [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: Int(size.width),
       kCVPixelBufferHeightKey: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey: [:],
       kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pool)
    guard result == kCVReturnSuccess, let pool = pool else { throw CommentParseError.invalid("PiP映像プール") }
    return pool
  }
  static func makeSample(_ pixel: CVPixelBuffer, hostTime: Double) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
      formatDescriptionOut: &format) == noErr, let format = format else { throw CommentParseError.invalid("PiP映像形式") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
      presentationTimeStamp: CMTimeMakeWithSeconds(hostTime, preferredTimescale: 1000000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
      formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sample = sample else { throw CommentParseError.invalid("PiP映像サンプル") }
    return sample
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    if playing { playAction?() } else { pauseAction?() }
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    if let seek = seekAction { seek(CMTimeGetSeconds(skipInterval), completionHandler) } else { completionHandler() }
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    let length = lengthProvider?() ?? 0, time = timeProvider?() ?? 0
    guard length > 0 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    return CMTimeRange(start: CMTimeMakeWithSeconds(CACurrentMediaTime() - time, preferredTimescale: 1000000),
      duration: CMTimeMakeWithSeconds(length, preferredTimescale: 1000000))
  }
  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    !(wantsPlaybackProvider?() ?? runningProvider?() ?? false)
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    frameLock.lock(); capturing = true; frameLock.unlock()
    active = true; work.async { [weak self] in self?.composing = true; self?.dirty = true }; onChange?()
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    frameLock.lock(); capturing = false; frameLock.unlock()
    active = false; work.async { [weak self] in self?.composing = false }; onChange?()
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    frameLock.lock(); capturing = false; frameLock.unlock()
    active = false; status = "PiPを開始できませんでした。"; work.async { [weak self] in self?.composing = false }; onChange?()
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}
