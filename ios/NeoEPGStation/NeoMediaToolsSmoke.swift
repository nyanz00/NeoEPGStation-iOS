#if targetEnvironment(simulator)
import Foundation
import UIKit

private final class NeoMediaToolsProtocol: URLProtocol {
  private struct CapturedRequest {
    let method: String
    let path: String
    let body: [String: Any]
    let profileID: String?
    let session: String?
  }
  private struct Job {
    let id: String
    let kind: String
    let source: Int
    let target: Int
    let index: Int
    let title: String
    let order: [Int]
    let plan: [String]
    let failure: String
    var pollIndex = 0
    var value: [String: Any]
    var applied = false
  }
  private struct Reply {
    let status: Int
    let value: Any
    let delay: TimeInterval
  }

  private static let lock = NSLock()
  private static var configDeveloperMode = true
  private static var records: [Int: [String: Any]] = [:]
  private static var recordIDs: [Int] = []
  private static var subtitles: [Int: [[String: Any]]] = [:]
  private static var requests: [CapturedRequest] = []
  private static var counts: [String: Int] = [:]
  private static var jobs: [String: Job] = [:]
  private static var jobOrder: [String] = []
  private static var jobPlans: [String: [[String]]] = [:]
  private static var jobErrors: [String: [String]] = [:]
  private static var histories: [String: [String]] = [:]
  private static var delays: [String: TimeInterval] = [:]
  private static var nextJobID = 0
  private var cancelled = false
  private let cancellationLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "detail-tools.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {
    cancellationLock.lock(); cancelled = true; cancellationLock.unlock()
  }

  override func startLoading() {
    let reply = Self.response(for: request)
    let data = (try? JSONSerialization.data(withJSONObject: reply.value, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
      cancellationLock.lock(); let stopped = cancelled; cancellationLock.unlock()
      guard !stopped else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  static func reset(records values: [[String: Any]], subtitles tracks: [Int: [[String: Any]]], developerMode: Bool) {
    lock.lock(); defer { lock.unlock() }
    records = Dictionary(uniqueKeysWithValues: values.compactMap { value in
      guard let id = value["id"] as? Int else { return nil }
      return (id, value)
    })
    recordIDs = Array(records.keys.sorted().prefix(4))
    subtitles = tracks
    configDeveloperMode = developerMode
    requests = []; counts = [:]; jobs = [:]; jobOrder = []; jobPlans = [:]; jobErrors = [:]; histories = [:]; delays = [:]; nextJobID = 0
  }

  static func setDeveloperMode(_ value: Bool) {
    lock.lock(); configDeveloperMode = value; lock.unlock()
  }

  static func enqueuePlan(kind: String, statuses: [String], error: String = "Fixture media operation failed") {
    lock.lock(); defer { lock.unlock() }
    jobPlans[kind, default: []].append(statuses.isEmpty ? ["completed"] : statuses)
    jobErrors[kind, default: []].append(error)
  }

  static func setDelay(method: String, path: String, seconds: TimeInterval) {
    lock.lock(); delays[method + " " + path] = seconds; lock.unlock()
  }

  static func count(_ method: String, _ path: String) -> Int {
    lock.lock(); defer { lock.unlock() }; return counts[method + " " + path, default: 0]
  }

  static func captured(method: String, path: String) -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return requests.filter { $0.method == method && $0.path == path }.map(\.body)
  }

  static func capturedJobIDs(kind: String) -> [String] {
    lock.lock(); defer { lock.unlock() }
    return jobOrder.filter { jobs[$0]?.kind == kind }
  }

  static func pollHistory(_ id: String) -> [String] {
    lock.lock(); defer { lock.unlock() }; return histories[id] ?? []
  }

  static func profileHeadersAreValid(profileID: String, session: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return !requests.isEmpty && requests.allSatisfy { $0.profileID == profileID && $0.session == session }
  }

  private static func requestBody(_ request: URLRequest) -> [String: Any] {
    var bytes = request.httpBody ?? Data()
    if bytes.isEmpty, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
      }
    }
    return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
  }

  private static func response(for request: URLRequest) -> Reply {
    let path = request.url!.path
    let method = request.httpMethod ?? "GET"
    let key = method + " " + path
    let body = requestBody(request)
    let parts = path.split(separator: "/").map(String.init)
    lock.lock(); defer { lock.unlock() }
    counts[key, default: 0] += 1
    requests.append(CapturedRequest(method: method, path: path, body: body,
      profileID: request.value(forHTTPHeaderField: "X-Viewer-Profile-Id"),
      session: request.value(forHTTPHeaderField: "X-Viewer-Session")))
    let delay = delays[key, default: 0]

    if path == "/api/config" && method == "GET" {
      return Reply(status: 200, value: ["developerMode": configDeveloperMode, "encode": []], delay: delay)
    }
    if path == "/api/channels" && method == "GET" {
      return Reply(status: 200, value: [["id": 11, "name": "Fixture Channel"]], delay: delay)
    }
    if path == "/api/recorded" && method == "GET" {
      let values = recordIDs.compactMap { records[$0] }
      return Reply(status: 200, value: ["records": values, "total": values.count], delay: delay)
    }
    if parts.count == 3, parts[0] == "api", parts[1] == "recorded", let id = Int(parts[2]), method == "GET" {
      return Reply(status: records[id] == nil ? 404 : 200, value: records[id] ?? ["message": "fixture recording not found"], delay: delay)
    }
    if parts.count == 4, parts[0] == "api", parts[1] == "videos", let id = Int(parts[2]), parts[3] == "subtitles", method == "GET" {
      return Reply(status: subtitles[id] == nil ? 404 : 200, value: ["items": subtitles[id] ?? []], delay: delay)
    }
    if parts.count == 5, parts[0] == "api", parts[1] == "videos", let target = Int(parts[2]), parts[3] == "subtitles", method == "POST" {
      let kind = parts[4]
      if ["transfer", "reorder"].contains(kind) {
        let source = kind == "transfer" ? (body["sourceVideoFileId"] as? Int ?? 0) : target
        let order = body["subtitleIndices"] as? [Int] ?? []
        let index = kind == "transfer" ? (body["subtitleIndex"] as? Int ?? -1) : (order.first ?? 0)
        return beginJob(kind: kind, source: source, target: target, index: index,
          title: body["title"] as? String ?? "", order: order, delay: delay)
      }
    }
    if parts.count == 6, parts[0] == "api", parts[1] == "videos", let target = Int(parts[2]), parts[3] == "subtitles", let index = Int(parts[4]), parts[5] == "rename", method == "POST" {
      return beginJob(kind: "rename", source: target, target: target, index: index,
        title: body["title"] as? String ?? "", order: [], delay: delay)
    }
    if parts.count == 6, parts[0] == "api", parts[1] == "videos", let target = Int(parts[2]), parts[3] == "subtitles", parts[4] == "transfer", method == "GET" {
      let id = parts[5]
      guard var job = jobs[id], job.target == target else {
        return Reply(status: 404, value: ["message": "fixture job not found"], delay: delay)
      }
      let status = job.plan[min(job.pollIndex, job.plan.count - 1)]
      job.pollIndex += 1; job.value["status"] = status
      if status == "failed" { job.value["error"] = job.failure }
      else { job.value.removeValue(forKey: "error") }
      histories[id, default: []].append(status)
      if status == "completed" && !job.applied {
        apply(job); job.applied = true
      }
      jobs[id] = job
      return Reply(status: 200, value: job.value, delay: delay)
    }
    return Reply(status: 404, value: ["message": "unexpected fixture request: \(method) \(path)"], delay: delay)
  }

  private static func beginJob(kind: String, source: Int, target: Int, index: Int, title: String, order: [Int], delay: TimeInterval) -> Reply {
    nextJobID += 1
    let id = "media-job-\(nextJobID)"
    var plans = jobPlans[kind] ?? []
    let plan = plans.isEmpty ? ["running", "completed"] : plans.removeFirst()
    jobPlans[kind] = plans
    var errors = jobErrors[kind] ?? []
    let error = errors.isEmpty ? "Fixture media operation failed" : errors.removeFirst()
    jobErrors[kind] = errors
    let now = Date().timeIntervalSince1970 * 1000
    let value: [String: Any] = ["id": id, "sourceVideoFileId": source, "targetVideoFileId": target,
      "subtitleIndex": index, "title": title, "status": "running", "createdAt": now, "updatedAt": now]
    jobs[id] = Job(id: id, kind: kind, source: source, target: target, index: index, title: title,
      order: order, plan: plan, failure: error, value: value)
    jobOrder.append(id)
    return Reply(status: 202, value: value, delay: delay)
  }

  private static func apply(_ job: Job) {
    switch job.kind {
    case "rename":
      guard var items = subtitles[job.target], let row = items.firstIndex(where: { ($0["subtitleIndex"] as? Int) == job.index }) else { return }
      items[row]["title"] = job.title; subtitles[job.target] = items
    case "reorder":
      guard let items = subtitles[job.target] else { return }
      let byIndex = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (Int, [String: Any])? in
        guard let index = item["subtitleIndex"] as? Int else { return nil }; return (index, item)
      })
      var reordered = job.order.compactMap { byIndex[$0] }
      for index in reordered.indices { reordered[index]["subtitleIndex"] = index }
      subtitles[job.target] = reordered
    case "transfer":
      guard var targetItems = subtitles[job.target], let sourceItems = subtitles[job.source],
        var added = sourceItems.first(where: { ($0["subtitleIndex"] as? Int) == job.index }) else { return }
      added["subtitleIndex"] = targetItems.count; added["streamIndex"] = 100 + targetItems.count; added["title"] = job.title
      targetItems.append(added); subtitles[job.target] = targetItems
    default: break
    }
  }
}

@MainActor enum NeoMediaToolsSmoke {
  static func run(shell: NeoShell) async -> [String: Bool] {
    let sourceID = 9201, targetID = 9202, alternateID = 9203, fourthID = 9204
    let sourceFile = 92011, secondSourceFile = 92012, targetFile = 92021, alternateTargetFile = 92022
    let originalViewerKey = "viewer." + "https://detail-tools.invalid"
    let savedViewer = UserDefaults.standard.object(forKey: originalViewerKey)
    let records = [
      record(sourceID, name: "Media tools source", files: [(92010, "Source.ts", 1000), (sourceFile, "SOURCE.MKV", 2000), (92013, "Later.mkv", 3000)]),
      record(targetID, name: "Media tools target", files: [(targetFile, "Target.mkv", 4000), (alternateTargetFile, "Alternate.mkv", 5000)]),
      record(alternateID, name: "Media tools third", files: [(92031, "Third.ts", 6000)]),
      record(fourthID, name: "Media tools fourth", files: [(92041, "Fourth.mkv", 7000)])
    ]
    let sourceTracks = [
      track(0, stream: 12, title: "Source A", display: "Japanese", codec: "ass", language: "jpn", isDefault: true, isForced: false),
      track(1, stream: 15, title: "Source B", display: "English", codec: "subrip", language: "eng", isDefault: false, isForced: true),
      track(2, stream: 18, title: "Source C", display: "Commentary", codec: "ass", language: "jpn", isDefault: false, isForced: false)
    ]
    let targetTracks = [
      track(0, stream: 31, title: "Target A", display: "Japanese", codec: "ass", language: "jpn", isDefault: true, isForced: false),
      track(1, stream: 35, title: "Target B", display: "English", codec: "subrip", language: "eng", isDefault: false, isForced: false)
    ]
    NeoMediaToolsProtocol.reset(records: records, subtitles: [sourceFile: sourceTracks, secondSourceFile: sourceTracks, targetFile: targetTracks, alternateTargetFile: targetTracks], developerMode: false)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoMediaToolsProtocol.self]
    let session = URLSession(configuration: configuration)
    let base = URL(string: "https://detail-tools.invalid")!
    let api = NeoAPI(base: base, session: session)
    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "fixture-session"])
    shell.smokeUseAPI(api)
    shell.showRoute("recorded")
    shell.view.layoutIfNeeded()
    var checks: [String: Bool] = [:]

    func waitFor(_ condition: () -> Bool, attempts: Int = 180) async -> Bool {
      for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return condition()
    }
    func navigation() -> UINavigationController? {
      shell.children.compactMap { $0 as? UINavigationController }.first(where: { $0.viewControllers.first is NeoRecordedPage })
    }
    func capture(_ page: UIViewController, name: String) {
      guard let window = page.view.window else { return }
      window.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
      try? image.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent(name))
    }
    func settle(_ page: UIViewController?, nav: UINavigationController?) async {
      if let page, nav?.topViewController === page { nav?.popToRootViewController(animated: false) }
      if let nav { _ = await waitFor({ nav.topViewController is NeoRecordedPage && nav.transitionCoordinator == nil }) }
      shell.showRoute("recorded"); shell.view.layoutIfNeeded()
    }
    func open(_ recording: NeoRecording) async -> (NeoMediaToolsPage, UINavigationController)? {
      let page = NeoMediaToolsPage(recording: recording, shell: shell)
      shell.pushPage { page }
      guard let nav = navigation() else { return nil }
      guard await waitFor({ page.openingContentFinished && nav.transitionCoordinator == nil }) else {
        await settle(page, nav: nav)
        return nil
      }
      return (page, nav)
    }
    func item(_ value: [String: Any]) -> NeoRecording? {
      guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
      return try? JSONDecoder().decode(NeoRecording.self, from: bytes)
    }
    func waitForJob(_ page: NeoMediaToolsPage, status: String, attempts: Int = 240) async -> Bool {
      await waitFor({ !page.smokeBusy && page.smokeStatus.contains(status) }, attempts: attempts)
    }

    defer {
      api.stopRecordingUpdates()
      if let savedViewer { UserDefaults.standard.set(savedViewer, forKey: originalViewerKey) }
      else { UserDefaults.standard.removeObject(forKey: originalViewerKey) }
      shell.showRoute("recorded")
    }

    guard let sourceItem = item(records[0]), let targetItem = item(records[1]), let nav = navigation() else {
      checks["fixtureAndRecordedNavigationReady"] = false
      return checks
    }
    checks["fixtureAndRecordedNavigationReady"] = true
    nav.popToRootViewController(animated: false)

    // Developer mode is checked before recording details or subtitle tracks are read.
    if let denied = await open(sourceItem) {
      checks["developerModeBlocksToolsBeforeSubtitleRequests"] = !denied.0.smokeEnabled
        && NeoMediaToolsProtocol.count("GET", "/api/videos/\(sourceFile)/subtitles") == 0
        && NeoMediaToolsProtocol.count("GET", "/api/recorded/\(sourceID)") == 0
      await settle(denied.0, nav: denied.1)
    } else { checks["developerModeBlocksToolsBeforeSubtitleRequests"] = false }

    NeoMediaToolsProtocol.setDeveloperMode(true)
    guard let opened = await open(sourceItem) else {
      checks["pageOpensWithDeveloperMode"] = false
      await settle(nil, nav: navigation())
      return checks
    }
    let page = opened.0, pageNav = opened.1
    checks["pageOpensWithDeveloperMode"] = page.smokeEnabled && page.openingContentFinished && pageNav.transitionCoordinator == nil
    guard page.smokeEnabled else {
      checks["leftDefaultsToFirstUppercaseMkvAndRightStartsEmpty"] = false
      checks["bothPanesLoadSubtitleMetadata"] = false
      checks["renameUsesSubtitleIndexAndSuppressesDuplicate"] = false
      checks["renamePollsRunningThenCompletedAndReloads"] = false
      checks["reorderSendsExactSubtitleIndices"] = false
      checks["reorderPollsAndReloadsChangedTrackOrder"] = false
      checks["failedTaskIsPolledAndShown"] = false
      checks["queueExecuteUsesSourceTargetSubtitleAndTrimmedTitle"] = false
      checks["selectionChangeDoesNotRetargetOrForgetAcceptedJob"] = false
      checks["requestsUseCapturedProfileHeaders"] = false
      checks["identityChangeRejectsLateTrackUpdate"] = false
      await settle(page, nav: pageNav)
      checks["finalRouteRecordedWithFourFixtureRecords"] = await finish(shell: shell, api: api, nav: navigation())
      return checks
    }
    let initialTracksLoaded = await waitFor({ page.smokeTracks(0).count == 3 })
    checks["leftDefaultsToFirstUppercaseMkvAndRightStartsEmpty"] = initialTracksLoaded
      && NeoMediaToolsProtocol.count("GET", "/api/videos/\(sourceFile)/subtitles") > 0
      && NeoMediaToolsProtocol.count("GET", "/api/videos/92013/subtitles") == 0
      && page.smokeTracks(1).isEmpty
      && NeoMediaToolsProtocol.count("GET", "/api/videos/\(targetFile)/subtitles") == 0
    guard initialTracksLoaded else {
      checks["bothPanesLoadSubtitleMetadata"] = false
      checks["renameUsesSubtitleIndexAndSuppressesDuplicate"] = false
      checks["renamePollsRunningThenCompletedAndReloads"] = false
      checks["reorderSendsExactSubtitleIndices"] = false
      checks["reorderPollsAndReloadsChangedTrackOrder"] = false
      checks["failedTaskIsPolledAndShown"] = false
      checks["queueExecuteUsesSourceTargetSubtitleAndTrimmedTitle"] = false
      checks["selectionChangeDoesNotRetargetOrForgetAcceptedJob"] = false
      checks["requestsUseCapturedProfileHeaders"] = false
      checks["identityChangeRejectsLateTrackUpdate"] = false
      await settle(page, nav: pageNav)
      checks["finalRouteRecordedWithFourFixtureRecords"] = await finish(shell: shell, api: api, nav: navigation())
      return checks
    }

    // Select the second pane through its UI callback and verify both metadata lists.
    page.smokePanes[1].onSelectRecording?(targetItem)
    let bothLoaded = await waitFor({ page.smokeTracks(0).count == 3 && page.smokeTracks(1).count == 2 })
    let sourceTrack = page.smokeTracks(0).first
    let targetTrack = page.smokeTracks(1).first
    checks["bothPanesLoadSubtitleMetadata"] = bothLoaded
      && sourceTrack?.subtitleIndex == 0 && sourceTrack?.streamIndex == 12 && sourceTrack?.codecName == "ass"
      && sourceTrack?.language == "jpn" && sourceTrack?.title == "Source A" && sourceTrack?.isDefault == true
      && targetTrack?.subtitleIndex == 0 && targetTrack?.streamIndex == 31 && targetTrack?.title == "Target A"
    capture(page, name: "recording-detail-tools.png")

    if let track = page.smokeTracks(0).first {
      NeoMediaToolsProtocol.enqueuePlan(kind: "rename", statuses: ["running", "completed"])
      page.smokePanes[0].onRename?(track, "Smoke renamed")
      page.smokePanes[0].onRename?(track, "Duplicate rename")
      let renameStarted = await waitFor({ NeoMediaToolsProtocol.count("POST", "/api/videos/\(sourceFile)/subtitles/0/rename") == 1 })
      checks["renameUsesSubtitleIndexAndSuppressesDuplicate"] = renameStarted
        && NeoMediaToolsProtocol.captured(method: "POST", path: "/api/videos/\(sourceFile)/subtitles/0/rename").first.map {
          Set($0.keys) == Set(["title"]) && ($0["title"] as? String) == "Smoke renamed"
        } == true
      let renameID = NeoMediaToolsProtocol.capturedJobIDs(kind: "rename").first
      let renameFinished = await waitForJob(page, status: "字幕名を変更しました。")
      let renameReloaded = await waitFor({ page.smokeTracks(0).first(where: { $0.subtitleIndex == 0 })?.title == "Smoke renamed" })
      checks["renamePollsRunningThenCompletedAndReloads"] = renameFinished
        && renameID.map { NeoMediaToolsProtocol.pollHistory($0).contains("running") && NeoMediaToolsProtocol.pollHistory($0).contains("completed") } == true
        && renameReloaded
    } else {
      checks["renameUsesSubtitleIndexAndSuppressesDuplicate"] = false
      checks["renamePollsRunningThenCompletedAndReloads"] = false
    }

    let desiredOrder = [2, 0, 1]
    NeoMediaToolsProtocol.enqueuePlan(kind: "reorder", statuses: ["running", "completed"])
    page.smokePanes[0].onReorder?(desiredOrder)
    let reorderPath = "/api/videos/\(sourceFile)/subtitles/reorder"
    let reorderStarted = await waitFor({ NeoMediaToolsProtocol.count("POST", reorderPath) == 1 })
    checks["reorderSendsExactSubtitleIndices"] = reorderStarted
      && NeoMediaToolsProtocol.captured(method: "POST", path: reorderPath).first.map {
        Set($0.keys) == Set(["subtitleIndices"]) && ($0["subtitleIndices"] as? [Int]) == desiredOrder
      } == true
    let reorderID = NeoMediaToolsProtocol.capturedJobIDs(kind: "reorder").first
    let reorderFinished = await waitForJob(page, status: "字幕を並び替えました。")
    let reorderReloaded = await waitFor({ page.smokeTracks(0).map(\.title) == ["Source C", "Smoke renamed", "Source B"] })
    checks["reorderPollsAndReloadsChangedTrackOrder"] = reorderFinished
      && reorderID.map { NeoMediaToolsProtocol.pollHistory($0).contains("running") && NeoMediaToolsProtocol.pollHistory($0).contains("completed") } == true
      && reorderReloaded

    if let track = page.smokeTracks(0).first {
      NeoMediaToolsProtocol.enqueuePlan(kind: "rename", statuses: ["running", "failed"], error: "Fixture media operation failed")
      let renameCountBeforeFailure = NeoMediaToolsProtocol.count("POST", "/api/videos/\(sourceFile)/subtitles/0/rename")
      page.smokePanes[0].onRename?(track, "Fail this operation")
      _ = await waitFor({ NeoMediaToolsProtocol.count("POST", "/api/videos/\(sourceFile)/subtitles/0/rename") > renameCountBeforeFailure })
      let failedID = NeoMediaToolsProtocol.capturedJobIDs(kind: "rename").last
      let renameFailureShown = await waitForJob(page, status: "Fixture media operation failed")
      checks["failedTaskIsPolledAndShown"] = renameFailureShown
        && failedID.map { NeoMediaToolsProtocol.pollHistory($0).contains("running") && NeoMediaToolsProtocol.pollHistory($0).contains("failed") } == true
    } else { checks["failedTaskIsPolledAndShown"] = false }

    if let track = page.smokeTracks(0).first {
      page.smokePanes[0].onQueue?(track)
      page.smokePanes[1].onPendingTitle?("  Smoke transferred  ")
      let enabled = page.smokeCanExecute
      NeoMediaToolsProtocol.enqueuePlan(kind: "transfer", statuses: ["running", "completed"])
      page.smokeExecute(); page.smokeExecute()
      let transferPath = "/api/videos/\(targetFile)/subtitles/transfer"
      let transferStarted = await waitFor({ NeoMediaToolsProtocol.count("POST", transferPath) == 1 })
      checks["queueExecuteUsesSourceTargetSubtitleAndTrimmedTitle"] = enabled && transferStarted
        && NeoMediaToolsProtocol.captured(method: "POST", path: transferPath).first.map {
          Set($0.keys) == Set(["sourceVideoFileId", "subtitleIndex", "title"])
            && ($0["sourceVideoFileId"] as? Int) == sourceFile
            && ($0["subtitleIndex"] as? Int) == track.subtitleIndex
            && ($0["title"] as? String) == "Smoke transferred"
        } == true
      let transferID = NeoMediaToolsProtocol.capturedJobIDs(kind: "transfer").first
      let transferStillTracked = await waitFor({
        guard let transferID else { return false }
        return NeoMediaToolsProtocol.count("GET", "/api/videos/\(targetFile)/subtitles/transfer/\(transferID)") > 0 && page.smokeBusy
      }, attempts: 80)
      page.smokePanes[1].onSelectFile?(alternateTargetFile)
      let transferFinished = await waitForJob(page, status: "字幕を移植しました。")
      checks["selectionChangeDoesNotRetargetOrForgetAcceptedJob"] = transferStillTracked && transferFinished
        && transferID.map { NeoMediaToolsProtocol.count("GET", "/api/videos/\(targetFile)/subtitles/transfer/\($0)") > 0 } == true
        && transferID.map { NeoMediaToolsProtocol.count("GET", "/api/videos/\(alternateTargetFile)/subtitles/transfer/\($0)") == 0 } == true
        && NeoMediaToolsProtocol.capturedJobIDs(kind: "transfer").count == 1
    } else {
      checks["queueExecuteUsesSourceTargetSubtitleAndTrimmedTitle"] = false
      checks["selectionChangeDoesNotRetargetOrForgetAcceptedJob"] = false
    }

    let beforeIdentity = NeoMediaToolsProtocol.profileHeadersAreValid(profileID: "21", session: "fixture-session")
    checks["requestsUseCapturedProfileHeaders"] = beforeIdentity

    // Make one subtitle read late, switch identity while it is in flight, and
    // ensure its response cannot repopulate the old page.
    await settle(page, nav: pageNav)
    NeoMediaToolsProtocol.setDelay(method: "GET", path: "/api/videos/\(sourceFile)/subtitles", seconds: 0.45)
    let readsBeforeIdentityPage = NeoMediaToolsProtocol.count("GET", "/api/videos/\(sourceFile)/subtitles")
    guard let identityPageResult = await open(sourceItem) else {
      checks["identityChangeRejectsLateTrackUpdate"] = false
      await settle(nil, nav: navigation())
      api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "fixture-session"])
      checks["finalRouteRecordedWithFourFixtureRecords"] = await finish(shell: shell, api: api, nav: navigation())
      return checks
    }
    let identityPage = identityPageResult.0, identityNav = identityPageResult.1
    let lateReadStarted = await waitFor({ NeoMediaToolsProtocol.count("GET", "/api/videos/\(sourceFile)/subtitles") > readsBeforeIdentityPage })
    api.activate(user: "9", headers: ["X-Viewer-Profile-Id": "22", "X-Viewer-Session": "alternate-fixture"])
    _ = await waitFor({ !identityPage.smokeEnabled })
    try? await Task.sleep(nanoseconds: 600_000_000)
    checks["identityChangeRejectsLateTrackUpdate"] = lateReadStarted && !identityPage.smokeEnabled && identityPage.smokeTracks(0).isEmpty
    await settle(identityPage, nav: identityNav)

    api.activate(user: "7", headers: ["X-Viewer-Profile-Id": "21", "X-Viewer-Session": "fixture-session"])
    checks["finalRouteRecordedWithFourFixtureRecords"] = await finish(shell: shell, api: api, nav: navigation())
    return checks
  }

  private static func finish(shell: NeoShell, api: NeoAPI, nav: UINavigationController?) async -> Bool {
    api.stopRecordingUpdates()
    if let nav { nav.popToRootViewController(animated: false) }
    shell.showRoute("recorded"); shell.view.layoutIfNeeded()
    let page = nav?.viewControllers.first(where: { $0 is NeoRecordedPage }) as? NeoRecordedPage
    for _ in 0..<180 {
      if page?.records.count == 4 { break }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return shell.route == "recorded" && page?.records.count == 4
  }

  private static func record(_ id: Int, name: String, files: [(Int, String, Int)]) -> [String: Any] {
    ["id": id, "name": name, "startAt": 1_700_000_000_000, "endAt": 1_700_001_800_000,
      "isRecording": false, "description": "Fixture description", "extended": "", "channelId": 11, "channelName": "Fixture Channel",
      "thumbnails": [1], "videoFiles": files.map { ["id": $0.0, "name": $0.1, "type": "encoded", "size": $0.2, "filename": $0.1] },
      "isProtected": false, "isEncoding": false, "userId": 7]
  }

  private static func track(_ subtitleIndex: Int, stream: Int, title: String, display: String, codec: String, language: String,
    isDefault: Bool, isForced: Bool) -> [String: Any] {
    ["subtitleIndex": subtitleIndex, "streamIndex": stream, "codecName": codec, "language": language,
      "title": title, "isDefault": isDefault, "isForced": isForced, "displayName": display]
  }
}
#endif
