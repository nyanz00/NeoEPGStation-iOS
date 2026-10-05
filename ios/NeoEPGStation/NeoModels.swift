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
}
struct NeoDropLog: Decodable {
  let id: Int; let errorCnt: Int; let dropCnt: Int; let scramblingCnt: Int
  var hasErrors: Bool { dropCnt > 0 || errorCnt > 0 || scramblingCnt > 0 }
}
struct NeoServerConfig: Decodable { let encode: [String]; let developerMode: Bool? }
enum NeoRecordingCommand: String {
  case download, rule, search, user, encode, info = "Info", protect, unprotect, subtitle, delete
}
enum NeoRecordingMenu {
  static func commands(item: NeoRecording, detail: Bool, config: NeoServerConfig?) -> [NeoRecordingCommand] {
    var result: [NeoRecordingCommand] = detail ? [.download] : []
    if item.ruleId != nil { result.append(.rule) }
    result += [.search, .user]
    if !item.isRecording && !(config?.encode ?? []).isEmpty { result.append(.encode) }
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

enum NeoSwipeAction { case menu, back }
enum NeoNavigationGesture {
  // The starting region fixes the action for the whole drag. No edge restriction.
  static func action(startY: Double, height: Double, canGoBack: Bool, tablet: Bool,
    horizontal: Double, vertical: Double) -> NeoSwipeAction? {
    guard horizontal > 0, horizontal >= abs(vertical) else { return nil }
    if startY >= height * 0.4 && canGoBack { return .back }
    return tablet ? nil : .menu
  }
}
struct NeoRecordingQuery: Hashable {
  let page: Int; let keyword: String; let reverse: Bool
}
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
final class NeoAPI {
  let base: URL; let session: URLSession
  init(base: URL, session: URLSession = .shared) { self.base = base; self.session = session }
  func url(_ path: String) -> URL { URL(string: base.absoluteString + "/api" + path)! }
  func recordings(page: Int, keyword: String = "", reverse: Bool = false) async throws -> NeoRecords {
    var parts = URLComponents(url: url("/recorded"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name: "isHalfWidth", value: "true"), URLQueryItem(name: "isReverse", value: reverse ? "true" : "false"),
      URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "offset", value: String(max(0, page - 1) * 30))]
    if !keyword.isEmpty { parts.queryItems!.append(URLQueryItem(name: "keyword", value: keyword)) }
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
  func configuration() async throws -> NeoServerConfig { try await request(url("/config")) }
  func dropLog(_ id: Int) async throws -> String {
    var request = URLRequest(url: url("/dropLogs/\(id)?maxsize=512")); request.timeoutInterval = 20
    request.setValue("text/plain", forHTTPHeaderField: "Accept")
    request.setValue("master", forHTTPHeaderField: "X-EPGStation-User-Id")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      http.mimeType?.lowercased() != "text/html", let text = String(data: data, encoding: .utf8) else {
      throw NeoError("ドロップログを取得できませんでした。接続・認証設定を確認してください。")
    }
    return text
  }
  private func request<T: Decodable>(_ url: URL) async throws -> T {
    var request = URLRequest(url: url); request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("master", forHTTPHeaderField: "X-EPGStation-User-Id")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw NeoError("サーバーの応答を確認できませんでした。") }
    guard (200..<300).contains(http.statusCode) else {
      throw NeoError([401,403].contains(http.statusCode) ? "アクセスできません。認証設定を確認してください。" : "サーバーがエラーを返しました（HTTP \(http.statusCode)）。")
    }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw NeoError("APIの応答形式が一致しません。NeoEPGStationのURLを確認してください。") }
  }
}
