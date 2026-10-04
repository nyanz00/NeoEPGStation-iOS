import Accelerate
import AVKit
import MetalKit
import VideoToolbox

struct CommentCompositionState {
  var timeline: CommentTimeline?
  var version: Int
  var enabled: Bool
  var size: Double
  var opacity: Float
}

private struct CapturedVideoFrame {
  let sample: CMSampleBuffer
  let hostTime: Double
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
  private var pip: AVPictureInPictureController?
  private var observation: NSKeyValueObservation?
  private let work = DispatchQueue(label: "neo.pip.compose", qos: .userInitiated)
  private let frameLock = NSLock()
  private var frames: [CapturedVideoFrame] = []
  private var closed = false, received = 0
  private var capturing = false
  private var timer: DispatchSourceTimer?
  private var renderer: NeoDanmakuRenderer?
  private var state = CommentCompositionState(timeline: nil, version: -1, enabled: false, size: 1, opacity: 1)
  private var current: CapturedVideoFrame?
  private var image: CGImage?
  private var outputSize = CGSize.zero
  private var pool: CVPixelBufferPool?
  private var clock = CommentPlaybackClock()
  private var composing = false, primed = false, dirty = true
  private var lastTime = -1.0
  private var errorReported = false
  private var failed = false
  @objc private(set) var active = false
  @objc private(set) var possible = false
  @objc private(set) var status = "PiP · 映像待ち"
  @objc var onChange: (() -> Void)?
  @objc var timeProvider: (() -> Double)?
  @objc var lengthProvider: (() -> Double)?
  @objc var runningProvider: (() -> Bool)?
  @objc var playAction: (() -> Void)?
  @objc var pauseAction: (() -> Void)?
  @objc var seekAction: ((Double, @escaping () -> Void) -> Void)?
  @objc var capturedFrameCount: Int { frameLock.lock(); defer { frameLock.unlock() }; return received }
  @objc var capturingForPiP: Bool { frameLock.lock(); defer { frameLock.unlock() }; return capturing }

  @objc override init() {
    surface = NeoPiPSurface(frame: .zero); view = surface
    super.init()
    surface.backgroundColor = .black; surface.isUserInteractionEnabled = false
    surface.displayLayer.videoGravity = .resizeAspect
    do {
      guard let device = MTLCreateSystemDefaultDevice() else { throw CommentParseError.invalid("Metalデバイス") }
      // CoreText images are cached; this instance never submits GPU commands.
      renderer = try NeoDanmakuRenderer(device: device, cpuOnly: true)
    } catch { status = "PiPのコメント描画を準備できません。"; return }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      status = "この環境ではPiPを利用できません。"; return
    }
    let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: surface.displayLayer, playbackDelegate: self)
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self; controller.canStartPictureInPictureAutomaticallyFromInline = false
    pip = controller
    observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
      DispatchQueue.main.async { self?.possible = controller.isPictureInPicturePossible && !(self?.failed ?? true); self?.onChange?() }
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
    frames.append(CapturedVideoFrame(sample: sampleBuffer, hostTime: pts))
    // Bound retained decoder surfaces and prefer recent frames after a stall.
    let capacity = capturing ? 8 : 1
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
  @objc func stop() {
    frameLock.lock(); closed = true; capturing = false; frames.removeAll(); frameLock.unlock()
    observation = nil; pip?.stopPictureInPicture(); pip?.delegate = nil; pip?.contentSource = nil; pip = nil
    active = false; possible = false; onChange = nil
    work.async { [weak self] in
      self?.timer?.cancel(); self?.timer = nil; self?.composing = false
      self?.current = nil; self?.image = nil; self?.pool = nil; self?.renderer?.reset()
      self?.surface.displayLayer.flushAndRemoveImage()
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
    let time = clock.time(media: timeProvider?() ?? 0, running: running, now: now)
    guard next != nil || current != nil else { return }
    if next == nil && !running && !dirty && time == lastTime { return }
    do {
      if let next = next, let pixel = CMSampleBufferGetImageBuffer(next.sample) {
        image = try Self.videoImage(pixel)
        current = next
        guard let format = CMSampleBufferGetFormatDescription(next.sample) else { throw CommentParseError.invalid("PiP映像形式") }
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        guard presentation.width.isFinite, presentation.height.isFinite, presentation.width > 0, presentation.height > 0 else {
          throw CommentParseError.invalid("PiP映像サイズ")
        }
        let scale = min(1, min(960 / presentation.width, 540 / presentation.height))
        let size = CGSize(width: max(2, floor(presentation.width * scale / 2) * 2),
          height: max(2, floor(presentation.height * scale / 2) * 2))
        if size != outputSize { outputSize = size; pool = try Self.makePool(size: size); surface.displayLayer.flush() }
      }
      guard let image = image, let pool = pool, let renderer = renderer else { return }
      let layer = surface.displayLayer
      if layer.status == .failed { layer.flush() }
      guard layer.isReadyForMoreMediaData else { return }
      guard let output = try Self.compose(image: image, size: outputSize, pool: pool, renderer: renderer, state: state, time: time) else { return }
      let sample = try Self.makeSample(output, hostTime: now)
      layer.enqueue(sample)
      lastTime = time; dirty = renderer.hasPendingImages
      if !primed {
        primed = true
        DispatchQueue.main.async { [weak self] in self?.status = "PiP · コメント合成"; self?.onChange?() }
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
      renderer.prepare(timeline.visible(at: time, lookAhead: 1), pixelScale: scale)
      _ = renderer.drawCPU(timeline: timeline, time: time, viewport: size,
        sizeMultiplier: state.size, opacity: state.opacity, pixelScale: scale, context: context)
      if let failure = renderer.error { throw CommentParseError.invalid(failure) }
    }
    return output
  }

  static func videoImage(_ pixel: CVPixelBuffer, allowTransfer: Bool = true) throws -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let cvFormat = vImageCVImageFormat_CreateWithCVPixelBuffer(pixel)?.takeRetainedValue() else {
      throw CommentParseError.invalid("PiP映像形式")
    }
    if cvFormat.colorSpace == nil {
      vImageCVImageFormat_SetColorSpace(cvFormat, space)
    }
    if CVPixelBufferIsPlanar(pixel) && cvFormat.chromaSiting == nil {
      vImageCVImageFormat_SetChromaSiting(cvFormat, kCVImageBufferChromaLocation_Left)
    }
    var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: Unmanaged.passUnretained(space),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      version: 0, decode: nil, renderingIntent: .defaultIntent)
    var buffer = vImage_Buffer()
    let result = vImageBuffer_InitWithCVPixelBuffer(&buffer, &format, pixel, cvFormat, nil, vImage_Flags(kvImageNoFlags))
    defer { free(buffer.data) }
    // vImage does not accept every 10-bit decoder format. VideoToolbox can
    // transfer those surfaces into BGRA without changing the decoder output.
    if result != kvImageNoError && allowTransfer {
      var session: VTPixelTransferSession?
      guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr,
        let session = session else { throw CommentParseError.invalid("PiP色変換セッション") }
      defer { VTPixelTransferSessionInvalidate(session) }
      var converted: CVPixelBuffer?
      guard CVPixelBufferCreate(nil, CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel),
        kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &converted) == kCVReturnSuccess,
        let converted = converted,
        VTPixelTransferSessionTransferImage(session, from: pixel, to: converted) == noErr else {
        throw CommentParseError.invalid("PiPの10bit映像色変換")
      }
      return try videoImage(converted, allowTransfer: false)
    }
    guard result == kvImageNoError, let data = buffer.data,
      let provider = CGDataProvider(data: Data(bytes: data, count: buffer.rowBytes * Int(buffer.height)) as CFData),
      let image = CGImage(width: Int(buffer.width), height: Int(buffer.height), bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: buffer.rowBytes, space: space, bitmapInfo: format.bitmapInfo,
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
      throw CommentParseError.invalid("PiP映像の色変換（\(result)）")
    }
    return image
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
    !(runningProvider?() ?? false)
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
