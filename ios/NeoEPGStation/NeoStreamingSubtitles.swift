import Foundation

// Server sends video without burned captions. Extract ordinary ASS/SRT for
// the shared styled caption renderer in VLC and Aether, separate from comments.
// TS ARIB remains a native track in the HLS TS payload.
@objc(NeoStreamingSubtitles)
final class NeoStreamingSubtitles: NSObject {
  private let loader: NeoCommentLoader
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neo-captions-"+UUID().uuidString)
  private var closed = false
  private var settled = false
  private var readyCallbacks: [() -> Void] = []
  @objc var initialTrackIndex: NSNumber?
  @objc private(set) var preferredIndex = -1
  @objc private(set) var files: [URL] = []
  @objc var onChange: (() -> Void)?
#if targetEnvironment(simulator)
  static func checkPreparation(source: URL, completion: @escaping ([String:Bool]) -> Void) {
    let captions = NeoStreamingSubtitles(source:source,username:"",password:"")
    var called = false
    captions.prepareBeforePlayback {
      called = true
      var checks = ["ordinaryPreparationWaits":!captions.files.isEmpty && captions.preferredIndex == 1]
      var immediate = false; captions.prepareBeforePlayback { immediate = true }
      checks["ordinaryPreparedCompletionReusable"] = immediate
      captions.close(); completion(checks)
    }
    precondition(!called,"Preparation completed before the request")
    captions.start()
  }
#endif
  @objc(initWithSource:username:password:)
  init(source: URL, username: String, password: String) {
    loader = NeoCommentLoader(source: source, username: username, password: password); super.init()
  }
  @objc func start() {
    loader.ordinaryTracks { [weak self] result in
      DispatchQueue.main.async {
      guard let self, !self.closed else { return }
      guard case .success(let tracks) = result else { self.finishPreparation(); return }
      self.preferredIndex = self.initialTrackIndex?.intValue ?? NeoCommentPreference.priority(tracks)?.subtitleIndex ?? -1
      if !tracks.contains(where: { $0.subtitleIndex == self.preferredIndex }) { self.finishPreparation() }
      for track in tracks {
        self.loader.ordinaryText(index: track.subtitleIndex) { [weak self] result in
          guard let self else { return }
          DispatchQueue.main.async {
            guard !self.closed else { return }
            defer { if track.subtitleIndex == self.preferredIndex { self.finishPreparation() } }
            guard case .success(let text) = result else { return }
            do {
              try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
              let ext = text.contains("[Events]") ? "ass" : text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") ? "vtt" : "srt"
              let name = track.displayName.replacingOccurrences(of: #"[^\p{L}\p{N} _-]"#, with: "_", options: .regularExpression)
              let url = self.directory.appendingPathComponent("\(track.subtitleIndex)-\(name.prefix(80)).\(ext)")
              try Data(text.utf8).write(to: url, options: .atomic); self.files.append(url); self.onChange?()
            } catch { NeoPlaybackDiagnostics.record("hls.subtitleFailure", fields: ["index": track.subtitleIndex]) }
          }
        }
      }
      }
    }
  }
  @objc func prepareBeforePlayback(_ completion: @escaping () -> Void) {
    if settled || closed { completion() } else { readyCallbacks.append(completion) }
  }
  private func finishPreparation() { settled = true; let callbacks = readyCallbacks; readyCallbacks.removeAll(); callbacks.forEach { $0() } }
  @objc func close() { closed = true; readyCallbacks.removeAll(); loader.close(); try? FileManager.default.removeItem(at: directory) }
}
