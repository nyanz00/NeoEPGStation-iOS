#if targetEnvironment(simulator)
import UIKit

private final class NeoAccountFixture: URLProtocol {
  static var valid = true
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    var code = 200, value = "{}"
    if path.hasSuffix("/users") { value = #"{"users":[{"id":7,"name":"Protected"},{"id":8,"name":"Unprotected"}]}"# }
    else if path.hasSuffix("/viewer-profiles") { value = #"{"profiles":[{"id":71,"name":"Protected","tvUserId":7,"lockRequired":true}]}"# }
    else if path.hasSuffix("/session") { value = Self.valid ? #"{"valid":true}"# : #"{"valid":false}"# }
    else if path.hasSuffix("/unlock") {
      let body = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
        stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }; return data
      }
      let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
      if json?["password"] == "fixture" { value = #"{"sessionToken":"ssssssssssssssssssssssssssssssss"}"# }
      else { code = 403; value = #"{"errors":"連携パスワードが違います"}"# }
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(value.utf8)); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor enum NeoAccountSmoke {
  private static func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }; return false
  }
  static func run(_ shell: NeoShell) async {
    let original = shell.api
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NeoAccountFixture.self]
    let session = URLSession(configuration: config)
    let base = URL(string: "https://account-fixture.invalid/epg")!, other = URL(string: "https://other-account-fixture.invalid/epg")!
    let api = NeoAPI(base: base, session: session), secrets = NeoProfileSecrets(server: base), isolated = NeoProfileSecrets(server: other)
    let oldViewer = api.viewer
    api.viewer = "master"; secrets.remove(71); isolated.remove(71)
    shell.smokeUseAPI(api)
    defer {
      shell.presentedViewController?.dismiss(animated: false); secrets.remove(71); isolated.remove(71)
      api.viewer = oldViewer; shell.smokeUseAPI(original); session.invalidateAndCancel()
    }
    var checks: [String: Bool] = [:]
    do {
      try secrets.save(71, token: String(repeating: "s", count: 32))
      checks["keychainRoundTrip"] = try secrets.read(71)?.count == 32
      checks["serverIsolation"] = try isolated.read(71) == nil
      secrets.remove(71); checks["keychainRemoval"] = try secrets.read(71) == nil
    } catch { checks["keychainRoundTrip"] = false }
    guard let account = shell.account else { NeoNative.writeSmoke("account-smoke", ["success": false]); return }
    let menu: [UIMenuElement] = await withCheckedContinuation { continuation in
      account.loadSelectionMenu { continuation.resume(returning: $0) }
    }
    let actions = menu.compactMap { $0 as? UIAction }
    checks["nativeMenuListsUsersAndMaster"] = actions.count == 3 && actions.first?.title == "master（すべて）" && actions.first?.state == .on
    checks["openingMenuKeepsIdentity"] = api.viewer == "master" && api.accountReady && !account.busy
    account.smokeSelect("8")
    checks["unprotectedSwitch"] = await wait { api.viewer == "8" && api.accountReady && !account.busy }
    account.smokeSelect("7")
    checks["protectedWaitsForPassword"] = await wait { shell.presentedViewController is UIAlertController && !account.busy }
    checks["pendingSwitchKeepsCurrentUser"] = api.viewer == "8"
    shell.presentedViewController?.dismiss(animated: false)
    _ = await wait { shell.presentedViewController == nil }
    account.smokeUnlock("7", password: "wrong")
    checks["wrongPasswordKeepsCurrentUser"] = await wait { shell.presentedViewController is UIAlertController && !account.busy && api.viewer == "8" }
    shell.presentedViewController?.dismiss(animated: false)
    _ = await wait { shell.presentedViewController == nil }
    account.smokeUnlock("7", password: "fixture")
    checks["successfulUnlockCommitsUserAndSession"] = await wait { api.viewer == "7" && api.accountReady && !account.busy && api.profileHeaders["X-Viewer-Session"]?.count == 32 }
    NeoAccountFixture.valid = true; account.restore()
    checks["savedSessionIsValidated"] = await wait { api.accountReady && !account.busy && api.viewer == "7" }
    NeoAccountFixture.valid = false; account.restore()
    checks["revocationRequiresReauthentication"] = await wait { !api.accountReady && !account.busy && shell.presentedViewController is UIAlertController }
    checks["revocationDeletesStoredToken"] = (try? secrets.read(71)) == nil
    shell.presentedViewController?.dismiss(animated: false); account.lockCurrent()
    checks["masterHasNoProfileSession"] = api.viewer == "master" && api.accountReady && api.profileHeaders.isEmpty
    account.smokeSelect("8"); account.lockCurrent()
    try? await Task.sleep(nanoseconds: 200_000_000)
    checks["lateSwitchCannotUndoMasterSelection"] = api.viewer == "master" && !account.busy && api.profileHeaders.isEmpty
    NeoAccountFixture.valid = true
    NeoNative.writeSmoke("account-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
  }
}
#endif
