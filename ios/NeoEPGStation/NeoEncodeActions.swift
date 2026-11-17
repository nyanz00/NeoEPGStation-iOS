import UIKit

extension NeoPage {
  func openEncode(_ records: [NeoRecording], bulk: Bool = false, completed: ((Set<Int>) -> Void)? = nil) {
    guard encodeActions == nil, recordingActions == nil, presentedViewController == nil,
      let shell, let api = shell.api, api.accountReady, !records.isEmpty else { return }
    let operation = NeoEncodeActions(host: self, shell: shell, api: api, records: records, bulk: bulk)
    operation.onCompleted = completed; encodeActions = operation; operation.start()
  }
}

@MainActor final class NeoEncodeActions {
  private weak var host: NeoPage?, shell: NeoShell?
  private let api: NeoAPI, revision: Int, user: String, headers: [String: String], records: [NeoRecording], bulk: Bool
  private var read: Task<Void, Never>?, mutation: Task<Void, Never>?, observer: NSObjectProtocol?
  private var finished = false, failures: [NeoEncodeFailure]?, successCount = 0
  private(set) var dialog: NeoEncodeDialog?
  var onCompleted: ((Set<Int>) -> Void)?
  var onFinished: (() -> Void)?
  init(host: NeoPage, shell: NeoShell, api: NeoAPI, records: [NeoRecording], bulk: Bool) {
    self.host = host; self.shell = shell; self.api = api; self.records = records; self.bulk = bulk
    revision = api.identityRevision; user = api.viewer; headers = api.profileHeaders
    observer = NotificationCenter.default.addObserver(forName: .neoAccountChanged, object: nil, queue: .main) { [weak self] _ in
      self?.authenticationChanged()
    }
  }
  private var current: Bool { !finished && host != nil && shell?.api === api
    && api.identityRevision == revision && api.viewer == user && api.profileHeaders == headers }
  private func authenticationChanged() {
    guard current else { cancel(); return }
    dialog?.authenticationReady = api.accountReady
    if api.accountReady, shell?.serverConfig == nil, mutation == nil { loadConfig() }
  }
  private func check() throws { try Task.checkCancellation(); if !current { throw CancellationError() } }
  func start() {
    guard current, api.accountReady else { cancel(); return }
    let modal = NeoEncodeDialog(records: records, bulk: bulk, settings: .load()); dialog = modal
    modal.onClose = { [weak self] in self?.finish(dismiss: false) }
    modal.onSubmit = { [weak self] dialog in self?.submit(dialog) }
    modal.onRetry = { [weak self] in self?.loadConfig() }
    host?.present(modal, animated: true)
    if let config = shell?.serverConfig { modal.setConfig(config) }
    else { loadConfig() }
  }
  private func loadConfig() {
    guard current, api.accountReady, mutation == nil, let dialog else { return }
    read?.cancel(); dialog.setMessage("読み込み中…")
    read = Task { [self] in
      do {
        let config = try await api.configuration(); try check()
        dialog.setConfig(config); dialog.setMessage(nil)
      } catch {
        guard current, !Task.isCancelled else { return }; dialog.setMessage("設定を取得できませんでした。", error: true)
      }
    }
  }
  private func submit(_ dialog: NeoEncodeDialog) {
    guard current, api.accountReady, mutation == nil else { return }
    let jobs: [NeoEncodeJob]
    do { jobs = try failures?.map(\.job) ?? NeoEncodePlan.jobs(records, sourceName: bulk ? dialog.sourceName : nil,
      sourceID: dialog.sourceVideoFileID, settings: dialog.settings, directory: dialog.directory) }
    catch { dialog.setMessage(error.localizedDescription, error: true); return }
    guard !jobs.isEmpty else { return }
    read?.cancel(); dialog.settings.save(); dialog.setBusy(true, total: jobs.count)
    mutation = Task { [self] in
      defer { mutation = nil }
      do {
        let result = try await NeoEncodePlan.submit(jobs, isCurrent: { [weak self] in self?.current == true },
          enqueue: { [self] job in
            // A pending request is never resent. Before the next bulk item,
            // wait for validation of the same identity to finish.
            while current && api.accountRevalidating && !api.accountReady {
              try await Task.sleep(nanoseconds: 50_000_000); try check()
            }
            try check(); guard api.accountReady else { throw CancellationError() }
            _ = try await api.addEncode(job, user: user, headers: headers)
            api.recordingChanged(job.recordedID)
            NotificationCenter.default.post(name: .neoEncodeChanged, object: api)
          }, progress: { dialog.setBusy(true, completed: $0, total: jobs.count) })
        try check(); successCount += result.succeeded.count; failures = result.failed
        if !bulk && !result.failed.isEmpty {
          failures = nil; dialog.setBusy(false); dialog.setMessage("エンコードを追加できません: " + result.failed[0].error, error: true); return
        }
        onCompleted?(Set(result.failed.map { $0.job.recordedID }))
        if result.failed.isEmpty {
          shell?.recordingNotice(NeoEncodePlan.successMessage(bulk:bulk,count:successCount))
          finish(dismiss: true)
        } else {
          dialog.setFailures(result.failed, successCount: successCount)
          shell?.recordingNotice("\(result.succeeded.count) 件を追加し、\(result.failed.count) 件の追加に失敗しました。", error: true)
        }
      } catch {
        guard current, !Task.isCancelled else { return }; dialog.setBusy(false); dialog.setMessage(error.localizedDescription, error: true)
      }
    }
  }
  func cancel() { finish(dismiss: true) }
  private func finish(dismiss: Bool) {
    guard !finished else { return }; finished = true
    dialog?.settings.save(); read?.cancel(); mutation?.cancel()
    if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    dialog?.onClose = nil; dialog?.onSubmit = nil; dialog?.onRetry = nil
    if dismiss { dialog?.dismiss(animated: true) }
    host?.encodeActions = nil; onCompleted = nil
    let callback = onFinished; onFinished = nil; callback?()
    NotificationCenter.default.post(name: .neoEncodeChanged, object: api)
  }
  deinit { read?.cancel(); mutation?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
