import Foundation

private final class NeoDetailToolsProtocol: URLProtocol {
  struct Captured {
    let method: String
    let percentEncodedPath: String
    let query: [String: String]
    let headers: [String: String]
    let cachePolicy: URLRequest.CachePolicy
    let timeoutInterval: TimeInterval
    let body: [String: Any]?

    func header(_ name: String) -> String? { headers[name.lowercased()] }
  }

  private struct ResponseSpec {
    let status: Int
    let object: [String: Any]
    let delay: TimeInterval
  }

  private struct State {
    var requests: [Captured] = []
    var completedPaths: [(String, String)] = []
    var tracks: [[String: Any]] = []
    var createResponse: ResponseSpec = ResponseSpec(status: 200, object: [String: Any](), delay: 0)
    var pollResponses: [ResponseSpec] = []
    var recordings: [Int: [String: Any]] = [:]
    var search: [String: (records: [[String: Any]], total: Int)] = [:]
  }

  private static let stateLock = NSLock()
  private static var state = State()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "hostdetail-tools.invalid"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let data = Self.bodyData(request)
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let captured = Self.capture(request, body: body)
    let response = Self.route(request, captured: captured)
    if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
    let responseData = (try? JSONSerialization.data(withJSONObject: response.object, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: responseData)
    client?.urlProtocolDidFinishLoading(self)
    Self.markCompleted(captured)
  }

  override func stopLoading() {}

  private static func bodyData(_ request: URLRequest) -> Data {
    if let data = request.httpBody, !data.isEmpty { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  private static func capture(_ request: URLRequest, body: [String: Any]?) -> Captured {
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
    let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, value in
      result[value.key.lowercased()] = value.value
    }
    return Captured(method: request.httpMethod ?? "GET", percentEncodedPath: components.percentEncodedPath,
      query: query, headers: headers, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval, body: body)
  }

  private static func route(_ request: URLRequest, captured: Captured) -> ResponseSpec {
    locked {
      state.requests.append(captured)
      if captured.method == "GET", captured.percentEncodedPath.hasPrefix("/api/videos/"), captured.percentEncodedPath.hasSuffix("/subtitles") {
        return ResponseSpec(status: 200, object: ["items": state.tracks], delay: 0)
      }
      if captured.method == "POST", captured.percentEncodedPath.contains("/subtitles/") {
        return state.createResponse
      }
      if captured.method == "GET", captured.percentEncodedPath.contains("/subtitles/transfer/") {
        if !state.pollResponses.isEmpty { return state.pollResponses.removeFirst() }
        return ResponseSpec(status: 404, object: ["message": "unexpected poll"], delay: 0)
      }
      if captured.method == "GET", captured.percentEncodedPath == "/api/recorded" {
        let key: String
        if let keyword = captured.query["keyword"] { key = "keyword:" + keyword }
        else if let channel = captured.query["channelId"] { key = "channel:" + channel }
        else { key = "missing" }
        let result = state.search[key] ?? (records: [], total: 0)
        return ResponseSpec(status: 200, object: ["records": result.records, "total": result.total], delay: 0)
      }
      if captured.method == "GET", captured.percentEncodedPath.hasPrefix("/api/recorded/") {
        let idText = String(captured.percentEncodedPath.dropFirst("/api/recorded/".count))
        if let id = Int(idText), let recording = state.recordings[id] {
          return ResponseSpec(status: 200, object: recording, delay: 0)
        }
        return ResponseSpec(status: 404, object: ["message": "fixture recording missing"], delay: 0)
      }
      return ResponseSpec(status: 404, object: ["message": "unexpected fixture request"], delay: 0)
    }
  }

  private static func locked<T>(_ body: () -> T) -> T {
    stateLock.lock(); defer { stateLock.unlock() }
    return body()
  }

  private static func markCompleted(_ request: Captured) {
    locked { state.completedPaths.append((request.method, request.percentEncodedPath)) }
  }

  static func reset() { locked { state = State() } }
  static func setTracks(_ tracks: [[String: Any]]) { locked { state.tracks = tracks } }
  static func setCreateResponse(_ status: Int = 200, object: [String: Any], delay: TimeInterval = 0) {
    locked { state.createResponse = ResponseSpec(status: status, object: object, delay: delay) }
  }
  static func enqueuePoll(_ status: Int = 200, object: [String: Any], delay: TimeInterval = 0) {
    locked { state.pollResponses.append(ResponseSpec(status: status, object: object, delay: delay)) }
  }
  static func setRecording(_ id: Int, object: [String: Any]) { locked { state.recordings[id] = object } }
  static func setSearch(_ key: String, records: [[String: Any]], total: Int) {
    locked { state.search[key] = (records, total) }
  }
  static func capturedRequests() -> [Captured] { locked { state.requests } }
  static func count(_ method: String, pathContaining path: String? = nil) -> Int {
    locked { state.requests.filter { $0.method == method && (path == nil || $0.percentEncodedPath.contains(path!)) }.count }
  }
  static func completedCount(_ method: String, pathContaining path: String) -> Int {
    locked { state.completedPaths.filter { $0.0 == method && $0.1.contains(path) }.count }
  }
}

private final class NeoDetailToolsEvents {
  private let lock = NSLock()
  private var recordingIDs = Set<Int>()
  func record(_ id: Int?) { guard let id else { return }; lock.lock(); recordingIDs.insert(id); lock.unlock() }
  func contains(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return recordingIDs.contains(id) }
}

@MainActor private enum NeoDetailToolsTests {
  static func waitFor(_ condition: @MainActor () -> Bool, attempts: Int = 160) async -> Bool {
    for _ in 0..<attempts {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }

  static func makeAPI() -> NeoAPI {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoDetailToolsProtocol.self]
    let api = NeoAPI(base: URL(string: "https://hostdetail-tools.invalid")!, session: URLSession(configuration: configuration))
    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "detail-tools-fixture", "X-Fixture-Header": "present"])
    return api
  }

  static func job(_ id: String, target: Int, status: String, source: Int = 100, index: Int = 4) -> [String: Any] {
    ["id": id, "sourceVideoFileId": source, "targetVideoFileId": target, "subtitleIndex": index,
      "title": "Fixture subtitle", "status": status, "error": NSNull()]
  }

  static func track(_ subtitleIndex: Int, streamIndex: Int, title: String) -> [String: Any] {
    ["subtitleIndex": subtitleIndex, "streamIndex": streamIndex, "codecName": "ass", "language": "jpn",
      "title": title, "isDefault": false, "isForced": false, "displayName": title]
  }

  static func recording(_ id: Int, startAt: Double, channelName: String = "Fixture") -> [String: Any] {
    ["id": id, "name": "Record \(id)", "startAt": startAt, "endAt": startAt + 1800, "isRecording": false,
      "channelId": 3, "channelName": channelName, "thumbnails": [], "videoFiles": []]
  }

  static func check(_ name: String, _ condition: Bool, count: inout Int) {
    count += 1
    guard condition else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
  }

  static func run() async throws {
    var count = 0
    let fileA = NeoVideoFile(id: 1, name: "name.mkv", type: "TS", size: 1, filename: "Film.MKV")
    let fileB = NeoVideoFile(id: 2, name: "Film.mkv", type: "TS", size: 1, filename: nil)
    let fileC = NeoVideoFile(id: 3, name: "Film.ts", type: "TS", size: 1, filename: "Film.ts")
    let fileD = NeoVideoFile(id: 4, name: "Film.mkv", type: "TS", size: 1, filename: "folder/episode.mKv")
    let media = NeoRecording(id: 1, name: "Fixture", startAt: 0, endAt: 1, isRecording: false, description: nil, extended: nil,
      channelId: nil, channelName: nil, thumbnails: nil, videoFiles: [fileA, fileB, fileC, fileD])
    check("MKV selection uses case-insensitive filename extension", NeoMediaTools.mkvFiles(media).map(\.id) == [1, 4], count: &count)
    check("MKV selection excludes missing files and nil recordings", NeoMediaTools.mkvFiles(nil).isEmpty && NeoMediaTools.mkvFiles(NeoRecording(
      id: 2, name: "Empty", startAt: 0, endAt: 1, isRecording: false, description: nil, extended: nil,
      channelId: nil, channelName: nil, thumbnails: nil, videoFiles: nil)).isEmpty, count: &count)
    check("subtitle title trims whitespace and accepts 128 UTF-16 units", NeoMediaTools.validTitle(" \n" + String(repeating: "a", count: 128) + "\t"), count: &count)
    check("subtitle title rejects blank and overlong UTF-16 input", !NeoMediaTools.validTitle(" \n\t") && !NeoMediaTools.validTitle(String(repeating: "a", count: 129)), count: &count)
    check("subtitle title limit counts surrogate pairs", NeoMediaTools.validTitle(String(repeating: "😀", count: 64)) && !NeoMediaTools.validTitle(String(repeating: "😀", count: 65)), count: &count)

    let tracks = [
      NeoManagedTrack(subtitleIndex: 0, streamIndex: 9, codecName: "ass", language: "jpn", title: "One", isDefault: false, isForced: false, displayName: "One"),
      NeoManagedTrack(subtitleIndex: 2, streamIndex: 11, codecName: "ass", language: "eng", title: "Two", isDefault: false, isForced: false, displayName: "Two"),
      NeoManagedTrack(subtitleIndex: 5, streamIndex: 18, codecName: "srt", language: nil, title: nil, isDefault: true, isForced: false, displayName: "Track 5")
    ]
    check("track order accepts a changed permutation of subtitle indexes", NeoMediaTools.validOrder([5, 0, 2], tracks: tracks), count: &count)
    check("track order rejects unchanged, duplicate, missing and foreign indexes", !NeoMediaTools.validOrder([0, 2, 5], tracks: tracks)
      && !NeoMediaTools.validOrder([0, 2, 2], tracks: tracks) && !NeoMediaTools.validOrder([0, 2], tracks: tracks)
      && !NeoMediaTools.validOrder([0, 2, 8], tracks: tracks), count: &count)

    NeoDetailToolsProtocol.reset()
    NeoDetailToolsProtocol.setTracks([track(4, streamIndex: 17, title: "Japanese CC"), track(7, streamIndex: 24, title: "English")])
    let api = makeAPI(), user = "viewer-override", headers = ["X-Viewer-Profile-Id": "42", "X-Viewer-Session": "api-fixture", "X-Fixture-Header": "present"]
    let managed = try await api.managedTracks(200, user: user, headers: headers)
    check("managed tracks decode subtitleIndex and streamIndex separately", managed.map(\.subtitleIndex) == [4, 7] && managed.map(\.streamIndex) == [17, 24], count: &count)
    let trackRequest = NeoDetailToolsProtocol.capturedRequests().first { $0.method == "GET" && $0.percentEncodedPath == "/api/videos/200/subtitles" }
    check("subtitle GET captures viewer headers and reload cache policy", trackRequest?.header("X-EPGStation-User-Id") == user
      && trackRequest?.header("X-Viewer-Profile-Id") == "42" && trackRequest?.header("X-Fixture-Header") == "present"
      && trackRequest?.cachePolicy == .reloadIgnoringLocalCacheData, count: &count)

    NeoDetailToolsProtocol.setCreateResponse(object: job("transfer-job", target: 200, status: "running", source: 101, index: 4))
    _ = try await api.startMediaEdit(.transfer, target: 200, source: 101, index: managed[0].subtitleIndex,
      title: "  Japanese CC \n", user: user, headers: headers)
    let transfer = NeoDetailToolsProtocol.capturedRequests().last { $0.method == "POST" && $0.percentEncodedPath == "/api/videos/200/subtitles/transfer" }
    check("transfer uses target path, source file id, subtitle index, and trimmed title", transfer?.body?.count == 3
      && transfer?.body?["sourceVideoFileId"] as? Int == 101 && transfer?.body?["subtitleIndex"] as? Int == 4
      && transfer?.body?["title"] as? String == "Japanese CC", count: &count)
    check("transfer POST captures JSON headers, auth, reload policy, and long timeout", transfer?.header("Content-Type") == "application/json"
      && transfer?.header("Accept") == "application/json" && transfer?.header("X-EPGStation-User-Id") == user
      && transfer?.header("X-Viewer-Session") == "api-fixture" && transfer?.cachePolicy == .reloadIgnoringLocalCacheData
      && transfer?.timeoutInterval == 120, count: &count)

    NeoDetailToolsProtocol.setCreateResponse(object: job("rename-job", target: 200, status: "completed"))
    _ = try await api.startMediaEdit(.rename, target: 200, index: 7, title: "  English  ", user: user, headers: headers)
    let rename = NeoDetailToolsProtocol.capturedRequests().last { $0.method == "POST" && $0.percentEncodedPath == "/api/videos/200/subtitles/7/rename" }
    check("rename uses subtitle index in path and sends only trimmed title", rename?.body?.count == 1 && rename?.body?["title"] as? String == "English", count: &count)

    NeoDetailToolsProtocol.setCreateResponse(object: job("reorder-job", target: 200, status: "running"))
    _ = try await api.startMediaEdit(.reorder, target: 200, order: [7, 4, 0], user: user, headers: headers)
    let reorder = NeoDetailToolsProtocol.capturedRequests().last { $0.method == "POST" && $0.percentEncodedPath == "/api/videos/200/subtitles/reorder" }
    check("reorder sends the exact subtitleIndices payload", reorder?.body?.count == 1 && reorder?.body?["subtitleIndices"] as? [Int] == [7, 4, 0], count: &count)

    let specialJob = NeoMediaJob(id: "job/a?version=1", sourceVideoFileId: 101, targetVideoFileId: 200, subtitleIndex: 4,
      title: "Fixture", status: "running", error: nil)
    NeoDetailToolsProtocol.enqueuePoll(object: job(specialJob.id, target: 200, status: "completed"))
    let polled = try await api.mediaJob(specialJob, user: user, headers: headers)
    let pollRequest = NeoDetailToolsProtocol.capturedRequests().last { $0.method == "GET" && $0.percentEncodedPath.contains("/subtitles/transfer/") }
    check("job polling percent-escapes slash and question mark in job ID", polled.status == "completed"
      && pollRequest?.percentEncodedPath.hasSuffix("job%2Fa%3Fversion%3D1") == true && pollRequest?.query.isEmpty == true, count: &count)

    NeoDetailToolsProtocol.reset()
    NeoDetailToolsProtocol.setCreateResponse(object: job("wrong-target", target: 201, status: "running"))
    do {
      _ = try await api.startMediaEdit(.rename, target: 200, index: 4, title: "Title", user: user, headers: headers)
      check("media edit rejects a response for another target", false, count: &count)
    } catch { check("media edit rejects a response for another target", NeoDetailToolsProtocol.count("POST") == 1, count: &count) }
    NeoDetailToolsProtocol.reset()
    NeoDetailToolsProtocol.setCreateResponse(object: job("invalid-status", target: 200, status: "queued"))
    do {
      _ = try await api.startMediaEdit(.rename, target: 200, index: 4, title: "Title", user: user, headers: headers)
      check("media edit rejects an unknown response status", false, count: &count)
    } catch { check("media edit rejects an unknown response status", NeoDetailToolsProtocol.count("POST") == 1, count: &count) }

    NeoDetailToolsProtocol.reset()
    let emptySearch = try await api.mediaSearch(keyword: " \n ", offset: 0, channels: [], user: user, headers: headers)
    check("empty media search returns without issuing a request", emptySearch.records.isEmpty && !emptySearch.more && NeoDetailToolsProtocol.capturedRequests().isEmpty, count: &count)

    NeoDetailToolsProtocol.reset()
    NeoDetailToolsProtocol.setSearch("keyword:ｄｒａｍａ", records: [recording(1, startAt: 100), recording(2, startAt: 200)], total: 65)
    NeoDetailToolsProtocol.setSearch("channel:3", records: [recording(2, startAt: 200, channelName: "Channel 3"), recording(3, startAt: 300)], total: 63)
    NeoDetailToolsProtocol.setSearch("channel:5", records: [recording(4, startAt: 400), recording(1, startAt: 100, channelName: "Channel 5")], total: 61)
    let search = try await api.mediaSearch(keyword: "  ｄｒａｍａ  ", offset: 30,
      channels: [NeoChannel(id: 3, name: "Drama 4K"), NeoChannel(id: 4, name: "News"), NeoChannel(id: 5, name: "DRAMA Plus")], user: user, headers: headers)
    let searches = NeoDetailToolsProtocol.capturedRequests().filter { $0.method == "GET" && $0.percentEncodedPath == "/api/recorded" }
    let channelIDs = Set(searches.compactMap { $0.query["channelId"] })
    check("media search merges title and matching-channel results, deduplicates, and sorts newest first", search.records.map(\.id) == [4, 3, 2, 1], count: &count)
    check("media search reports another page when merged queries have more", search.more, count: &count)
    check("media search sends one title query and only matching channels with 30-item pagination", searches.count == 3
      && searches.contains(where: { $0.query["keyword"] == "ｄｒａｍａ" }) && channelIDs == Set(["3", "5"])
      && searches.allSatisfy({ $0.query["offset"] == "30" && $0.query["limit"] == "30" && $0.query["isReverse"] == "false" }), count: &count)

    NeoDetailToolsProtocol.reset()
    let successAPI = makeAPI()
    NeoDetailToolsProtocol.setRecording(700, object: recording(700, startAt: 700))
    _ = try await successAPI.recording(700)
    let successCacheReady = successAPI.cachedRecording(700) != nil
    NeoDetailToolsProtocol.setCreateResponse(object: job("success-watch", target: 200, status: "running"))
    let successInitial = try await successAPI.startMediaEdit(.rename, target: 200, index: 4, title: "Watch", user: user, headers: headers)
    NeoDetailToolsProtocol.enqueuePoll(object: job(successInitial.id, target: 200, status: "completed"))
    let successEvents = NeoDetailToolsEvents()
    let successObserver = NotificationCenter.default.addObserver(forName: .neoRecordedChanged, object: nil, queue: nil) { note in
      guard (note.object as? NeoAPI) === successAPI else { return }
      successEvents.record(note.userInfo?["recordingID"] as? Int)
    }
    var successUpdates: [(String, String?)] = []
    successAPI.watchMediaJob(successInitial, recordings: [700], revision: successAPI.identityRevision, user: user, headers: headers, interval: 1_000_000,
      update: { job, error in successUpdates.append((job.status, error)) })
    let didComplete = await waitFor({ successUpdates.contains(where: { $0.0 == "completed" && $0.1 == nil }) && successEvents.contains(700) })
    check("successful media-job polling updates status and invalidates changed recordings", didComplete && successCacheReady && successAPI.cachedRecording(700) == nil, count: &count)
    check("successful watcher polls status without repeating the accepted POST", NeoDetailToolsProtocol.count("POST", pathContaining: "/subtitles/") == 1, count: &count)
    successAPI.stopRecordingUpdates()
    NotificationCenter.default.removeObserver(successObserver)

    NeoDetailToolsProtocol.reset()
    let retryAPI = makeAPI()
    NeoDetailToolsProtocol.setCreateResponse(object: job("retry-watch", target: 200, status: "running"))
    let retryInitial = try await retryAPI.startMediaEdit(.rename, target: 200, index: 4, title: "Retry", user: user, headers: headers)
    NeoDetailToolsProtocol.enqueuePoll(503, object: ["message": "fixture poll failure"])
    NeoDetailToolsProtocol.enqueuePoll(object: job(retryInitial.id, target: 200, status: "completed"))
    var retryUpdates: [(String, String?)] = []
    retryAPI.watchMediaJob(retryInitial, recordings: [], revision: retryAPI.identityRevision, user: user, headers: headers, interval: 1_000_000,
      update: { job, error in retryUpdates.append((job.status, error)) })
    let failedPoll = await waitFor({ retryUpdates.contains(where: { $0.1?.contains("fixture poll failure") == true }) })
    let retryResult = try await retryAPI.mediaJob(retryInitial, user: user, headers: headers)
    check("failed job-status GET can be retried with a status-only GET", failedPoll && retryResult.status == "completed"
      && NeoDetailToolsProtocol.count("GET", pathContaining: "/subtitles/transfer/") == 2, count: &count)
    check("status retry never resubmits the media-edit POST", NeoDetailToolsProtocol.count("POST", pathContaining: "/subtitles/") == 1, count: &count)
    retryAPI.stopRecordingUpdates()

    NeoDetailToolsProtocol.reset()
    let identityAPI = makeAPI()
    NeoDetailToolsProtocol.setCreateResponse(object: job("identity-late", target: 200, status: "running"))
    let identityInitial = try await identityAPI.startMediaEdit(.rename, target: 200, index: 4, title: "Identity", user: user, headers: headers)
    NeoDetailToolsProtocol.enqueuePoll(object: job(identityInitial.id, target: 200, status: "completed"), delay: 0.15)
    let identityEvents = NeoDetailToolsEvents()
    let identityObserver = NotificationCenter.default.addObserver(forName: .neoRecordedChanged, object: nil, queue: nil) { note in
      guard (note.object as? NeoAPI) === identityAPI else { return }
      identityEvents.record(note.userInfo?["recordingID"] as? Int)
    }
    var identityUpdates: [(String, String?)] = []
    identityAPI.watchMediaJob(identityInitial, recordings: [704], revision: identityAPI.identityRevision, user: user, headers: headers, interval: 1_000_000,
      update: { job, error in identityUpdates.append((job.status, error)) })
    let requestStarted = await waitFor({ NeoDetailToolsProtocol.count("GET", pathContaining: "/subtitles/transfer/") == 1 })
    identityAPI.activate(user: "9", headers: ["X-Viewer-Profile-Id": "22", "X-Viewer-Session": "new-identity"])
    let responseFinished = await waitFor({ NeoDetailToolsProtocol.completedCount("GET", pathContaining: "/subtitles/transfer/") == 1 }, attempts: 100)
    try? await Task.sleep(nanoseconds: 30_000_000)
    check("identity switch ignores an in-flight job completion", requestStarted && responseFinished
      && identityUpdates.count == 1 && identityUpdates.first?.0 == "running" && !identityEvents.contains(704), count: &count)
    identityAPI.stopRecordingUpdates()
    NotificationCenter.default.removeObserver(identityObserver)

    print("Detail tools: \(count) checks passed")
  }
}

Task { @MainActor in
  do {
    try await NeoDetailToolsTests.run()
    exit(0)
  } catch {
    fatalError("Unexpected detail-tools test failure: \(error)")
  }
}
dispatchMain()
