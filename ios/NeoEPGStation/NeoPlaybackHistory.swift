import Foundation

// Mirrors RecordedPlaybackTracker and RecordedWatchPage's cumulative session
// totals. A seek changes the resume position, never the amount watched.
struct NeoWatchClock {
  private(set) var position = 0.0, duration = 0.0, total = 0.0
  private var host: Double?
  mutating func sample(position: Double, duration: Double, running: Bool, seeking: Bool,
                       rate: Double, now: Double) {
    guard position.isFinite, duration.isFinite else { return }
    let elapsed = host.map { max(0, now - $0) } ?? 0
    let advance = position - self.position
    if running && !seeking && advance > 0 && advance <= max(1, elapsed * max(1, rate) + 0.75) {
      total += advance
    }
    self.position = max(0, position); self.duration = max(0, duration); host = now
  }
}

@objc(NeoPlaybackHistory)
final class NeoPlaybackHistory: NSObject, URLSessionTaskDelegate {
  private let endpoint: URL, user: String, authorization: String?
  private let sessionID = UUID().uuidString.lowercased()
  private var clock = NeoWatchClock(), acknowledged = 0.0, lastSent = 0.0
  private var sending = false, pending = false, ended = false
  private var lastAttempt = -Double.infinity
  private var session: URLSession!
  @objc private(set) var status = ""
  @objc var onChange: (() -> Void)?
  @objc var onDiagnostic: (([String: Any]) -> Void)?
  static func observedMilliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
  static func errorMessage(_ error: Error?) -> String {
    let error = error as NSError?
    let connectionCodes = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
      NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
      NSURLErrorSecureConnectionFailed, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
    if let error, error.domain == NSURLErrorDomain, connectionCodes.contains(error.code) {
      return "視聴履歴を送信できません。サーバーに接続できませんでした。"
    }
    return "視聴履歴の送信中にエラーが発生しました。"
  }

  @objc(initWithBase:recordingID:user:username:password:)
  init(base: URL, recordingID: Int, user: String, username: String, password: String) {
    endpoint = base.appendingPathComponent("api/recorded/\(recordingID)/playback")
    self.user = user
    authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    super.init()
    if Int(user).map({ $0 > 0 }) != true {
      status = "視聴履歴を保存するには、アプリ設定でWebと同じ通常ユーザーを選んでください。"
    }
    let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
    session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
  }

  @objc func sample(_ position: Double, duration: Double, running: Bool, seeking: Bool, rate: Double) {
    let now = ProcessInfo.processInfo.systemUptime
    clock.sample(position: position, duration: duration, running: running, seeking: seeking, rate: rate, now: now)
    if now - lastSent >= 5 && clock.duration > 0 { flush() }
  }
  @objc func flush() {
    guard Int(user).map({ $0 > 0 }) == true, clock.duration > 0 else { return }
    pending = true; drain()
  }
  private func drain() {
    guard pending, !sending else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastAttempt >= 1 else {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) { [self] in drain() }; return
    }
    sending = true; pending = false; lastAttempt = now; lastSent = now
    let total = min(clock.total, acknowledged + 30)
    var request = URLRequest(url: endpoint); request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(user, forHTTPHeaderField: "X-EPGStation-User-Id")
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["position": min(clock.position, clock.duration),
      "duration": clock.duration, "sessionId": sessionID, "sessionWatchedSeconds": total,
      "observedAt": Self.observedMilliseconds(Date())])
    // The request keeps this sender alive through the final close-time flush.
    session.dataTask(with: request) { [self] data, response, error in
      sending = false
      if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
        acknowledged = total; status = ""; pending = pending || clock.total > total
        NotificationCenter.default.post(name: Notification.Name("NeoHistoryChanged"), object: nil)
      } else {
        status = Self.errorMessage(error); pending = true
        // Keep diagnostics numeric/fixed-field only: responses may contain private data.
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let errors = json?["errors"] as? [[String: Any]] ?? []
        let validation = errors.contains { (($0["path"] as? String) ?? "").contains("observedAt") }
        onDiagnostic?(["httpStatus": (response as? HTTPURLResponse)?.statusCode ?? 0,
          "urlError": (error as NSError?)?.domain == NSURLErrorDomain ? (error as NSError?)?.code ?? 0 : 0,
          "observedAtValidation": validation])
      }
      onChange?()
      if pending {
        DispatchQueue.main.asyncAfter(deadline: .now() + (status.isEmpty ? 1 : 5)) { [self] in
          if ended && !status.isEmpty { session.finishTasksAndInvalidate(); return }
          drain()
        }
      } else if ended { session.finishTasksAndInvalidate() }
    }.resume()
  }
  @objc func finish() {
    ended = true; onChange = nil
    if Int(user).map({ $0 > 0 }) == true && clock.duration > 0 { flush() } else { session.finishTasksAndInvalidate() }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    // A progress PUT must never be redirected into a different user or server.
    completionHandler(nil)
  }
}
