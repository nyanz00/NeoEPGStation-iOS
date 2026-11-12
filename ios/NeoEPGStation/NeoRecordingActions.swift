import UIKit

extension NeoPage {
  func performRecordingAction(_ command: NeoRecordingCommand, item: NeoRecording) {
    guard recordingActions == nil, presentedViewController == nil, let shell, let api = shell.api, api.accountReady else { return }
    let operation = NeoRecordingActions(host:self,shell:shell,api:api,item:item)
    recordingActions = operation; operation.start(command)
  }
}

// One operation owns its captured account, modal and temporary export. Server
// mutations are never automatically retried; a changed identity cancels work.
@MainActor final class NeoRecordingActions: NSObject, UIDocumentPickerDelegate {
  private weak var host: NeoPage?
  private weak var shell: NeoShell?
  private let api: NeoAPI, revision: Int, user: String, headers: [String:String]
  private var item: NeoRecording
  private var dialog: NeoRecordingActionDialog?
  private var task: Task<Void,Never>?
  private var observer: NSObjectProtocol?
  private var export: NeoRecordingExport?
  private weak var picker: UIDocumentPickerViewController?
  private var finished = false

  init(host: NeoPage, shell: NeoShell, api: NeoAPI, item: NeoRecording) {
    self.host = host; self.shell = shell; self.api = api; self.item = item
    revision = api.identityRevision; user = api.viewer; headers = api.profileHeaders
    super.init()
    observer = NotificationCenter.default.addObserver(forName:.neoAccountChanged,object:nil,queue:.main) { [weak self] _ in
      guard let self, !self.current else { return }; self.cancel()
    }
  }
  private var current: Bool {
    !finished && shell?.api === api && api.accountReady && api.identityRevision == revision
      && api.viewer == user && api.profileHeaders == headers
  }
  private func check() throws { try Task.checkCancellation(); if !current { throw CancellationError() } }

  func start(_ command: NeoRecordingCommand) {
    if command == .protect || command == .unprotect {
      task = Task { [self] in
        do {
          try check()
          try await api.protectRecording(item.id,protected:command == .protect,user:user,headers:headers)
          api.recordingChanged(item.id)
          try check(); complete(command == .protect ? "録画を保護しました。" : "保護を解除しました。")
        } catch { if current { complete(error.localizedDescription,error:true) } }
      }
      return
    }
    let modal = NeoRecordingActionDialog(command:command,item:item,selectAll:api.deleteRecordedDefaultValue)
    dialog = modal
    modal.onClose = { [weak self] in self?.cancel(dismiss:false) }
    modal.onSubmit = { [weak self] dialog in self?.submit(dialog) }
    modal.onDownload = { [weak self] file, playlist in self?.download(file,playlist:playlist) }
    host?.present(modal,animated:true)
    if command == .user { loadUsers() }
  }

  private func loadUsers() {
    guard task == nil, let dialog else { return }
    dialog.setBusy(false,message:"読み込み中…")
    task = Task { [self] in
      defer { task = nil }
      do {
        try check(); let result = try await api.viewers(); try check()
        let preferred = item.userId ?? Int(user)
        dialog.setUsers(result.users,selected:preferred); dialog.onRetry = nil; dialog.setBusy(false)
      } catch {
        guard current else { return }
        dialog.setBusy(false); dialog.setMessage(error.localizedDescription,error:true)
        dialog.onRetry = { [weak self] in self?.loadUsers() }
      }
    }
  }

  private func submit(_ dialog: NeoRecordingActionDialog) {
    guard current, task == nil else { return }
    let selected = dialog.selectedFiles, selectedFile = dialog.selectedFile, selectedUser = dialog.selectedUser
    dialog.onRetry = nil; dialog.setBusy(true,message:"処理中…")
    task = Task { [self] in
      var changed = false
      defer { task = nil }
      do {
        try check()
        switch dialog.command {
        case .user:
          guard let selectedUser else { throw NeoError("ユーザーを選択してください。") }
          try await api.assignRecordingUser(item.id,userID:selectedUser,user:user,headers:headers)
          changed = true; api.recordingChanged(item.id); try check(); complete("ユーザーを変更しました。")
        case .thumbnail:
          let latest = try await api.recording(item.id,refresh:true); try check()
          guard let selectedFile, latest.videoFiles?.contains(where:{$0.id == selectedFile}) == true else {
            dialog.setFiles(latest.videoFiles ?? []); throw NeoError("録画ファイルが変更されました。もう一度選択してください。")
          }
          try await api.replaceRecordingThumbnail(selectedFile,user:user,headers:headers); try check()
          api.watchRecordingThumbnail(item.id,previous:latest.thumbnails ?? [])
          complete("サムネイル再生成を開始しました。")
        case .delete:
          let latest = try await api.recording(item.id,refresh:true); try check()
          let files = latest.videoFiles ?? [], available = Set(files.map(\.id))
          guard !selected.isEmpty, selected.isSubset(of:available) else {
            dialog.setFiles(files); throw NeoError("録画ファイルが変更されました。もう一度選択してください。")
          }
          if selected == available {
            try await api.deleteRecording(item.id,user:user,headers:headers)
            changed = true; api.recordingChanged(item.id,deleted:true); try check(); complete("録画を削除しました。")
          } else {
            for file in files where selected.contains(file.id) {
              try check(); try await api.deleteRecordingVideo(file.id,user:user,headers:headers)
              changed = true
              // Deleting a file while recording promotes to whole-record
              // deletion on the server. Do not submit the remaining IDs then.
              if latest.isRecording {
                api.recordingChanged(item.id,deleted:true); try check(); complete("録画を削除しました。"); return
              }
            }
            try check()
            do { _ = try await api.recording(item.id,refresh:true) }
            catch let missing as NeoError where missing.statusCode == 404 {
              api.recordingChanged(item.id,deleted:true); try check(); complete("録画を削除しました。"); return
            } catch { /* The accepted deletes still need cache invalidation. */ }
            api.recordingChanged(item.id); try check(); complete("録画ファイルを削除しました。")
          }
        default: break
        }
      } catch {
        if changed { api.recordingChanged(item.id) }
        guard current else { return }
        let failure = error.localizedDescription
        if dialog.command == .delete {
          do {
            let latest = try await api.recording(item.id,refresh:true); try check()
            item = latest; dialog.setFiles(latest.videoFiles ?? [],selected:selected)
          } catch let missing as NeoError where missing.statusCode == 404 {
            api.recordingChanged(item.id,deleted:true); complete("録画は削除されています。"); return
          } catch { }
        }
        guard current else { return }
        dialog.setBusy(false); dialog.setMessage((changed ? "一部のファイルは削除されました。\n" : "")+failure,error:true)
      }
    }
  }

  private func download(_ file: NeoVideoFile, playlist: Bool) {
    guard current, task == nil, export == nil, let dialog else { return }
    dialog.setBusy(true,message:"ダウンロード中…")
    recordDownloadWatch()
    task = Task { [self] in
      defer { task = nil }
      do {
        try check(); let result = try await api.downloadRecording(file,playlist:playlist,user:user,headers:headers)
        do { try check() } catch { result.remove(); throw error }
        export = result
        let controller = UIDocumentPickerViewController(forExporting:[result.file],asCopy:true)
        controller.delegate = self; picker = controller
        dialog.setMessage("保存先を選択してください。")
        dialog.present(controller,animated:true)
      } catch {
        guard current else { return }; dialog.setBusy(false); dialog.setMessage(error.localizedDescription,error:true)
      }
    }
  }
  private func recordDownloadWatch() {
    guard NeoAnnictPreferences.onDownload else { return }
    // A download must not wait for Annict. Keep this bounded request alive
    // after ordinary modal closing, but never cross accounts or servers.
    Task { [api, weak shell, user, headers, revision, id = item.id] in
      func eligible() -> Bool { shell?.api === api && api.accountReady && api.identityRevision == revision && !Task.isCancelled }
      do {
        guard eligible() else { return }
        let episode = try await api.annictEpisode(id,user:user,headers:headers,refresh:true)
        guard eligible(), episode.state == "matched", episode.writeConfigured, !episode.watched else { return }
        _ = try await api.annictEpisode(id,method:"PUT",user:user,headers:headers)
        guard eligible() else { return }
        NotificationCenter.default.post(name:.neoAnnictChanged,object:api,userInfo:["recordingID":id])
      } catch { if eligible() { shell?.recordingNotice("Annictへ記録できませんでした。",error:true) } }
    }
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { exported(controller,saved:true) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { exported(controller,saved:false) }
  private func exported(_ controller: UIDocumentPickerViewController, saved: Bool) {
    guard picker === controller else { return }
    picker = nil; export?.remove(); export = nil
    guard current else { return }; dialog?.setBusy(false)
    dialog?.setMessage(saved ? "保存しました。" : nil)
  }
  private func complete(_ message: String, error: Bool = false) {
    guard current else { return }
    let shell = self.shell
    dialog?.onClose = nil
    if let dialog { dialog.dismiss(animated:true) { shell?.recordingNotice(message,error:error) } }
    else { shell?.recordingNotice(message,error:error) }
    finish()
  }
  func cancel(dismiss: Bool = true) {
    guard !finished else { return }
    task?.cancel(); task = nil
    let temporary = export; export = nil
    dialog?.onClose = nil
    if dismiss, let dialog { dialog.dismiss(animated:false) { temporary?.remove() } }
    else { temporary?.remove() }
    finish()
  }
  private func finish() {
    finished = true
    if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
    host?.recordingActions = nil; dialog = nil
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; export?.remove() }
}

extension NeoShell {
  func recordingNotice(_ message: String, error: Bool = false) {
    view.viewWithTag(80921)?.removeFromSuperview()
    let label = UILabel(); label.tag = 80921; label.text = "  "+message+"  "; label.numberOfLines = 0
    label.font = .systemFont(ofSize:14); label.textColor = error ? .white : UIColor.black.withAlphaComponent(0.87)
    label.backgroundColor = error ? UIColor(red:211/255,green:47/255,blue:47/255,alpha:1) : UIColor(red:56/255,green:142/255,blue:60/255,alpha:1)
    label.layer.cornerRadius = 4; label.clipsToBounds = true; label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo:view.centerXAnchor),label.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor,constant:-32),label.heightAnchor.constraint(greaterThanOrEqualToConstant:48),label.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-80)])
    UIAccessibility.post(notification:.announcement,argument:message)
    DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak label] in label?.removeFromSuperview() }
  }
}
