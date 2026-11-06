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
  let id: Int; var name: String; let startAt: Double; let endAt: Double; let isRecording: Bool
  var description: String?; var extended: String?; let channelId: Int?; let channelName: String?
  let thumbnails: [Int]?; let videoFiles: [NeoVideoFile]?
  var ruleId: Int? = nil
  var isProtected: Bool? = nil
  var isEncoding: Bool? = nil
  var dropLogFile: NeoDropLog? = nil
  var genre1: Int? = nil; var subGenre1: Int? = nil
  var genre2: Int? = nil; var subGenre2: Int? = nil
  var genre3: Int? = nil; var subGenre3: Int? = nil
  func displayed(halfWidth: Bool) -> Self {
    guard halfWidth else { return self }
    var copy = self; copy.name = NeoProgramText.halfWidth(name)
    copy.description = description.map(NeoProgramText.halfWidth); copy.extended = extended.map(NeoProgramText.halfWidth)
    return copy
  }
}
struct NeoDropLog: Decodable {
  let id: Int; let errorCnt: Int; let dropCnt: Int; let scramblingCnt: Int
  var hasErrors: Bool { dropCnt > 0 || errorCnt > 0 || scramblingCnt > 0 }
}
struct NeoServerConfig: Decodable {
  struct WatchConfig: Decodable {
    var availableEncoders: [String]?; var liveQualities: [String]?
  }
  var watchConfig: WatchConfig? = nil
  struct StreamConfig: Decodable {
    struct Live: Decodable {
      struct TS: Decodable {
        struct Mode: Decodable { let name: String; let isUnconverted: Bool? }
        let m2ts: [Mode]?; let m2tsll: [String]?
      }
      let ts: TS?
    }
    struct Recorded: Decodable {
      struct Source: Decodable { let hls: [String]? }
      let ts: Source?; let encoded: Source?
    }
    let recorded: Recorded?
    var live: Live? = nil
  }
  var streamConfig: StreamConfig? = nil
  func streamingQualities(_ type: String) -> [String] {
    let values = type == "ts" ? streamConfig?.recorded?.ts?.hls : streamConfig?.recorded?.encoded?.hls
    return values ?? []
  }
  let encode: [String]; let developerMode: Bool?
  var isEnableTSRecordedStream: Bool? = nil
  var isEnableEncodedRecordedStream: Bool? = nil
  var isEnableTSLiveStream: Bool? = nil
  var broadcast: [String: Bool]? = nil
  var urlscheme: [String:[String:String]]? = nil
  init(encode: [String], developerMode: Bool?, isEnableTSRecordedStream: Bool? = nil, isEnableEncodedRecordedStream: Bool? = nil) {
    self.encode = encode; self.developerMode = developerMode
    self.isEnableTSRecordedStream = isEnableTSRecordedStream; self.isEnableEncodedRecordedStream = isEnableEncodedRecordedStream
  }
  private enum CodingKeys: String, CodingKey { case encode, developerMode, isEnableTSRecordedStream, isEnableEncodedRecordedStream, streamConfig, isEnableTSLiveStream, broadcast, urlscheme, watchConfig }
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
    watchConfig = try values.decodeIfPresent(WatchConfig.self,forKey:.watchConfig)
    encode = modes
    developerMode = try values.decodeIfPresent(Bool.self, forKey: .developerMode)
    isEnableTSRecordedStream = try values.decodeIfPresent(Bool.self, forKey: .isEnableTSRecordedStream)
    isEnableEncodedRecordedStream = try values.decodeIfPresent(Bool.self, forKey: .isEnableEncodedRecordedStream)
    isEnableTSLiveStream = try values.decodeIfPresent(Bool.self, forKey: .isEnableTSLiveStream)
    broadcast = try values.decodeIfPresent([String: Bool].self, forKey: .broadcast)
    urlscheme = try values.decodeIfPresent([String:[String:String]].self, forKey:.urlscheme)
  }
}

// Shared by settings pages, playback controls and request construction. Keep
// existing player keys so moving controls never resets a saved preference.
@objc(NeoViewingPreferences)
final class NeoViewingPreferences: NSObject {
  static var defaults: UserDefaults { .standard }
  static var encoder: String {
    get { defaults.string(forKey:"watch.encoder") ?? "Config" }
    set { defaults.set(newValue,forKey:"watch.encoder") }
  }
  static var quality: String {
    get { defaults.string(forKey:"watch.quality") ?? "" }
    set { defaults.set(newValue,forKey:"watch.quality") }
  }
  static var hevc: Bool {
    get { defaults.bool(forKey:"watch.hevc") }
    set { defaults.set(newValue,forKey:"watch.hevc") }
  }
  static var lowLatency: Bool {
    get { defaults.object(forKey:"watch.lowLatency") as? Bool ?? true }
    set { defaults.set(newValue,forKey:"watch.lowLatency") }
  }
  static var bufferedStart: Bool {
    get { defaults.bool(forKey:"watch.bufferedStart") }
    set { defaults.set(newValue,forKey:"watch.bufferedStart") }
  }
  static var subtitleKeywords: [String] {
    get { let values = defaults.stringArray(forKey:"watch.subtitleKeywords") ?? []; return values+Array(repeating:"",count:max(0,3-values.count)) }
    set { defaults.set(newValue+Array(repeating:"",count:max(0,3-newValue.count)),forKey:"watch.subtitleKeywords") }
  }
  static func addSubtitlePriority() { var values = subtitleKeywords; values.append(""); subtitleKeywords = values }
  static func removeSubtitlePriority(at index: Int) { var values = subtitleKeywords; guard index >= 3, values.indices.contains(index) else { return }; values.remove(at:index); subtitleKeywords = values }
  static func preferredMetadata(_ values: [[String]]) -> Int? {
    for keyword in subtitleKeywords {
      let word = keyword.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
      if !word.isEmpty, let index = values.firstIndex(where: { $0.contains { $0.lowercased().contains(word) } }) { return index }
    }
    return nil
  }
  static func initialQuality(_ values: [String], saved: Int) -> Int {
    values.firstIndex(of:quality) ?? (values.indices.contains(saved) && !values[saved].isEmpty ? saved : values.firstIndex(where: { !$0.isEmpty }) ?? 0)
  }
  static var streamQuery: [URLQueryItem] {
    var result: [URLQueryItem] = []
    if encoder != "Config" { result.append(.init(name:"encoder",value:encoder)) }
    if hevc { result.append(.init(name:"hevc",value:"true")) }
    return result
  }
  @objc static var networkSeconds: Int {
    get { min(30,max(1,defaults.object(forKey:"player.network.seconds") as? Int ?? 5)) }
    set { defaults.set(min(30,max(1,newValue)),forKey:"player.network.seconds") }
  }
  static var commentSize: Double {
    get { let value = defaults.object(forKey:"player.comments.size") as? Double ?? 1; return value.isFinite ? min(2,max(0.5,value)) : 1 }
    set { defaults.set(newValue.isFinite ? min(2,max(0.5,newValue)) : 1,forKey:"player.comments.size"); NotificationCenter.default.post(name:.init("neoViewingCommentsChanged"),object:nil) }
  }
  static var commentsEnabled: Bool {
    get { defaults.object(forKey:"player.comments.enabled") as? Bool ?? true }
    set { defaults.set(newValue,forKey:"player.comments.enabled"); NotificationCenter.default.post(name:.init("neoViewingCommentsChanged"),object:nil) }
  }
  static var commentOpacity: Float {
    get { let value = defaults.object(forKey:"player.comments.absoluteOpacity") as? Float ?? 1; return value.isFinite ? min(1,max(0,value)) : 1 }
    set { defaults.set(newValue.isFinite ? min(1,max(0,newValue)) : 1,forKey:"player.comments.absoluteOpacity"); NotificationCenter.default.post(name:.init("neoViewingCommentsChanged"),object:nil) }
  }
  static var navigationLabels: Bool {
    get { defaults.object(forKey:"neoepgstation.navigation.labels") as? Bool ?? true }
    set { defaults.set(newValue,forKey:"neoepgstation.navigation.labels") }
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
    return (drop.map { "drop: \($0.dropCnt), error: \($0.errorCnt), scrambling: \($0.scramblingCnt)" } ?? "drop: —, error: —, scrambling: —")
      + (total > 0 ? " \(bytes(total))" : "")
  }
  // src/util/StrUtil.ts toHalf. Do not use NFKC: it also changes kana and
  // compatibility characters that the Web leaves alone.
  static func halfWidth(_ text: String) -> String {
    let replacements: [UInt32:UInt32] = [0x201d:0x22,0x2019:0x27,0x2018:0x60,0xffe5:0x5c,0x3000:0x20,0x301c:0x7e]
    return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
      UnicodeScalar((0xff01...0xff5e).contains(scalar.value) ? scalar.value-0xfee0 : replacements[scalar.value] ?? scalar.value)!
    }))
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
struct NeoVideoInfo: Decodable {
  let fileName: String
  let formatName, videoCodec, videoProfile, pixelFormat, hdr, analysisError: String?
  let size: Double
  let duration, frameRate, analyzedAt: Double?
  let width, height, bitDepth: Int?
  let streams: [Stream]
  let ts: TS?
  let keyframes: Keys?
  struct Stream: Decodable { let index: Int; let type: String; let codec, language, title: String?; let channels: Int? }
  struct TS: Decodable { let networkId, transportStreamId, serviceId, pmtPid, pcrPid, videoPid, audioPid, subtitlePid: Int? }
  struct Keys: Decodable {
    let status: String; let stale: Bool
    let averageInterval, minInterval, maxInterval: Double?
    let sampledDuration: Double
    let intervalCount, keyframeCount: Int
    let sampleWindows: [Window]
    let analyzedAt: Double?; let error: String?
    struct Window: Decodable { let start, end: Double; let keyframeCount: Int }
  }
  static func seconds(_ value: Double?) -> String { value.map { String(format:"%.3f sec",$0) } ?? "-" }
  static func bytes(_ value: Double) -> String {
    if value >= pow(1024,3) { return String(format:"%.2f GB",value/pow(1024,3)) }
    if value >= pow(1024,2) { return String(format:"%.1f MB",value/pow(1024,2)) }
    return "\(max(0,Int((value/1024).rounded()))) KB"
  }
  var rows: [(String,String)] {
    func number(_ value: Int?) -> String { value.map(String.init) ?? "-" }
    let audio = streams.filter { $0.type == "audio" }.map { "\($0.index): \($0.codec ?? "-") \($0.language ?? "") \($0.channels.map(String.init) ?? "")ch" }.joined(separator:"\n")
    let subs = streams.filter { $0.type == "subtitle" }.map { "\($0.index): \($0.codec ?? "-") \($0.language ?? "") \($0.title ?? "")" }.joined(separator:"\n")
    let video = [videoCodec,videoProfile].compactMap { $0 }.joined(separator:" / ")
    let pixel = [pixelFormat,bitDepth.map { "\($0) bit" },hdr].compactMap { $0 }.joined(separator:" / ")
    return [("File",fileName),("Format",formatName ?? "-"),("Size",Self.bytes(size)),("Duration",Self.seconds(duration)),
      ("Video",video.isEmpty ? "-" : video),("Resolution",width != nil && height != nil ? "\(width!) x \(height!)" : "-"),
      ("Frame rate",frameRate.map { String(format:"%.3f fps",$0) } ?? "-"),("Pixel / HDR",pixel.isEmpty ? "-" : pixel),
      ("Audio",audio.isEmpty ? "-" : audio),("Subtitle",subs.isEmpty ? "-" : subs),
      ("TS IDs",ts.map { "network=\(number($0.networkId)) transport=\(number($0.transportStreamId)) service=\(number($0.serviceId))" } ?? "-"),
      ("TS PIDs",ts.map { "PMT=\(number($0.pmtPid)) PCR=\(number($0.pcrPid)) video=\(number($0.videoPid)) audio=\(number($0.audioPid)) subtitle=\(number($0.subtitlePid))" } ?? "-")]
  }
  var keyRows: [(String,String)] {
    guard let keys = keyframes, keys.status == "ready" || keys.stale else { return [] }
    return [("Average interval",Self.seconds(keys.averageInterval)),("Minimum interval",Self.seconds(keys.minInterval)),
      ("Maximum interval",Self.seconds(keys.maxInterval)),("Sample windows",String(keys.sampleWindows.count)),
      ("Sampled duration",Self.seconds(keys.sampledDuration)),("Keyframes",String(keys.keyframeCount)),("Intervals",String(keys.intervalCount))]
  }
  var status: String {
    var values = analysisError.map { ["Video error: \($0)"] } ?? []
    if let keys = keyframes {
      if keys.status != "ready" || keys.stale {
        let name = keys.status == "ready" && keys.stale ? "Stale" : keys.status.capitalized
        let note = keys.stale && keys.status != "ready" ? " (stale results available)" : ""
        let error = ["error","unavailable"].contains(keys.status) ? keys.error.map { ": \($0)" } ?? "" : ""
        values.append("Keyframe analysis \(name)\(note)\(error)")
      }
    } else { values.append("Keyframe analysis unavailable") }
    return values.isEmpty ? "OK" : values.joined(separator:"; ")
  }
  var analyzed: String {
    guard let time = [analyzedAt,keyframes?.analyzedAt].compactMap({ $0 }).filter({ $0.isFinite }).max() else { return "-" }
    let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
    return formatter.string(from:Date(timeIntervalSince1970:time/1000))
  }
}
struct NeoAnnictStatus: Decodable { let configured, writeConfigured: Bool; let viewerProfileId: Int? }
struct NeoAnnictEpisode: Decodable {
  let state: String
  let annictId, programAnnictId, episodeAnnictId: Int?
  let episodeNumber: Double?
  let episodeNumberText, episodeTitle, pendingReason: String?
  let lastCheckedAt: Double?
  let viewerProfileId: Int?
  let writeConfigured, watched, canUnwatch: Bool
  var label: String { episodeNumberText ?? episodeNumber.map { "第\(String(format:"%g",$0))話" } ?? "エピソード" }
}
enum NeoAnnictPreferences {
  static var mode: String {
    get { let value = UserDefaults.standard.string(forKey:"annict.autoWatchMode") ?? "disabled"; return ["disabled","start","progress"].contains(value) ? value : "disabled" }
    set { UserDefaults.standard.set(newValue,forKey:"annict.autoWatchMode") }
  }
  static var threshold: Int {
    get { min(100,max(1,UserDefaults.standard.object(forKey:"annict.threshold") as? Int ?? 90)) }
    set { UserDefaults.standard.set(min(100,max(1,newValue)),forKey:"annict.threshold") }
  }
  static var markFinal: Bool {
    get { UserDefaults.standard.object(forKey:"annict.markFinal") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue,forKey:"annict.markFinal") }
  }
  static var disableFinalRules: Bool {
    get { UserDefaults.standard.object(forKey:"annict.disableFinalRules") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue,forKey:"annict.disableFinalRules") }
  }
  static var watchOptions: [String:Any] { ["markWorkWatchedOnFinalEpisode":markFinal,"disableRulesOnFinalEpisode":markFinal && disableFinalRules] }
  static func shouldRecord(started: Bool, watched: Double, duration: Double) -> Bool {
    guard started else { return false }
    return mode == "start" || mode == "progress" && duration.isFinite && duration > 0 && watched.isFinite && watched/duration*100 >= Double(threshold)
  }
}
struct NeoListPosition: Decodable { let page: Int; let userId: Int? }
extension Notification.Name {
  static let neoAccountChanged = Notification.Name("NeoAccountChanged")
  static let neoHistoryChanged = Notification.Name("NeoHistoryChanged")
  static let neoRecordingPreferencesChanged = Notification.Name("NeoRecordingPreferencesChanged")
  static let neoAnnictChanged = Notification.Name("NeoAnnictChanged")
  static let neoTextPreferencesChanged = Notification.Name("NeoTextPreferencesChanged")
}
private final class NeoAPIRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class NeoAPI {
  let base: URL; let session: URLSession
  @MainActor private var checkpointRequests: [String: Task<NeoCheckpointVideoInfo, Error>] = [:]
  @MainActor private var detailCache: [String:(value:NeoRecording,stored:Date)] = [:]
  @MainActor private var episodeCache: [String:(value:NeoAnnictEpisode,stored:Date)] = [:]
  @MainActor private var detailRequests: [String:Task<NeoRecording,Error>] = [:]
  @MainActor private var episodeRequests: [String:Task<NeoAnnictEpisode,Error>] = [:]
  @MainActor private var episodeRevisions: [String:Int] = [:]
  @MainActor private var preparationQueue: [Int] = []
  @MainActor private var preparationWorkers: [UUID:Task<Void,Never>] = [:]
  @MainActor var onPreparedDetail: (() -> Void)?
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
  var liveRequestHeaders: [String:String] {
    let identity = identitySnapshot()
    return identity.1.merging(["X-EPGStation-User-Id":identity.0]) { _, current in current }
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
  var isHalfWidthDisplayed: Bool {
    get { UserDefaults.standard.object(forKey:"display.halfWidth."+base.absoluteString) as? Bool ?? true }
    set {
      guard newValue != isHalfWidthDisplayed else { return }
      UserDefaults.standard.set(newValue,forKey:"display.halfWidth."+base.absoluteString)
      NotificationCenter.default.post(name:.neoTextPreferencesChanged,object:self)
    }
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
    let halfWidth = isHalfWidthDisplayed
    parts.queryItems = [URLQueryItem(name: "isHalfWidth", value: String(halfWidth)), URLQueryItem(name: "isReverse", value: reverse ? "true" : "false"),
      URLQueryItem(name: "limit", value: String(recordedLength)), URLQueryItem(name: "offset", value: String(max(0, page - 1) * recordedLength))]
    var search = filters ?? NeoRecordedFilters(); if filters == nil { search.keyword = keyword }
    parts.queryItems! += try search.queryItems()
    if let userID, userID > 0 { parts.queryItems!.append(URLQueryItem(name: "userId", value: String(userID))) }
    let result: NeoRecords = try await request(parts.url!)
    guard result.total >= 0, result.records.allSatisfy({ $0.id > 0 }) else { throw NeoError("録画一覧の応答形式が一致しません。") }
    return NeoRecords(records:result.records.map { $0.displayed(halfWidth:halfWidth) },total:result.total)
  }
  @MainActor private func detailKey(_ id: Int) -> String { "\(identityRevision):\(isHalfWidthDisplayed):\(id)" }
  @MainActor func cachedRecording(_ id: Int) -> NeoRecording? {
    guard let entry = detailCache[detailKey(id)], Date().timeIntervalSince(entry.stored) < 60 else { return nil }; return entry.value
  }
  @MainActor func recording(_ id: Int, refresh: Bool = false) async throws -> NeoRecording {
    if !refresh, let cached = cachedRecording(id) { return cached }
    let key = detailKey(id), revision = identityRevision, halfWidth = isHalfWidthDisplayed
    if let active = detailRequests[key] { return try await active.value }
    let user = viewer, headers = profileHeaders
    let active = Task<NeoRecording,Error> {
      let value: NeoRecording = try await self.request(self.url("/recorded/\(id)?isHalfWidth=\(halfWidth)"),user:user,headers:headers)
      guard value.id == id else { throw NeoError("録画情報の応答形式が一致しません。") }
      guard self.identityRevision == revision, self.isHalfWidthDisplayed == halfWidth else { throw CancellationError() }
      return value.displayed(halfWidth:halfWidth)
    }
    detailRequests[key] = active; defer { detailRequests.removeValue(forKey:key) }
    let value = try await active.value
    detailCache[key] = (value,Date())
    if detailCache.count > 64, let oldest = detailCache.min(by:{ $0.value.stored < $1.value.stored })?.key { detailCache.removeValue(forKey:oldest) }
    return value
  }
  func channels() async throws -> [NeoChannel] { try await request(url("/channels")) }
  func broadcasting() async throws -> [NeoLiveSchedule] { try await request(url("/schedules/broadcasting?isHalfWidth=\(isHalfWidthDisplayed)")) }
  func liveForces() async throws -> [NeoLiveForce] { try await request(url("/channels/jikkyo")) }
  func liveJikkyo(_ channel: Int) async throws -> NeoLiveJikkyoInfo { try await request(url("/channels/\(channel)/jikkyo"), timeout: 8) }
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
    let halfWidth = isHalfWidthDisplayed
    let result: NeoHistory = try await request(url("/recorded/playbackHistory?isHalfWidth=\(halfWidth)"), user: user, timeout: 10, headers: [:])
    return NeoHistory(items:result.items.map { NeoHistoryItem(recorded:$0.recorded.displayed(halfWidth:halfWidth),playback:$0.playback) })
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
    let halfWidth = isHalfWidthDisplayed
    parts.queryItems = [URLQueryItem(name: "isHalfWidth", value: String(halfWidth)), URLQueryItem(name: "isReverse", value: "true"),
      URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: "0")]
    if let ruleId { parts.queryItems!.append(URLQueryItem(name: "ruleId", value: String(ruleId))) }
    else { parts.queryItems!.append(URLQueryItem(name: "keyword", value: keyword)) }
    let result: NeoRecords = try await request(parts.url!)
    return NeoRecords(records:result.records.map { $0.displayed(halfWidth:halfWidth) },total:result.total)
  }
  func configuration() async throws -> NeoServerConfig { try await request(url("/config")) }
  func videoInfo(_ id: Int, force: Bool = false) async throws -> NeoVideoInfo {
    try await request(url("/videos/\(id)/info"),method:force ? "POST" : "GET")
  }
  func annictStatus() async throws -> NeoAnnictStatus { try await request(url("/annict/status")) }
  @MainActor func annictToken(_ token: String?, write: Bool, user: String? = nil, headers: [String:String]? = nil) async throws {
    _ = try await response(url(write ? "/annict/write-token" : "/annict/token"),method:token == nil ? "DELETE" : "PUT",body:token.map { ["accessToken":$0] },user:user,headers:headers)
    episodeCache.removeAll(); episodeRequests.values.forEach { $0.cancel() }; episodeRequests.removeAll()
    for key in Array(episodeRevisions.keys) { episodeRevisions[key,default:0] += 1 }
  }
  @MainActor private func episodeKey(_ id: Int) -> String { "\(identityRevision):\(id)" }
  @MainActor func cachedAnnictEpisode(_ id: Int) -> NeoAnnictEpisode? {
    guard let entry = episodeCache[episodeKey(id)], Date().timeIntervalSince(entry.stored) < 60 else { return nil }; return entry.value
  }
  @MainActor func annictEpisode(_ id: Int, method: String = "GET", user: String? = nil, headers: [String:String]? = nil, refresh: Bool = false) async throws -> NeoAnnictEpisode {
    let user = user ?? viewer, headers = headers ?? profileHeaders
    guard accountReady, user == viewer, headers == profileHeaders else { throw CancellationError() }
    let key = episodeKey(id), revision = identityRevision
    if method == "GET", !refresh, let cached = cachedAnnictEpisode(id) { return cached }
    if method == "GET", let active = episodeRequests[key] { return try await active.value }
    if method != "GET" {
      episodeRevisions[key,default:0] += 1
      episodeRequests.removeValue(forKey:key)?.cancel()
    }
    let generation = episodeRevisions[key,default:0]
    let active = Task<NeoAnnictEpisode,Error> {
      let value: NeoAnnictEpisode = try await self.request(self.url("/recorded/\(id)/annictEpisode"),method:method,body:method == "PUT" ? NeoAnnictPreferences.watchOptions : nil,user:user,headers:headers)
      guard self.identityRevision == revision, self.episodeRevisions[key,default:0] == generation else { throw CancellationError() }
      self.episodeCache[key] = (value,Date())
      if self.episodeCache.count > 64, let oldest = self.episodeCache.min(by:{ $0.value.stored < $1.value.stored })?.key { self.episodeCache.removeValue(forKey:oldest) }
      return value
    }
    if method == "GET" { episodeRequests[key] = active }
    defer { if method == "GET", episodeRevisions[key,default:0] == generation { episodeRequests.removeValue(forKey:key) } }
    return try await active.value
  }
  // Only the visible window is prepared. Two workers, at most four HTTP
  // requests, 16 pending records and 64 cached results bound work and memory.
  @MainActor func prepareDetails(_ ids: [Int]) {
    guard accountReady else { return }
    preparationQueue = Array(NSOrderedSet(array:ids).array.compactMap { $0 as? Int }.prefix(16))
    let revision = identityRevision, halfWidth = isHalfWidthDisplayed
    while preparationWorkers.count < 2 && !preparationQueue.isEmpty {
      let token = UUID()
      preparationWorkers[token] = Task { [weak self] in
        guard let self else { return }
        defer {
          preparationWorkers.removeValue(forKey:token)
          if !preparationQueue.isEmpty { prepareDetails(preparationQueue) }
        }
        while !preparationQueue.isEmpty, identityRevision == revision, isHalfWidthDisplayed == halfWidth {
          let id = preparationQueue.removeFirst()
          async let detail = try? recording(id)
          async let episode = try? annictEpisode(id)
          _ = await (detail,episode)
          if identityRevision == revision, isHalfWidthDisplayed == halfWidth { onPreparedDetail?() }
        }
      }
    }
  }
  @MainActor func checkpointVideoInfo(_ id: Int) async throws -> NeoCheckpointVideoInfo {
    let key = "\(identityRevision):\(id)"
    if let active = checkpointRequests[key] { return try await active.value }
    let active = Task { try await self.request(self.url("/videos/\(id)/info"), timeout: 10) as NeoCheckpointVideoInfo }
    checkpointRequests[key] = active
    defer { checkpointRequests.removeValue(forKey: key) }
    // A detail prefetch and a play request share the in-flight GET. Cancelling
    // one waiter must not cancel the other's request; the HTTP timeout bounds it.
    return try await active.value
  }
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
    if url.path.contains("/annict") || url.path.hasSuffix("/info") { request.cachePolicy = .reloadIgnoringLocalCacheData }
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
