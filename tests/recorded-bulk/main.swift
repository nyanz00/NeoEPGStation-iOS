import Foundation

private final class NeoRecordedBulkProtocol: URLProtocol {
  struct Captured {
    let method: String
    let path: String
    let headers: [String: String]
    let body: [String: Any]?
  }
  private struct Reply { let status: Int; let data: Data }
  private static let lock = NSLock()
  private static var requests: [Captured] = []
  private static var replies: [String: Reply] = [:]

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "hostrecorded-bulk.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
      result[pair.key.lowercased()] = pair.value
    }
    let captured = Captured(method: request.httpMethod ?? "GET", path: request.url!.path, headers: headers, body: body)
    let reply = Self.withLock {
      Self.requests.append(captured)
      return Self.replies[captured.path] ?? Reply(status: 200, data: Data("{}".utf8))
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private static func withLock<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }; return body()
  }
  static func reset() { withLock { requests = []; replies = [:] } }
  static func respond(_ path: String, status: Int = 200, json: String) {
    withLock { replies[path] = Reply(status: status, data: Data(json.utf8)) }
  }
  static func captured() -> [Captured] { withLock { requests } }
}

@MainActor private enum NeoRecordedBulkTests {
  static func check(_ name: String, _ condition: @autoclosure () -> Bool, count: inout Int) {
    count += 1
    guard condition() else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
  }

  static func recording(_ id: Int, files: [(Int, String, String)] = [], isRecording: Bool = false) -> NeoRecording {
    NeoRecording(id: id, name: "Recording \(id)", startAt: Double(id), endAt: Double(id + 10),
      isRecording: isRecording, description: nil, extended: nil, channelId: 1, channelName: "Fixture",
      thumbnails: [], videoFiles: files.map { NeoVideoFile(id: $0.0, name: $0.1, type: $0.2, size: 1, filename: nil) })
  }
  static func targets(_ values: [NeoRecording], _ option: NeoBulkDeleteOption, names: Set<String> = []) -> [NeoBulkDeleteTarget] {
    NeoRecordedBulk.targets(values, option: option, names: names)
  }
  static func makeAPI() -> NeoAPI {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoRecordedBulkProtocol.self]
    let api = NeoAPI(base: URL(string: "https://hostrecorded-bulk.invalid")!, session: URLSession(configuration: configuration))
    api.activate(user: "17", headers: ["X-Viewer-Profile-Id": "8", "X-Viewer-Session": "recorded-bulk-fixture"])
    return api
  }

  static func run() async throws {
    var count = 0
    let records = [
      recording(1, files: [(11, "same.ts", "ts"), (12, "encoded.mp4", "encoded"), (13, "same.ts", "ts")]),
      recording(2, files: [(21, "encoded.mp4", "encoded"), (22, "other.ts", "ts")]),
      recording(3)
    ]
    let names = NeoRecordedBulk.fileNames(records)
    check("selected size uses Web units and one decimal without spaces", NeoRecordedBulk.formattedSize(1_000_000) == "976.6KB"
      && NeoRecordedBulk.formattedSize(0) == "0.0B", count: &count)
    check("file names count duplicates and preserve first-seen order", names.map { $0.name } == ["same.ts", "encoded.mp4", "other.ts"] && names.map { $0.count } == [2, 2, 1], count: &count)
    let all = targets(records, .all)
    check("all targets include even recordings without files and mark whole-record deletion", all.map(\.item.id) == [1, 2, 3]
      && all.allSatisfy(\.deleteRecording) && all[2].videoFileIDs.isEmpty, count: &count)
    let originals = targets(records, .original)
    check("original targets include TS files only", originals.map(\.item.id) == [1, 2]
      && originals.map(\.videoFileIDs) == [[11, 13], [22]] && originals.allSatisfy { !$0.deleteRecording }, count: &count)
    let encoded = targets(records, .encoded)
    check("encoded targets include encoded files only", encoded.map(\.item.id) == [1, 2]
      && encoded.map(\.videoFileIDs) == [[12], [21]], count: &count)
    let byName = targets(records, .names, names: ["encoded.mp4", "other.ts"])
    check("name targets match selected names across records", byName.map(\.item.id) == [1, 2]
      && byName.map(\.videoFileIDs) == [[12], [21, 22]], count: &count)
    check("empty name selection yields no targets", targets(records, .names).isEmpty, count: &count)
    check("file name list is empty when no records contain files", NeoRecordedBulk.fileNames([recording(3)]).isEmpty, count: &count)

    var attemptedFiles: [Int] = []
    let partial = try await NeoRecordedBulk.delete(targets(records, .original), isCurrent: { true },
      deleteRecording: { _ in fatalError("unexpected whole-record delete") },
      deleteVideo: { id in attemptedFiles.append(id); if id == 11 { throw NeoError("fixture failure") } }, didChange: { _, _ in })
    check("file failure is reported while later files and records continue", Set(attemptedFiles) == Set([11, 13, 22])
      && attemptedFiles.firstIndex(of:11)! < attemptedFiles.firstIndex(of:13)!
      && partial.succeeded == [2] && partial.failed.map { $0.item.id } == [1]
      && partial.failed[0].error.contains("fixture failure"), count: &count)
    check("partial deletion never retries a failed video", attemptedFiles.filter { $0 == 11 }.count == 1, count: &count)

    var promotedCalls: [Int] = []
    let promoted = try await NeoRecordedBulk.delete(targets([recording(4, files: [(41, "a", "ts"), (42, "b", "ts")], isRecording: true)], .original),
      isCurrent: { true }, deleteRecording: { _ in fatalError("unexpected whole-record delete") },
      deleteVideo: { promotedCalls.append($0) }, didChange: { _, _ in })
    check("deleting an in-progress recording video stops subsequent file IDs", promotedCalls == [41] && promoted.succeeded == [4], count: &count)

    var current = true
    var invalidatedCalls: [Int] = []
    do {
      _ = try await NeoRecordedBulk.delete(targets([recording(5, files: [(51, "a", "ts"), (52, "b", "ts")])], .original),
        isCurrent: { current }, deleteRecording: { _ in },
        deleteVideo: { id in invalidatedCalls.append(id); current = false }, didChange: { _, _ in })
      check("stale identity cancels after the current mutation", false, count: &count)
    } catch is CancellationError {
      check("stale identity cancels before further mutations", invalidatedCalls == [51], count: &count)
    }

    var neverCalled = false
    do {
      _ = try await NeoRecordedBulk.delete(targets([recording(6, files: [(61, "a", "ts")])], .original),
        isCurrent: { false }, deleteRecording: { _ in neverCalled = true },
        deleteVideo: { _ in neverCalled = true }, didChange: { _, _ in })
      check("stale identity is rejected before mutation", false, count: &count)
    } catch is CancellationError {
      check("stale identity is rejected before mutation", !neverCalled, count: &count)
    }

    var active = 0, peak = 0
    let concurrencyTargets = targets((10..<18).map { recording($0, files: [($0 * 10, "file", "ts")]) }, .original)
    let concurrent = try await NeoRecordedBulk.delete(concurrencyTargets, isCurrent: { true }, deleteRecording: { _ in },
      deleteVideo: { _ in
        active += 1; peak = max(peak, active)
        try await Task.sleep(nanoseconds: 15_000_000)
        active -= 1
      }, didChange: { _, _ in })
    check("bulk deletion caps concurrent record mutations at four", peak == 4 && concurrent.succeeded.count == 8, count: &count)

    NeoRecordedBulkProtocol.reset()
    NeoRecordedBulkProtocol.respond("/api/recorded/directories", json: #"{"directories":["","News","Shows"]}"#)
    NeoRecordedBulkProtocol.respond("/api/recorded/bulk/user", json: #"{"updatedCount":2,"movedFileCount":0}"#)
    NeoRecordedBulkProtocol.respond("/api/recorded/bulk/subDirectory", json: #"{"updatedCount":2,"movedFileCount":3}"#)
    let api = makeAPI()
    let headers = api.profileHeaders.merging(["X-Fixture-Header":"present"]) { _,new in new }
    let directories = try await api.recordedDirectories(user: "17", headers: headers)
    let assigned = try await api.bulkAssignRecordingUser([101, 202], userID: 9, user: "17", headers: headers)
    let moved = try await api.bulkMoveRecordings([101, 202], subDirectory: "Drama/2026", user: "17", headers: headers)
    let requests = NeoRecordedBulkProtocol.captured()
    let directoryRequest = requests.first { $0.path == "/api/recorded/directories" }
    let userRequest = requests.first { $0.path == "/api/recorded/bulk/user" }
    let moveRequest = requests.first { $0.path == "/api/recorded/bulk/subDirectory" }
    check("directory API issues GET and decodes directory list", directories == ["", "News", "Shows"]
      && directoryRequest?.method == "GET", count: &count)
    check("bulk user API sends exact PUT route, body, and auth headers", assigned.updatedCount == 2
      && userRequest?.method == "PUT" && userRequest?.body?["recordedIds"] as? [Int] == [101, 202]
      && userRequest?.body?["userId"] as? Int == 9 && userRequest?.headers["x-epgstation-user-id"] == "17"
      && userRequest?.headers["x-viewer-session"] == "recorded-bulk-fixture" && userRequest?.headers["x-fixture-header"] == "present", count: &count)
    check("bulk move API sends exact PUT route, body, and result", moved.updatedCount == 2 && moved.movedFileCount == 3
      && moveRequest?.method == "PUT" && moveRequest?.body?["recordedIds"] as? [Int] == [101, 202]
      && moveRequest?.body?["subDirectory"] as? String == "Drama/2026", count: &count)

    NeoRecordedBulkProtocol.reset()
    do {
      _ = try await api.bulkAssignRecordingUser([1], userID: 0, user: "17", headers: headers)
      check("invalid master user is rejected without network access", false, count: &count)
    } catch {
      check("invalid master user is rejected without network access", NeoRecordedBulkProtocol.captured().isEmpty, count: &count)
    }
    NeoRecordedBulkProtocol.reset()
    do {
      _ = try await api.bulkAssignRecordingUser([], userID: 1, user: "17", headers: headers)
      check("empty bulk user selection is rejected without network access", false, count: &count)
    } catch {
      check("empty bulk user selection is rejected without network access", NeoRecordedBulkProtocol.captured().isEmpty, count: &count)
    }
    NeoRecordedBulkProtocol.reset()
    NeoRecordedBulkProtocol.respond("/api/recorded/bulk/subDirectory", status: 503, json: #"{"message":"fixture unavailable"}"#)
    do {
      _ = try await api.bulkMoveRecordings([1], subDirectory: "", user: "17", headers: headers)
      check("bulk move reports server status errors", false, count: &count)
    } catch {
      let apiError = error as? NeoError
      check("bulk move reports HTTP 503 and server message", apiError?.statusCode == 503
        && apiError?.message == "fixture unavailable" && NeoRecordedBulkProtocol.captured().count == 1, count: &count)
    }
    NeoRecordedBulkProtocol.reset()
    NeoRecordedBulkProtocol.respond("/api/recorded/directories", json: #"{"unexpected":[]}"#)
    do {
      _ = try await api.recordedDirectories(user: "17", headers: headers)
      check("directory API rejects malformed response", false, count: &count)
    } catch {
      let apiError = error as? NeoError
      check("directory API rejects malformed response with the API decode error", apiError?.message == "APIの応答形式が一致しません。NeoEPGStationのURLを確認してください。"
        && NeoRecordedBulkProtocol.captured().count == 1, count: &count)
    }

    print("Recorded bulk: \(count) checks passed")
  }
}

@main private struct NeoRecordedBulkMain {
  @MainActor static func main() async {
    do { try await NeoRecordedBulkTests.run() }
    catch { fatalError("Unexpected recorded-bulk test failure: \(error)") }
  }
}
