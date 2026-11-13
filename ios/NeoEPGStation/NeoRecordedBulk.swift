import Foundation

enum NeoBulkRecordingCommand: String { case encode, user, move, delete }
enum NeoBulkDeleteOption: String, CaseIterable { case all, original, encoded, names }
struct NeoBulkOperationResult: Decodable { let updatedCount: Int; let movedFileCount: Int }
struct NeoRecordedDirectories: Decodable { let directories: [String] }
struct NeoBulkDeleteTarget {
  let item: NeoRecording
  let deleteRecording: Bool
  let videoFileIDs: [Int]
}
struct NeoBulkDeleteFailure { let item: NeoRecording; let error: String }
struct NeoBulkDeleteResult { let succeeded: [Int]; let failed: [NeoBulkDeleteFailure] }

enum NeoRecordedBulk {
  static func formattedSize(_ bytes: Double) -> String {
    let units = ["B","KB","MB","GB","TB","PB"]
    var value = max(0,bytes), index = 0
    while value >= 1000 && index < units.count-1 { value /= 1024; index += 1 }
    return String(format:"%.1f%@",value,units[index])
  }
  static func fileNames(_ records: [NeoRecording]) -> [(name: String, count: Int)] {
    var order: [String] = [], counts: [String:Int] = [:]
    for item in records { for file in item.videoFiles ?? [] {
      if counts[file.name] == nil { order.append(file.name) }
      counts[file.name, default:0] += 1
    } }
    return order.map { ($0, counts[$0,default:0]) }
  }
  static func targets(_ records: [NeoRecording], option: NeoBulkDeleteOption, names: Set<String> = []) -> [NeoBulkDeleteTarget] {
    if option == .names && names.isEmpty { return [] }
    return records.compactMap { item in
      let files = (item.videoFiles ?? []).filter { file in
        switch option {
        case .all: return true
        case .original: return file.type == "ts"
        case .encoded: return file.type == "encoded"
        case .names: return names.contains(file.name)
        }
      }
      guard option == .all || !files.isEmpty else { return nil }
      return NeoBulkDeleteTarget(item:item,deleteRecording:option == .all,videoFileIDs:files.map(\.id))
    }
  }

  // Four records at a time; each record's file deletions stay ordered. Never
  // retry mutations. A failed file does not prevent processing the other files.
  @MainActor static func delete(_ targets: [NeoBulkDeleteTarget],
    isCurrent: @escaping @MainActor () -> Bool,
    deleteRecording: @escaping @MainActor (Int) async throws -> Void,
    deleteVideo: @escaping @MainActor (Int) async throws -> Void,
    didChange: @escaping @MainActor (Int, Bool) -> Void) async throws -> NeoBulkDeleteResult {
    struct Outcome { let position: Int; let error: String? }
    var outcomes: [Outcome] = []
    try await withThrowingTaskGroup(of: Outcome.self) { group in
      var next = 0
      func enqueue(_ position: Int) {
        let target = targets[position]
        group.addTask { @MainActor in
          func check() throws { try Task.checkCancellation(); if !isCurrent() { throw CancellationError() } }
          try check()
          if target.deleteRecording {
            do {
              try await deleteRecording(target.item.id); didChange(target.item.id,true); try check()
              return Outcome(position:position,error:nil)
            } catch {
              try check()
              return Outcome(position:position,error:error.localizedDescription)
            }
          }
          var errors: [String] = []
          for id in target.videoFileIDs {
            try check()
            do {
              try await deleteVideo(id)
              didChange(target.item.id,target.item.isRecording)
              try check()
              // Server promotes deletion of a recording-in-progress's video
              // to whole-record deletion; do not issue more file requests.
              if target.item.isRecording { return Outcome(position:position,error:nil) }
            } catch {
              try check(); errors.append(error.localizedDescription)
            }
          }
          return Outcome(position:position,error:errors.isEmpty ? nil : errors.joined(separator:" / "))
        }
      }
      while next < min(4,targets.count) { enqueue(next); next += 1 }
      while let outcome = try await group.next() {
        outcomes.append(outcome)
        try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
        if next < targets.count { enqueue(next); next += 1 }
      }
    }
    let ordered = outcomes.sorted { $0.position < $1.position }
    return NeoBulkDeleteResult(
      succeeded:ordered.filter { $0.error == nil }.map { targets[$0.position].item.id },
      failed:ordered.compactMap { outcome in outcome.error.map { NeoBulkDeleteFailure(item:targets[outcome.position].item,error:$0) } })
  }
}

extension NeoAPI {
  func recordedDirectories(user: String, headers: [String:String]) async throws -> [String] {
    let result: NeoRecordedDirectories = try await request(url("/recorded/directories"),user:user,headers:headers)
    return result.directories
  }
  func bulkAssignRecordingUser(_ ids: [Int], userID: Int, user: String, headers: [String:String]) async throws -> NeoBulkOperationResult {
    guard userID > 0, !ids.isEmpty, ids.allSatisfy({ $0 > 0 }) else { throw NeoError("ユーザーと録画を選択してください。") }
    return try await request(url("/recorded/bulk/user"),method:"PUT",body:["recordedIds":ids,"userId":userID],user:user,headers:headers)
  }
  func bulkMoveRecordings(_ ids: [Int], subDirectory: String, user: String, headers: [String:String]) async throws -> NeoBulkOperationResult {
    guard !ids.isEmpty, ids.allSatisfy({ $0 > 0 }) else { throw NeoError("録画を選択してください。") }
    return try await request(url("/recorded/bulk/subDirectory"),method:"PUT",body:["recordedIds":ids,"subDirectory":subDirectory],user:user,timeout:120,headers:headers)
  }
}
