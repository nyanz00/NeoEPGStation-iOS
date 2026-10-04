import Foundation

func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
for count in 1...150 {
  for page in 1...count {
    let values = NeoPagination.mobile(page: page, count: count)
    expect(values.contains(page) && values.count == min(count, 5), "Mobile current page and count")
    expect(values.first! >= 1 && values.last! <= count, "No nonexistent page")
    expect(zip(values, values.dropFirst()).allSatisfy { $0.1 == $0.0 + 1 }, "Consecutive mobile pages")
    let desktop = NeoPagination.desktop(page: page, count: count, width: 720).compactMap { $0 }
    expect(desktop.first == 1 && desktop.last == count && desktop.contains(page), "Desktop endpoints and current page")
  }
}
expect(NeoPagination.mobile(page: 1, count: 10) == [1,2,3,4,5], "First page reference")
expect(NeoPagination.mobile(page: 7, count: 10) == [5,6,7,8,9], "Page seven reference")
expect(NeoPagination.mobile(page: 10, count: 10) == [6,7,8,9,10], "Last page")
let root = try NeoServerURL.normalize(" https://example.com/#/recorded ")
expect(root.absoluteString == "https://example.com", "SPA route removed")
expect(try NeoServerURL.normalize("https://example.com/epg/api/").absoluteString == "https://example.com/epg", "Reverse proxy path preserved")
for invalid in ["file:///tmp", "https://user:pass@example.com/", "https://example.com/?token=x", "https://example.com/#other", "not a url"] {
  do { _ = try NeoServerURL.normalize(invalid); fatalError("Accepted invalid URL") } catch {}
}
let start = 1791042600000.0 // 2026-10-04 00:50 JST
expect(NeoProgramText.interval(start: start, end: start + 1800000) == "10/04(日) 00:50 - 01:20 (30 m)", "Compact Web timestamp")
let decoded = try JSONDecoder().decode(NeoRecords.self, from: Data(#"{"total":1,"records":[{"id":1,"name":"Sample","startAt":1,"endAt":2,"isRecording":false,"videoFiles":[{"id":2,"name":"AV1","type":"encoded","size":352200000}]}]}"#.utf8))
expect(decoded.records[0].videoFiles?[0].id == 2, "PLAY file data decoded")
print("Native pagination, server URL, timestamp and recording model tests passed")

final class FixtureProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, Data))!
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
let completion = DispatchSemaphore(value: 0)
Task.detached {
  let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
  let session = URLSession(configuration: configuration)
  let api = NeoAPI(base: URL(string: "https://example.com/epg")!, session: session)
  defer { session.invalidateAndCancel(); completion.signal() }
  do {
    FixtureProtocol.handler = { request in
      expect(request.url?.path == "/epg/api/recorded", "API preserves reverse-proxy prefix")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      expect(query.contains(URLQueryItem(name: "offset", value: "180")), "Page seven offset")
      expect(query.contains(URLQueryItem(name: "isReverse", value: "false")), "Newest recordings first")
      expect(query.contains(URLQueryItem(name: "keyword", value: "アニメ & 日曜")), "Keyword encoding")
      expect(request.value(forHTTPHeaderField: "Authorization") == nil, "No legacy Basic auth")
      expect(request.value(forHTTPHeaderField: "X-EPGStation-User-Id") == "master", "Viewer header")
      return (200, Data(#"{"total":300,"records":[]}"#.utf8))
    }
    let result = try await api.recordings(page: 7, keyword: "アニメ & 日曜")
    expect(result.total == 300, "List response decoded")
    for status in [401, 403, 500] {
      FixtureProtocol.handler = { _ in (status, Data()) }
      do { _ = try await api.recordings(page: 1); fatalError("Accepted HTTP error") } catch is NeoError {}
    }
    FixtureProtocol.handler = { _ in (200, Data("<html>login</html>".utf8)) }
    do { _ = try await api.recordings(page: 1); fatalError("Accepted non-JSON") } catch is NeoError {}
    FixtureProtocol.handler = { _ in (200, Data(#"{"id":99,"name":"Sample","startAt":0,"endAt":1,"isRecording":false}"#.utf8)) }
    do { _ = try await api.recording(1); fatalError("Accepted mismatched recording ID") } catch is NeoError {}
    print("Native API request, response and authentication-error tests passed")
  } catch { fatalError("Native API fixture failed: \(error)") }
}
expect(completion.wait(timeout: .now() + 30) == .success, "API tests timed out")
