#if targetEnvironment(simulator)
import Foundation
import UIKit

/// Local-only HTTP fixture for the native program-search screen.
///
/// The host is deliberately invalid and the URLSession used by the smoke
/// test is ephemeral, so this protocol can never fall through to a real
/// server.  It records the wire bodies as well as request counts so the smoke
/// checks can verify search and related-search options rather than only the
/// rendered result.
private final class NeoProgramSearchSmokeProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var calls: [String: Int] = [:]
  private static var bodies: [String: [[String: Any]]] = [:]
  private static var reservationFailures = 0
  private static var nonSearchWrites = 0
  private var stopped = false
  private let stateLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "program-search.invalid"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func stopLoading() {
    stateLock.lock(); stopped = true; stateLock.unlock()
  }

  override func startLoading() {
    let request = self.request
    let method = request.httpMethod ?? "GET"
    let path = request.url?.path ?? ""
    let key = "\(method) \(path)"
    let body = Self.requestBody(request)
    let (status, value) = Self.response(for: request, key: key, body: body)
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
      guard let self else { return }
      stateLock.lock(); let cancelled = stopped; stateLock.unlock()
      guard !cancelled else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  static func reset() {
    lock.lock(); defer { lock.unlock() }
    calls.removeAll(); bodies.removeAll(); reservationFailures = 1; nonSearchWrites = 0
  }

  static func count(_ key: String) -> Int {
    lock.lock(); defer { lock.unlock() }
    return calls[key, default: 0]
  }

  static func searchBodies() -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return bodies["POST /api/schedules/search"] ?? []
  }

  static func mutationWriteCount() -> Int {
    lock.lock(); defer { lock.unlock() }
    return nonSearchWrites
  }

  private static func requestBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var collected = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        collected.append(buffer, count: count)
      }
      data = collected
    }
    return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
  }

  private static func response(for request: URLRequest, key: String, body: [String: Any]) -> (Int, Any) {
    let path = request.url?.path ?? ""
    lock.lock()
    calls[key, default: 0] += 1
    if request.httpMethod != "GET", path != "/api/schedules/search" { nonSearchWrites += 1 }
    if !body.isEmpty { bodies[key, default: []].append(body) }

    var status = 200
    let value: Any
    if path == "/api/channels", request.httpMethod == "GET" {
      value = [[
        "id": 1,
        "name": "Fixture Station",
        "channelType": "GR",
        "hasLogoData": false
      ]]
    } else if path == "/api/config", request.httpMethod == "GET" {
      value = ["encode": [] as [String], "broadcast": ["GR": true]] as [String: Any]
    } else if path == "/api/schedules/search", request.httpMethod == "POST" {
      let option = body["option"] as? [String: Any] ?? [:]
      let hasRelatedChannel = (option["channelIds"] as? [Any])?.contains { ($0 as? NSNumber)?.intValue == 1 } == true
      value = [Self.program(hasRelatedChannel ? 9002 : 9001, related: hasRelatedChannel)]
    } else if path == "/api/reserves/lists", request.httpMethod == "GET" {
      if reservationFailures > 0 {
        reservationFailures -= 1
        status = 503
        value = ["message": "fixture reservation failure"]
      } else {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = query.first(where: { $0.name == "startAt" })?.value.flatMap(Int64.init) ?? 0
        let id = start == 1791025200000 ? 9002 : 9001
        value = [
          "normal": [[String: Any]](),
          "conflicts": [["reserveId": 5000 + id, "userId": 7, "programId": id] as [String: Any]],
          "overlaps": [[String: Any]](),
          "skips": [[String: Any]]()
        ] as [String: Any]
      }
    } else if path == "/api/users", request.httpMethod == "GET" {
      value = ["users": [["id": 7, "name": "Fixture user"] as [String: Any]]] as [String: Any]
    } else {
      status = 404
      value = ["message": "unexpected fixture request: \(key)"]
    }
    lock.unlock()
    return (status, value)
  }

  private static func program(_ id: Int, related: Bool) -> [String: Any] {
    let start = related ? 1791025200000.0 : 1791021600000.0
    return [
      "id": id,
      "channelId": 1,
      "startAt": start,
      "endAt": start + 1_800_000,
      "isFree": true,
      "name": "Fixture program",
      "description": "概要とリンク https://program-search.invalid/details",
      "extended": "◇見どころ\n拡張情報とリンク https://program-search.invalid/extended",
      "genre1": 3,
      "subGenre1": 0,
      "videoType": "h.264",
      "videoResolution": "1920x1080",
      "audioSamplingRate": 48_000,
      "audioComponentType": 3
    ]
  }
}

@MainActor enum NeoProgramSearchSmoke {
  static func run(shell: NeoShell) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    NeoProgramSearchSmokeProtocol.reset()

    let base = URL(string: "https://program-search.invalid")!
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoProgramSearchSmokeProtocol.self]
    let api = NeoAPI(base: base, session: URLSession(configuration: configuration))
    api.activate(user: "7", headers: [
      "X-Viewer-Profile-Id": "77",
      "X-Viewer-Session": "program-search-fixture"
    ])
    api.programSearchLimit = 10
    api.programRelatedIncludesChannel = true
    api.programRelatedIncludesGenre = true
    api.alwaysShowProgramBroadcastDetails = false

    shell.smokeUseAPI(api)
    shell.showRoute("search")
    shell.view.layoutIfNeeded()
    NotificationCenter.default.post(name: .neoAccountChanged, object: api)
    NotificationCenter.default.post(name: .neoTextPreferencesChanged, object: api)

    func waitFor(_ condition: () -> Bool, attempts: Int = 180) async -> Bool {
      for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return condition()
    }

    func views(in root: UIView) -> [UIView] {
      [root] + root.subviews.flatMap { views(in: $0) }
    }

    func identified(_ root: UIView, _ identifier: String) -> UIView? {
      views(in: root).first { $0.accessibilityIdentifier == identifier }
    }

    func button(in root: UIView, identifier: String? = nil, label: String? = nil) -> UIButton? {
      views(in: root).compactMap { $0 as? UIButton }.first { button in
        if let identifier, button.accessibilityIdentifier == identifier { return true }
        if let label, button.accessibilityLabel == label || button.title(for: .normal) == label { return true }
        return false
      }
    }

    func capture(_ name: String) {
      guard let window = shell.view.window, window.bounds.width > 0, window.bounds.height > 0 else { return }
      window.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try? image.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent("program-search-\(name).png"))
    }

    func searchNavigation() -> UINavigationController? {
      shell.children.compactMap { $0 as? UINavigationController }.first {
        $0.viewControllers.first is NeoProgramSearchPage
      }
    }

    guard let navigation = searchNavigation(), let page = navigation.viewControllers.first as? NeoProgramSearchPage,
      await waitFor({ page.viewIfLoaded?.window != nil && identified(page.view, "programSearch.keyword") != nil
        && identified(page.view, "programSearch.search") != nil }) else {
      checks["programSearchPageReady"] = false
      return checks
    }
    checks["programSearchPageReady"] = true
    page.view.layoutIfNeeded()
    shell.view.endEditing(true)
    capture("form")

    guard let keyword = identified(page.view, "programSearch.keyword") as? UITextField,
      let search = button(in: page.view, identifier: "programSearch.search") else {
      checks["programSearchFormControlsReady"] = false
      return checks
    }
    checks["programSearchFormControlsReady"] = true
    keyword.text = "Fixture"
    keyword.sendActions(for: .editingChanged)
    search.sendActions(for: .touchUpInside)

    let searchPosted = await waitFor { NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") == 1 }
    let firstBody = NeoProgramSearchSmokeProtocol.searchBodies().first?["option"] as? [String: Any]
    checks["searchPostsEnteredKeyword"] = searchPosted && firstBody?["keyword"] as? String == "Fixture"
      && firstBody?["name"] as? Bool == true && firstBody?["description"] as? Bool == true
    checks["searchUsesConfiguredLimit"] = NeoProgramSearchSmokeProtocol.searchBodies().first?["limit"] as? Int == 10

    let reservationFailure = await waitFor {
      button(in: page.view, label: "再試行") != nil
        && NeoProgramSearchSmokeProtocol.count("GET /api/reserves/lists") == 1
    }
    let failedRowCount = (identified(page.view, "programSearch.list") as? UITableView)?.numberOfRows(inSection: 0) ?? -1
    checks["reservationFailureOffersRetry"] = reservationFailure
    capture("reservation-failure")
    button(in: page.view, label: "再試行")?.sendActions(for: .touchUpInside)

    let resultsReady = await waitFor {
      let list = identified(page.view, "programSearch.list") as? UITableView
      let count = identified(page.view, "programSearch.count") as? UILabel
      return list?.numberOfRows(inSection: 0) == 1 && count?.text == "1件ヒット"
        && NeoProgramSearchSmokeProtocol.count("GET /api/reserves/lists") >= 2
        && button(in: page.view, label: "再試行") == nil
    }
    checks["reservationRetryShowsResults"] = resultsReady
    checks["programSearchReservationBadge"] = resultsReady
      && views(in: page.view).compactMap { $0 as? UILabel }.contains { $0.text == "競合" }
    checks["reservationFailureLeavesNoRows"] = reservationFailure && failedRowCount == 0
    checks["reservationRetryDoesNotRepeatSearch"] = resultsReady
      && NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") == 1
    guard let list = identified(page.view, "programSearch.list") as? UITableView, resultsReady else {
      checks["programSearchResultListReady"] = false
      return checks
    }
    checks["programSearchResultListReady"] = list.numberOfRows(inSection: 0) == 1
    list.layoutIfNeeded()
    list.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
    list.layoutIfNeeded()
    checks["programSearchResultCardVisible"] = list.cellForRow(at: IndexPath(row: 0, section: 0))?.window != nil
    checks["programSearchReservationBadge"] = checks["programSearchReservationBadge"] == true
      || views(in: list).compactMap { $0 as? UILabel }.contains { $0.text == "競合" }
    capture("results")
    page.tableView(list, didSelectRowAt: IndexPath(row: 0, section: 0))

    let detailReady = await waitFor {
      guard let detail = page.presentedViewController as? NeoProgramDetailDialog else { return false }
      return detail.viewIfLoaded?.window != nil && !detail.isBeingPresented
    }
    checks["programDetailOpensFromResult"] = detailReady
    guard let detail = page.presentedViewController as? NeoProgramDetailDialog, detailReady else {
      checks["programDetailReadOnly"] = false
      return checks
    }
    detail.view.layoutIfNeeded()

    let detailButtons = views(in: detail.view).compactMap { $0 as? UIButton }
    let buttonTitles = Set(detailButtons.compactMap { $0.title(for: .normal) })
    let forbidden = Set(["予約", "削除", "編集", "解除", "除外", "詳細"])
    checks["programDetailReadOnly"] = buttonTitles.contains("検索") && buttonTitles.contains("閉じる")
      && buttonTitles.isDisjoint(with: forbidden)
    checks["programDetailShowsOverviewAndExtended"] = views(in: detail.view).compactMap { $0 as? UITextView }
      .map { $0.text ?? "" }.joined(separator: "\n").contains("概要とリンク")
      && views(in: detail.view).compactMap { $0 as? UITextView }.map { $0.text ?? "" }.joined(separator: "\n").contains("拡張情報")
    checks["programDetailLinkifiedText"] = views(in: detail.view).compactMap { $0 as? UITextView }.contains { textView in
      var found = false
      let range = NSRange(location: 0, length: textView.attributedText.length)
      textView.attributedText.enumerateAttribute(.link, in: range) { value, _, _ in
        if value != nil { found = true }
      }
      return found
    }

    let expand = detailButtons.first { $0.accessibilityLabel?.contains("情報を表示") == true }
    let initiallyCollapsed = expand?.accessibilityValue == "非表示"
    expand?.sendActions(for: .touchUpInside)
    let expanded = await waitFor {
      detail.view.layoutIfNeeded()
      return detailButtons.first { $0.accessibilityLabel?.contains("情報を閉じる") == true }?.accessibilityValue == "表示中"
    }
    checks["programDetailBroadcastDetailsExpand"] = initiallyCollapsed && expanded
    let userChipReady = await waitFor {
      NeoProgramSearchSmokeProtocol.count("GET /api/users") > 0
        && views(in: detail.view).compactMap { $0 as? UILabel }.contains { $0.text == "Fixture user・競合" }
    }
    checks["programDetailReservationUsersUpdate"] = userChipReady
    capture("detail")

    let relatedButton = button(in: detail.view, label: "検索")
    relatedButton?.sendActions(for: .touchUpInside)
    let relatedReady = await waitFor {
      navigation.viewControllers.count == 2 && navigation.topViewController !== page
        && NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") >= 2
    }
    checks["relatedSearchOpensSecondSearch"] = relatedReady
    guard relatedReady else { return checks }

    let bodies = NeoProgramSearchSmokeProtocol.searchBodies()
    let relatedOption = bodies.count > 1 ? bodies[1]["option"] as? [String: Any] : nil
    let relatedChannels = (relatedOption?["channelIds"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    let relatedGenres = relatedOption?["genres"] as? [[String: Any]] ?? []
    checks["relatedSearchCarriesChannelAndGenre"] = relatedChannels == [1]
      && relatedGenres.contains { ($0["genre"] as? NSNumber)?.intValue == 3 && ($0["subGenre"] as? NSNumber)?.intValue == 0 }

    let relatedPage = navigation.topViewController
    _ = await waitFor {
      guard let relatedPage else { return false }
      return identified(relatedPage.view, "programSearch.count") is UILabel
        && (identified(relatedPage.view, "programSearch.count") as? UILabel)?.text == "1件ヒット"
    }
    _ = await waitFor { navigation.transitionCoordinator == nil }
    shell.goBack()
    let returned = await waitFor {
      navigation.topViewController === page
        && NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") >= 3
        && (identified(page.view, "programSearch.keyword") as? UITextField)?.text == "Fixture"
    }
    checks["relatedSearchBackRetainsOriginalForm"] = returned
    checks["relatedSearchBackRetainsOriginalResults"] = returned
      && (identified(page.view, "programSearch.count") as? UILabel)?.text == "1件ヒット"
    let clear = button(in: page.view, identifier: "programSearch.clear")
    clear?.sendActions(for: .touchUpInside)
    let cleared = await waitFor {
      (identified(page.view, "programSearch.keyword") as? UITextField)?.text?.isEmpty == true
        && (identified(page.view, "programSearch.list") as? UITableView)?.numberOfRows(inSection: 0) == 0
    }
    checks["clearResetsResultWithoutMutation"] = cleared && NeoProgramSearchSmokeProtocol.mutationWriteCount() == 0
    return checks
  }
}
#endif
