import UIKit
import AVFoundation
import Combine
import AetherEngine
import CoreImage
import IOSurface

private final class NeoAetherTransportClock: @unchecked Sendable {
  struct Value {
    var timeMs: Int64 = 0, durationMs: Int64 = 0
    var playing = false, seekable = false, buffering = false, ready = false, ended = false, failed = false
  }
  private let lock = NSLock()
  private var value = Value()
  func access<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

// Production transport only. NeoPlayerController remains the common owner of
// controls, comments, composited PiP, history, session APIs and navigation.
@MainActor @objc(NeoAetherBackend)
final class NeoAetherBackend: NSObject {
  @objc let view = UIView()
  private let surface = AetherPlayerView(frame: .zero)
  private let caption = UIImageView()
  private let ass = NeoASSSubtitleRenderer()
  private var engine: AetherEngine?
  private var subscriptions = Set<AnyCancellable>()
  private var task: Task<Void, Never>?, seekTask: Task<Void, Never>?, aheadTask: Task<Void, Never>?
  private var timer: Timer?, output: AVPlayerItemVideoOutput?
  private weak var outputItem: AVPlayerItem?
  private var epoch = 0, closed = false, loaded = false, wantsPlayback = true
  private var primingPausedFrame = false
  private var lastPTS = -Double.infinity, lastFrameHost = 0.0, openedAt = 0.0
  private var lastTick = 0.0, lastCheckpointTick = -Double.infinity, checkpointOffset = 0.0
  private var samples = 0, outputID = 0, pendingTarget: Double?, pendingBegan = 0.0
  private var sampleFailure: OSStatus = noErr
  private var seekCompletion: ((Bool) -> Void)?
  private var recovering = false, stalledSince = 0.0, lastReportedState = ""
  private var snapshotPixel: CVPixelBuffer?
  private var lastGeneration: UInt64?, pendingGeneration: UInt64?
  private var checkpoints: NeoCheckpointPlayback?
  private var choices: [Int: URL] = [:], chosenSubtitle = -1
  private var nativeSubtitle = false
  private var logCapture = NeoAetherLogCapture()
  private let decodedFrames = NeoAetherDecodedFrames()
  private var rate: Float = 1
  // Comment/PiP workers sample these synchronously off-main. Never cross a
  // MainActor ObjC thunk from their time/running providers or dispatch_sync(main).
  private nonisolated let transport = NeoAetherTransportClock()
  @objc var options: [String: Any] = [:]
  @objc weak var frameSink: (any NeoVideoFrameSink)?
  @objc var onChange: (() -> Void)?
  @objc var onRecovery: ((Int64) -> Void)?
  @objc nonisolated private(set) var timeMs: Int64 { get { transport.access { $0.timeMs } } set { transport.access { $0.timeMs = newValue } } }
  @objc nonisolated private(set) var durationMs: Int64 { get { transport.access { $0.durationMs } } set { transport.access { $0.durationMs = newValue } } }
  @objc nonisolated private(set) var playing: Bool { get { transport.access { $0.playing } } set { transport.access { $0.playing = newValue } } }
  @objc nonisolated private(set) var seekable: Bool { get { transport.access { $0.seekable } } set { transport.access { $0.seekable = newValue } } }
  @objc nonisolated private(set) var buffering: Bool { get { transport.access { $0.buffering } } set { transport.access { $0.buffering = newValue } } }
  @objc nonisolated private(set) var ready: Bool { get { transport.access { $0.ready } } set { transport.access { $0.ready = newValue } } }
  @objc nonisolated private(set) var ended: Bool { get { transport.access { $0.ended } } set { transport.access { $0.ended = newValue } } }
  @objc nonisolated private(set) var failed: Bool { get { transport.access { $0.failed } } set { transport.access { $0.failed = newValue } } }
  @objc private(set) var videoSize = CGSize.zero
  @objc var muted = false { didSet { engine?.volume = muted || primingPausedFrame ? 0 : 1 } }
  @objc var pipActive = false {
    didSet {
      engine?.pictureInPictureActive = pipActive
      lastReportedState = ""; updateCaption()
    }
  }
  @objc var subtitleTracks: [[String: Any]] = []
  @objc var downloadedRanges: [[NSNumber]] {
    guard let engine, durationMs > 0 else { return [] }
    return engine.residentRanges.map { [NSNumber(value: $0.lowerBound/Double(durationMs)*1000), NSNumber(value: $0.upperBound/Double(durationMs)*1000)] }
  }
  @objc var snapshot: [String: NSNumber] {
    ["samples":NSNumber(value:samples),"changes":NSNumber(value:samples),"outputID":NSNumber(value:outputID),
     "age":NSNumber(value:lastFrameHost > 0 ? CACurrentMediaTime()-lastFrameHost : -1),
     "contentAge":NSNumber(value:lastFrameHost > 0 ? CACurrentMediaTime()-lastFrameHost : -1),
     "scheduledInMs":0,"layerStatus":NSNumber(value:failed ? 2 : ready ? 1 : 0),
     "nativeDecoded":NSNumber(value:samples),"nativeLost":0,"requiresFlush":false]
  }
  @objc override init() {
    super.init()
    view.backgroundColor = .black; view.isUserInteractionEnabled = false
    surface.autoresizingMask = [.flexibleWidth,.flexibleHeight]
    caption.autoresizingMask = [.flexibleWidth,.flexibleHeight]; caption.contentMode = .scaleToFill
    view.addSubview(surface); view.addSubview(caption)
  }
  @objc func layout() { surface.frame = view.bounds; caption.frame = view.bounds }
  @objc(loadURL:startMilliseconds:playing:)
  func load(url: URL, startMilliseconds: Int64, playing: Bool) {
    guard !closed else { return }
    epoch += 1; let generation = epoch
    task?.cancel(); seekTask?.cancel(); aheadTask?.cancel(); subscriptions.removeAll()
    checkpoints?.stop(); checkpoints = nil; NeoAV1PlaybackBridge.install(nil)
    AetherEngine.setForceSoftwarePathForTesting(false)
    engine?.stop(); detachOutput(); snapshotPixel = nil
    loaded = false; ready = false; ended = false; failed = false; buffering = true; recovering = false; primingPausedFrame = false
    wantsPlayback = playing; self.playing = false; timeMs = max(0,startMilliseconds)
    lastPTS = -.infinity; lastFrameHost = 0; openedAt = CACurrentMediaTime(); lastCheckpointTick = -.infinity
    outputID += 1; samples = 0; pendingTarget = nil; settleSeek(false)
    do {
      let hls = options["streaming"] as? Bool == true
      if !hls, options["checkpointEnabled"] as? Bool == true {
        let cache = NeoCheckpointPlayback(enabled:true); checkpoints = cache
        cache.onRecovery { [weak self] sourceTarget in
          Task { @MainActor [weak self] in
            guard let self, self.epoch == generation, !self.closed else { return }
            self.seek(milliseconds:Int64((sourceTarget-self.checkpointOffset)*1000)) { _ in }
          }
        }
        cache.onFailure { [weak self] _ in Task { @MainActor [weak self] in self?.requestRecovery() } }
        NeoAV1PlaybackBridge.install { [cache] in cache.makeDecoder() }
        NeoPlaybackDiagnostics.record("checkpoint.configuration", fields:["enabled":true,"historySeconds":60,"futureSeconds":20,"budgetBytes":NeoCheckpointPlayback.budget])
      }
      if let decision = options["checkpointSelection"] as? [String:Any] { NeoPlaybackDiagnostics.record("checkpoint.selection",fields:decision) }
      let next = try AetherEngine(); engine = next
      next.backgroundPlaybackEnabled = true; next.pictureInPictureActive = pipActive
      next.volume = muted ? 0 : 1; next.bind(view:surface)
      next.setSoftwareVideoFrameTimeObserver { [frames = decodedFrames] in frames.accept($0) }
      EngineLog.handler = { [capture = logCapture] in capture.receive($0) }
      next.$state.sink { [weak self] state in
        guard let self, self.epoch == generation else { return }
        if case .ended = state { self.ended = true; self.playing = false; self.onChange?() }
        if case .error = state { self.requestRecovery() }
      }.store(in:&subscriptions)
      next.$currentAVPlayerItem.sink { [weak self] in self?.attachOutput($0) }.store(in:&subscriptions)
      next.$videoRoute.sink { route in NeoPlaybackDiagnostics.record("aether.route",fields:["route":route.rawValue]) }.store(in:&subscriptions)
      next.diagnostics.$liveTelemetry.sink { value in
        guard let value else { return }
        NeoPlaybackDiagnostics.record("aether.telemetry",fields:["sourceBytes":value.demuxerBytesFetched,"producerRestarts":value.producerRestartCount,
          "cachedBytes":value.cachedBytes ?? -1,"softwareCacheHits":value.softwareCacheSeekHits ?? 0,"softwareCacheMisses":value.softwareCacheSeekMisses ?? 0])
      }.store(in:&subscriptions)
      task = Task { [weak self, next] in
        guard let self else { return }
        do {
          var load = LoadOptions(preferredSubtitleLanguages:[], autoplay:false)
          load.nativeRemoteHLS = hls
          load.forwardBufferSegments = hls ? nil : (self.checkpoints != nil ? 5 : max(1,Int(ceil(Double(self.options["networkCachingMs"] as? Int ?? 5000)/4000))))
          load.sessionCacheByteBudget = 256*1024*1024
          _ = try await next.load(url:url,startPosition:Double(startMilliseconds)/1000,options:load)
          guard !Task.isCancelled, !self.closed, self.epoch == generation else { return }
          if next.sourceVideoCodecName?.lowercased() != "av1", self.checkpoints != nil {
            self.checkpoints?.stop(); self.checkpoints = nil; NeoAV1PlaybackBridge.install(nil)
          }
          next.setRate(self.rate)
          if !self.wantsPlayback {
            if next.videoRoute == .software {
              // PausedFirstFrame in SWHost keeps already-started loops reading
              // at a stopped clock. It cannot start loops that never ran.
              // Start then pause while muted, so that policy can prepare the
              // first picture without starting audible playback or our UI clock.
              self.primingPausedFrame = true; next.volume = 0
              next.play(); next.pause()
              NeoPlaybackDiagnostics.record("aether.pausedPicturePrime",fields:["targetMs":startMilliseconds])
            } else { await next.seek(to:Double(startMilliseconds)/1000) }
          }
          guard !Task.isCancelled, !self.closed, self.epoch == generation else { return }
          self.loaded = true
          self.applyIntent(); next.clearSubtitle()
          for font in next.fontAttachments { self.ass.addFont(font.data,name:font.filename) }
          self.refreshTracks(); self.onChange?()
          NeoPlaybackDiagnostics.record("aether.connected",fields:["hlsDirect":hls,"checkpoint":self.checkpoints != nil])
        } catch {
          guard !Task.isCancelled, !self.closed, self.epoch == generation else { return }
          self.requestRecovery()
        }
      }
      if timer == nil {
        timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer!,forMode:.common)
      }
    } catch { failed = true; buffering = false; onChange?() }
  }
  private func applyIntent() {
    guard let engine, loaded, !recovering else { return }
    if wantsPlayback {
      primingPausedFrame = false; engine.volume = muted ? 0 : 1; engine.play()
    } else { engine.pause() }
  }
  @objc func play() { wantsPlayback = true; applyIntent() }
  @objc func pause() { wantsPlayback = false; engine?.pause(); playing = false }
  @objc func setPlaybackRate(_ value: Float) { if value.isFinite && value > 0 { rate = value; engine?.setRate(value) } }
  @objc func suspend() { engine?.pause(); playing = false }
  @objc(seekMilliseconds:completion:)
  func seek(milliseconds: Int64, completion: @escaping (Bool) -> Void) {
    guard let engine, !closed, loaded, seekable else { completion(false); return }
    settleSeek(false); seekTask?.cancel()
    let target = min(max(0,Double(milliseconds)/1000),max(0,engine.duration-0.01))
    pendingTarget = target; pendingGeneration = lastGeneration; pendingBegan = CACurrentMediaTime()
    seekCompletion = completion; stalledSince = 0; ended = false
    let token = epoch
    seekTask = Task { [weak self, engine] in
      await engine.seek(to:target)
      guard let self, !self.closed, self.epoch == token else { return }
      self.applyIntent()
    }
  }
  private func settleSeek(_ ok: Bool) {
    let done = seekCompletion; seekCompletion = nil; pendingTarget = nil
    done?(ok)
  }
  private func requestRecovery(target: Int64? = nil) {
    guard !closed, !recovering, !ended else { return }
    recovering = true; buffering = true; playing = false; ready = false
    engine?.volume = 0; engine?.pause(); settleSeek(false)
    NeoPlaybackDiagnostics.record("aether.recoveryRequested",fields:["targetMs":timeMs])
    onChange?(); onRecovery?(target ?? timeMs)
  }
  private func attachOutput(_ item: AVPlayerItem?) {
    guard item !== outputItem else { return }; detachOutput()
    guard let item else { return }
    let next = AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    item.add(next); outputItem = item; output = next
    engine?.currentAVPlayer?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
  }
  private func detachOutput() { if let output { outputItem?.remove(output) }; output = nil; outputItem = nil }
  private func layers(_ layer: CALayer) -> [CALayer] { [layer]+(layer.sublayers ?? []).flatMap { layers($0) } }
  private func picture() -> (CVPixelBuffer,Double,UInt64?,Bool)? {
    guard let engine else { return nil }
    if engine.videoRoute == .software {
      for layer in layers(surface.layer).compactMap({ $0 as? AVSampleBufferDisplayLayer }) {
        guard layer.isReadyForDisplay, let pixel = layer.sampleBufferRenderer.displayedPixelBuffer() else { continue }
        let io = CVPixelBufferGetIOSurface(pixel)?.takeUnretainedValue()
        let pts = io.flatMap { IOSurfaceCopyValue($0,"NeoAetherSourcePTS" as CFString) as? NSNumber }?.doubleValue
        let generation = io.flatMap { IOSurfaceCopyValue($0,"NeoAetherPictureGeneration" as CFString) as? NSNumber }?.uint64Value
        let decoded = decodedFrames.latest()
        let position = pts ?? decoded?.time
        guard let position, position.isFinite else { continue }
        return (pixel,position,generation ?? decoded?.generation,pts != nil)
      }
    } else if let item = outputItem, let output {
      let current = item.currentTime(); var shown = CMTime.invalid
      if output.hasNewPixelBuffer(forItemTime:current), let pixel = output.copyPixelBuffer(forItemTime:current,itemTimeForDisplay:&shown), shown.isNumeric {
        let pts = engine.presentationAxisMap.sourceSeconds(forItemSeconds:shown.seconds) ?? shown.seconds
        return (pixel,pts,nil,true)
      }
    }
    return nil
  }
  private func tick() {
    guard !closed, let engine else { return }
    // An outgoing layer may still hold a picture during the engine handover.
    // It cannot establish readiness for the new input before load completes.
    guard loaded, !recovering else { return }
    let now = CACurrentMediaTime(); seekable = engine.canSeek
    let duration = engine.duration
    if duration.isFinite, duration > 0 { durationMs = Int64(duration*1000) }
    if let size = engine.softwareDisplaySize, size.width > 0 { videoSize = size }
    if videoSize == .zero, engine.sourceVideoHeight > 0 {
      videoSize = CGSize(width:Double(engine.sourceVideoWidth)*engine.sourceVideoPixelAspectRatio,height:Double(engine.sourceVideoHeight))
    }
    let frame = picture()
    if let (pixel,pts,generation,displayTimeVerified) = frame, pts != lastPTS || generation != lastGeneration {
      lastPTS = pts; lastGeneration = generation; snapshotPixel = pixel; lastFrameHost = now; samples += 1
      if primingPausedFrame {
        engine.pause()
        NeoPlaybackDiagnostics.record("aether.pausedPictureReady",fields:["mediaMs":pts*1000,"volume":engine.volume,"intent":wantsPlayback])
        primingPausedFrame = false; engine.volume = muted ? 0 : 1
      }
      if videoSize == .zero { videoSize = CGSize(width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel)) }
      if pendingTarget == nil || abs(pts-(pendingTarget ?? pts)) <= 0.5 {
        timeMs = Int64(max(0,pts)*1000)
      }
      if !ready { ready = true; buffering = false; onChange?() }
      if let target = pendingTarget, abs(pts-target) <= 0.5,
        generation == nil || generation != pendingGeneration {
        if displayTimeVerified {
          NeoPlaybackDiagnostics.record("seek.videoResume",fields:["engine":"aether","durationMs":(now-pendingBegan)*1000,"mediaMs":pts*1000,"targetMs":target*1000,"verification":"displayedPixelBuffer"])
        } else {
          NeoPlaybackDiagnostics.record("aether.seekDecodedTarget",fields:["engine":"aether","decodeReadyMs":(now-pendingBegan)*1000,"mediaMs":pts*1000,"targetMs":target*1000,"displayTimeVerified":false,"verification":"decodedTargetAndPicture"])
        }
        settleSeek(true)
      }
      if let sample = makeSample(pixel,pts:pts) { frameSink?.receiveVideoSampleBuffer(sample) }
    }
    playing = wantsPlayback && loaded && !ended && !recovering && engine.state == .playing
    buffering = !ended && !failed && (!ready || engine.isBuffering || recovering)
    if let target = pendingTarget, now-pendingBegan > 12 { requestRecovery(target:Int64(target*1000)) }
    // Confirmed frame timestamps, not image differences: static scenes remain valid.
    // Keep the last displayed position while output is stale, including audio-only progress.
    if loaded, wantsPlayback, !ended, !recovering, pendingTarget == nil, now-openedAt > 5 {
      let stale = lastFrameHost > 0 ? now-lastFrameHost : now-openedAt
      if stale > 3 { if stalledSince == 0 { stalledSince = now }; if now-stalledSince > 2 { requestRecovery() } }
      else { stalledSince = 0 }
    }
    updateCaption()
    if now-lastCheckpointTick >= 1 {
      lastCheckpointTick = now
      if let checkpoints {
        checkpoints.updatePosition(Double(timeMs)/1000+checkpointOffset)
        NeoPlaybackDiagnostics.record("checkpoint.cache",fields:checkpoints.report())
        if aheadTask == nil, checkpoints.needsAheadRun, pendingTarget == nil {
          let position = Double(timeMs)/1000, token = epoch
          aheadTask = Task { [weak self, engine, checkpoints] in
            guard let self else { return }; defer { self.aheadTask = nil }
            guard let run = await engine.neoCheckpointPackets(fromSession:position), self.epoch == token else { return }
            self.checkpointOffset = run.sourcePosition-position; checkpoints.offer(run)
          }
        }
      }
      refreshTracks(); onChange?()
    }
    lastTick = now
  }
  private func makeSample(_ pixel: CVPixelBuffer, pts: Double) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    let pixelRatio = videoSize.width/max(1,videoSize.height)*Double(CVPixelBufferGetHeight(pixel))/Double(CVPixelBufferGetWidth(pixel))
    // The format must include the actual buffer's color/aperture attachments.
    // A generic codec/size description can fail the image-buffer compatibility
    // check even when its pixel format and dimensions match.
    CVBufferSetAttachment(pixel,kCVImageBufferPixelAspectRatioKey,
      [kCVImageBufferPixelAspectRatioHorizontalSpacingKey:Int((max(0.01,pixelRatio)*10000).rounded()),
       kCVImageBufferPixelAspectRatioVerticalSpacingKey:10000] as CFDictionary,.shouldPropagate)
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&format)
    guard formatStatus == noErr, let format else { sampleFailure = formatStatus; return nil }
    // NeoCommentPiP consumes HOST-scheduled frames, just like the VLC frame tap.
    // This pixel is already displayed; source PTS remains on the separate media clock.
    var timing = CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(seconds:CACurrentMediaTime(),preferredTimescale:1000000),decodeTimeStamp:.invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescription:format,sampleTiming:&timing,sampleBufferOut:&sample)
    if status != noErr && status != sampleFailure {
      NeoPlaybackDiagnostics.record("aether.sampleFailure",fields:["status":status])
    }
    sampleFailure = status
    return sample
  }
  @objc(addSubtitleURL:selected:)
  func addSubtitle(url: URL, selected: Bool) {
    let id = Int(url.lastPathComponent.components(separatedBy:"-").first ?? "") ?? choices.count
    choices[id] = url
    if selected { selectSubtitle(id) }
    else if options["streamSubtitleIndex"] == nil, chosenSubtitle < 0, let name = NeoSubtitlePreference.savedName, !name.isEmpty,
      url.deletingPathExtension().lastPathComponent.contains(name) { selectSubtitle(id) }
    refreshTracks()
  }
  @objc func selectSubtitle(_ index: Int) {
    chosenSubtitle = index; nativeSubtitle = false; ass.clear(); caption.image = nil; frameSink?.receiveSubtitleImage(nil)
    guard index >= 0 else { engine?.clearSubtitle(); NeoSubtitlePreference.save(""); refreshTracks(); return }
    if let url = choices[index], let text = try? String(contentsOf:url,encoding:.utf8) {
      _ = ass.loadText(NeoSubtitleScript.ass(text)); engine?.clearSubtitle()
      NeoSubtitlePreference.save(subtitleName(url))
    } else {
      nativeSubtitle = true; engine?.selectSubtitleTrack(index:index)
      if let track = engine?.subtitleTracks.first(where: { $0.id == index }) { NeoSubtitlePreference.save(track.name) }
    }
    refreshTracks(); updateCaption()
  }
  private func subtitleName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.components(separatedBy:"-").dropFirst().joined(separator:"-") }
  private func refreshTracks() {
    if !choices.isEmpty {
      subtitleTracks = choices.sorted { $0.key < $1.key }.map { ["index":$0.key,"name":subtitleName($0.value),"detail":"","selected":$0.key == chosenSubtitle] }
    } else {
      subtitleTracks = (engine?.subtitleTracks ?? []).filter { !NeoCommentOverlay.isCommentName($0.name) }.map {
        ["index":$0.id,"name":$0.name,"detail":$0.codec,"selected":$0.id == chosenSubtitle]
      }
    }
  }
  private func updateCaption() {
    guard chosenSubtitle >= 0 else { return }
    let size = videoSize == .zero ? view.bounds.size : videoSize
    if !nativeSubtitle {
      let image = ass.image(atMilliseconds:timeMs,size:size)
      if caption.image !== image { caption.image = image; frameSink?.receiveSubtitleImage(image) }
    } else {
      let cues = (engine?.subtitleCues ?? []).filter { $0.startTime <= Double(timeMs)/1000 && $0.endTime > Double(timeMs)/1000 }
      let key = cues.map(\.id).description
      guard key != lastReportedState else { return }; lastReportedState = key
      let renderer = UIGraphicsImageRenderer(size:CGSize(width:max(2,size.width),height:max(2,size.height)))
      let image: UIImage? = cues.isEmpty ? nil : renderer.image { _ in
        for cue in cues {
          if case .image(let bitmap) = cue.body {
            let sx = size.width/max(1,bitmap.canvasSize.width), sy = size.height/max(1,bitmap.canvasSize.height)
            UIImage(cgImage:bitmap.cgImage).draw(in:CGRect(x:bitmap.position.minX*sx,y:bitmap.position.minY*sy,width:bitmap.position.width*sx,height:bitmap.position.height*sy))
          } else if let text = cue.text {
            let attrs: [NSAttributedString.Key:Any] = [.font:UIFont.systemFont(ofSize:max(12,size.height/20)),.foregroundColor:UIColor.white,.strokeColor:UIColor.black,.strokeWidth: -3]
            let line = NSAttributedString(string:text,attributes:attrs), rect = line.boundingRect(with:CGSize(width:size.width*0.9,height:size.height),options:[.usesLineFragmentOrigin],context:nil)
            line.draw(in:CGRect(x:(size.width-rect.width)/2,y:size.height-rect.height-size.height*0.04,width:rect.width,height:rect.height))
          }
        }
      }
      caption.image = image
      // The software engine already burns bitmap cues into its PiP frames.
      // Our separate libass captions are never engine-owned and still compose.
      frameSink?.receiveSubtitleImage(pipActive && engine?.videoRoute == .software ? nil : image)
    }
  }
  @objc func foreground() { applyIntent(); stalledSince = 0; openedAt = CACurrentMediaTime() }
#if targetEnvironment(simulator)
  @objc var surfaceProbe: [String:Any] {
    ["inWindow":surface.window != nil,"width":surface.bounds.width,"height":surface.bounds.height,
     "sampleFailure":sampleFailure,"frames":samples,"hasSink":frameSink != nil,
     "loaded":loaded,"intent":wantsPlayback,"recovering":recovering,"primingPausedFrame":primingPausedFrame,"state":String(describing:engine?.state),
     "layers":layers(surface.layer).map { String(describing:type(of:$0)) }]
  }
  @objc var renderSurfaceReadyForProbe: Bool {
    surface.window != nil && surface.bounds.width > 0 && layers(surface.layer).contains {
      ($0 as? AVPlayerLayer)?.isReadyForDisplay == true || ($0 as? AVSampleBufferDisplayLayer)?.isReadyForDisplay == true
    }
  }
  @objc var checkpointReadyForProbe: Bool {
    guard let checkpoints else { return true }
    return (checkpoints.report()["newestMs"] as? Double ?? 0) >= 30000
  }
  @objc var effectiveVolume: Float { engine?.volume ?? 0 }
  @objc var subtitleVisible: Bool { caption.image != nil }
  @objc func simulateFailureForProbe() { requestRecovery() }
  @objc func saveProbePicture(_ name: String) -> Bool {
    guard let pixel = snapshotPixel,
      let image = CIContext().createCGImage(CIImage(cvPixelBuffer:pixel),from:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel))),
      let bytes = UIImage(cgImage:image).pngData() else { return false }
    do { try bytes.write(to:NeoPiPSmoke.directory.appendingPathComponent(name)); return true } catch { return false }
  }
#endif
  @objc func shutdown() {
    guard !closed else { return }; closed = true; epoch += 1
    task?.cancel(); seekTask?.cancel(); aheadTask?.cancel(); settleSeek(false)
    timer?.invalidate(); timer = nil; detachOutput(); subscriptions.removeAll()
    checkpoints?.stop(); checkpoints = nil; engine?.stop(); engine = nil
    NeoAV1PlaybackBridge.install(nil); AetherEngine.setForceSoftwarePathForTesting(false); EngineLog.handler = nil
    ass.clear(); frameSink = nil; snapshotPixel = nil; onChange = nil; onRecovery = nil
  }
}
