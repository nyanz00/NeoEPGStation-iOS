import Foundation

// Server sends video without burned captions. Keep extracted ordinary ASS
// separate and let VLC/libass render its complete styles, alongside the native
// comment worker. TS ARIB remains a native track in the HLS TS payload.
@objc(NeoStreamingSubtitles)
final class NeoStreamingSubtitles: NSObject {
  private let loader: NeoCommentLoader
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neo-captions-"+UUID().uuidString)
  private var closed = false
  @objc private(set) var files: [URL] = []
  @objc var onChange: (() -> Void)?
  @objc(initWithSource:username:password:)
  init(source: URL, username: String, password: String) {
    loader = NeoCommentLoader(source: source, username: username, password: password); super.init()
  }
  @objc func start() {
    loader.ordinaryTracks { [weak self] result in
      guard let self, case .success(let tracks) = result else { return }
      for track in tracks {
        self.loader.ordinaryText(index: track.subtitleIndex) { [weak self] result in
          guard let self else { return }
          DispatchQueue.main.async {
            guard !self.closed, case .success(let text) = result else { return }
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
  @objc func close() { closed = true; loader.close(); try? FileManager.default.removeItem(at: directory) }
}
