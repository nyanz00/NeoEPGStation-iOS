import Foundation

/// The Web client's default Socket.IO namespace, over its Engine.IO v4 HTTP
/// polling transport. No user credentials are copied to a configured socket port.
/// These are invalidations only; encode data still comes from the guarded API.
enum NeoEncodeSocketProtocol {
  static func endpoints(base: URL, port: Int?) -> [URL] {
    guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return [] }
    parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    parts.path = "/" + (parts.path.isEmpty ? "" : parts.path + "/") + "socket.io/"
    parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
    guard let original = parts.url else { return [] }
    let currentPort = parts.port ?? (parts.scheme == "https" ? 443 : 80)
    if let port, (1...65535).contains(port), port != currentPort {
      parts.port = port
      if let preferred = parts.url { return [preferred, original] }
    }
    return [original]
  }
  static func url(_ endpoint: URL, sid: String? = nil) -> URL {
    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name:"EIO",value:"4"), URLQueryItem(name:"transport",value:"polling"),
      URLQueryItem(name:"t",value:UUID().uuidString)]
    if let sid { parts.queryItems?.append(URLQueryItem(name:"sid",value:sid)) }
    return parts.url!
  }
  static func packets(_ payload: String) -> [String] { payload.components(separatedBy:"\u{1e}") }
  static func isUpdate(_ packet: String) -> Bool {
    guard packet.hasPrefix("42"), let data = String(packet.dropFirst(2)).data(using:.utf8),
      let event = try? JSONSerialization.jsonObject(with:data) as? [Any], let name = event.first as? String else { return false }
    return name == "updateEncode" || name == "updateStatus"
  }
}

@MainActor final class NeoEncodeUpdates {
  private var task: Task<Void,Never>?
  func start(api: NeoAPI, port: Int?, connectionChanged: ((Bool) -> Void)? = nil, updated: @escaping () -> Void) {
    guard task == nil else { return }
    let endpoints = NeoEncodeSocketProtocol.endpoints(base:api.base,port:port)
    task = Task {
      var endpointIndex = 0, failures = 0
      while !Task.isCancelled, !endpoints.isEmpty {
        do {
          try await Self.connect(session:api.session,endpoint:endpoints[endpointIndex],connectionChanged:connectionChanged,updated:updated)
        } catch {
          connectionChanged?(false)
          if Task.isCancelled { break }
          // Like SocketBridge: try the API origin if the configured port fails.
          endpointIndex = min(endpointIndex+1,endpoints.count-1)
          failures += 1
          try? await Task.sleep(nanoseconds:UInt64(min(5,failures))*1_000_000_000)
        }
      }
    }
  }
  func stop() { task?.cancel(); task = nil }
  deinit { task?.cancel() }

  private static func request(session: URLSession, url: URL, body: String? = nil, timeout: TimeInterval) async throws -> String {
    var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:timeout)
    if let body { request.httpMethod = "POST"; request.httpBody = Data(body.utf8); request.setValue("text/plain;charset=UTF-8",forHTTPHeaderField:"Content-Type") }
    let (data,response) = try await session.data(for:request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      let text = String(data:data,encoding:.utf8) else { throw URLError(.badServerResponse) }
    return text
  }
  private static func connect(session: URLSession, endpoint: URL, connectionChanged: ((Bool) -> Void)?, updated: @escaping () -> Void) async throws {
    let opened = try await request(session:session,url:NeoEncodeSocketProtocol.url(endpoint),timeout:3)
    guard let first = NeoEncodeSocketProtocol.packets(opened).first, first.first == "0",
      let json = String(first.dropFirst()).data(using:.utf8),
      let handshake = try JSONSerialization.jsonObject(with:json) as? [String:Any],
      let sid = handshake["sid"] as? String, !sid.isEmpty else { throw URLError(.cannotParseResponse) }
    let interval = (handshake["pingInterval"] as? Double ?? 25000) + (handshake["pingTimeout"] as? Double ?? 20000)
    let timeout = max(10,min(120,interval/1000+5))
    defer {
      // Release the server session after hiding/backgrounding the tab.
      Task { _ = try? await request(session:session,url:NeoEncodeSocketProtocol.url(endpoint,sid:sid),body:"1",timeout:3) }
    }
    _ = try await request(session:session,url:NeoEncodeSocketProtocol.url(endpoint,sid:sid),body:"40",timeout:3)
    while !Task.isCancelled {
      let payload = try await request(session:session,url:NeoEncodeSocketProtocol.url(endpoint,sid:sid),timeout:timeout)
      var changed = false
      for packet in NeoEncodeSocketProtocol.packets(payload) {
        if packet == "1" || packet == "41" || packet.hasPrefix("44") { throw URLError(.networkConnectionLost) }
        if packet.hasPrefix("2") {
          _ = try await request(session:session,url:NeoEncodeSocketProtocol.url(endpoint,sid:sid),body:"3"+String(packet.dropFirst()),timeout:3)
        } else if packet.hasPrefix("40") { connectionChanged?(true); changed = true }
        else if NeoEncodeSocketProtocol.isUpdate(packet) { changed = true }
      }
      if changed { updated() }
    }
  }
}
