import Foundation

struct NeoEncodeItem: Decodable {
  let id: Int, mode: String, recorded: NeoRecording
  let percent: Double?, log: String?, scheduledAt: Double?, scheduledAtLabel: String?

  func hasSameCardDetails(as other: Self) -> Bool {
    mode == other.mode && scheduledAt == other.scheduledAt && scheduledAtLabel == other.scheduledAtLabel
      && recorded.name == other.recorded.name && recorded.startAt == other.recorded.startAt
      && recorded.endAt == other.recorded.endAt && recorded.channelName == other.recorded.channelName
      && recorded.channelId == other.recorded.channelId && recorded.thumbnails?.first == other.recorded.thumbnails?.first
  }
}
struct NeoEncodeRecovery: Decodable {
  let id: Int, status: String, mode: String?, recorded: NeoRecording?, reason: String, canRetry: Bool

  func hasSameRow(as other: Self) -> Bool {
    id == other.id && status == other.status && mode == other.mode && recorded?.name == other.recorded?.name
      && reason == other.reason && canRetry == other.canRetry
  }
}
struct NeoEncodeInfo: Decodable {
  let runningItems: [NeoEncodeItem], waitItems: [NeoEncodeItem]
  var scheduledItems: [NeoEncodeItem] = [], recoveryItems: [NeoEncodeRecovery] = []
  static let empty = NeoEncodeInfo(runningItems: [], waitItems: [])
  var allItems: [NeoEncodeItem] { runningItems + waitItems + scheduledItems }

  func hasSameRows(as other: Self) -> Bool {
    runningItems.map(\.id) == other.runningItems.map(\.id)
      && waitItems.map(\.id) == other.waitItems.map(\.id)
      && scheduledItems.map(\.id) == other.scheduledItems.map(\.id)
      && recoveryItems.count == other.recoveryItems.count
      && zip(recoveryItems, other.recoveryItems).allSatisfy { $0.0.hasSameRow(as: $0.1) }
  }
  private enum CodingKeys: CodingKey { case runningItems, waitItems, scheduledItems, recoveryItems }
  init(runningItems: [NeoEncodeItem], waitItems: [NeoEncodeItem], scheduledItems: [NeoEncodeItem] = [], recoveryItems: [NeoEncodeRecovery] = []) {
    self.runningItems = runningItems; self.waitItems = waitItems; self.scheduledItems = scheduledItems; self.recoveryItems = recoveryItems
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    runningItems = try c.decode([NeoEncodeItem].self, forKey: .runningItems)
    waitItems = try c.decode([NeoEncodeItem].self, forKey: .waitItems)
    scheduledItems = try c.decodeIfPresent([NeoEncodeItem].self, forKey: .scheduledItems) ?? []
    recoveryItems = try c.decodeIfPresent([NeoEncodeRecovery].self, forKey: .recoveryItems) ?? []
  }
  func cancellationOrder(_ ids: [Int]) -> [Int] {
    let running = Set(runningItems.map(\.id)), available = Set(allItems.map(\.id))
    var seen = Set<Int>(); let targets = ids.filter { available.contains($0) && seen.insert($0).inserted }
    return targets.filter { !running.contains($0) } + targets.filter { running.contains($0) }
  }
  func canSaveOrder(_ ids: [Int], expected: [Int]) -> Bool {
    waitItems.map(\.id) == expected && ids != expected && ids.count == expected.count && Set(ids).count == ids.count && Set(ids) == Set(expected)
  }
}
struct NeoAddEncodeSettings: Codable, Equatable {
  var mode = "", parentDir = "", sameDirectory = false, removeOriginal = false, updateThumbnail = true
  static func load(_ defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: "encode.add.settings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
    return value
  }
  func save(_ defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "encode.add.settings") } }
}
struct NeoEncodeJob {
  let recordedID: Int, recordedName: String, option: [String: Any]
}
struct NeoEncodeFailure { let job: NeoEncodeJob, error: String }
struct NeoEncodeBatchResult { var succeeded: [NeoEncodeJob] = [], failed: [NeoEncodeFailure] = [] }
enum NeoEncodePlan {
  static func successMessage(bulk: Bool, count: Int) -> String {
    bulk ? "\(count) 件をエンコードキューに追加しました。" : "エンコードキューに追加しました。"
  }
  static func commonSourceNames(_ items: [NeoRecording]) -> [String] {
    guard let first = items.first else { return [] }
    var seen = Set<String>()
    return (first.videoFiles ?? []).map(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }
      .filter { name in items.allSatisfy { ($0.videoFiles ?? []).contains { $0.name == name } } }
  }
  static func jobs(_ items: [NeoRecording], sourceName: String? = nil, sourceID: Int? = nil,
    settings: NeoAddEncodeSettings, directory: String) throws -> [NeoEncodeJob] {
    guard !items.isEmpty, !items.contains(where: \.isRecording) else { throw NeoError("録画中の番組はエンコードに追加できません。") }
    guard !settings.mode.isEmpty, settings.sameDirectory || !settings.parentDir.isEmpty else { throw NeoError("プリセットと保存先を選択してください。") }
    if let sourceName, !commonSourceNames(items).contains(sourceName) { throw NeoError("選択した録画すべてに共通する元ファイルがありません。") }
    var seen = Set<Int>()
    return try items.filter { seen.insert($0.id).inserted }.map { item in
      guard item.id > 0, let source = (item.videoFiles ?? []).first(where: { video in
        if let sourceName { return video.name == sourceName }
        return video.id == sourceID
      }), source.id > 0 else {
        throw NeoError("選択した録画ファイルは存在しません。")
      }
      var body: [String: Any] = ["recordedId": item.id, "sourceVideoFileId": source.id, "mode": settings.mode,
        "removeOriginal": settings.removeOriginal, "updateThumbnail": settings.updateThumbnail, "isSaveSameDirectory": settings.sameDirectory]
      if !settings.sameDirectory {
        body["parentDir"] = settings.parentDir
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["directory"] = trimmed }
      }
      return NeoEncodeJob(recordedID: item.id, recordedName: item.name, option: body)
    }
  }
  @MainActor static func submit(_ jobs: [NeoEncodeJob], isCurrent: () -> Bool,
    enqueue: (NeoEncodeJob) async throws -> Void, progress: (Int) -> Void) async throws -> NeoEncodeBatchResult {
    var result = NeoEncodeBatchResult()
    for job in jobs {
      try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
      do { try await enqueue(job); result.succeeded.append(job) }
      catch is CancellationError { throw CancellationError() }
      catch { result.failed.append(NeoEncodeFailure(job: job, error: error.localizedDescription)) }
      try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
      progress(result.succeeded.count + result.failed.count)
    }
    return result
  }
}
extension Notification.Name { static let neoEncodeChanged = Notification.Name("neoEncodeChanged") }
extension NeoAPI {
  private struct EncodeAdded: Decodable { let encodeId: Int }
  private struct EncodeAcknowledgement: Decodable { }
  func encodes(user: String, headers: [String: String]) async throws -> NeoEncodeInfo {
    var parts = URLComponents(url: url("/encode"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [.init(name: "isHalfWidth", value: String(isHalfWidthDisplayed))]
    return try await request(parts.url!, user: user, headers: headers)
  }
  func addEncode(_ job: NeoEncodeJob, user: String, headers: [String: String]) async throws -> Int {
    let value: EncodeAdded = try await request(url("/encode"), method: "POST", body: job.option, user: user, headers: headers)
    return value.encodeId
  }
  func cancelEncode(_ id: Int, user: String, headers: [String: String]) async throws {
    let _: EncodeAcknowledgement = try await request(url("/encode/\(id)"), method: "DELETE", user: user, timeout: 86400, headers: headers)
  }
  func retryEncode(_ id: Int, user: String, headers: [String: String]) async throws {
    let _: EncodeAcknowledgement = try await request(url("/encode/\(id)/retry"), method: "POST", user: user, headers: headers)
  }
  func reorderEncodes(_ ids: [Int], expected: [Int], user: String, headers: [String: String]) async throws {
    guard ids.count == expected.count, Set(ids).count == ids.count, Set(ids) == Set(expected) else { throw NeoError("エンコードキューの順番が一致しません。") }
    let _: EncodeAcknowledgement = try await request(url("/encode/order"), method: "PUT", body: ["encodeIds": ids, "expectedEncodeIds": expected], user: user, headers: headers)
  }
}
