import Foundation

struct NeoManagedTrack: Decodable, Equatable {
  let subtitleIndex: Int, streamIndex: Int
  let codecName: String?, language: String?, title: String?
  let isDefault: Bool, isForced: Bool, displayName: String
  var name: String { title ?? displayName }
}
struct NeoManagedTracks: Decodable { let items: [NeoManagedTrack] }
struct NeoMediaJob: Decodable {
  let id: String, sourceVideoFileId: Int, targetVideoFileId: Int, subtitleIndex: Int
  let title: String, status: String, error: String?
}
enum NeoMediaEditKind: String { case transfer, rename, reorder
  var progress: String { switch self { case .transfer: return "字幕を移植"; case .rename: return "字幕名を変更"; case .reorder: return "字幕を並び替え" } }
  var completed: String { switch self { case .transfer: return "字幕を移植しました。"; case .rename: return "字幕名を変更しました。"; case .reorder: return "字幕を並び替えました。" } }
}
enum NeoMediaTools {
  static func mkvFiles(_ item: NeoRecording?) -> [NeoVideoFile] { (item?.videoFiles ?? []).filter { $0.filename?.lowercased().hasSuffix(".mkv") == true } }
  static func validTitle(_ text: String) -> Bool { let value = text.trimmingCharacters(in:.whitespacesAndNewlines); return !value.isEmpty && value.utf16.count <= 128 }
  static func errorMessage(_ text: String) -> String {
    let messages = [
      ("SubtitleTransferTargetIsProtected","対象の録画が保護されています。録画詳細で保護を解除してください。"),
      ("SubtitleTransferRequiresMatroska","字幕の移植・名前変更はMKVファイルでのみ利用できます。"),
      ("SubtitleTransferVideoFileIsBusy","選択した録画ファイルは別の字幕処理で使用中です。"),
      ("SubtitleTransferEncodeIsRunning","選択した録画を使用するエンコードが実行中です。"),
      ("SubtitleTransferRecordingIsRunning","録画中のファイルへ字幕を移植することはできません。"),
      ("SubtitleReorderTracksChanged","字幕一覧が変更されたため並び替えを中止しました。一覧を再読み込みしてください。"),
      ("SubtitleReorderOrderIsUnchanged","字幕の順序は変更されていません。"),
      ("SubtitleReorderOutputValidationFailed","並び替え後の字幕を検証できなかったため、元のファイルを維持しました。")]
    return messages.first { text.contains($0.0) }?.1 ?? text
  }
  static func validOrder(_ order: [Int], tracks: [NeoManagedTrack]) -> Bool {
    let old = tracks.map(\.subtitleIndex)
    return order.count == old.count && Set(order).count == order.count && Set(order) == Set(old) && order != old
  }
}

extension NeoAPI {
  func managedTracks(_ video: Int, user: String, headers: [String:String]) async throws -> [NeoManagedTrack] {
    let value: NeoManagedTracks = try await request(url("/videos/\(video)/subtitles"),user:user,headers:headers)
    return value.items
  }
  func startMediaEdit(_ kind: NeoMediaEditKind, target: Int, source: Int? = nil, index: Int? = nil, title: String = "", order: [Int] = [], user: String, headers: [String:String]) async throws -> NeoMediaJob {
    var path = "/videos/\(target)/subtitles/", body: [String:Any]
    switch kind {
    case .transfer:
      guard let source, source > 0, source != target, let index, index >= 0, NeoMediaTools.validTitle(title) else { throw NeoError("移植元・移植先と字幕名を確認してください。") }
      path += "transfer"; body = ["sourceVideoFileId":source,"subtitleIndex":index,"title":title.trimmingCharacters(in:.whitespacesAndNewlines)]
    case .rename:
      guard let index, index >= 0, NeoMediaTools.validTitle(title) else { throw NeoError("字幕名を確認してください。") }
      path += "\(index)/rename"; body = ["title":title.trimmingCharacters(in:.whitespacesAndNewlines)]
    case .reorder:
      guard !order.isEmpty, order.allSatisfy({$0 >= 0}), Set(order).count == order.count else { throw NeoError("字幕の順序を確認してください。") }
      path += "reorder"; body = ["subtitleIndices":order]
    }
    let result: NeoMediaJob = try await request(url(path),method:"POST",body:body,user:user,timeout:120,headers:headers)
    guard result.targetVideoFileId == target, ["running","completed","failed"].contains(result.status), !result.id.isEmpty else { throw NeoError("処理の応答を確認できませんでした。再実行する前に録画情報を更新してください。") }
    return result
  }
  func mediaJob(_ job: NeoMediaJob, user: String, headers: [String:String]) async throws -> NeoMediaJob {
    let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    guard let id = job.id.addingPercentEncoding(withAllowedCharacters:allowed) else { throw NeoError("処理のIDを確認できませんでした。") }
    let value: NeoMediaJob = try await request(url("/videos/\(job.targetVideoFileId)/subtitles/transfer/\(id)"),user:user,headers:headers)
    guard value.id == job.id, value.targetVideoFileId == job.targetVideoFileId, ["running","completed","failed"].contains(value.status) else { throw NeoError("処理の応答が一致しません。") }
    return value
  }
  @MainActor func watchMediaJob(_ initial: NeoMediaJob, recordings: Set<Int>, revision: Int, user: String, headers: [String:String], interval: UInt64 = 1_000_000_000, update: @escaping @MainActor (NeoMediaJob,String?) -> Void) {
    let key = initial.id, token = UUID()
    mediaJobWatches[key]?.cancel(); mediaJobTokens[key] = token
    mediaJobWatches[key] = Task { [weak self] in
      guard let self else { return }
      defer { if mediaJobTokens[key] == token { mediaJobWatches.removeValue(forKey:key); mediaJobTokens.removeValue(forKey:key) } }
      var job = initial
      while !Task.isCancelled, identityRevision == revision, accountReady {
        update(job,nil)
        if job.status != "running" {
          for id in recordings { recordingChanged(id) }; return
        }
        do {
          try await Task.sleep(nanoseconds:interval); try Task.checkCancellation()
          let value = try await mediaJob(job,user:user,headers:headers)
          guard !Task.isCancelled, identityRevision == revision, accountReady else { return }; job = value
        } catch {
          guard !Task.isCancelled, identityRevision == revision, accountReady else { return }
          // Keep the known job ID and offer status-only retry. Never repeat POST.
          update(job,error.localizedDescription); return
        }
      }
    }
  }
  func mediaSearch(keyword: String, offset: Int, channels: [NeoChannel], user: String, headers: [String:String]) async throws -> (records:[NeoRecording], more:Bool) {
    let text = keyword.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !text.isEmpty else { return ([],false) }
    let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
    let matches = channels.filter { $0.name.precomposedStringWithCompatibilityMapping.lowercased().contains(normalized) }.map(\.id)
    var records: [NeoRecording] = [], more = false
    // A bounded worker group avoids starting one request per matching station
    // at once. Merge exactly the same title/station search results as Web.
    let queries: [Int?] = [nil]+matches.map(Optional.some)
    for start in stride(from:0,to:queries.count,by:4) {
      try Task.checkCancellation()
      let batch = Array(queries[start..<min(start+4,queries.count)])
      let results = try await withThrowingTaskGroup(of:NeoRecords.self) { group in
        for channel in batch {
          var parts = URLComponents(url:url("/recorded"),resolvingAgainstBaseURL:false)!
          var query = [URLQueryItem(name:"offset",value:String(offset)),.init(name:"limit",value:"30"),.init(name:"isReverse",value:"false"),.init(name:"isHalfWidth",value:String(isHalfWidthDisplayed))]
          if let channel { query.append(.init(name:"channelId",value:String(channel))) } else { query.append(.init(name:"keyword",value:text)) }
          parts.queryItems = query; let address = parts.url!
          group.addTask { () async throws -> NeoRecords in try await self.request(address,user:user,headers:headers) }
        }
        var result: [NeoRecords] = []; for try await value in group { result.append(value) }; return result
      }
      for result in results { records += result.records; more = more || offset+result.records.count < result.total }
    }
    var seen = Set<Int>(); records = records.filter { seen.insert($0.id).inserted }.sorted { $0.startAt > $1.startAt }.map { $0.displayed(halfWidth:isHalfWidthDisplayed) }
    return (records,more)
  }
}
