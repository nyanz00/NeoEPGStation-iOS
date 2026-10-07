#if targetEnvironment(simulator)
import AVFoundation
import MetalKit

enum NeoPiPSmoke {
  static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
  static var fixture: CommentTimeline {
    let style = CommentStyle(size: 24, outline: 1)
    return CommentTimeline(width: 640, height: 360, comments: (0..<80).map { index in
      NativeComment(id: index, layer: 0, start: 0, end: CommentTiming.scrollingDuration, text: "TEST コメント \(index)", style: style,
        position: nil, motion: CommentMotion(from: CommentPoint(x: 640, y: Double(index % 10) * 32 + 32),
          to: CommentPoint(x: -160, y: Double(index % 10) * 32 + 32), start: 0, end: CommentTiming.scrollingDuration), usesDanmakuTiming: true)
    })
  }
  static func save(_ name: String, _ result: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: directory.appendingPathComponent(name + ".json"))
    }
  }
  static func pixels(_ pixel: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    return Data(bytes: CVPixelBufferGetBaseAddress(pixel)!, count: CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
  }
  static func colorPixel(_ format: OSType) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 640, 360, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
      let pixel = pixel else { throw CommentParseError.invalid("色変換のテストバッファ") }
    CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    if format == kCVPixelFormatType_32BGRA {
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
      for y in 0..<360 { for x in 0..<640 {
        let i = y * stride + x * 4
        bytes[i] = 20; bytes[i + 1] = y < 180 ? 100 : 20; bytes[i + 2] = x < 320 ? 100 : 20; bytes[i + 3] = 255
      } }
    } else {
      for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
        let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!
        let count = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane)
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
          let values = base.assumingMemoryBound(to: UInt16.self)
          for i in 0..<(count / 2) { values[i] = UInt16(512 << 6) }
        } else { memset(base, 128, count) }
      }
      CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
    return pixel
  }
  static func compositionTest() {
    do {
      guard let device = MTLCreateSystemDefaultDevice() else { throw CommentParseError.invalid("Metal") }
      let renderer = try NeoDanmakuRenderer(device: device, cpuOnly: true)
      let timeline = fixture, size = CGSize(width: 640, height: 360)
      let pool = try NeoCommentPiP.makePool(size: size)
      let input = try colorPixel(kCVPixelFormatType_32BGRA), image = try NeoCommentPiP.videoImage(input)
      renderer.prepare(timeline.comments); renderer.waitForPreparedImages()
      func frame(_ time: Double, _ opacity: Float = 1, _ scale: Double = 1, _ enabled: Bool = true) throws -> CVPixelBuffer {
        renderer.prepare(timeline.comments, absoluteOpacity: opacity)
        renderer.prepareLayout(timeline, size: scale); renderer.waitForPreparedImages()
        guard let output = try NeoCommentPiP.compose(image: image, size: size, pool: pool, renderer: renderer,
          state: CommentCompositionState(timeline: timeline, version: 0, enabled: enabled, size: scale, opacity: opacity), time: time)
          else { throw CommentParseError.invalid("合成テストのプール容量") }
        return output
      }
      let first = try frame(3), firstBytes = pixels(first), paused = pixels(try frame(3)), moved = pixels(try frame(4))
      let base = pixels(try frame(3, 1, 1, false))
      try UIImage(cgImage: NeoCommentPiP.videoImage(first)).pngData()?.write(to: directory.appendingPathComponent("pip-composition-smoke.png"))
      let checks = ["commentsVisible": firstBytes != base, "pause": firstBytes == paused, "movement": firstBytes != moved,
        "size": firstBytes != pixels(try frame(3, 1, 1.5)), "opacity": base == pixels(try frame(3, 0)),
        "end": base == pixels(try frame(9)), "videoOrientation": base == pixels(input)]
      guard checks.values.allSatisfy({ $0 }) else {
        throw CommentParseError.invalid("PiP合成テスト: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", "))
      }
      let sample = try NeoCommentPiP.makeSample(first, hostTime: 100)
      guard abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - 100) < 0.00001,
        abs(CMTimeGetSeconds(CMSampleBufferGetDuration(sample)) - 1.0 / 60) < 0.00001 else { throw CommentParseError.invalid("PiPサンプル時刻") }
      for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
        let converted = try NeoCommentPiP.videoImage(colorPixel(format))
        guard let normalized = try NeoCommentPiP.compose(image: converted, size: size, pool: pool, renderer: renderer,
          state: CommentCompositionState(timeline: nil, version: 0, enabled: false, size: 1, opacity: 1), time: 0)
          else { throw CommentParseError.invalid("色変換テストの出力") }
        // CGImage's provider may use an optimized channel order. Test the
        // actual BGRA output sent to AVKit, rather than assuming that order.
        let bytes = [UInt8](pixels(normalized).prefix(4))
        guard (90...180).contains(Int(bytes[0])), abs(Int(bytes[0]) - Int(bytes[1])) < 5,
          abs(Int(bytes[1]) - Int(bytes[2])) < 5 else {
          throw CommentParseError.invalid("YUV \(format)色変換 BGRA=\(bytes)")
        }
      }
      save("pip-composition-smoke", ["success": true, "comments": 80, "cacheBytes": renderer.cachedBytes,
        "checks": ["videoOrientation", "movement", "pause", "size", "opacity", "onOff", "end", "hostTimestamp", "YUV8", "YUV10"]])
    } catch { save("pip-composition-smoke", ["success": false, "error": error.localizedDescription]) }
  }

  // Local synthetic H.264 exercises the actual pinned VLC output and frame tap.
  // It does not stand in for device AV1 throughput or background PiP testing.
  static func playerTest(root: UIViewController) {
    save("playback-phase-smoke", ["phase": "encode"])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let url = directory.appendingPathComponent("pip-fixture.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw CommentParseError.invalid("合成動画の準備") }
        writer.startSession(atSourceTime: .zero)
        let pixel = try colorPixel(kCVPixelFormatType_32BGRA)
        let deadline = Date().addingTimeInterval(20)
        for frame in 0..<480 {
          while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
          guard Date() < deadline, adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
            throw CommentParseError.invalid("合成動画の書き込み")
          }
        }
        input.markAsFinished()
        writer.finishWriting {
          guard writer.status == .completed else { save("pip-player-smoke", ["success": false, "error": "fixture encoding"]); return }
          DispatchQueue.main.async {
            let player = NeoPlayerController(url: url, title: "Synthetic PiP test", username: "", password: "", networkCaching: 100)
            player.recordingContext = ["id": 1, "channelName": "サンプル放送", "startAt": 1791042600000.0, "endAt": 1791044400000.0,
              "description": "番組の説明がここに表示されます。", "extended": "◇番組内容\n検証用の番組情報です。\n\n◇出演者\nサンプル"]
            player.modalPresentationStyle = .fullScreen
            root.present(player, animated: false) {
              save("playback-phase-smoke", ["phase": "encoded player"])
              DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                player.runVideoTapSmoke { encodedTap in
                  player.runControlsSmoke { controls in
                    save("playback-phase-smoke", ["phase": "controls", "success": controls["success"] ?? false])
                    save("player-controls-smoke", controls)
                    var result = player.runLayoutSmokeChecks()
                    // VLC resize reporting and MTK drawable replacement are async.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                      result.merge(player.finishLayoutSmokeSnapshot()) { _, new in new }
                      let attempted = player.startPiPSmoke()
                      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        result.merge(player.piPSmokeState()) { _, new in new }
                        result["pipStartAttempted"] = attempted
                        let primed = result["pipSupported"] as? Bool != true || result["pipStatus"] as? String == "PiP · コメント合成"
                        result["success"] = result["success"] as? Bool == true && result["videoFillsFit"] as? Bool == true && primed && (!attempted || result["pipActive"] as? Bool == true)
                        player.runReloadSmoke { playback in
                          save("playback-phase-smoke", ["phase": "reload", "success": playback["success"] ?? false])
                          save("player-playback-smoke", playback)
                          player.runExitSmoke(host: root) { exit in
                            save("playback-phase-smoke", ["phase": "exit", "success": exit["success"] ?? false])
                            save("player-exit-smoke", exit)
                            save("pip-player-smoke", result)
                            tsTapTest(root: root, encoded: encodedTap)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      } catch { save("pip-player-smoke", ["success": false, "error": error.localizedDescription]) }
    }
  }
  static func tsTapTest(root: UIViewController, encoded: [String: Any]) {
    save("playback-phase-smoke", ["phase": "TS player"])
    let file = directory.appendingPathComponent("player-tap.ts")
    guard FileManager.default.fileExists(atPath: file.path) else { save("player-tap-smoke", ["success": false, "error": "missing TS fixture"]); return }
    let base = ProcessInfo.processInfo.environment["NEO_EPG_RANGE_SMOKE"]
    let url = base.flatMap { URL(string: $0+"/api/videos/1") } ?? file
    let player = NeoPlayerController(url: url, title: "Synthetic TS tap test", username: "", password: "", networkCaching: 100)
    player.modalPresentationStyle = .fullScreen
    if let base { player.recordingContext = ["baseURL": base, "id": 1, "user": "7", "name": "Synthetic HTTP TS"] }
    root.present(player, animated: false) {
      player.runVideoTapSmoke { ts in
        save("playback-phase-smoke", ["phase": "TS tap", "success": ts["success"] ?? false])
        save("player-seek-state-smoke", player.runSeekStateSmokeChecks())
        player.runEndedSmoke { end in
          save("playback-phase-smoke", ["phase": "natural end", "success": end["success"] ?? false])
          save("player-ended-smoke", end)
          player.onClose = {
            save("playback-phase-smoke", ["phase": "closed"])
            disabledHistoryTest(root: root, encoded: encoded, ts: ts)
          }
          player.closeTapSmoke()
        }
      }
    }
  }
  static func disabledHistoryTest(root: UIViewController, encoded: [String: Any], ts: [String: Any]) {
    guard let base = ProcessInfo.processInfo.environment["NEO_EPG_RANGE_SMOKE"],
      let url = URL(string: base+"/api/videos/1") else {
      save("player-tap-smoke", ["success": false, "error": "missing history fixture server"]); return
    }
    let player = NeoPlayerController(url: url, title: "Synthetic history disabled test", username: "", password: "", networkCaching: 100)
    player.recordingContext = ["baseURL": base, "id": 1, "user": "8", "disableHistory": true, "name": "Synthetic HTTP TS"]
    player.modalPresentationStyle = .fullScreen
    root.present(player, animated: false) {
      player.runVideoTapSmoke { disabledTap in
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
          player.runEndedSmoke { end in
            player.onClose = {
              let correct = disabledTap["success"] as? Bool == true && end["success"] as? Bool == true
              save("player-history-disabled-smoke", ["success": correct, "disabledViewer": "8", "playPauseSeekEnd": correct])
              recoveryTest(root: root) { recovered in
                save("player-tap-smoke", ["success": encoded["success"] as? Bool == true && ts["success"] as? Bool == true && correct && recovered,
                  "encodedMP4": encoded, "transportStream": ts])
              }
            }
            player.closeTapSmoke()
          }
        }
      }
    }
  }
  static func recoveryTest(root: UIViewController, completion: @escaping (Bool) -> Void) {
    guard let base = ProcessInfo.processInfo.environment["NEO_EPG_RANGE_SMOKE"], let url = URL(string: base+"/api/videos/2") else { completion(false); return }
    let player = NeoPlayerController(url: url, title: "Synthetic encoded HTTP recovery", username: "", password: "", networkCaching: 100)
    player.modalPresentationStyle = .fullScreen
    root.present(player, animated: false) {
      player.runVideoTapSmoke { taps in
        player.runRecoverySmoke { recovery in
          save("player-recovery-smoke", recovery)
          player.onClose = { completion(taps["success"] as? Bool == true && recovery["success"] as? Bool == true) }
          player.closeTapSmoke()
        }
      }
    }
  }
}
#endif
