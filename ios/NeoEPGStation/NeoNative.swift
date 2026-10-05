import Foundation
import Security

final class NeoNative {
  private var service = "io.github.nyanz00.neoepgstation.connection"
  private var preferences = UserDefaults.standard
  private let navigationKey = "neoepgstation.navigation.v1"
  var hideRecordedThumbnailButton: Bool {
    get { preferences.object(forKey: "neoepgstation.hideRecordedThumbnailButton") as? Bool ?? true }
    set { preferences.set(newValue, forKey: "neoepgstation.hideRecordedThumbnailButton") }
  }
  var shortcuts: [String] {
    let saved = preferences.stringArray(forKey: navigationKey) ?? []
    return Self.validShortcuts(saved) ? saved : ["recorded", "onair", "guide", "anime", "settings"]
  }
  private static func validShortcuts(_ items: [String]) -> Bool {
    let allowed = Set(["dashboard","onair","guide","anime","recording","recorded","encode","reserves","search","rule","history","system","settings"])
    return (1...5).contains(items.count) && Set(items).count == items.count && items.allSatisfy { allowed.contains($0) }
  }
  func saveShortcuts(_ items: [String]) throws {
    guard Self.validShortcuts(items) else { throw NeoError("ナビゲーションの項目を確認してください。") }
    preferences.set(items, forKey: navigationKey)
  }
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "server"]
  }
  func loadConnection() throws -> URL? {
    var query = self.query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String], let text = saved["url"] else {
      throw NeoError("接続設定を読み込めませんでした。")
    }
    return try NeoServerURL.normalize(text)
  }
  func saveConnection(_ url: URL) throws {
    let normalized = try NeoServerURL.normalize(url.absoluteString)
    let data = try JSONSerialization.data(withJSONObject: ["url": normalized.absoluteString])
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
    guard status == errSecSuccess else { throw NeoError("接続設定を保存できませんでした。") }
  }
#if targetEnvironment(simulator)
  static func runStorageSmokeTest() {
    let storage = NeoNative(); storage.service += ".ci-smoke"
    let suite = "io.github.nyanz00.neoepgstation.navigation.ci-smoke"
    storage.preferences = UserDefaults(suiteName: suite)!
    defer { SecItemDelete(storage.query as CFDictionary); storage.preferences.removePersistentDomain(forName: suite) }
    var result: [String: Any] = ["success": false, "navigationSuccess": false]
    do {
      try storage.saveConnection(URL(string: "https://example.com")!)
      let loaded = try storage.loadConnection()
      let legacy = try JSONSerialization.data(withJSONObject: ["url":"https://example.com", "username":"legacy", "password":"fixture"])
      let status = SecItemUpdate(storage.query as CFDictionary, [kSecValueData as String: legacy] as CFDictionary)
      let migrated = try storage.loadConnection()
      let thumbnailDefault = storage.hideRecordedThumbnailButton
      storage.hideRecordedThumbnailButton = false
      let thumbnailSaved = !storage.hideRecordedThumbnailButton
      storage.hideRecordedThumbnailButton = true
      result["thumbnailPreferenceSuccess"] = thumbnailDefault && thumbnailSaved && storage.hideRecordedThumbnailButton
      result["success"] = status == errSecSuccess && loaded == URL(string: "https://example.com") && migrated == loaded
        && thumbnailDefault && thumbnailSaved && storage.hideRecordedThumbnailButton
      try storage.saveShortcuts(["guide","recorded"])
      let saved = storage.shortcuts == ["guide","recorded"]
      do { try storage.saveShortcuts(["unknown"]) } catch { result["navigationSuccess"] = saved }
    } catch { result["error"] = "Storage smoke failed" }
    writeSmoke("storage-smoke", result)
  }
  static func writeSmoke(_ name: String, _ result: [String: Any]) {
    guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let data = try? JSONSerialization.data(withJSONObject: result) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent(name + ".json"))
  }
#endif
}
