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
      let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
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
      _ = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })
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
    _ = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })

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
      _ = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })
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
      _ = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })
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
      _ = await waitFor({ host.presentedViewController == nil && host.recordingActions == nil })
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
#endif
