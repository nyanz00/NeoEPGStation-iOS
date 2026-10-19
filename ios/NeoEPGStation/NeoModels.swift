import Foundation

struct NeoError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}
enum NeoServerURL {
  static func normalize(_ input: String) throws -> URL {
    guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty else {
      throw NeoError("http:// または https:// から始まるサーバーURLを入力してください。")
    }
    guard parts.user == nil, parts.password == nil, parts.query == nil,
      parts.fragment == nil || parts.fragment!.hasPrefix("/") else { throw NeoError("URLに認証情報・クエリを含めないでください。") }
    parts.fragment = nil
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    if parts.path.hasSuffix("/api") { parts.path.removeLast(4) }
    guard let url = parts.url else { throw NeoError("サーバーURLの形式を確認してください。") }
    return url
  }
}
struct NeoVideoFile: Decodable {
  let id: Int; let name: String; let type: String; let size: Double; let filename: String?
}
struct NeoRecording: Decodable {
  let id: Int; let name: String; let startAt: Double; let endAt: Double; let isRecording: Bool
  let description: String?; let extended: String?; let channelId: Int?; let channelName: String?
  let thumbnails: [Int]?; let videoFiles: [NeoVideoFile]?
  var ruleId: Int? = nil
  var isProtected: Bool? = nil
  var isEncoding: Bool? = nil
  var dropLogFile: NeoDropLog? = nil
  var genre1: Int? = nil; var subGenre1: Int? = nil
  var genre2: Int? = nil; var subGenre2: Int? = nil
  var genre3: Int? = nil; var subGenre3: Int? = nil
}
struct NeoDropLog: Decodable {
  let id: Int; let errorCnt: Int; let dropCnt: Int; let scramblingCnt: Int
  var hasErrors: Bool { dropCnt > 0 || errorCnt > 0 || scramblingCnt > 0 }
}
struct NeoServerConfig: Decodable {
  struct StreamConfig: Decodable {
    struct Recorded: Decodable {
      struct Source: Decodable { let hls: [String]? }
      let ts: Source?; let encoded: Source?
    }
    let recorded: Recorded?
  }
  var streamConfig: StreamConfig? = nil
  func streamingQualities(_ type: String) -> [String] {
    let values = type == "ts" ? streamConfig?.recorded?.ts?.hls : streamConfig?.recorded?.encoded?.hls
    return values ?? []
  }
  let encode: [String]; let developerMode: Bool?
  var isEnableTSRecordedStream: Bool? = nil
  var isEnableEncodedRecordedStream: Bool? = nil
  init(encode: [String], developerMode: Bool?, isEnableTSRecordedStream: Bool? = nil, isEnableEncodedRecordedStream: Bool? = nil) {
    self.encode = encode; self.developerMode = developerMode
    self.isEnableTSRecordedStream = isEnableTSRecordedStream; self.isEnableEncodedRecordedStream = isEnableEncodedRecordedStream
  }
  private enum CodingKeys: String, CodingKey { case encode, developerMode, isEnableTSRecordedStream, isEnableEncodedRecordedStream, streamConfig }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // queries.ts normalizes missing/non-string encode modes independently of capabilities.
    var modes: [String] = []
    if var array = try? values.nestedUnkeyedContainer(forKey: .encode) {
      while !array.isAtEnd {
        let value = try array.superDecoder().singleValueContainer()
        if let mode = try? value.decode(String.self), !mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { modes.append(mode) }
      }
    }
    streamConfig = try values.decodeIfPresent(StreamConfig.self, forKey: .streamConfig)
    encode = modes
    developerMode = try values.decodeIfPresent(Bool.self, forKey: .developerMode)
    isEnableTSRecordedStream = try values.decodeIfPresent(Bool.self, forKey: .isEnableTSRecordedStream)
    isEnableEncodedRecordedStream = try values.decodeIfPresent(Bool.self, forKey: .isEnableEncodedRecordedStream)
  }
}
enum NeoRecordingCommand: String {
  case download, rule, search, user, encode, thumbnail, info = "Info", protect, unprotect, subtitle, delete
}
enum NeoRecordingMenu {
  static func commands(item: NeoRecording, detail: Bool, config: NeoServerConfig?, hideThumbnailButton: Bool = true) -> [NeoRecordingCommand] {
    var result: [NeoRecordingCommand] = detail ? [.download] : []
    if item.ruleId != nil { result.append(.rule) }
    result += [.search, .user]
    // Keep the requested encode placeholder even before server capabilities load.
    if !item.isRecording { result.append(.encode) }
    if detail && hideThumbnailButton && !(item.videoFiles ?? []).isEmpty { result.append(.thumbnail) }
    if detail && config?.developerMode == true { result.append(.subtitle) }
    if !item.isRecording && !(item.videoFiles ?? []).isEmpty { result.append(.info) }
    result.append(item.isProtected == true ? .unprotect : .protect)
    if !detail && config?.developerMode == true { result.append(.subtitle) }
    result.append(.delete)
    return result
  }
}
struct NeoRecords: Decodable { let records: [NeoRecording]; let total: Int }
struct NeoChannel: Decodable { let id: Int; let name: String }
struct NeoRule: Decodable {
  struct Search: Decodable { let keyword: String? }
  let id: Int; let searchOption: Search
}

enum NeoRelatedSearch {
  // core/media/recorded.ts createRecordedRelatedSearchOption.
  static func keyword(_ name: String) -> String {
    var title = name
    for pattern in [#"\[.+?\]"#, #"【.+?】"#, #"\(.\)"#, #" +"#] {
      title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let delimiter = title.contains(" #") ? " #" : title.contains("「") ? "「" : ""
    let keyword = delimiter.isEmpty ? title : title.components(separatedBy: delimiter)[0]
    return keyword.isEmpty ? title : keyword
  }
}

enum NeoSwipeAction { case menu, back }
enum NeoNavigationGesture {
  // The starting region fixes the action for the whole drag. No edge restriction.
  static func action(startY: Double, height: Double, canGoBack: Bool, tablet: Bool,
    horizontal: Double, vertical: Double, persistentMenu: Bool = false) -> NeoSwipeAction? {
    guard horizontal > 0, horizontal >= abs(vertical) else { return nil }
    if startY >= height * (persistentMenu ? 0.3 : 0.4) && canGoBack { return .back }
    return tablet ? nil : .menu
  }
}
struct NeoRecordingQuery: Hashable {
  let page: Int; let keyword: String; let reverse: Bool
  var userID: Int? = nil
  var filters = NeoRecordedFilters()
  var limit = 24
}
// RecordedPage.tsx's request options, including JST dates and inclusive upper bounds.
struct NeoRecordedFilters: Hashable {
  var keyword = "", ruleID: Int?, channelID: Int?, genre: Int?
  var encodeModes: [String] = [], encodeModeMatch = "include"
  var manualOnly = false, hasOriginalFile = false, hasDrop = false, hasError = false, hasScrambling = false
  var specificDate = false, startDate = "", endDate = "", year = "", month = "", day = ""
  var isEmpty: Bool { self == Self() }
  func queryItems() throws -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    func add(_ name: String, _ value: String) { items.append(URLQueryItem(name: name, value: value)) }
    if !keyword.isEmpty { add("keyword", keyword) }
    if manualOnly { add("ruleId", "0") } else if let ruleID { add("ruleId", String(ruleID)) }
    if let channelID { add("channelId", String(channelID)) }
    if let genre { add("genre", String(genre)) }
    for mode in Set(encodeModes).sorted() { add("encodeModes[]", mode) }
    if !encodeModes.isEmpty { add("encodeModeMatch", encodeModeMatch) }
    for (key, enabled) in [("hasOriginalFile", hasOriginalFile), ("hasDrop", hasDrop), ("hasError", hasError), ("hasScrambling", hasScrambling)] where enabled { add(key, "true") }
    let range = try dateRange()
    if let start = range.0 { add("recordedStartAt", String(start)) }
    if let end = range.1 { add("recordedEndAt", String(end)) }
    return items
  }
  func dateRange() throws -> (Int64?, Int64?) {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    func date(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
      guard (1...9999).contains(y), (1...12).contains(m), (1...31).contains(d),
        let value = calendar.date(from: DateComponents(year: y, month: m, day: d)),
        calendar.component(.year, from: value) == y, calendar.component(.month, from: value) == m,
        calendar.component(.day, from: value) == d else { throw NeoError("録画日の指定が不正です") }
      return value
    }
    func parse(_ text: String) throws -> Date? {
      if text.isEmpty { return nil }
      guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { throw NeoError("録画日の指定が不正です") }
      let parts = text.split(separator: "-").compactMap { Int($0) }
      return try date(parts[0], parts[1], parts[2])
    }
    func milliseconds(_ value: Date?) -> Int64? { value.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }
    if specificDate {
      if year.isEmpty {
        guard month.isEmpty && day.isEmpty else { throw NeoError("録画日の指定が不正です") }; return (nil, nil)
      }
      guard year.count == 4, let y = Int(year), month.isEmpty || Int(month) != nil,
        day.isEmpty || (!month.isEmpty && Int(day) != nil) else { throw NeoError("録画日の指定が不正です") }
      let start = try date(y, Int(month) ?? 1, Int(day) ?? 1)
      let unit: Calendar.Component = !day.isEmpty ? .day : !month.isEmpty ? .month : .year
      let end = calendar.date(byAdding: unit, value: 1, to: start)!
      return (milliseconds(start), milliseconds(end)! - 1)
    }
    let start = try parse(startDate), endDay = try parse(endDate)
    let end = endDay.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
    if let start, let end, start >= end { throw NeoError("録画日の指定が不正です") }
    return (milliseconds(start), milliseconds(end).map { $0 - 1 })
  }
}
struct NeoRecordedOptions: Decodable {
  struct Channel: Decodable { let channelId: Int; let cnt: Int }
  struct Genre: Decodable { let genre: Int; let cnt: Int }
  struct Encode: Decodable { let name: String; let suffix: String? }
  let channels: [Channel]; let genres: [Genre]; let encode: [Encode]
}
struct NeoRuleKeyword: Decodable { let id: Int; let keyword: String }
struct NeoRuleKeywords: Decodable { let items: [NeoRuleKeyword] }
enum NeoPagination {
  // VueCompatiblePagination.tsx: five consecutive mobile buttons.
  static func mobile(page: Int, count: Int) -> [Int] {
    let count = max(1, count), page = min(max(1, page), max(1, count))
    let start = max(1, page <= 2 ? 1 : count - page >= 2 ? page - 2 : count - 4)
    return Array(start...min(count, start + 4))
  }
  static func desktop(page: Int, count: Int, width: Double) -> [Int?] {
    let count = max(1, count), page = min(max(1, page), count)
    let size = max(5, min(12, Int((width - 96) / 42)))
    if count <= size { return (1...count).map { Optional($0) } }
    let even = size % 2 == 0 ? 1 : 0, left = size / 2, right = count - size / 2 + 1 + even
    func range(_ a: Int, _ b: Int) -> [Int?] { a <= b ? (a...b).map { Optional($0) } : [] }
    if page > left && page < right {
      let start = page - left + 2, end = page + left - 2 - even
      return [1, start - 1 == 2 ? 2 : nil] + range(start, end) + [end + 1 == count - 1 ? end + 1 : nil, count]
    }
    if page == left { return range(1, page + left - 1 - even) + [nil, count] }
    if page == right { return [1, nil] + range(page - left + 1, count) }
    return range(1, left) + [nil] + range(right, count)
  }
}
enum NeoProgramText {
  private static let date: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    f.dateFormat = "MM/dd(EEE) HH:mm"; return f
  }()
  private static let time: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    f.dateFormat = "HH:mm"; return f
  }()
  static func interval(start: Double, end: Double) -> String {
    let minutes = max(0, Int(((end - start) / 60000).rounded()))
    return "\(date.string(from: Date(timeIntervalSince1970: start / 1000))) - \(time.string(from: Date(timeIntervalSince1970: end / 1000))) (\(minutes) m)"
  }
  static func bytes(_ size: Double) -> String {
    if size >= 1073741824 { return String(format: "%.2f GB", size / 1073741824) }
    if size >= 1048576 { return String(format: "%.1f MB", size / 1048576) }
    return String(format: "%.0f KB", max(0, size / 1024))
  }
  static func dropSummary(_ item: NeoRecording) -> String {
    let drop = item.dropLogFile
    let total = (item.videoFiles ?? []).reduce(0) { $0 + $1.size }
    return "drop: \(drop?.dropCnt ?? 0), error: \(drop?.errorCnt ?? 0), scrambling: \(drop?.scramblingCnt ?? 0)"
      + (total > 0 ? " \(bytes(total))" : "")
  }
}
struct NeoViewer: Decodable { let id: Int; let name: String }
struct NeoViewers: Decodable { let users: [NeoViewer] }
struct NeoViewerProfile: Decodable {
  let id: Int; let name: String; let tvUserId: Int?; let lockRequired: Bool
}
struct NeoViewerProfiles: Decodable { let profiles: [NeoViewerProfile] }
struct NeoViewerSession: Decodable { let sessionToken: String; let recoveryCode: String? }
struct NeoSessionValidity: Decodable { let valid: Bool }
struct NeoPlayback: Decodable {
  let position: Double; let duration: Double; let watchedSeconds: Double; let updatedAt: Double?
  var resumePosition: Double? {
    guard position.isFinite, duration.isFinite, position >= 5, duration <= 0 || position < duration - 10 else { return nil }
    return position
  }
}
struct NeoHistoryItem: Decodable { let recorded: NeoRecording; let playback: NeoPlayback }
struct NeoHistory: Decodable { let items: [NeoHistoryItem] }
struct NeoHistorySettings: Decodable { let enabled: Bool; let limit: Int }
struct NeoListPosition: Decodable { let page: Int; let userId: Int? }
extension Notification.Name {
  static let neoAccountChanged = Notification.Name("NeoAccountChanged")
  static let neoHistoryChanged = Notification.Name("NeoHistoryChanged")
  static let neoRecordingPreferencesChanged = Notification.Name("NeoRecordingPreferencesChanged")
}
private final class NeoAPIRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class NeoAPI {
  let base: URL; let session: URLSession
  private let headersLock = NSLock()
  private var authenticationHeaders: [String: String] = [:]
  var profileHeaders: [String: String] {
    get { headersLock.lock(); defer { headersLock.unlock() }; return authenticationHeaders }
    set { headersLock.lock(); authenticationHeaders = newValue; headersLock.unlock() }
  }
  var accountReady = false
  var identityRevision = 0
  var onLocked: ((Int) -> Void)?
  var viewer: String {
    get { UserDefaults.standard.string(forKey: "viewer." + base.absoluteString) ?? "master" }
    set {
      headersLock.lock()
      UserDefaults.standard.set(newValue, forKey: "viewer." + base.absoluteString)
      headersLock.unlock()
      identityRevision += 1
      NotificationCenter.default.post(name: .neoAccountChanged, object: self)
    }
  }
  func activate(user: String, headers: [String: String]) {
    headersLock.lock()
    authenticationHeaders = headers
    UserDefaults.standard.set(user, forKey: "viewer." + base.absoluteString)
    headersLock.unlock()
    accountReady = true; identityRevision += 1
    NotificationCenter.default.post(name: .neoAccountChanged, object: self)
  }
  private func identitySnapshot() -> (String, [String: String]) {
    headersLock.lock(); defer { headersLock.unlock() }
    return (viewer, authenticationHeaders)
  }
  var resumePlayback: Bool {
    get { UserDefaults.standard.object(forKey: "resume." + base.absoluteString) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "resume." + base.absoluteString) }
  }
  var disablePlaybackHistory: Bool {
    get { UserDefaults.standard.bool(forKey: "history.disabled." + base.absoluteString) }
    set { UserDefaults.standard.set(newValue, forKey: "history.disabled." + base.absoluteString) }
  }
  var recordedLength: Int {
    get { min(1000, max(1, UserDefaults.standard.object(forKey: "recorded.length." + base.absoluteString) as? Int ?? 24)) }
    set { UserDefaults.standard.set(min(1000, max(1, newValue)), forKey: "recorded.length." + base.absoluteString)
      NotificationCenter.default.post(name: .neoRecordingPreferencesChanged, object: self) }
  }
  var highlightRecorded: Bool {
    get { UserDefaults.standard.object(forKey: "recorded.highlight." + base.absoluteString) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "recorded.highlight." + base.absoluteString)
      NotificationCenter.default.post(name: .neoRecordingPreferencesChanged, object: self) }
  }
  init(base: URL, session: URLSession? = nil) {
    self.base = base
    self.session = session ?? URLSession(configuration: .ephemeral, delegate: NeoAPIRedirectPolicy(), delegateQueue: nil)
    accountReady = viewer == "master" || viewer == "0"
  }
  func url(_ path: String) -> URL { URL(string: base.absoluteString + "/api" + path)! }
  func recordings(page: Int, keyword: String = "", reverse: Bool = false, userID: Int? = nil, filters: NeoRecordedFilters? = nil) async throws -> NeoRecords {
    var parts = URLComponents(url: url("/recorded"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name: "isHalfWidth", value: "true"), URLQueryItem(name: "isReverse", value: reverse ? "true" : "false"),
      URLQueryItem(name: "limit", value: String(recordedLength)), URLQueryItem(name: "offset", value: String(max(0, page - 1) * recordedLength))]
    var search = filters ?? NeoRecordedFilters(); if filters == nil { search.keyword = keyword }
    parts.queryItems! += try search.queryItems()
    if let userID, userID > 0 { parts.queryItems!.append(URLQueryItem(name: "userId", value: String(userID))) }
    let result: NeoRecords = try await request(parts.url!)
    guard result.total >= 0, result.records.allSatisfy({ $0.id > 0 }) else { throw NeoError("録画一覧の応答形式が一致しません。") }
    return result
  }
  func recording(_ id: Int) async throws -> NeoRecording {
    let value: NeoRecording = try await request(url("/recorded/\(id)?isHalfWidth=true"))
    guard value.id == id else { throw NeoError("録画情報の応答形式が一致しません。") }
    return value
  }
  func channels() async throws -> [NeoChannel] { try await request(url("/channels")) }
  func viewers() async throws -> NeoViewers { try await request(url("/users"), headers: [:]) }
  func viewerProfiles() async throws -> NeoViewerProfiles { try await request(url("/viewer-profiles"), headers: [:]) }
  func unlockProfile(_ id: Int, password: String) async throws -> NeoViewerSession {
    try await request(url("/viewer-profiles/\(id)/unlock"), method: "POST",
      body: ["password": password.precomposedStringWithCanonicalMapping], headers: [:])
  }
  func validateProfile(_ id: Int, token: String) async throws -> Bool {
    let value: NeoSessionValidity = try await request(url("/viewer-profiles/\(id)/session"),
      headers: ["X-Viewer-Profile-Id": String(id), "X-Viewer-Session": token])
    return value.valid
  }
  func playback(_ id: Int, user: String) async throws -> NeoPlayback {
    try await request(url("/recorded/\(id)/playback"), user: user, timeout: 3, headers: [:])
  }
  func history(user: String) async throws -> NeoHistory {
    try await request(url("/recorded/playbackHistory?isHalfWidth=true"), user: user, timeout: 10, headers: [:])
  }
  func historySettings(user: String) async throws -> NeoHistorySettings {
    try await request(url("/recorded/playbackHistory/settings"), user: user, headers: [:])
  }
  func updateHistorySettings(user: String, enabled: Bool? = nil, limit: Int? = nil) async throws -> NeoHistorySettings {
    var body: [String: Any] = [:]
    if let enabled { body["enabled"] = enabled }
    if let limit { body["limit"] = limit }
    return try await request(url("/recorded/playbackHistory/settings"), method: "PUT", body: body, user: user, headers: [:])
  }
  func removeHistory(_ id: Int, user: String) async throws {
    _ = try await response(url("/recorded/\(id)/playback"), method: "DELETE", user: user, headers: [:])
    NotificationCenter.default.post(name: .neoHistoryChanged, object: self)
  }
  func listPosition(_ id: Int) async throws -> NeoListPosition { try await request(url("/recorded/\(id)/listPosition?limit=\(recordedLength)")) }
  func recordedOptions(userID: Int?) async throws -> NeoRecordedOptions {
    try await request(url("/recorded/options" + (userID.map { "?userId=\($0)" } ?? "")))
  }
  func ruleKeywords(keyword: String, userID: Int?) async throws -> [NeoRuleKeyword] {
    var parts = URLComponents(url: url("/rules/keyword"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name: "limit", value: "1000")]
    if !keyword.isEmpty { parts.queryItems!.append(URLQueryItem(name: "keyword", value: keyword)) }
    if let userID { parts.queryItems!.append(URLQueryItem(name: "userId", value: String(userID))) }
    let result: NeoRuleKeywords = try await request(parts.url!); return result.items
  }
  func rule(_ id: Int) async throws -> NeoRule { try await request(url("/rules/\(id)")) }
  func relatedRecordings(ruleId: Int?, keyword: String) async throws -> NeoRecords {
    var parts = URLComponents(url: url("/recorded"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name: "isHalfWidth", value: "true"), URLQueryItem(name: "isReverse", value: "true"),
      URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: "0")]
    if let ruleId { parts.queryItems!.append(URLQueryItem(name: "ruleId", value: String(ruleId))) }
    else { parts.queryItems!.append(URLQueryItem(name: "keyword", value: keyword)) }
    return try await request(parts.url!)
  }
  func configuration() async throws -> NeoServerConfig { try await request(url("/config")) }
  func dropLog(_ id: Int) async throws -> String {
    var request = URLRequest(url: url("/dropLogs/\(id)?maxsize=512")); request.timeoutInterval = 20
    request.setValue("text/plain", forHTTPHeaderField: "Accept")
    request.setValue(viewer, forHTTPHeaderField: "X-EPGStation-User-Id")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      http.mimeType?.lowercased() != "text/html", let text = String(data: data, encoding: .utf8) else {
      throw NeoError("ドロップログを取得できませんでした。接続・認証設定を確認してください。")
    }
    return text
  }
  private func request<T: Decodable>(_ url: URL, method: String = "GET", body: [String: Any]? = nil,
    user: String? = nil, timeout: Double = 20, headers: [String: String]? = nil) async throws -> T {
    let data = try await response(url, method: method, body: body, user: user, timeout: timeout, headers: headers)
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw NeoError("APIの応答形式が一致しません。NeoEPGStationのURLを確認してください。") }
  }
  private func response(_ url: URL, method: String = "GET", body: [String: Any]? = nil,
    user: String? = nil, timeout: Double = 20, headers: [String: String]? = nil) async throws -> Data {
    var request = URLRequest(url: url); request.timeoutInterval = timeout; request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let identity = identitySnapshot()
    request.setValue(user ?? identity.0, forHTTPHeaderField: "X-EPGStation-User-Id")
    for (key, value) in headers ?? identity.1 { request.setValue(value, forHTTPHeaderField: key) }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw NeoError("サーバーの応答を確認できませんでした。") }
    guard (200..<300).contains(http.statusCode) else {
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let message = (json?["errors"] as? String) ?? (json?["message"] as? String)
      if message == "視聴者プロフィールのロックを解除してください",
        let profile = request.value(forHTTPHeaderField: "X-Viewer-Profile-Id").flatMap(Int.init) {
        DispatchQueue.main.async { [weak self] in self?.onLocked?(profile) }
      }
      throw NeoError(message ?? ([401,403].contains(http.statusCode) ? "アクセスできません。認証設定を確認してください。" : "サーバーがエラーを返しました（HTTP \(http.statusCode)）。"))
    }
    return data
  }
}
