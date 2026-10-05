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

let menuRecording = try JSONDecoder().decode(NeoRecording.self, from: Data(#"{"id":1,"name":"Sample","startAt":1,"endAt":2,"isRecording":false,"ruleId":2,"isProtected":true,"dropLogFile":{"id":3,"dropCnt":2,"errorCnt":0,"scramblingCnt":1},"videoFiles":[{"id":2,"name":"TS","type":"ts","size":1073741824},{"id":3,"name":"AV1","type":"encoded","size":1073741824}]}"#.utf8))
let capabilities = NeoServerConfig(encode: ["Sample"], developerMode: false)
expect(NeoRecordingMenu.commands(item: menuRecording, detail: false, config: capabilities) == [.rule, .search, .user, .encode, .info, .unprotect, .delete], "Web list menu order and protection state")
expect(NeoRecordingMenu.commands(item: menuRecording, detail: true, config: capabilities) == [.download, .rule, .search, .user, .encode, .thumbnail, .info, .unprotect, .delete], "Web detail hidden THUMB menu position")
expect(NeoRecordingMenu.commands(item: decoded.records[0], detail: false, config: nil) == [.search, .user, .encode, .info, .protect, .delete], "Encode placeholder remains without config")
let developer = try JSONDecoder().decode(NeoServerConfig.self, from: Data(#"{"encode":[null,123,"",{},"Sample"],"developerMode":true,"isEnableTSRecordedStream":true}"#.utf8))
expect(developer.encode == ["Sample"] && developer.developerMode == true && developer.isEnableTSRecordedStream == true, "Web encode normalization preserves developer capabilities")
let noModes = try JSONDecoder().decode(NeoServerConfig.self, from: Data(#"{"developerMode":true,"encode":null}"#.utf8))
expect(noModes.encode.isEmpty && noModes.developerMode == true, "Missing encode modes do not discard developer mode")
expect(NeoRecordingMenu.commands(item: menuRecording, detail: true, config: developer) == [.download, .rule, .search, .user, .encode, .thumbnail, .subtitle, .info, .unprotect, .delete], "Detail developer subtitle follows thumbnail")
expect(NeoRecordingMenu.commands(item: menuRecording, detail: false, config: developer) == [.rule, .search, .user, .encode, .info, .unprotect, .subtitle, .delete], "List developer subtitle follows protection")
expect(!NeoRecordingMenu.commands(item: menuRecording, detail: true, config: developer, hideThumbnailButton: false).contains(.thumbnail), "Visible THUMB is not duplicated in menu")
expect(NeoProgramText.dropSummary(menuRecording) == "drop: 2, error: 0, scrambling: 1 2.00 GB", "Drop counters and total file size decoded")
expect(menuRecording.dropLogFile?.hasErrors == true && decoded.records[0].dropLogFile == nil, "Drop presence and error state")
print("Recorded menu metadata and drop summary tests passed")

// Test the behavioral boundaries, including diagonal input, the 40/60 split,
// root fallback and vertical/right-to-left rejection. X never enters the
// policy: horizontal swipes must work even when starting at screen center.
expect(NeoNavigationGesture.action(startY: 100, height: 800, canGoBack: true, tablet: false, horizontal: 110, vertical: 100) == .menu, "Diagonal upper swipe opens menu")
expect(NeoNavigationGesture.action(startY: 319.9, height: 800, canGoBack: true, tablet: false, horizontal: 100, vertical: 0) == .menu, "Upper 40 percent opens menu")
expect(NeoNavigationGesture.action(startY: 320, height: 800, canGoBack: true, tablet: false, horizontal: 100, vertical: 0) == .back, "40 percent boundary begins back region")
expect(NeoNavigationGesture.action(startY: 360, height: 800, canGoBack: true, tablet: false, horizontal: 100, vertical: 0) == .back, "Former upper-half area now goes back")
expect(NeoNavigationGesture.action(startY: 320, height: 800, canGoBack: false, tablet: false, horizontal: 100, vertical: 0) == .menu, "Boundary opens menu at tab root")
expect(NeoNavigationGesture.action(startY: 650, height: 800, canGoBack: false, tablet: false, horizontal: 100, vertical: -100) == .menu, "Lower swipe opens menu without back target")
expect(NeoNavigationGesture.action(startY: 650, height: 800, canGoBack: true, tablet: false, horizontal: 100, vertical: 20) == .back, "Lower swipe returns when possible")
expect(NeoNavigationGesture.action(startY: 650, height: 800, canGoBack: true, tablet: false, horizontal: 20, vertical: 100) == nil, "Vertical scrolling preserved")
expect(NeoNavigationGesture.action(startY: 100, height: 800, canGoBack: false, tablet: false, horizontal: -100, vertical: 20) == nil, "Left drag never opens menu")
expect(NeoNavigationGesture.action(startY: 100, height: 800, canGoBack: false, tablet: true, horizontal: 100, vertical: 20) == nil, "Persistent iPad menu is not dragged")
print("Full-screen navigation gesture policy tests passed")

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
expect(NeoRelatedSearch.keyword("[新]【全12話】サンプル (字) #01「初回」") == "サンプル", "Related keyword removes broadcast marks and episode number")
expect(NeoRelatedSearch.keyword("番組「初回」") == "番組", "Related keyword strips quoted episode")
expect(NeoRelatedSearch.keyword("番組(特別版)") == "番組(特別版)", "Related keyword preserves multi-character parentheses")
expect(NeoRelatedSearch.keyword("[字] #01") == "#01", "Empty title fallback follows Web")

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
    FixtureProtocol.handler = { request in
      expect(request.url?.path == "/epg/api/config", "Config uses same reverse-proxy API path")
      return (200, Data(#"{"encode":null,"developerMode":true,"isEnableEncodedRecordedStream":true}"#.utf8))
    }
    let config = try await api.configuration()
    expect(config.developerMode == true && config.isEnableEncodedRecordedStream == true, "Config capabilities survive absent encode modes")
    FixtureProtocol.handler = { request in
      expect(request.url?.path == "/epg/api/rules/7", "Rule metadata uses API prefix")
      return (200, Data(#"{"id":7,"searchOption":{"keyword":"サンプル"}}"#.utf8))
    }
    expect(try await api.rule(7).searchOption.keyword == "サンプル", "Rule keyword decoded")
    for ruleId in [Int?(7), nil] {
      FixtureProtocol.handler = { request in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        expect(request.url?.path == "/epg/api/recorded", "Related recording endpoint")
        expect(query.contains(URLQueryItem(name: "limit", value: "100")) && query.contains(URLQueryItem(name: "isReverse", value: "true")), "Related panel uses Web's limit and order")
        expect(query.contains(URLQueryItem(name: "ruleId", value: "7")) == (ruleId != nil), "Rule filter used when available")
        expect(query.contains(URLQueryItem(name: "keyword", value: "サンプル & 番組")) == (ruleId == nil), "Keyword fallback is exclusive and encoded")
        return (200, Data(#"{"total":1,"records":[{"id":1,"name":"Sample","startAt":1,"endAt":2,"isRecording":false,"genre1":7,"subGenre1":0}]}"#.utf8))
      }
      let related = try await api.relatedRecordings(ruleId: ruleId, keyword: "サンプル & 番組")
      expect(related.records.first?.genre1 == 7 && related.records.first?.subGenre1 == 0, "Player genre metadata decoded")
    }
    FixtureProtocol.handler = { request in
      expect(request.url?.path == "/epg/api/dropLogs/3" && request.url?.query == "maxsize=512", "Drop log endpoint and limit")
      expect(request.value(forHTTPHeaderField: "X-EPGStation-User-Id") == "master", "Drop log viewer header")
      return (200, Data("sample drop log".utf8))
    }
    expect(try await api.dropLog(3) == "sample drop log", "Plain text drop log returned")
    FixtureProtocol.handler = { _ in (403, Data()) }
    do { _ = try await api.dropLog(3); fatalError("Accepted unauthorized drop log") } catch is NeoError {}
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
