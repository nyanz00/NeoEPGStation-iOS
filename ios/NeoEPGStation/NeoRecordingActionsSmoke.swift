#if targetEnvironment(simulator)
import Foundation
import UIKit

private final class NeoRecordingActionsProtocol: URLProtocol {
  private struct Fixture {
    var value: [String: Any]
    var detailRequests = 0
    var thumbnailReplacements = 0
    var requestsSinceReplacement = 0
    var replacementThumbnails: [Int]?
  }

  private static let lock = NSLock()
  private static var fixtures: [Int: Fixture] = [:]
  private static var listIDs: [Int] = []
  private static var counts: [String: Int] = [:]
  private static var assignedUsers: [Int: Int] = [:]
  private static var fileDeleteFailures = Set<Int>()
  private static var deletedRecordIDs = Set<Int>()
  private static var deletedFileIDs = [Int]()
  private static var replacedThumbnailFileIDs = [Int]()
  private static var usersDelay: TimeInterval = 0
  private var cancelled = false
  private let cancellationLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "recording-actions.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {
    cancellationLock.lock(); cancelled = true; cancellationLock.unlock()
  }

  override func startLoading() {
    let (status, body, delay) = Self.response(for: request)
    let data = try! JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
      cancellationLock.lock(); let stopped = cancelled; cancellationLock.unlock()
      guard !stopped else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  static func reset(_ values: [[String: Any]], failVideoIDs: Set<Int> = [], usersDelay: TimeInterval = 0) {
    lock.lock(); defer { lock.unlock() }
    fixtures = Dictionary(uniqueKeysWithValues: values.compactMap { value in
      guard let id = value["id"] as? Int else { return nil }
      return (id, Fixture(value: value))
    })
    listIDs = fixtures.keys.sorted().prefix(4).map { $0 }
    counts = [:]; assignedUsers = [:]; fileDeleteFailures = failVideoIDs
    deletedRecordIDs = []; deletedFileIDs = []; replacedThumbnailFileIDs = []
    self.usersDelay = usersDelay
  }

  static func setUsersDelay(_ delay: TimeInterval) {
    lock.lock(); usersDelay = delay; lock.unlock()
  }

  static func setListIDs(_ values: [Int]) {
    lock.lock(); listIDs = values; lock.unlock()
  }

  static func setThumbnailResult(recordingID: Int, thumbnails: [Int]) {
    lock.lock(); defer { lock.unlock() }
    fixtures[recordingID]?.replacementThumbnails = thumbnails
  }

  static func count(_ request: String) -> Int {
    lock.lock(); defer { lock.unlock() }; return counts[request, default: 0]
  }

  static func assignedUser(_ recordingID: Int) -> Int? {
    lock.lock(); defer { lock.unlock() }; return assignedUsers[recordingID]
  }

  static func deletedVideos() -> [Int] {
    lock.lock(); defer { lock.unlock() }; return deletedFileIDs
  }

  static func replacedThumbnails() -> [Int] {
    lock.lock(); defer { lock.unlock() }; return replacedThumbnailFileIDs
  }

  static func deletedRecords() -> Set<Int> {
    lock.lock(); defer { lock.unlock() }; return deletedRecordIDs
  }

  private static func response(for request: URLRequest) -> (Int, [String: Any], TimeInterval) {
    let path = request.url!.path
    let parts = path.split(separator: "/").map(String.init)
    let method = request.httpMethod ?? "GET"
    let key = method + " " + path
    lock.lock(); defer { lock.unlock() }
    counts[key, default: 0] += 1
    var status = 200, result: [String: Any] = [:], delay: TimeInterval = 0

    if path == "/api/users" && method == "GET" {
      result = ["users": [["id": 7, "name": "Fixture user"], ["id": 9, "name": "Other user"]]]
      delay = usersDelay
    } else if path == "/api/recorded" && method == "GET" {
      let values = listIDs.compactMap { id in deletedRecordIDs.contains(id) ? nil : fixtures[id]?.value }
      result = ["records": values, "total": values.count]
    } else if parts.count == 3, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), method == "GET" {
      if var fixture = fixtures[id], !deletedRecordIDs.contains(id) {
        fixture.detailRequests += 1
        if fixture.thumbnailReplacements > 0 {
          fixture.requestsSinceReplacement += 1
          if fixture.requestsSinceReplacement >= 1, let changed = fixture.replacementThumbnails { fixture.value["thumbnails"] = changed }
        }
        fixtures[id] = fixture
        result = fixture.value
      } else { status = 404; result = ["message": "fixture recording not found"] }
    } else if parts.count == 4, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), parts[3] == "user", method == "PUT" {
      // URLSession can expose upload bytes as httpBodyStream inside a custom
      // URLProtocol. A missing httpBody does not mean an empty HTTP request.
      var bytes = request.httpBody ?? Data()
      if bytes.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating:0,count:4096)
        while true {
          let count = stream.read(&buffer,maxLength:buffer.count)
          if count <= 0 { break }; bytes.append(contentsOf:buffer.prefix(count))
        }
      }
      let body = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
      if let userID = body["userId"] as? Int {
        assignedUsers[id] = userID
        if var fixture = fixtures[id] { fixture.value["userId"] = userID; fixtures[id] = fixture }
      }
      else { status = 400 }
    } else if parts.count == 4, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), ["protect", "unprotect"].contains(parts[3]), method == "PUT" {
      if var fixture = fixtures[id] { fixture.value["isProtected"] = parts[3] == "protect"; fixtures[id] = fixture }
      else { status = 404 }
    } else if parts.count == 3, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), method == "DELETE" {
      deletedRecordIDs.insert(id)
    } else if parts.count == 3, parts[0] == "api", parts[1] == "videos", let fileID = Int(parts[2]), method == "DELETE" {
      if fileDeleteFailures.contains(fileID) {
        status = 500; result = ["message": "fixture file delete failure"]
      } else {
        deletedFileIDs.append(fileID)
        for id in Array(fixtures.keys) {
          guard var fixture = fixtures[id], let videos = fixture.value["videoFiles"] as? [[String: Any]] else { continue }
          fixture.value["videoFiles"] = videos.filter { ($0["id"] as? Int) != fileID }
          fixtures[id] = fixture
        }
      }
    } else if parts.count == 5, parts[0] == "api", parts[1] == "thumbnails", parts[2] == "videos", let fileID = Int(parts[3]), parts[4] == "replace", method == "POST" {
      replacedThumbnailFileIDs.append(fileID)
      var found = false
      for id in Array(fixtures.keys) {
        guard var fixture = fixtures[id], let videos = fixture.value["videoFiles"] as? [[String: Any]], videos.contains(where: { ($0["id"] as? Int) == fileID }) else { continue }
        fixture.thumbnailReplacements += 1; fixture.requestsSinceReplacement = 0; fixtures[id] = fixture; found = true
      }
      if !found { status = 404 }
    } else {
      status = 404; result = ["message": "unexpected fixture request"]
    }
    return (status, result, delay)
  }
}

private final class NeoRecordingActionsEventFlag {
  private let lock = NSLock()
  private var value = false
  func set() { lock.lock(); value = true; lock.unlock() }
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor enum NeoRecordingActionsSmoke {
  static func run(shell: NeoShell) async -> [String: Bool] {
    let savedDeleteDefault = UserDefaults.standard.object(forKey: "recorded.deleteDefault." + "https://recording-actions.invalid")
    let values = [
      record(6101, files: [(61011, "Protect.ts", 1024)], protected: false),
      record(6102, files: [(61021, "User.ts", 2048)]),
      record(6103, files: [(61031, "Original.ts", 4096), (61032, "Encoded.mkv", 8192)], thumbnails: [63]),
      record(6104, files: [(61041, "Keep.ts", 1024), (61042, "Remove.ts", 2048), (61043, "Other.ts", 3072)]),
      record(6105, files: [(61051, "First.ts", 1024), (61052, "Second.ts", 2048)]),
      record(6106, files: [(61061, "First partial.ts", 1024), (61062, "Fails.ts", 2048), (61063, "Keep partial.ts", 3072)]),
      record(6107, files: [(61071, "Cancel.ts", 1024)])
    ]
    NeoRecordingActionsProtocol.reset(values, failVideoIDs: [61062])
    NeoRecordingActionsProtocol.setThumbnailResult(recordingID: 6103, thumbnails: [64])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoRecordingActionsProtocol.self]
    let session = URLSession(configuration: configuration)
    let api = NeoAPI(base: URL(string: "https://recording-actions.invalid")!, session: session)
    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "fixture-session"])
    api.deleteRecordedDefaultValue = false
    defer {
      api.stopRecordingUpdates()
      if let savedDeleteDefault { UserDefaults.standard.set(savedDeleteDefault, forKey: "recorded.deleteDefault." + "https://recording-actions.invalid") }
      else { UserDefaults.standard.removeObject(forKey: "recorded.deleteDefault." + "https://recording-actions.invalid") }
    }
    shell.smokeUseAPI(api)
    shell.showRoute("recorded")
    shell.view.layoutIfNeeded()

    var checks: [String: Bool] = [:]
    func waitFor(_ condition: () -> Bool, attempts: Int = 120) async -> Bool {
      for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return condition()
    }
    func dismiss(_ controller: UIViewController) async {
      guard controller.presentingViewController != nil else { return }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        controller.dismiss(animated: false) { continuation.resume() }
      }
    }
    func capture(_ host: UIViewController, name: String) {
      guard let window = host.view.window else { return }
      window.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try? image.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent(name))
    }
    func actionDialog(_ host: NeoPage) async -> NeoRecordingActionDialog? {
      for _ in 0..<120 {
        if let dialog = host.presentedViewController as? NeoRecordingActionDialog {
          _ = await waitFor({ dialog.viewIfLoaded?.window != nil && !dialog.isBeingPresented })
          return dialog
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return host.presentedViewController as? NeoRecordingActionDialog
    }
    func finishAction(_ host: NeoPage) async {
      if await waitFor({ host.presentedViewController == nil && host.recordingActions == nil }) { return }
      // Keep evidence for the failed assertion, then isolate the next action.
      // Otherwise one retained error dialog blocks every subsequent test.
      host.recordingActions?.cancel()
      if let presented = host.presentedViewController { await dismiss(presented) }
      _ = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })
    }

    guard let navigation = shell.children.compactMap({ $0 as? UINavigationController }).first(where: { $0.viewControllers.first is NeoRecordedPage }) else {
      checks["recordedPageAttached"] = false
      return checks
    }
    navigation.popToRootViewController(animated: false)
    shell.view.layoutIfNeeded()
    guard let host = navigation.viewControllers.first as? NeoRecordedPage,
      await waitFor({ host.viewIfLoaded?.window != nil && navigation.transitionCoordinator == nil }) else {
      checks["recordedPageAttached"] = false
      return checks
    }
    checks["recordedPageAttached"] = true

    let search = NeoRecordedSearch(api: api, channels: [:], userID: nil, filters: NeoRecordedFilters())
    search.smokeFixtures = true
    let searchNavigation = UINavigationController(rootViewController: search)
    searchNavigation.modalPresentationStyle = .pageSheet
    searchNavigation.sheetPresentationController?.detents = [.large()]
    searchNavigation.overrideUserInterfaceStyle = .dark
    host.present(searchNavigation, animated: true)
    let searchPresented = await waitFor({
      host.presentedViewController === searchNavigation && search.viewIfLoaded?.window != nil && !searchNavigation.isBeingPresented
    })
    checks["recordedSearchActuallyPresented"] = searchPresented
    checks["recordedSearchFixtureOptionsLoaded"] = search.smokeValid
    checks["recordedSearchFocusedBeforeDidAppear"] = search.smokeFocusedBeforeAppearanceCompleted
    await dismiss(searchNavigation)
    _ = await waitFor({ host.presentedViewController == nil })

    let protectItem = item(values[0])
    host.performRecordingAction(.protect, item: protectItem)
    let protected = await waitFor({
      NeoRecordingActionsProtocol.count("PUT /api/recorded/6101/protect") == 1 && host.recordingActions == nil
    })
    checks["protectViaHostAction"] = protected
    host.performRecordingAction(.unprotect, item: protectItem)
    checks["unprotectViaHostAction"] = await waitFor({
      NeoRecordingActionsProtocol.count("PUT /api/recorded/6101/unprotect") == 1 && host.recordingActions == nil
    })

    host.performRecordingAction(.user, item: item(values[1]))
    if let dialog = await actionDialog(host) {
      let usersReady = await waitFor({ !dialog.smokeBusy && dialog.selectedUser == 7 })
      checks["userDialogPresentedAndLoaded"] = usersReady
      capture(host, name: "recording-actions-user.png")
      dialog.smokeSelectUser(9)
      let enabled = dialog.selectedUser == 9 && dialog.smokeSubmitEnabled
      dialog.smokeTapSubmit()
      let assigned = await waitFor({
        NeoRecordingActionsProtocol.assignedUser(6102) == 9 && host.recordingActions == nil
      })
      checks["userSelectionEnablesSubmit"] = enabled
      checks["userAssignmentFromDialogButton"] = assigned
      let assignmentReloaded = await waitFor({ host.records.first(where: { $0.id == 6102 })?.userId == 9 })
      checks["userAssignmentReloadsRecordedList"] = assignmentReloaded
      await finishAction(host)
    } else { checks["userDialogPresentedAndLoaded"] = false }

    let thumbnailNotifications = NeoRecordingActionsEventFlag()
    let thumbnailObserver = NotificationCenter.default.addObserver(forName: .neoRecordedChanged, object: nil, queue: .main) { note in
      guard (note.object as? NeoAPI) === api else { return }
      if note.userInfo?["recordingID"] as? Int == 6103 && note.userInfo?["thumbnail"] as? Bool == true { thumbnailNotifications.set() }
    }
    host.performRecordingAction(.thumbnail, item: item(values[2]))
    if let dialog = await actionDialog(host) {
      let defaultedToFirst = dialog.selectedFile == 61031
      dialog.smokeSelectFile(61032)
      let changedSelection = dialog.selectedFile == 61032
      dialog.smokeTapSubmit()
      let queued = await waitFor({ NeoRecordingActionsProtocol.replacedThumbnails().contains(61032) })
      let refreshed = await waitFor({ thumbnailNotifications.isSet }, attempts: 320)
      checks["thumbnailStartsOnFirstFile"] = defaultedToFirst
      checks["thumbnailFileSelection"] = changedSelection
      checks["thumbnailReplaceQueuedFromDialog"] = queued
      checks["thumbnailChangeObservedAndRefreshed"] = refreshed && NeoRecordingActionsProtocol.count("GET /api/recorded/6103") >= 2
    } else {
      checks["thumbnailStartsOnFirstFile"] = false
      checks["thumbnailFileSelection"] = false
      checks["thumbnailReplaceQueuedFromDialog"] = false
      checks["thumbnailChangeObservedAndRefreshed"] = false
    }
    NotificationCenter.default.removeObserver(thumbnailObserver)
    await finishAction(host)

    host.performRecordingAction(.delete, item: item(values[3]))
    if let dialog = await actionDialog(host) {
      capture(host, name: "recording-actions-delete.png")
      dialog.smokeToggleFile(61042)
      let selectedOnlyOne = dialog.selectedFiles == [61042]
      dialog.smokeTapSubmit()
      let deletedOne = await waitFor({
        NeoRecordingActionsProtocol.deletedVideos().contains(61042) && host.recordingActions == nil
      })
      let refreshedRecord = await waitFor({
        host.records.first(where: { $0.id == 6104 })?.videoFiles?.contains(where: { $0.id == 61042 }) == false
      })
      checks["subsetDeleteUsesVideoEndpoint"] = selectedOnlyOne && deletedOne
      checks["subsetDeleteKeepsRecord"] = !NeoRecordingActionsProtocol.deletedRecords().contains(6104)
      checks["subsetDeleteReloadShowsRemainingFiles"] = refreshedRecord && host.records.first(where: { $0.id == 6104 })?.videoFiles?.count == 2
      await finishAction(host)
    } else {
      checks["subsetDeleteUsesVideoEndpoint"] = false
      checks["subsetDeleteKeepsRecord"] = false
      checks["subsetDeleteReloadShowsRemainingFiles"] = false
    }

    NeoRecordingActionsProtocol.setListIDs([6101, 6102, 6103, 6105])
    host.performRecordingAction(.delete, item: item(values[4]))
    if let dialog = await actionDialog(host) {
      dialog.smokeToggleFile(61051); dialog.smokeToggleFile(61052)
      let allSelected = dialog.selectedFiles == [61051, 61052]
      dialog.smokeTapSubmit()
      let deletedAll = await waitFor({
        NeoRecordingActionsProtocol.deletedRecords().contains(6105) && host.recordingActions == nil
          && !host.records.contains(where: { $0.id == 6105 })
      })
      checks["allFilesDeleteWholeRecording"] = allSelected && deletedAll
      checks["allDeletionReloadRemovesRecording"] = deletedAll
      await finishAction(host)
    } else { checks["allFilesDeleteWholeRecording"] = false; checks["allDeletionReloadRemovesRecording"] = false }

    NeoRecordingActionsProtocol.setListIDs([6101, 6102, 6103, 6104])
    host.performRecordingAction(.delete, item: item(values[5]))
    if let dialog = await actionDialog(host) {
      dialog.smokeToggleFile(61061); dialog.smokeToggleFile(61062); dialog.smokeTapSubmit()
      let partialFailure = await waitFor({
        dialog.smokeMessage?.hasPrefix("一部のファイルは削除されました。") == true && !dialog.smokeBusy && host.presentedViewController === dialog
      })
      checks["partialFailureKeepsDialogAndExplainsSucceededSubset"] = partialFailure && dialog.selectedFiles == [61062]
      checks["partialFailureOnlyDeletesEarlierFile"] = NeoRecordingActionsProtocol.deletedVideos().contains(61061)
        && !NeoRecordingActionsProtocol.deletedVideos().contains(61062)
      dialog.smokeTapCancel()
      await finishAction(host)
    } else {
      checks["partialFailureKeepsDialogAndExplainsSucceededSubset"] = false
      checks["partialFailureOnlyDeletesEarlierFile"] = false
    }

    NeoRecordingActionsProtocol.setUsersDelay(1.5)
    let previousUserRequestCount = NeoRecordingActionsProtocol.count("GET /api/users")
    host.performRecordingAction(.user, item: item(values[6]))
    if let dialog = await actionDialog(host) {
      let requestStarted = await waitFor({ NeoRecordingActionsProtocol.count("GET /api/users") > previousUserRequestCount })
      let pendingLoadAllowsCancel = !dialog.smokeBusy && !dialog.smokeSubmitEnabled && dialog.smokeCancelEnabled
      api.activate(user: "9", headers: ["X-Viewer-Profile-Id": "22", "X-Viewer-Session": "fixture-session"])
      let cancelled = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })
      checks["identityChangeCancelsPendingUserLoad"] = requestStarted && pendingLoadAllowsCancel && cancelled
      checks["identityCancelDoesNotAssignUser"] = NeoRecordingActionsProtocol.assignedUser(6107) == nil
    } else {
      checks["identityChangeCancelsPendingUserLoad"] = false
      checks["identityCancelDoesNotAssignUser"] = false
    }

    api.stopRecordingUpdates()
    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "fixture-session"])
    NeoRecordingActionsProtocol.setUsersDelay(0)
    NeoRecordingActionsProtocol.setListIDs([6101, 6102, 6103, 6104])
    api.recordingChanged(6101)
    let finalList = await waitFor({ host.records.count == 4 && host.records.first(where: { $0.id == 6102 })?.userId == 9 })
    checks["finalRecordedListHasFourRecords"] = host.records.count == 4
    checks["finalRecordedRouteHasFourRefreshedItems"] = finalList && shell.route == "recorded"
    shell.showRoute("recorded")
    return checks
  }

  private static func record(_ id: Int, files: [(Int, String, Int)], thumbnails: [Int] = [1], protected: Bool = false) -> [String: Any] {
    ["id": id, "name": "Fixture recording \(id)", "startAt": 1_700_000_000_000, "endAt": 1_700_001_800_000,
      "isRecording": false, "description": "Fixture description", "extended": "", "channelId": NSNull(), "channelName": NSNull(),
      "thumbnails": thumbnails, "videoFiles": files.map { file -> [String: Any] in ["id": file.0, "name": file.1, "type": "TS", "size": file.2] },
      "isProtected": protected, "userId": 7]
  }

  private static func item(_ value: [String: Any]) -> NeoRecording {
    try! JSONDecoder().decode(NeoRecording.self, from: JSONSerialization.data(withJSONObject: value))
  }
}

private final class NeoActiveRecordingsProtocol: URLProtocol {
  private struct Fixture { var value: [String: Any] }

  private static let lock = NSLock()
  private static var fixtures: [Int: Fixture] = [:]
  private static var listIDs: [Int] = []
  private static var dropValues: [Int: [String: Any]] = [:]
  private static var removedIDs = Set<Int>()
  private static var stoppedIDs = Set<Int>()
  private static var deletedVideoIDs: [Int] = []
  private static var counts: [String: Int] = [:]
  private static var authPasses = 0
  private static var authFailures = 0
  private var cancelled = false
  private let cancellationLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "recording-active.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {
    cancellationLock.lock(); cancelled = true; cancellationLock.unlock()
  }

  override func startLoading() {
    let (status, body) = Self.response(for: request)
    let data = try! JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    DispatchQueue.global().async { [self] in
      cancellationLock.lock(); let stopped = cancelled; cancellationLock.unlock()
      guard !stopped else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  static func reset(_ values: [[String: Any]], drops: [Int: [String: Any]]) {
    lock.lock(); defer { lock.unlock() }
    fixtures = Dictionary(uniqueKeysWithValues: values.compactMap { value in
      guard let id = value["id"] as? Int else { return nil }
      return (id, Fixture(value: value))
    })
    listIDs = fixtures.keys.sorted()
    dropValues = drops; removedIDs = []; stoppedIDs = []; deletedVideoIDs = []; counts = [:]
    authPasses = 0; authFailures = 0
  }

  static func count(_ method: String, _ path: String) -> Int {
    lock.lock(); defer { lock.unlock() }
    return counts[method + " " + path, default: 0]
  }
  static func stopped() -> Set<Int> {
    lock.lock(); defer { lock.unlock() }; return stoppedIDs
  }
  static func deletedVideos() -> [Int] {
    lock.lock(); defer { lock.unlock() }; return deletedVideoIDs
  }
  static func authSummary() -> (passes: Int, failures: Int) {
    lock.lock(); defer { lock.unlock() }; return (authPasses, authFailures)
  }

  private static func response(for request: URLRequest) -> (Int, Any) {
    let path = request.url!.path
    let parts = path.split(separator: "/").map(String.init)
    let method = request.httpMethod ?? "GET"
    let key = method + " " + path
    lock.lock(); defer { lock.unlock() }
    counts[key, default: 0] += 1

    guard path == "/api/recording" || path.hasPrefix("/api/recording/") || path.hasPrefix("/api/recorded/")
      || path.hasPrefix("/api/videos/") else { return (404, ["message": "unexpected fixture request"]) }
    let hasIdentity = request.value(forHTTPHeaderField: "X-EPGStation-User-Id") == "7"
      && request.value(forHTTPHeaderField: "X-Viewer-Profile-Id") == "21"
      && request.value(forHTTPHeaderField: "X-Viewer-Session") == "active-recording-session"
    if hasIdentity { authPasses += 1 } else { authFailures += 1 }
    guard hasIdentity else { return (401, ["message": "fixture authentication failed"]) }

    if path == "/api/recording", method == "GET" {
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let offset = Int(query.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
      let limit = Int(query.first(where: { $0.name == "limit" })?.value ?? "24") ?? 24
      let activeIDs = listIDs.filter { !removedIDs.contains($0) }
      let page = activeIDs.dropFirst(max(0, offset)).prefix(max(0, limit))
      return (200, ["records": page.compactMap { fixtures[$0]?.value }, "total": activeIDs.count])
    }
    if path == "/api/recording/dropStatus", method == "GET" {
      let statuses = listIDs.filter { !removedIDs.contains($0) }.compactMap { id -> [String: Any]? in
        guard let value = dropValues[id] else { return nil }
        return ["recordedId": id, "dropLogFile": value]
      }
      return (200, statuses as [[String: Any]])
    }
    if parts.count == 4, parts[0] == "api", parts[1] == "recording", let id = Int(parts[2]), parts[3] == "stop", method == "POST" {
      guard fixtures[id] != nil, !removedIDs.contains(id) else { return (404, ["message": "active recording not found"]) }
      stoppedIDs.insert(id); removedIDs.insert(id)
      return (200, ["code": 200])
    }
    if parts.count == 3, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), method == "GET" {
      guard let fixture = fixtures[id] else { return (404, ["message": "recording fixture not found"]) }
      return (200, fixture.value)
    }
    if parts.count == 3, parts[0] == "api", parts[1] == "videos", let fileID = Int(parts[2]), method == "DELETE" {
      guard let id = fixtures.first(where: { _, fixture in
        guard let files = fixture.value["videoFiles"] as? [[String: Any]] else { return false }
        return files.contains { ($0["id"] as? Int) == fileID }
      })?.key else { return (404, ["message": "video fixture not found"]) }
      deletedVideoIDs.append(fileID)
      if fixtures[id]?.value["isRecording"] as? Bool == true {
        removedIDs.insert(id)
      } else if var fixture = fixtures[id], let files = fixture.value["videoFiles"] as? [[String: Any]] {
        fixture.value["videoFiles"] = files.filter { ($0["id"] as? Int) != fileID }
        fixtures[id] = fixture
      }
      return (200, ["code": 200])
    }
    if parts.count == 3, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), method == "DELETE" {
      guard fixtures[id] != nil else { return (404, ["message": "recording fixture not found"]) }
      removedIDs.insert(id); return (200, ["code": 200])
    }
    return (404, ["message": "unexpected fixture request"])
  }
}

@MainActor enum NeoActiveRecordingsSmoke {
  static func run(shell: NeoShell) async -> [String: Bool] {
    let savedAPI = shell.api
    let savedRoute = shell.route
    let savedConfig = shell.serverConfig
    let base = URL(string: "https://recording-active.invalid")!
    let values = [
      record(7201, files: [(72011, "Live-1.ts")], thumbnail: 71),
      record(7202, files: [(72021, "Live-2.ts")], thumbnail: 72),
      record(7203, files: [(72031, "Live-3.ts")], thumbnail: 73),
      record(7204, files: [(72041, "Live-4.ts")], thumbnail: 74),
    ]
    NeoActiveRecordingsProtocol.reset(values, drops: [
      7201: ["id": 9701, "dropCnt": 3, "errorCnt": 1, "scramblingCnt": 0],
      7202: ["id": 9702, "dropCnt": 0, "errorCnt": 0, "scramblingCnt": 0],
      7203: ["id": 9703, "dropCnt": 2, "errorCnt": 0, "scramblingCnt": 1],
      7204: ["id": 9704, "dropCnt": 0, "errorCnt": 0, "scramblingCnt": 0],
    ])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoActiveRecordingsProtocol.self]
    let session = URLSession(configuration: configuration)
    let api = NeoAPI(base: base, session: session)
    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "active-recording-session"])
    api.activeRecordingLength = 2
    shell.smokeUseAPI(api)
    shell.smokeUseServerConfig(config: nil)
    shell.showRoute("recording")
    shell.view.layoutIfNeeded()

    var checks: [String: Bool] = [:]
    func waitFor(_ condition: () -> Bool, attempts: Int = 220) async -> Bool {
      for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return condition()
    }
    func views(in root: UIView) -> [UIView] {
      [root] + root.subviews.flatMap { views(in: $0) }
    }
    func rootView() -> UIView { shell.view.window ?? shell.view }
    func view(_ identifier: String) -> UIView? {
      views(in: rootView()).first { $0.accessibilityIdentifier == identifier }
    }
    func button(_ identifier: String) -> UIButton? { view(identifier) as? UIButton }
    func table() -> UITableView? { view("recording.list") as? UITableView }
    func card(_ id: Int) -> UITableViewCell? {
      table()?.visibleCells.first { $0.accessibilityIdentifier == "recording.card.\(id)" }
    }
    func confirm(_ title: String) async -> UIButton? {
      func matchingButton() -> UIButton? {
        views(in: rootView()).compactMap { $0 as? UIButton }.first {
          $0.accessibilityIdentifier == "recording.confirm" && $0.currentTitle == title && $0.isEnabled
        }
      }
      guard await waitFor({ matchingButton() != nil }) else { return nil }
      return matchingButton()
    }
    func confirmationClosed() -> Bool {
      view("recording.confirm") == nil
    }
    func selectRow(_ id: Int) -> Bool {
      guard let table = table(), let cell = card(id), let indexPath = table.indexPath(for: cell) else { return false }
      table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
      table.delegate?.tableView?(table, didSelectRowAt: indexPath)
      return true
    }
    func actionDialog() async -> NeoRecordingActionDialog? {
      func find(_ controller: UIViewController) -> NeoRecordingActionDialog? {
        if let dialog = controller as? NeoRecordingActionDialog { return dialog }
        for child in controller.children {
          if let dialog = find(child) { return dialog }
        }
        if let presented = controller.presentedViewController, let dialog = find(presented) { return dialog }
        return nil
      }
      _ = await waitFor { find(shell) != nil }
      return find(shell)
    }
    defer {
      api.stopRecordingUpdates()
      shell.smokeUseAPI(savedAPI)
      shell.smokeUseServerConfig(config: savedConfig)
      if savedAPI != nil { shell.showRoute(savedRoute) }
    }

    let loaded = await waitFor {
      guard let table = view("recording.list") as? UITableView else { return false }
      return table.numberOfRows(inSection: 0) == 2 && card(7201) != nil && card(7202) != nil
    }
    checks["recordingPageLoadsActiveList"] = loaded
    checks["recordingPaginationAppears"] = view("recording.pagination") != nil
    checks["activeRecordingIndicatorTurnsOn"] = loaded && shell.hasActiveRecording

    let dropRendered = await waitFor(attempts: 340) {
      guard let cell = card(7201),
        let label = views(in: cell).first(where: { $0.accessibilityIdentifier == "recording.drop" }) as? UILabel else { return false }
      return NeoActiveRecordingsProtocol.count("GET", "/api/recording/dropStatus") > 0
        && (label.text == "drop: 3 / error: 1 / scrambling: 0" || label.accessibilityValue == "drop: 3 / error: 1 / scrambling: 0")
    }
    checks["dropStatusPollsAndUpdatesVisibleCard"] = dropRendered

    if let next = views(in: rootView()).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityLabel == "次のページ" }) {
      next.sendActions(for: .touchUpInside)
    }
    checks["recordingPaginationLoadsSecondPage"] = await waitFor { card(7203) != nil && card(7201) == nil }
    if let previous = views(in: rootView()).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityLabel == "前のページ" }) {
      previous.sendActions(for: .touchUpInside)
    }
    _ = await waitFor { card(7201) != nil }

    if let menuButton = views(in: card(7201) ?? UIView()).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "recording.card.menu" }) {
      menuButton.sendActions(for: .touchUpInside)
    }
    let menuReady = await waitFor { (view("anchored-menu") as? NeoAnchoredMenu) != nil }
    let menu = menuReady ? (view("anchored-menu") as? NeoAnchoredMenu) : nil
    checks["recordingMenuUsesWebStopDeleteLabels"] = menu?.titles.contains("stop") == true && menu?.titles.contains("delete") == true
    if let menu, let stop = menu.titles.firstIndex(of: "stop") { menu.select(stop) }
    if let stopConfirm = await confirm("録画停止") { stopConfirm.sendActions(for: .touchUpInside) }
    checks["individualStopUsesRecordingEndpoint"] = await waitFor {
      NeoActiveRecordingsProtocol.stopped().contains(7201) && card(7201) == nil && confirmationClosed()
    }

    // The individual delete action must use the same file-selection dialog as
    // recorded items. For an active recording it refreshes /recorded/{id},
    // then deletes through /videos/{fileId}; the server promotes that request
    // to removal of the whole active recording.
    if let menuButton = views(in: card(7202) ?? UIView()).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "recording.card.menu" }) {
      menuButton.sendActions(for: .touchUpInside)
    }
    let deleteMenuReady = await waitFor { (view("anchored-menu") as? NeoAnchoredMenu) != nil }
    let deleteMenu = deleteMenuReady ? (view("anchored-menu") as? NeoAnchoredMenu) : nil
    if let deleteMenu, let delete = deleteMenu.titles.firstIndex(of: "delete") { deleteMenu.select(delete) }
    if let dialog = await actionDialog() {
      dialog.smokeToggleFile(72021)
      dialog.smokeTapSubmit()
      checks["individualDeleteUsesVideoEndpoint"] = await waitFor {
        NeoActiveRecordingsProtocol.deletedVideos().contains(72021) && card(7202) == nil && dialog.view.window == nil
      }
    } else {
      checks["individualDeleteUsesVideoEndpoint"] = false
    }
    checks["activeDeleteLoadsCurrentRecordedFixture"] = NeoActiveRecordingsProtocol.count("GET", "/api/recorded/7202") > 0

    button("recording.select")?.sendActions(for: .touchUpInside)
    let selectedForStop = selectRow(7203)
    checks["recordingSelectionEnablesBulkStop"] = selectedForStop && button("recording.bulkStop")?.isEnabled == true
    button("recording.bulkStop")?.sendActions(for: .touchUpInside)
    if let stopConfirm = await confirm("録画停止") { stopConfirm.sendActions(for: .touchUpInside) }
    checks["bulkStopUsesRecordingEndpoint"] = await waitFor {
      NeoActiveRecordingsProtocol.stopped().contains(7203) && card(7203) == nil && confirmationClosed()
    }

    button("recording.select")?.sendActions(for: .touchUpInside)
    let selectedForDelete = selectRow(7204)
    checks["recordingSelectionEnablesBulkDelete"] = selectedForDelete && button("recording.bulkDelete")?.isEnabled == true
    button("recording.bulkDelete")?.sendActions(for: .touchUpInside)
    let deleteConfirm = await confirm("削除")
    checks["bulkDeleteConfirmationReady"] = deleteConfirm != nil
    deleteConfirm?.sendActions(for: .touchUpInside)
    checks["bulkDeleteUsesVideoEndpoint"] = await waitFor { NeoActiveRecordingsProtocol.deletedVideos().contains(72041) }
    checks["bulkDeleteRefreshesActiveList"] = await waitFor { table()?.numberOfRows(inSection: 0) == 0 && confirmationClosed() }
    checks["activeRecordingIndicatorTurnsOffWhenEmpty"] = await waitFor { !shell.hasActiveRecording }
    let auth = NeoActiveRecordingsProtocol.authSummary()
    checks["recordingRequestsCarryIdentityHeaders"] = auth.passes > 0 && auth.failures == 0
    return checks
  }

  private static func record(_ id: Int, files: [(Int, String)], thumbnail: Int) -> [String: Any] {
    ["id": id, "name": "Live fixture \(id)", "startAt": 1_700_000_000_000, "endAt": 1_700_001_800_000,
      "isRecording": true, "description": "Active recording fixture", "extended": "", "channelId": 1, "channelName": "Fixture Channel",
      "thumbnails": [thumbnail], "videoFiles": files.map { ["id": $0.0, "name": $0.1, "type": "TS", "size": 1024] },
      "isProtected": false, "userId": 7]
  }
}
#endif
