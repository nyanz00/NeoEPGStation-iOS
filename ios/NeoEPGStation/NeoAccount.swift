import UIKit
import Security

// Tokens are scoped to both server and profile. Passwords never leave the unlock request.
final class NeoProfileSecrets {
  private let server: String
  init(server: URL) { self.server = server.absoluteString }
  private func query(_ profile: Int) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "io.github.nyanz00.neoepgstation.viewer-session",
     kSecAttrAccount as String: "\(server)|\(profile)"]
  }
  func read(_ profile: Int) throws -> String? {
    var query = query(profile); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
      throw NeoError("認証セッションを読み込めませんでした。")
    }
    return token
  }
  func save(_ profile: Int, token: String) throws {
    guard token.count >= 32 else { throw NeoError("認証セッションの応答形式が一致しません。") }
    let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let query = query(profile)
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
    guard status == errSecSuccess else { throw NeoError("認証セッションを保存できませんでした。") }
  }
  func remove(_ profile: Int) { SecItemDelete(query(profile) as CFDictionary) }
}

@MainActor final class NeoAccountCoordinator {
  let api: NeoAPI
  private weak var shell: NeoShell?
  private let secrets: NeoProfileSecrets
  private(set) var users: [NeoViewer] = []
  private(set) var profiles: [NeoViewerProfile] = []
  private(set) var busy = false
  private var revision = 0
  private var current: Bool { shell?.api === api }
  var currentName: String { users.first { String($0.id) == api.viewer }?.name ?? (Int(api.viewer).map { $0 > 0 } == true ? "ユーザー \(api.viewer)" : "master（すべて）") }
  init(api: NeoAPI, shell: NeoShell) {
    self.api = api; self.shell = shell; secrets = NeoProfileSecrets(server: api.base)
    api.onLocked = { [weak self] profile in self?.sessionExpired(profile) }
  }
  func restore() {
    guard current, !busy, let user = Int(api.viewer), user > 0 else { return }
    api.accountReady = false; api.identityRevision += 1
    NotificationCenter.default.post(name: .neoAccountChanged, object: api)
    resolve(String(user), restoring: true)
  }
  // Deferred native menu stays anchored to the shared outlined selector.
  func loadSelectionMenu(completion: @escaping ([UIMenuElement]) -> Void) {
    guard current, !busy else { completion([]); return }
    busy = true; let attempt = revision
    Task { [weak self] in
      guard let self else { completion([]); return }
      do {
        let users = try await api.viewers()
        guard current, revision == attempt else { completion([]); return }
        let profiles = try await api.viewerProfiles()
        guard current, revision == attempt else { completion([]); return }
        self.users = users.users; self.profiles = profiles.profiles; busy = false
        let values = [("master", "master（すべて）")] + users.users.filter { $0.id > 0 }.map { (String($0.id), $0.name) }
        completion(values.map { id, name in
          UIAction(title: name, state: api.viewer == id ? .on : .off) { [weak self] _ in
            guard let self, self.current, !self.busy else { return }
            if id == "master" { self.commit(id, profile: nil, token: nil) }
            else { self.resolve(id, restoring: false) }
          }
        })
      } catch {
        guard current, revision == attempt else { completion([]); return }
        busy = false
        completion([UIAction(title: "ユーザーを取得できません。再試行してください。", attributes: .disabled) { _ in }])
      }
    }
  }
  private func resolve(_ user: String, restoring: Bool) {
    guard current, !busy else { return }
    busy = true; revision += 1; let attempt = revision
    Task { [weak self] in
      guard let self else { return }
      do {
        let users = try await api.viewers()
        // A cancelled switch must stop before issuing another request. In
        // particular, its session may already be closed after leaving the server.
        guard current, attempt == revision else { return }
        let profiles = try await api.viewerProfiles()
        guard current, attempt == revision else { return }
        self.users = users.users; self.profiles = profiles.profiles
        guard let target = users.users.first(where: { String($0.id) == user && $0.id > 0 }) else {
          if restoring { commit("master", profile: nil, token: nil) }
          throw NeoError("選択したユーザーが見つかりません。")
        }
        let profile = profiles.profiles.first { $0.tvUserId == target.id }
        var token: String?
        if let profile, profile.lockRequired {
          token = try secrets.read(profile.id)
          if let stored = token {
            let valid = try await api.validateProfile(profile.id, token: stored)
            guard current, attempt == revision else { return }
            if !valid { secrets.remove(profile.id); token = nil }
          }
          if token == nil {
            busy = false
            askPassword(user: user, name: target.name, profile: profile, restoring: restoring)
            return
          }
        }
        commit(user, profile: profile, token: token); busy = false
      } catch {
        guard current, attempt == revision else { return }
        busy = false
        if restoring { api.accountReady = false }
        let alert = UIAlertController(title: "ユーザーを確認できません", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "再試行", style: .default) { [weak self] _ in self?.resolve(user, restoring: restoring) })
        alert.addAction(UIAlertAction(title: restoring ? "masterへ戻る" : "キャンセル", style: .cancel) { [weak self] _ in
          if restoring { self?.commit("master", profile: nil, token: nil) }
        })
        host()?.present(alert, animated: true)
      }
    }
  }
  private func askPassword(user: String, name: String, profile: NeoViewerProfile, restoring: Bool, error: String? = nil) {
    guard current else { return }
    let alert = UIAlertController(title: "アクティブユーザーの確認",
      message: error ?? "\(name)は外部連携パスワードで保護されています。このユーザーを使用するにはパスワードを入力してください。", preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "外部連携パスワード"; field.isSecureTextEntry = true
      field.textContentType = .password; field.autocorrectionType = .no; field.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: restoring ? "masterへ戻る" : "キャンセル", style: .cancel) { [weak self] _ in
      if restoring { self?.commit("master", profile: nil, token: nil) }
    })
    alert.addAction(UIAlertAction(title: "解除", style: .default) { [weak self, weak alert] _ in
      guard let self, current, !busy else { return }
      let password = alert?.textFields?.first?.text ?? ""
      alert?.textFields?.first?.text = ""
      performUnlock(user: user, name: name, profile: profile, restoring: restoring, password: password)
    })
    host()?.present(alert, animated: true)
  }
  private func performUnlock(user: String, name: String, profile: NeoViewerProfile, restoring: Bool, password: String) {
      busy = true; revision += 1; let attempt = revision
      Task { [weak self] in
        guard let self else { return }
        do {
          guard !password.isEmpty else { throw NeoError("連携パスワードを入力してください。") }
          let session = try await api.unlockProfile(profile.id, password: password)
          guard current, revision == attempt else { return }
          try secrets.save(profile.id, token: session.sessionToken)
          commit(user, profile: profile, token: session.sessionToken); busy = false
          if let code = session.recoveryCode {
            let recovery = UIAlertController(title: "回復コード", message: "サーバーとは別の安全な場所へ保存してください。\n\n\(code)", preferredStyle: .alert)
            recovery.addAction(UIAlertAction(title: "コピー", style: .default) { _ in UIPasteboard.general.string = code })
            recovery.addAction(UIAlertAction(title: "閉じる", style: .cancel)); host()?.present(recovery, animated: true)
          }
        } catch {
          guard current, revision == attempt else { return }; busy = false
          askPassword(user: user, name: name, profile: profile, restoring: restoring, error: error.localizedDescription)
        }
      }
  }
  private func commit(_ user: String, profile: NeoViewerProfile?, token: String?) {
    guard current else { return }
    revision += 1; busy = false
    var headers: [String: String] = [:]
    if let profile {
      headers["X-Viewer-Profile-Id"] = String(profile.id)
      if let token { headers["X-Viewer-Session"] = token }
    }
    api.activate(user: user, headers: headers)
  }
  func lockCurrent() {
    if let profile = api.profileHeaders["X-Viewer-Profile-Id"].flatMap(Int.init) { secrets.remove(profile) }
    commit("master", profile: nil, token: nil)
  }
  private func sessionExpired(_ profile: Int) {
    secrets.remove(profile)
    guard current, api.profileHeaders["X-Viewer-Profile-Id"] == String(profile) else { return }
    let previous = api.viewer
    commit("master", profile: nil, token: nil)
    resolve(previous, restoring: false)
  }
#if targetEnvironment(simulator)
  func smokeSelect(_ user: String) { resolve(user, restoring: false) }
  func smokeUnlock(_ user: String, password: String) {
    guard let target = users.first(where: { String($0.id) == user }), let profile = profiles.first(where: { $0.tvUserId == target.id }) else { return }
    performUnlock(user: user, name: target.name, profile: profile, restoring: false, password: password)
  }
#endif
  private func host() -> UIViewController? {
    guard current, let shell, shell.view.window != nil else { return nil }
    var host: UIViewController = shell
    while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
    return host
  }
}
