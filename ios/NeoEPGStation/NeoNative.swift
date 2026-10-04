import Foundation
import React
import Security
import UIKit

@objc(NeoNative)
final class NeoNative: NSObject {
  private var service = "io.github.nyanz00.neoepgstation.connection"
  private var player: NeoPlayerController?

  @objc static func requiresMainQueueSetup() -> Bool { true }

  private var preferences = UserDefaults.standard
  private let navigationKey = "neoepgstation.navigation.v1"

  @objc func constantsToExport() -> [String: Any] {
#if targetEnvironment(simulator)
    return ["uiSmoke": ProcessInfo.processInfo.environment["NEO_EPG_UI_SMOKE"] ?? ""]
#else
    return ["uiSmoke": ""]
#endif
  }

  @objc(loadNavigation:rejecter:)
  func loadNavigation(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    if let items = preferences.stringArray(forKey: navigationKey) { resolve(items) }
    else { resolve(NSNull()) }
  }

  @objc(reportUIReady:resolver:rejecter:)
  func reportUIReady(_ value: [String: Any], resolver resolve: RCTPromiseResolveBlock,
                     rejecter reject: RCTPromiseRejectBlock) {
#if targetEnvironment(simulator)
    let stage = ProcessInfo.processInfo.environment["NEO_EPG_UI_SMOKE"] ?? ""
    guard ["recorded", "menu", "settings"].contains(stage), value["stage"] as? String == stage,
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      reject("smoke", "UI smoke stage mismatch", nil); return
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: value.merging(["success": true]) { _, new in new })
      try data.write(to: directory.appendingPathComponent("ui-\(stage)-smoke.json"))
    } catch { reject("smoke", "Cannot write UI smoke result", error); return }
#endif
    resolve(NSNull())
  }

  @objc(saveNavigation:resolver:rejecter:)
  func saveNavigation(_ items: [String], resolver resolve: RCTPromiseResolveBlock,
                      rejecter reject: RCTPromiseRejectBlock) {
    let allowed = Set(["dashboard", "onair", "guide", "anime", "recording", "recorded", "encode",
      "reserves", "search", "rule", "history", "system", "settings"])
    guard (1...5).contains(items.count), Set(items).count == items.count,
      items.allSatisfy({ allowed.contains($0) }) else {
      reject("navigation", "ナビゲーションの項目を確認してください。", nil); return
    }
    preferences.set(items, forKey: navigationKey)
    resolve(NSNull())
  }

  private var keychainQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: "server"]
  }

  @objc(loadConnection:rejecter:)
  func loadConnection(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    var query = keychainQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { resolve(NSNull()); return }
    guard status == errSecSuccess, let data = item as? Data,
      let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
      reject("keychain-\(status)", "接続設定を読み込めませんでした。", nil); return
    }
    // Older prototypes stored Basic credentials alongside the URL. Reuse the
    // server address, but never restore those credentials into the new app.
    guard let text = saved["url"] else {
      reject("storage", "保存した接続先を読み込めませんでした。", nil); return
    }
    resolve(["url": text])
  }

  @objc(saveConnection:resolver:rejecter:)
  func saveConnection(_ value: [String: String], resolver resolve: RCTPromiseResolveBlock,
                      rejecter reject: RCTPromiseRejectBlock) {
    guard let text = value["url"], let url = URL(string: text),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
      reject("url", "サーバーURLを確認してください。", nil); return
    }
    let saved = ["url": text]
    guard let data = try? JSONSerialization.data(withJSONObject: saved) else {
      reject("storage", "接続設定を保存できませんでした。", nil); return
    }
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(keychainQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      reject("keychain-\(status)", "接続設定を保存できませんでした。", nil); return
    }
    resolve(saved)
  }

  @objc(play:resolver:rejecter:)
  func play(_ options: [String: Any], resolver resolve: @escaping RCTPromiseResolveBlock,
            rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.player == nil,
        let text = options["url"] as? String, let url = URL(string: text),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
        url.user == nil, url.password == nil else {
        reject("player", "プレイヤーを開始できませんでした。", nil); return
      }
      let controller = NeoPlayerController(url: url, title: options["title"] as? String ?? "PLAY",
        username: options["username"] as? String ?? "", password: options["password"] as? String ?? "",
        networkCaching: min(30000, max(1000, options["networkCaching"] as? Int ?? 5000)))
      controller.modalPresentationStyle = .fullScreen
      controller.onClose = { [weak self] in self?.player = nil; resolve(NSNull()) }
      self.player = controller
      self.present(controller, attempt: 0, reject: reject)
    }
  }

  private func present(_ controller: NeoPlayerController, attempt: Int,
                       reject: @escaping RCTPromiseRejectBlock) {
    guard let presenter = RCTPresentedViewController() else {
      player = nil; reject("presentation", "画面を開けませんでした。", nil); return
    }
    // Wait for the React Native file picker to finish dismissing before presenting.
    if presenter.isBeingDismissed || presenter.isBeingPresented || presenter.transitionCoordinator != nil {
      guard attempt < 30 else {
        player = nil; reject("presentation", "画面の切り替えが完了しませんでした。", nil); return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.present(controller, attempt: attempt + 1, reject: reject)
      }
      return
    }
    presenter.present(controller, animated: true)
  }

#if targetEnvironment(simulator)
  // The simulator job exercises the real storage methods with an isolated service.
  static func runStorageSmokeTest() {
    let module = NeoNative()
    module.service += ".ci-smoke"
    defer { SecItemDelete(module.keychainQuery as CFDictionary) }
    let value = ["url": "https://example.com"]
    var result: [String: Any] = ["success": false]
    let suite = "io.github.nyanz00.neoepgstation.navigation.ci-smoke"
    module.preferences = UserDefaults(suiteName: suite)!
    defer { module.preferences.removePersistentDomain(forName: suite) }
    var navigationSaved = false
    module.saveNavigation(["guide", "recorded"], resolver: { _ in
      module.loadNavigation({ items in navigationSaved = (items as? [String]) == ["guide", "recorded"] }, rejecter: { _, _, _ in })
    }, rejecter: { _, _, _ in })
    var rejectedInvalid = false
    module.saveNavigation(["unknown"], resolver: { _ in }, rejecter: { _, _, _ in rejectedInvalid = true })
    result["navigationSuccess"] = navigationSaved && rejectedInvalid
    module.saveConnection(value, resolver: { _ in
      module.loadConnection({ saved in
        let restored = saved as? [String: String]
        result["success"] = restored == value
      }, rejecter: { code, _, _ in result["error"] = code ?? "unknown" })
    }, rejecter: { code, _, _ in result["error"] = code ?? "unknown" })
    // Simulate a previously installed prototype. Its old credentials must
    // not reappear in JavaScript or produce an Authorization header.
    if result["success"] as? Bool == true,
      let legacy = try? JSONSerialization.data(withJSONObject:
        ["url": "https://example.com", "username": "legacy", "password": "fixture"]) {
      let status = SecItemUpdate(module.keychainQuery as CFDictionary,
        [kSecValueData as String: legacy] as CFDictionary)
      result["success"] = status == errSecSuccess
      module.loadConnection({ saved in
        result["success"] = result["success"] as? Bool == true && (saved as? [String: String]) == value
      }, rejecter: { code, _, _ in result["success"] = false; result["error"] = code ?? "unknown" })
    }
    if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
       let data = try? JSONSerialization.data(withJSONObject: result) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: directory.appendingPathComponent("storage-smoke.json"))
    }
  }
#endif
}
