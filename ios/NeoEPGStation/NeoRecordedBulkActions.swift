import UIKit

// Owns one immutable selection and account snapshot. Mutations are never
// retried automatically, even if the server accepted a request before a cut.
@MainActor final class NeoRecordedBulkActions {
  private weak var host: NeoRecordedPage?
  private weak var shell: NeoShell?
  private let api: NeoAPI, revision: Int, user: String, headers: [String:String]
  private let records: [NeoRecording]
  private var dialog: NeoBulkRecordingDialog?
  private var read: Task<Void,Never>?, mutation: Task<Void,Never>?
  private var observer: NSObjectProtocol?, finished = false
  private var mutationStarted = false
  var onFinish: ((Set<Int>?) -> Void)?
  var isBusy: Bool { mutation != nil }

  init(host: NeoRecordedPage, shell: NeoShell, api: NeoAPI, records: [NeoRecording]) {
    self.host = host; self.shell = shell; self.api = api; self.records = records
    revision = api.identityRevision; user = api.viewer; headers = api.profileHeaders
    observer = NotificationCenter.default.addObserver(forName:.neoAccountChanged,object:api,queue:.main) { [weak self] _ in
      guard let self, !self.current else { return }; self.cancel()
    }
  }
  private var current: Bool {
    !finished && host != nil && shell?.api === api && api.accountReady
      && api.identityRevision == revision && api.viewer == user && api.profileHeaders == headers
  }
  private func check() throws { try Task.checkCancellation(); if !current { throw CancellationError() } }

  func start(_ command: NeoBulkRecordingCommand) {
    guard current, !records.isEmpty else { cancel(); return }
    let modal = NeoBulkRecordingDialog(command:command,records:records); dialog = modal
    modal.onClose = { [weak self] in self?.cancel(dismiss:false) }
    modal.onSubmit = { [weak self] in self?.submit($0) }
    host?.present(modal,animated:true)
    if command == .user || command == .move { loadChoices() }
  }
  private func loadChoices() {
    guard current, let dialog else { return }
    read?.cancel(); dialog.onRetry = nil; dialog.setMessage("読み込み中…")
    read = Task { [self] in
      do {
        try check()
        if dialog.command == .user {
          let users = try await api.viewers(); try check(); dialog.setUsers(users.users,preferred:Int(user))
        } else {
          let values = try await api.recordedDirectories(user:user,headers:headers); try check(); dialog.setDirectories(values)
        }
        dialog.setMessage(nil)
      } catch {
        guard current, !Task.isCancelled else { return }
        dialog.setMessage(dialog.command == .user ? "ユーザーを取得できません。" : "保存先を取得できません。",error:true)
        dialog.onRetry = { [weak self] in self?.loadChoices() }
      }
    }
  }
  private func submit(_ dialog: NeoBulkRecordingDialog) {
    guard current, mutation == nil, dialog.command != .encode else { return }
    let ids = records.map(\.id), selectedUser = dialog.selectedUser
    let directory = dialog.subDirectory
    let targets = NeoRecordedBulk.targets(records,option:dialog.deleteOption,names:dialog.deleteFileNames)
    if dialog.command == .user && selectedUser == nil { return }
    if dialog.command == .delete && targets.isEmpty { return }
    read?.cancel(); dialog.onRetry = nil; dialog.setBusy(true,message:"処理中…")
    mutation = Task { [self] in
      defer { mutation = nil }
      do {
        try check(); mutationStarted = true
        switch dialog.command {
        case .encode: return
        case .user:
          guard let selectedUser else { return }
          let result = try await api.bulkAssignRecordingUser(ids,userID:selectedUser,user:user,headers:headers)
          invalidate(); try check()
          complete([],message:"\(result.updatedCount) 件のユーザーを変更しました。")
        case .move:
          let result = try await api.bulkMoveRecordings(ids,subDirectory:directory,user:user,headers:headers)
          invalidate(); try check()
          let name = directory.trimmingCharacters(in:.whitespacesAndNewlines)
          complete([],message:"\(result.updatedCount) 件（\(result.movedFileCount) ファイル）を「\(name.isEmpty ? "録画ルート直下" : name)」へ移動しました。")
        case .delete:
          let result = try await NeoRecordedBulk.delete(targets,
            isCurrent:{ [weak self] in self?.current == true },
            deleteRecording:{ [api,user,headers] id in try await api.deleteRecording(id,user:user,headers:headers) },
            deleteVideo:{ [api,user,headers] id in try await api.deleteRecordingVideo(id,user:user,headers:headers) },
            didChange:{ [api] id,deleted in api.recordingChanged(id,deleted:deleted) })
          invalidate(); try check()
          var messages: [String] = []
          if !result.succeeded.isEmpty { messages.append("\(result.succeeded.count)件の削除処理が完了しました。") }
          if !result.failed.isEmpty {
            let details = result.failed.prefix(3).map { "\($0.item.name): \($0.error)" }.joined(separator:" / ")
            messages.append("\(result.failed.count)件を削除できませんでした: \(details)")
          }
          complete(Set(result.failed.map { $0.item.id }),message:messages.joined(separator:"\n"),error:!result.failed.isEmpty)
        }
      } catch {
        invalidate()
        guard current, !Task.isCancelled else { return }
        let prefix = dialog.command == .user ? "ユーザーの一括変更に失敗しました: " : "サブディレクトリ移動に失敗しました: "
        let message = prefix+error.localizedDescription
        dialog.setBusy(false); dialog.setMessage(message,error:true); shell?.recordingNotice(message,error:true)
      }
    }
  }
  private func invalidate() { for item in records { api.recordingChanged(item.id) } }
  private func complete(_ remaining: Set<Int>, message: String, error: Bool = false) {
    guard current else { return }
    shell?.recordingNotice(message,error:error)
    finish(remaining,dismiss:true)
  }
  func cancel(dismiss: Bool = true) {
    if mutationStarted { invalidate() }
    finish(nil,dismiss:dismiss)
  }
  private func finish(_ remaining: Set<Int>?, dismiss: Bool) {
    guard !finished else { return }
    finished = true; read?.cancel(); mutation?.cancel()
    if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    dialog?.onClose = nil; dialog?.onSubmit = nil; dialog?.onRetry = nil
    if dismiss { dialog?.dismiss(animated:true) }
    let callback = onFinish; onFinish = nil; callback?(remaining)
  }
#if targetEnvironment(simulator)
  var smokeDialog: NeoBulkRecordingDialog? { dialog }
#endif
  deinit { read?.cancel(); mutation?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
