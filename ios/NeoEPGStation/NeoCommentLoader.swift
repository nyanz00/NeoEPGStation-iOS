import Foundation

struct NativeCommentTrack: Decodable {
  let subtitleIndex: Int, streamIndex: Int
  let codecName: String?
  let displayName: String
  let title: String?
  let language: String?
  var isJikkyo: Bool { codecName == "jikkyo" }
  var isComment: Bool {
    ["ass", "ssa"].contains(codecName?.lowercased() ?? "") &&
      [displayName, title ?? "", language ?? ""].contains(where: NeoASSComments.isCommentName)
  }
}

private struct CommentTrackList: Decodable { let items: [NativeCommentTrack] }
private struct CommentTextResponse: Decodable { let subtitleText: String }

private struct JikkyoResponse: Decodable {
  struct Comment: Decodable {
    let time: Double, text: String, color: String, position: String, size: String
    let postedAt: Double?
  }
  let isSuccess: Bool, source: String, timeBase: String
  let comments: [Comment]
}

enum CommentLoadError: Error, LocalizedError {
  case response, http(Int), transport, noJikkyo
  var errorDescription: String? {
    switch self {
    case .response: return "コメントAPIの応答を読み取れません。VLCの字幕表示は引き続き利用できます。"
    case .http(let status): return "コメントを取得できません（HTTP \(status)）。字幕APIと認証設定を確認してください。"
    case .transport: return "コメントを取得できません。接続を確認し、再読み込みしてください。"
    case .noJikkyo: return "実況ログがないか、取得できませんでした。"
    }
  }
}

// Fetch and parse natively. Neither raw ASS nor video frames cross the JS bridge.
// Credentials are only sent to the configured origin; redirects cannot downgrade
// TLS or move authentication to a different host/port.
final class NeoCommentLoader: NSObject, URLSessionTaskDelegate {
  var onMetric: ((String, Double, Int) -> Void)?
  private let source: URL
  private let authorization: String?
  private let parsing = DispatchQueue(label: "neo.comments.parse", qos: .userInitiated)
  private var session: URLSession!
  private var jikkyoCache: CommentTimeline?

  init(source: URL, username: String, password: String) {
    self.source = source
    authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 90
    configuration.timeoutIntervalForResource = 120
    configuration.urlCache = nil
    configuration.httpCookieStorage = .shared; configuration.urlCredentialStorage = .shared
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  func tracks(jikkyo: Bool = false, completion: @escaping (Result<[NativeCommentTrack], Error>) -> Void) -> URLSessionDataTask? {
    if jikkyo {
      completion(.success([NativeCommentTrack(subtitleIndex: 0, streamIndex: 0, codecName: "jikkyo",
        displayName: "実況過去ログ", title: nil, language: nil)]))
      return nil
    }
    let began = ProcessInfo.processInfo.systemUptime
    return allTracks { [weak self] result in
      self?.onMetric?("comments.tracks", (ProcessInfo.processInfo.systemUptime-began)*1000, (try? result.get().count) ?? 0)
      completion(result.map { $0.filter(\.isComment) })
    }
  }
  @discardableResult func allTracks(completion: @escaping (Result<[NativeCommentTrack], Error>) -> Void) -> URLSessionDataTask? {
    request(source.appendingPathComponent("subtitles")) { result in
      completion(result.flatMap { data in
        do {
          let items = try JSONDecoder().decode(CommentTrackList.self, from:data).items
          guard items.allSatisfy({ $0.subtitleIndex >= 0 && $0.streamIndex >= 0 }), Set(items.map(\.subtitleIndex)).count == items.count else { throw CommentLoadError.response }
          return .success(items)
        } catch { return .failure(CommentLoadError.response) }
      })
    }
  }
  func ordinaryTracks(completion: @escaping (Result<[NativeCommentTrack], Error>) -> Void) {
    allTracks { completion($0.map { items in items.filter { !$0.isComment && ["ass","ssa","subrip","srt","webvtt"].contains($0.codecName?.lowercased() ?? "") } }) }
  }

  func ordinaryText(index: Int, completion: @escaping (Result<String, Error>) -> Void) {
    request(source.appendingPathComponent("subtitles/\(index)/text")) { result in
      completion(result.flatMap { data in
        do { return .success(try JSONDecoder().decode(CommentTextResponse.self, from: data).subtitleText) }
        catch { return .failure(error) }
      })
    }
  }

  func text(track: NativeCommentTrack, range: (startAt: Double, duration: Double)? = nil, completion: @escaping (Result<CommentTimeline, Error>) -> Void) -> URLSessionDataTask? {
    if track.isJikkyo { return jikkyo(range: range, completion: completion) }
    var url = source.appendingPathComponent("subtitles").appendingPathComponent(String(track.subtitleIndex)).appendingPathComponent("text")
    if let range {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "startAt", value: String(range.startAt)), URLQueryItem(name: "duration", value: String(range.duration))]
      url = components.url!
    }
    let began = ProcessInfo.processInfo.systemUptime
    return request(url) { [weak self] result in
      guard let self = self else { return }
      self.onMetric?(range == nil ? "comments.fullFetch" : "comments.previewFetch", (ProcessInfo.processInfo.systemUptime-began)*1000, (try? result.get().count) ?? 0)
      self.parsing.async {
        let parseBegan = ProcessInfo.processInfo.systemUptime
        let parsed = result.flatMap { data -> Result<CommentTimeline, Error> in
          do {
            let response = try JSONDecoder().decode(CommentTextResponse.self, from: data)
            return .success(try NeoASSComments.parse(response.subtitleText, timing: .danmaku, allowEmpty: range != nil))
          } catch { return .failure(error) }
        }
        self.onMetric?(range == nil ? "comments.fullParse" : "comments.previewParse", (ProcessInfo.processInfo.systemUptime-parseBegan)*1000, (try? parsed.get().comments.count) ?? 0)
        completion(parsed)

      }
    }
  }

  // The TS API returns video-relative seconds and already resolves command colors.
  // Preserve literal text: JSON comments must never be interpreted as ASS tags.
  static func parseJikkyo(_ data: Data) throws -> CommentTimeline {
    let response = try JSONDecoder().decode(JikkyoResponse.self, from: data)
    guard response.source == "jikkyo", response.timeBase == "video", response.comments.count <= 200_000 else { throw CommentLoadError.response }
    guard response.isSuccess else { throw CommentLoadError.noJikkyo }
    var comments: [NativeComment] = []
    for item in response.comments {
      guard item.time.isFinite, item.time >= 0, item.time <= 604800,
            !item.text.isEmpty, item.text.utf8.count <= 16384 else { continue }
      let scrolling = item.position == "right"
      guard scrolling || item.position == "top" || item.position == "bottom",
            ["small", "medium", "big"].contains(item.size),
            item.color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
            let rgb = UInt32(item.color.dropFirst(), radix: 16) else { throw CommentLoadError.response }
      var style = CommentStyle()
      // Match the commentary ASS baseline (28 at 200%) in the same 1920x1080
      // coordinate space. The user's multiplier is applied by the renderer.
      style.size = item.size == "big" ? 84 : item.size == "small" ? 42 : 56
      style.color = CommentColor(red: Double((rgb >> 16) & 255)/255,
        green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255, alpha: 1)
      style.alignment = scrolling ? 7 : item.position == "top" ? 8 : 2
      let lifetime = scrolling ? CommentTiming.scrollingDuration : CommentTiming.fixedDuration
      comments.append(NativeComment(id: comments.count, layer: 0, start: item.time, end: item.time+lifetime,
        text: item.text, style: style, position: nil,
        motion: scrolling ? CommentMotion(from: CommentPoint(x: 1920, y: 20), to: CommentPoint(x: 0, y: 20), start: 0, end: lifetime) : nil,
        usesDanmakuTiming: true, postedAt: item.postedAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }))
    }
    guard !comments.isEmpty else { throw CommentLoadError.noJikkyo }
    return CommentTimeline(width: 1920, height: 1080, comments: comments)
  }
  private func jikkyo(range: (startAt: Double, duration: Double)?, completion: @escaping (Result<CommentTimeline, Error>) -> Void) -> URLSessionDataTask? {
    func deliver(_ timeline: CommentTimeline) {
      guard let range else { completion(.success(timeline)); return }
      completion(.success(CommentTimeline(width: timeline.width, height: timeline.height,
        comments: timeline.comments.filter { $0.end >= range.startAt && $0.start < range.startAt+range.duration })))
    }
    // Cache the decoded full response once; prepare layout/textures near playback
    // first, and let the existing full-timeline reconciliation run afterwards.
    if let jikkyoCache { parsing.async { deliver(jikkyoCache) }; return nil }
    return request(source.appendingPathComponent("comments")) { [weak self] result in
      guard let self else { return }
      self.parsing.async {
        do {
          let timeline = try Self.parseJikkyo(result.get())
          self.jikkyoCache = timeline; deliver(timeline)
        } catch { completion(.failure(error)) }
      }
    }
  }

  static func previewRange(at time: Double) -> (startAt: Double, duration: Double) {
    (max(0, (time.isFinite ? time : 0)-30), 210)
  }

  func close() { session.invalidateAndCancel() }

  func permitsRedirect(to target: URL) -> Bool {
    let root = source.path + "/subtitles"
    return target.scheme == source.scheme && target.host == source.host && target.port == source.port &&
      (target.path == root || target.path.hasPrefix(root + "/") || target.path == source.path+"/comments")
  }

  private func request(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("master", forHTTPHeaderField: "X-EPGStation-User-Id")
    if let authorization = authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    let task = session.dataTask(with: request) { data, response, error in
      if error != nil { completion(.failure(CommentLoadError.transport)); return }
      guard let response = response as? HTTPURLResponse else { completion(.failure(CommentLoadError.response)); return }
      guard response.statusCode == 200 else { completion(.failure(CommentLoadError.http(response.statusCode))); return }
      guard let data = data, data.count <= 64 * 1024 * 1024 else { completion(.failure(CommentLoadError.response)); return }
      completion(.success(data))
    }
    task.resume(); return task
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let target = request.url, permitsRedirect(to: target) else { completionHandler(nil); return }
    var redirected = request
    if let authorization = authorization { redirected.setValue(authorization, forHTTPHeaderField: "Authorization") }
    completionHandler(redirected)
  }
}

// A track ID/index belongs to one input; names survive the next recording.
enum NeoCommentPreference {
  static let key = "player.comments.trackName"
  static func save(_ name: String) { UserDefaults.standard.set(name, forKey: key) }
  static func preferred(_ tracks: [NativeCommentTrack]) -> NativeCommentTrack? {
    let name = UserDefaults.standard.string(forKey: key)
    return tracks.first(where: { $0.displayName == name }) ?? tracks.first
  }
}

@objc(NeoSubtitlePreference)
final class NeoSubtitlePreference: NSObject {
  private static let key = "player.subtitle.name"
  @objc static var savedName: String? { UserDefaults.standard.string(forKey: key) }
  @objc static func save(_ name: String) { UserDefaults.standard.set(name, forKey: key) }
  @objc static func preferredIndex(_ names: [String]) -> Int {
    guard let name = savedName, !name.isEmpty else { return -1 }
    return names.firstIndex(of: name) ?? -1
  }
}
