import Foundation

struct NativeCommentTrack: Decodable {
  let subtitleIndex: Int, streamIndex: Int
  let codecName: String?
  let displayName: String
  let title: String?
  let language: String?
  var isComment: Bool {
    ["ass", "ssa"].contains(codecName?.lowercased() ?? "") &&
      [displayName, title ?? "", language ?? ""].contains(where: NeoASSComments.isCommentName)
  }
}

private struct CommentTrackList: Decodable { let items: [NativeCommentTrack] }
private struct CommentTextResponse: Decodable { let subtitleText: String }

enum CommentLoadError: Error, LocalizedError {
  case response, http(Int), transport
  var errorDescription: String? {
    switch self {
    case .response: return "コメントAPIの応答を読み取れません。VLCの字幕表示は引き続き利用できます。"
    case .http(let status): return "コメントを取得できません（HTTP \(status)）。字幕APIと認証設定を確認してください。"
    case .transport: return "コメントを取得できません。接続を確認し、再読み込みしてください。"
    }
  }
}

// Fetch and parse natively. Neither raw ASS nor video frames cross the JS bridge.
// Credentials are only sent to the configured origin; redirects cannot downgrade
// TLS or move authentication to a different host/port.
final class NeoCommentLoader: NSObject, URLSessionTaskDelegate {
  private let source: URL
  private let authorization: String?
  private let parsing = DispatchQueue(label: "neo.comments.parse", qos: .userInitiated)
  private var session: URLSession!

  init(source: URL, username: String, password: String) {
    self.source = source
    authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 90
    configuration.timeoutIntervalForResource = 120
    configuration.urlCache = nil
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  func tracks(completion: @escaping (Result<[NativeCommentTrack], Error>) -> Void) -> URLSessionDataTask {
    request(source.appendingPathComponent("subtitles")) { result in
      completion(result.flatMap { data in
        do {
          let items = try JSONDecoder().decode(CommentTrackList.self, from: data).items
          guard items.allSatisfy({ $0.subtitleIndex >= 0 && $0.streamIndex >= 0 }),
            Set(items.map(\.subtitleIndex)).count == items.count else { throw CommentLoadError.response }
          return .success(items.filter(\.isComment))
        } catch { return .failure(CommentLoadError.response) }
      })
    }
  }

  func text(track: NativeCommentTrack, completion: @escaping (Result<CommentTimeline, Error>) -> Void) -> URLSessionDataTask {
    let url = source.appendingPathComponent("subtitles").appendingPathComponent(String(track.subtitleIndex)).appendingPathComponent("text")
    return request(url) { [weak self] result in
      guard let self = self else { return }
      self.parsing.async {
        completion(result.flatMap { data in
          do {
            let response = try JSONDecoder().decode(CommentTextResponse.self, from: data)
            return .success(try NeoASSComments.parse(response.subtitleText))
          } catch let error as CommentParseError { return .failure(error) }
          catch { return .failure(CommentLoadError.response) }
        })
      }
    }
  }

  func close() { session.invalidateAndCancel() }

  func permitsRedirect(to target: URL) -> Bool {
    let root = source.path + "/subtitles"
    return target.scheme == source.scheme && target.host == source.host && target.port == source.port &&
      (target.path == root || target.path.hasPrefix(root + "/"))
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
