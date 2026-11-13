#if targetEnvironment(simulator)
import Foundation
import UIKit

private final class NeoRecordedBulkProtocol: URLProtocol {
  private struct Fixture {
    var value: [String: Any]
    var deleted = false
  }
  private static let lock = NSLock()
  private static var fixtures: [Int: Fixture] = [:]
  private static var listIDs: [Int] = []
  private static var counts: [String: Int] = [:]
  private static var bodies: [String: [[String: Any]]] = [:]
  private static var headers: [String: [[String: String]]] = [:]
  private static var deletedVideoIDs = Set<Int>()
  private static var failedVideoIDs = Set<Int>()
  private static var usersDelay: TimeInterval = 0
  private static var pendingUserResponses = 0
  private static var usersDelayDeadline = Date.distantPast
  private static var holdUserReplies = false, heldUserReplies: [() -> Void] = []
  private var cancelled = false
  private let cancellationLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recorded-bulk.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }

  override func startLoading() {
    let requestBody = Self.bodyData(request)
    let (status, body, delay) = Self.response(for: request, bodyData: requestBody)
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    let deliver: () -> Void = { [self] in
      cancellationLock.lock(); let stopped = cancelled; cancellationLock.unlock()
      Self.finishDelayedUserResponse(request: self.request)
      guard !stopped else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
      client?.urlProtocolDidFinishLoading(self)
    }
    if request.url?.path == "/api/users" {
      Self.lock.lock()
      if Self.holdUserReplies { Self.heldUserReplies.append(deliver); Self.lock.unlock(); return }
      Self.lock.unlock()
    }
    DispatchQueue.global().asyncAfter(deadline:.now()+delay,execute:deliver)
  }

  private static func bodyData(_ request: URLRequest) -> Data {
    if let data = request.httpBody, !data.isEmpty { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  static func reset(_ values: [[String: Any]], failVideoIDs: Set<Int> = [], usersDelay: TimeInterval = 0) {
    lock.lock(); defer { lock.unlock() }
    fixtures = Dictionary(uniqueKeysWithValues: values.compactMap { value in
      guard let id = value["id"] as? Int else { return nil }
      return (id, Fixture(value: value))
    })
    listIDs = values.compactMap { $0["id"] as? Int }
    counts = [:]; bodies = [:]; headers = [:]; deletedVideoIDs = []; self.failedVideoIDs = failVideoIDs; self.usersDelay = usersDelay
    pendingUserResponses = 0
    usersDelayDeadline = .distantPast
  }
  static func setUsersDelay(_ value: TimeInterval) { lock.lock(); usersDelay = value; lock.unlock() }
  static func holdUsers(_ hold: Bool) {
    lock.lock(); holdUserReplies = hold
    let deliveries = hold ? [] : heldUserReplies
    if !hold { heldUserReplies.removeAll() }
    lock.unlock()
    deliveries.forEach { $0() }
  }
  static func setListIDs(_ ids: [Int]) { lock.lock(); listIDs = ids; lock.unlock() }
  static func delayedUsersSettled() -> Bool { lock.lock(); defer { lock.unlock() }; return pendingUserResponses == 0 && Date() >= usersDelayDeadline }
  static func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
  static func body(_ key: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return bodies[key]?.last }
  static func requestHeaders(_ key: String) -> [String: String]? { lock.lock(); defer { lock.unlock() }; return headers[key]?.last }
  static func fileIDsDeleted() -> Set<Int> { lock.lock(); defer { lock.unlock() }; return deletedVideoIDs }

  private static func finishDelayedUserResponse(request: URLRequest) {
    guard request.url?.path == "/api/users" else { return }
    lock.lock(); defer { lock.unlock() }
    pendingUserResponses = max(0, pendingUserResponses - 1)
  }

  private static func response(for request: URLRequest, bodyData: Data) -> (Int, [String: Any], TimeInterval) {
    let path = request.url!.path
    let method = request.httpMethod ?? "GET"
    let key = method + " " + path
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
    lock.lock(); defer { lock.unlock() }
    counts[key, default: 0] += 1
    if method != "GET", !body.isEmpty { bodies[key, default: []].append(body) }
    headers[key, default: []].append(Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }))
    var status = 200, result: [String: Any] = [:], delay: TimeInterval = 0

    if path == "/api/users" && method == "GET" {
      result = ["users": [["id": 7, "name": "Account seven"], ["id": 8, "name": "Account eight"]]]
      delay = usersDelay
      if delay > 0 || holdUserReplies {
        pendingUserResponses += 1
        usersDelayDeadline = max(usersDelayDeadline, Date().addingTimeInterval(delay))
      }
    } else if path == "/api/recorded" && method == "GET" {
      let selectedUser = query.first(where: { $0.name == "userId" })?.value.flatMap(Int.init)
      let offset = max(0, Int(query.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0)
      let limit = max(1, Int(query.first(where: { $0.name == "limit" })?.value ?? "24") ?? 24)
      let matching = listIDs.compactMap { id -> [String: Any]? in
        guard let fixture = fixtures[id], !fixture.deleted, (fixture.value["isHidden"] as? Bool) != true else { return nil }
        if let selectedUser, (fixture.value["userId"] as? Int) != selectedUser { return nil }
        return fixture.value
      }
      result = ["records": Array(matching.dropFirst(offset).prefix(limit)), "total": matching.count]
    } else if path == "/api/recorded/directories" && method == "GET" {
      result = ["directories": ["既存", "保管済み"]]
    } else if path == "/api/recorded/bulk/user" && method == "PUT" {
      guard let ids = body["recordedIds"] as? [Int], let userID = body["userId"] as? Int else { status = 400; return (status, ["message": "bad request"], delay) }
      for id in ids { fixtures[id]?.value["userId"] = userID }
      result = ["updatedCount": ids.count, "movedFileCount": 0]
    } else if path == "/api/recorded/bulk/subDirectory" && method == "PUT" {
      guard let ids = body["recordedIds"] as? [Int], body["subDirectory"] is String else { status = 400; return (status, ["message": "bad request"], delay) }
      result = ["updatedCount": ids.count, "movedFileCount": ids.reduce(0) { total, id in total + ((fixtures[id]?.value["videoFiles"] as? [[String: Any]])?.count ?? 0) }]
    } else if path.hasPrefix("/api/recorded/"), method == "DELETE", let id = Int(path.split(separator: "/").last ?? "") {
      fixtures[id]?.deleted = true
    } else if path.hasPrefix("/api/videos/"), method == "DELETE", let id = Int(path.split(separator: "/").last ?? "") {
      if failedVideoIDs.contains(id) { status = 500; result = ["message": "fixture file delete failure"] }
      else {
        deletedVideoIDs.insert(id)
        for recordingID in Array(fixtures.keys) {
          guard var fixture = fixtures[recordingID], let files = fixture.value["videoFiles"] as? [[String: Any]] else { continue }
          fixture.value["videoFiles"] = files.filter { ($0["id"] as? Int) != id }
          fixtures[recordingID] = fixture
        }
      }
    } else {
      status = 404; result = ["message": "unexpected fixture request: \(method) \(path)"]
    }
    return (status, result, delay)
  }
}

@MainActor enum NeoRecordedBulkSmoke {
  static func run(shell: NeoShell) async -> [String: Bool] {
    let values = [
      record(6801, "Bulk one", userID: 7, files: [(68011, "Original one.ts", "ts"), (68012, "Encode one.mkv", "encoded")]),
      record(6802, "Bulk two", userID: 7, files: [(68021, "Original two.ts", "ts")]),
      record(6803, "Encoding bulk", userID: 7, isEncoding: true, files: [(68031, "Encoding.ts", "ts")]),
      record(6804, "Partial bulk", userID: 7, files: [(68041, "Keep.ts", "ts"), (68042, "Fail.ts", "encoded"), (68043, "Remove.ts", "encoded")]),
      record(6805, "Delete bulk", userID: 7, files: [(68051, "Delete.ts", "ts")])
    ]
    NeoRecordedBulkProtocol.reset(values, failVideoIDs: [68042])
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NeoRecordedBulkProtocol.self]
    let session = URLSession(configuration: config)
    let api = NeoAPI(base: URL(string: "https://recorded-bulk.invalid")!, session: session)
    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "77", "X-Viewer-Session": "fixture-session"])
    api.recordedLength = 2
    defer { api.stopRecordingUpdates() }
    shell.smokeUseAPI(api); shell.showRoute("recorded"); shell.view.layoutIfNeeded()
    NotificationCenter.default.post(name:.neoAccountChanged,object:api)
    NotificationCenter.default.post(name:.neoRecordingPreferencesChanged,object:api)

    var checks: [String: Bool] = [:]
    func waitFor(_ condition: () -> Bool, attempts: Int = 180) async -> Bool {
      for _ in 0..<attempts { if condition() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
      return condition()
    }
    func views(in root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    func button(in root: UIView, label: String) -> UIButton? { views(in: root).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label || $0.title(for:.normal) == label } }
    func userOptionsLoaded(_ dialog: NeoBulkRecordingDialog) -> Bool {
      views(in: dialog.view).compactMap { $0 as? UIButton }.contains { $0.menu?.children.count == 2 }
    }
    func chooseDirectory(_ dialog: NeoBulkRecordingDialog, _ value: String) async -> Bool {
      await waitFor({ dialog.smokeChooseDirectory(value); return dialog.smokeSubDirectory == value })
    }
    func tap(_ button: UIButton?) { button?.sendActions(for: .touchUpInside) }
    func capture(_ name: String) {
      guard let window = shell.view.window else { return }
      window.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
      try? image.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent(name))
    }
    func readyDialog(_ host: NeoRecordedPage) async -> NeoBulkRecordingDialog? {
      _ = await waitFor({ host.smokeBulkDialog?.viewIfLoaded?.window != nil && host.smokeBulkDialog?.isBeingPresented == false && host.presentedViewController === host.smokeBulkDialog })
      return host.smokeBulkDialog
    }
    func tapMenuCommand(_ command: String, host: NeoRecordedPage) async -> Bool {
      if button(in: host.view, label: "一括操作") == nil { return false }
      tap(button(in: host.view, label: "一括操作"))
      let menuReady = await waitFor({ host.presentedViewController is NeoBulkActionsDialog })
      guard menuReady, let menu = host.presentedViewController else { return false }
      tap(button(in: menu.view, label: command))
      return await waitFor({ host.presentedViewController is NeoBulkRecordingDialog })
    }
    guard let nav = shell.children.compactMap({ $0 as? UINavigationController }).first(where: { $0.viewControllers.first is NeoRecordedPage }),
      let host = nav.viewControllers.first as? NeoRecordedPage,
      await waitFor({ host.viewIfLoaded?.window != nil && host.records.map(\.id) == [6801,6802] && host.smokeLoadSettled && nav.topViewController === host }) else {
      checks["recordedBulkPageReady"] = false; return checks
    }
    checks["recordedBulkPageReady"] = true

    host.smokeEnterEditing(); shell.view.layoutIfNeeded()
    let mobileNames = ["すべて選択", "一括操作", "削除", "編集を終了"]
    let wideNames = ["すべて選択", "エンコードを一括追加", "ユーザーを一括変更", "サブディレクトリへ一括移動", "削除", "編集を終了"]
    let isMobile = (shell.view.window?.bounds.width ?? shell.view.bounds.width) < 600
    let expectedNames = isMobile ? mobileNames : wideNames
    checks["editHeaderMatchesCurrentWidth"] = host.smokeEditActionNames == expectedNames
    capture("recorded-bulk-edit.png")
    host.smokeToggleRecording(6801)
    checks["cardSelectionDoesNotOpenDetail"] = host.smokeSelectedIDs == [6801] && shell.route == "recorded" && nav.topViewController === host
    tap(button(in: host.view, label: "すべて選択"))
    checks["selectAllSelectsCurrentPage"] = host.smokeSelectedIDs == [6801, 6802]
    tap(button(in: host.view, label: "すべて解除"))
    checks["selectAllDeselectsCurrentPage"] = host.smokeSelectedIDs.isEmpty
    host.smokeToggleRecording(6801)
    checks["paginationHiddenWhileEditing"] = host.smokePaginationHidden

    if isMobile {
      checks["mobileBulkMenuOpens"] = await tapMenuCommand("エンコードを一括追加", host: host)
    } else { host.smokeOpenBulk(.encode); checks["mobileBulkMenuOpens"] = true }
    if let encode = await readyDialog(host) {
      checks["encodeEntryIsBlankAndReadOnly"] = encode.command == .encode && encode.records.map(\.id) == [6801] && !encode.smokeSubmitEnabled
      capture("recorded-bulk-encode.png")
      // The encode form is intentionally informational only. Close it without enqueuing.
      button(in: encode.view, label: "閉じる")?.sendActions(for: .touchUpInside)
      checks["encodeCancelKeepsSelection"] = await waitFor({ host.presentedViewController == nil && host.smokeSelectedIDs == [6801] })
    } else { checks["encodeEntryIsBlankAndReadOnly"] = false; checks["encodeCancelKeepsSelection"] = false }

    // User assignment waits for its options, prefers the active regular user,
    // and never changes the signed-in account.
    tap(button(in: host.view, label: "すべて選択"))
    let usersBefore = NeoRecordedBulkProtocol.count("GET /api/users")
    let unloadedUserDialog = NeoBulkRecordingDialog(command:.user,records:host.records)
    checks["userSubmitDisabledBeforeOptionsLoad"] = unloadedUserDialog.smokeSelectedUser == nil && !unloadedUserDialog.smokeSubmitEnabled
    host.smokeOpenBulk(.user)
    if let userDialog = await readyDialog(host) {
      let usersReady = await waitFor({ userOptionsLoaded(userDialog) })
      let currentUserSelected = usersReady && userDialog.smokeSelectedUser == 7
      userDialog.smokeSelectUser(0)
      checks["userDialogPrefersCurrentUserAndRejectsMaster"] = currentUserSelected && userDialog.smokeSelectedUser == 7
      capture("recorded-bulk-user.png")
      userDialog.smokeSelectUser(8)
      let enabled = userDialog.smokeSubmitEnabled
      userDialog.smokeTapSubmit()
      userDialog.smokeTapSubmit()
      let sent = await waitFor({ NeoRecordedBulkProtocol.count("PUT /api/recorded/bulk/user") == 1 && !host.smokeEditing })
      let body = NeoRecordedBulkProtocol.body("PUT /api/recorded/bulk/user")
      let sentHeaders = NeoRecordedBulkProtocol.requestHeaders("PUT /api/recorded/bulk/user")
      let ids = (body?["recordedIds"] as? [Int] ?? []).sorted()
      checks["userSelectionSubmitsExactIDsAndTarget"] = enabled && sent && ids == [6801, 6802] && body?["userId"] as? Int == 8
        && sentHeaders?["x-epgstation-user-id"] == "7" && sentHeaders?["x-viewer-profile-id"] == "77"
      let listReloadedForCurrentFilter = await waitFor({ host.presentedViewController == nil && host.smokeBulkDialog == nil
        && host.records.allSatisfy { $0.userId == 7 } && !host.records.contains { [6801, 6802].contains($0.id) } })
      checks["userMutationLeavesAccountAndReloadsFilter"] = api.viewer == "7" && listReloadedForCurrentFilter
      checks["usersWereLoaded"] = NeoRecordedBulkProtocol.count("GET /api/users") > usersBefore
    } else { checks["userSubmitDisabledBeforeOptionsLoad"] = false; checks["userDialogPrefersCurrentUserAndRejectsMaster"] = false; checks["userSelectionSubmitsExactIDsAndTarget"] = false; checks["userMutationLeavesAccountAndReloadsFilter"] = false; checks["usersWereLoaded"] = false }

    // A recording in an active encode must block moves. A normal recording
    // accepts an existing choice, a new name, and the empty root destination.
    host.smokeEnterEditing(); host.smokeToggleRecording(6803); host.smokeOpenBulk(.move)
    if let moveBlocked = await readyDialog(host) {
      let moveChoicesSettled = await waitFor({ NeoRecordedBulkProtocol.count("GET /api/recorded/directories") > 0 })
      checks["encodingDisablesMove"] = moveChoicesSettled && !moveBlocked.smokeSubmitEnabled
      moveBlocked.smokeTapCancel()
      _ = await waitFor({ moveBlocked.presentingViewController == nil && host.smokeBulkDialog == nil })
    } else { checks["encodingDisablesMove"] = false }
    host.smokeEndEditing()
    NeoRecordedBulkProtocol.setListIDs([6804, 6805, 6803, 6801, 6802])
    host.smokeFixtureRefresh()
    let movePairLoaded = await waitFor({ host.records.contains(where: { $0.id == 6804 }) && host.records.contains(where: { $0.id == 6805 }) })
    if movePairLoaded {
      host.smokeEnterEditing(); host.smokeToggleRecording(6804); host.smokeToggleRecording(6805); host.smokeOpenBulk(.move)
      if let moveExisting = await readyDialog(host) {
        let existingReady = await waitFor({ NeoRecordedBulkProtocol.count("GET /api/recorded/directories") > 0 })
        let existingChosen = await chooseDirectory(moveExisting, "既存")
        let canMoveExisting = moveExisting.smokeSubmitEnabled
        moveExisting.smokeTapSubmit()
        let movedExisting = await waitFor({ NeoRecordedBulkProtocol.count("PUT /api/recorded/bulk/subDirectory") == 1 && !host.smokeEditing && host.presentedViewController == nil })
        let existingBody = NeoRecordedBulkProtocol.body("PUT /api/recorded/bulk/subDirectory")
        let existingHeaders = NeoRecordedBulkProtocol.requestHeaders("PUT /api/recorded/bulk/subDirectory")
        checks["moveDirectoryChoiceSubmitsExactSelection"] = existingReady && existingChosen && canMoveExisting && movedExisting
          && (existingBody?["recordedIds"] as? [Int] == [6804, 6805]) && (existingBody?["subDirectory"] as? String == "既存")
          && existingHeaders?["x-viewer-profile-id"] == "77"
        host.smokeEnterEditing(); host.smokeToggleRecording(6804); host.smokeToggleRecording(6805); host.smokeOpenBulk(.move)
        if let moveNew = await readyDialog(host) {
          moveNew.smokeSetSubDirectory("新規")
          let canMoveNew = moveNew.smokeSubmitEnabled
          moveNew.smokeTapSubmit(); moveNew.smokeTapSubmit()
          let movedNew = await waitFor({ NeoRecordedBulkProtocol.count("PUT /api/recorded/bulk/subDirectory") == 2 && !host.smokeEditing && host.presentedViewController == nil })
          let newBody = NeoRecordedBulkProtocol.body("PUT /api/recorded/bulk/subDirectory")
          checks["moveNewDirectorySubmitsOnceForSelection"] = canMoveNew && movedNew && (newBody?["recordedIds"] as? [Int] == [6804, 6805]) && (newBody?["subDirectory"] as? String == "新規")
          host.smokeEnterEditing(); host.smokeToggleRecording(6804); host.smokeToggleRecording(6805); host.smokeOpenBulk(.move)
          if let moveRoot = await readyDialog(host) {
            moveRoot.smokeSetSubDirectory(""); let canMoveRoot = moveRoot.smokeSubmitEnabled
            moveRoot.smokeTapSubmit()
            let movedRoot = await waitFor({ NeoRecordedBulkProtocol.count("PUT /api/recorded/bulk/subDirectory") == 3 && !host.smokeEditing && host.presentedViewController == nil })
            let rootBody = NeoRecordedBulkProtocol.body("PUT /api/recorded/bulk/subDirectory")
            checks["moveEmptyDirectoryTargetsRoot"] = canMoveRoot && movedRoot && (rootBody?["recordedIds"] as? [Int] == [6804, 6805]) && (rootBody?["subDirectory"] as? String == "")
          } else { checks["moveEmptyDirectoryTargetsRoot"] = false }
        } else { checks["moveNewDirectorySubmitsOnceForSelection"] = false; checks["moveEmptyDirectoryTargetsRoot"] = false }
      } else { checks["moveDirectoryChoiceSubmitsExactSelection"] = false; checks["moveNewDirectorySubmitsOnceForSelection"] = false; checks["moveEmptyDirectoryTargetsRoot"] = false }
    } else { checks["moveDirectoryChoiceSubmitsExactSelection"] = false; checks["moveNewDirectorySubmitsOnceForSelection"] = false; checks["moveEmptyDirectoryTargetsRoot"] = false }

    // Delete-by-name has no default target. Two files on the first record are
    // deliberately partial: one succeeds and one fails; another record fully succeeds.
    host.smokeFixtureRefresh()
    _ = await waitFor({ host.records.contains(where: { $0.id == 6804 }) && host.records.contains(where: { $0.id == 6805 }) })
    host.smokeEnterEditing()
    if host.records.contains(where: { $0.id == 6804 }) && host.records.contains(where: { $0.id == 6805 }) {
      host.smokeToggleRecording(6804); host.smokeToggleRecording(6805); host.smokeOpenBulk(.delete)
      if let delete = await readyDialog(host) {
        delete.smokeSelectDeleteOption(.names)
        checks["emptyDeleteNamesDisableSubmit"] = !delete.smokeSubmitEnabled
        delete.smokeToggleDeleteName("Fail.ts"); delete.smokeToggleDeleteName("Remove.ts"); delete.smokeToggleDeleteName("Delete.ts")
        let enabled = delete.smokeSubmitEnabled
        delete.smokeTapSubmit(); delete.smokeTapSubmit()
        let completed = await waitFor({ host.presentedViewController == nil && host.smokeSelectedIDs == [6804] && NeoRecordedBulkProtocol.fileIDsDeleted().contains(68043)
          && host.records.first(where: { $0.id == 6804 })?.videoFiles?.map(\.id) == [68041,68042]
          && host.records.first(where: { $0.id == 6805 })?.videoFiles?.isEmpty == true })
        let finalBodies = ["DELETE /api/videos/68042", "DELETE /api/videos/68043", "DELETE /api/videos/68051"].map(NeoRecordedBulkProtocol.count)
        checks["partialDeleteUpdatesFilesAndKeepsFailedRecordSelected"] = enabled && completed && finalBodies == [1, 1, 1]
          && host.records.first(where: { $0.id == 6805 })?.videoFiles?.isEmpty == true
      } else { checks["emptyDeleteNamesDisableSubmit"] = false; checks["partialDeleteUpdatesFilesAndKeepsFailedRecordSelected"] = false }
    } else { checks["emptyDeleteNamesDisableSubmit"] = false; checks["partialDeleteUpdatesFilesAndKeepsFailedRecordSelected"] = false }

    // Cancel an in-flight choice load by switching account identity. No stale
    // user dialog may submit under the new viewer.
    NeoRecordedBulkProtocol.holdUsers(true)
    host.smokeEndEditing(); host.smokeEnterEditing()
    if let available = host.records.first {
      host.smokeToggleRecording(available.id)
      let staleUsersBefore = NeoRecordedBulkProtocol.count("GET /api/users")
      host.smokeOpenBulk(.user)
      if let stale = await readyDialog(host) {
        let staleRequestStarted = await waitFor({ NeoRecordedBulkProtocol.count("GET /api/users") > staleUsersBefore })
        let responseWasHeld = !NeoRecordedBulkProtocol.delayedUsersSettled()
        api.activate(user: "9", headers: ["X-Viewer-Profile-Id": "99", "X-Viewer-Session": "other-fixture-session"])
        NeoRecordedBulkProtocol.holdUsers(false)
        let cancelled = await waitFor({ host.presentedViewController == nil && host.smokeBulkDialog == nil })
        let responseFinished = await waitFor({ NeoRecordedBulkProtocol.delayedUsersSettled() })
        stale.smokeSelectUser(8); stale.smokeTapSubmit()
        checks["accountSwitchCancelsStaleChoicesWithoutMutation"] = staleRequestStarted && responseWasHeld && responseFinished && cancelled
          && NeoRecordedBulkProtocol.count("PUT /api/recorded/bulk/user") == 1 && NeoRecordedBulkProtocol.count("PUT /api/recorded/bulk/subDirectory") == 3 && host.smokeSelectedIDs.isEmpty
      } else { checks["accountSwitchCancelsStaleChoicesWithoutMutation"] = false }
    } else { checks["accountSwitchCancelsStaleChoicesWithoutMutation"] = false }
    NeoRecordedBulkProtocol.holdUsers(false)

    // Actual keyboard Return control event is sent to a rendered search field;
    // onApply must receive the committed field value and its return key is Search.
    let search = NeoRecordedSearch(api: api, channels: [:], userID: nil, filters: NeoRecordedFilters())
    search.smokeFixtures = true
    var appliedKeyword: String?
    search.onApply = { appliedKeyword = $0.keyword }
    let searchNav = UINavigationController(rootViewController: search); searchNav.overrideUserInterfaceStyle = .dark
    host.present(searchNav, animated: false)
    let searchVisible = await waitFor({ search.viewIfLoaded?.window != nil })
    let keyword = views(in: search.view).compactMap { $0 as? UITextField }.first { $0.accessibilityLabel == "キーワード" }
    keyword?.text = "Bulk Return"
    keyword?.sendActions(for: .editingChanged)
    let returnType = keyword?.returnKeyType == .search
    keyword?.sendActions(for: .editingDidEndOnExit)
    let applied = await waitFor({ appliedKeyword == "Bulk Return" })
    checks["searchReturnRunsApplyWithLatestKeyword"] = searchVisible && returnType && applied
    search.dismiss(animated: false)
    // The shared UI runner expects the retained root list's four-item fixture
    // after every scenario, independently of earlier ownership/deletion tests.
    NeoRecordedBulkProtocol.reset(Array(values.prefix(4)))
    api.activate(user:"7",headers:["X-Viewer-Profile-Id":"77","X-Viewer-Session":"fixture-session"])
    api.recordedLength = 24
    NotificationCenter.default.post(name:.neoRecordingPreferencesChanged,object:api)
    host.smokeEndEditing(); host.smokeFixtureRefresh()
    checks["finalRecordedPageRestored"] = await waitFor({ host.records.map(\.id) == [6801,6802,6803,6804] && host.smokeLoadSettled && host.presentedViewController == nil })
    return checks
  }

  private static func record(_ id: Int, _ name: String, userID: Int, isEncoding: Bool = false,
    files: [(Int, String, String)]) -> [String: Any] {
    ["id": id, "name": name, "startAt": 1_790_000_000_000.0, "endAt": 1_790_003_600_000.0,
      "isRecording": false, "channelId": 1, "channelName": "Fixture Channel", "isEncoding": isEncoding,
      "userId": userID, "videoFiles": files.map { ["id": $0.0, "name": $0.1, "type": $0.2, "size": 1024.0] }]
  }
}
#endif
