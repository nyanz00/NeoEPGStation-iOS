#if targetEnvironment(simulator)
import Foundation
import UIKit

private final class NeoRulesSmokeProtocol: URLProtocol {
  private struct Fixture {
    var value: [String: Any]
    var enabled: Bool
    var deleted = false
  }

  private static let lock = NSLock()
  private static var fixtures: [Int: Fixture] = [:]
  private static var order: [Int] = []
  private static var counts: [String: Int] = [:]
  private static var ruleQueries: [[String: String]] = []
  private static var putQueries: [[String: String]] = []
  private var cancelled = false
  private let cancellationLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "rules.invalid"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func stopLoading() {
    cancellationLock.lock()
    cancelled = true
    cancellationLock.unlock()
  }

  override func startLoading() {
    let (status, value) = Self.response(for: request)
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
      guard let self else { return }
      cancellationLock.lock()
      let stopped = cancelled
      cancellationLock.unlock()
      guard !stopped else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    let values: [(Int, Fixture)] = [
      (1001, Fixture(value: rule(id: 1001, userID: 7, keyword: "Alpha", enabled: true, reserves: 1, annictID: 5501, encoded: true), enabled: true)),
      (1002, Fixture(value: rule(id: 1002, userID: 7, keyword: "Beta", enabled: true, reserves: 0, annictID: nil, encoded: false), enabled: true)),
      (1003, Fixture(value: rule(id: 1003, userID: 7, keyword: "Gamma", enabled: false, reserves: 1, annictID: nil, encoded: false), enabled: false)),
      (1004, Fixture(value: rule(id: 1004, userID: 8, keyword: "Other", enabled: true, reserves: 1, annictID: nil, encoded: false), enabled: true)),
    ]
    fixtures = Dictionary(uniqueKeysWithValues: values)
    order = values.map(\.0)
    counts.removeAll()
    ruleQueries.removeAll()
    putQueries.removeAll()
  }

  static func count(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[key, default: 0]
  }

  static func rulesQueries() -> [[String: String]] {
    lock.lock()
    defer { lock.unlock() }
    return ruleQueries
  }

  static func latestPutQuery() -> [String: String]? {
    lock.lock()
    defer { lock.unlock() }
    return putQueries.last
  }

  private static func response(for request: URLRequest) -> (Int, Any) {
    let method = request.httpMethod ?? "GET"
    let path = request.url?.path ?? ""
    let key = method + " " + path
    let query = queryMap(request.url)
    lock.lock()
    defer { lock.unlock() }
    counts[key, default: 0] += 1

    if method == "GET", path == "/api/channels" {
      let channel: [String: Any] = [
        "id": 1, "name": "Fixture Station", "channelType": "GR", "hasLogoData": false
      ]
      return (200, [channel])
    }

    var status = 200
    var value: [String: Any] = [:]
    if method == "GET", path == "/api/users" {
      value = [
        "users": [
          ["id": 7, "name": "Fixture user"],
          ["id": 8, "name": "Other user"],
        ]
      ]
    } else if method == "GET", path == "/api/config" {
      value = ["encode": [], "recorded": [], "broadcast": ["GR": true]]
    } else if method == "POST", path == "/api/rules" {
      value = ["ruleId": 2001]
    } else if method == "GET", path == "/api/rules" {
      ruleQueries.append(query)
      let matching = order.compactMap { id -> [String: Any]? in
        guard let fixture = fixtures[id], !fixture.deleted else { return nil }
        if let rawUser = query["userId"] {
          guard let requestedUser = Int(rawUser), let fixtureUser = fixture.value["userId"] as? Int,
                requestedUser == fixtureUser else { return nil }
        }
        if let keyword = query["keyword"], !keyword.isEmpty {
          let search = fixture.value["searchOption"] as? [String: Any]
          let title = search?["keyword"] as? String ?? ""
          if !title.localizedCaseInsensitiveContains(keyword) { return nil }
        }
        if query["hasReserve"] == "true", (fixture.value["reservesCnt"] as? Int ?? 0) <= 0 { return nil }
        return json(for: fixture)
      }
      let offset = max(0, Int(query["offset"] ?? "0") ?? 0)
      let limit = max(1, Int(query["limit"] ?? "24") ?? 24)
      value = [
        "rules": Array(matching.dropFirst(offset).prefix(limit)),
        "total": matching.count,
      ]
    } else if method == "PUT", let parts = ruleParts(path), parts.count >= 4,
              let id = Int(parts[2]), fixtures[id] != nil {
      putQueries.append(query)
      let enabled = parts[3] == "enable"
      fixtures[id]?.enabled = enabled
      value = [:]
    } else if method == "DELETE", let parts = ruleParts(path), parts.count == 3,
              let id = Int(parts[2]), fixtures[id] != nil {
      if id == 1002 {
        status = 503
        value = ["message": "fixture rule delete failure"]
      } else {
        fixtures[id]?.deleted = true
        value = [:]
      }
    } else {
      status = 404
      value = ["message": "unexpected fixture request: " + method + " " + path]
    }
    return (status, value)
  }

  private static func queryMap(_ url: URL?) -> [String: String] {
    guard let url else { return [:] }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in
      item.value.map { (item.name, $0) }
    })
  }

  private static func ruleParts(_ path: String) -> [String]? {
    let parts = path.split(separator: "/").map(String.init)
    return parts.first == "api" && parts.count >= 3 && parts[1] == "rules" ? parts : nil
  }

  private static func json(for fixture: Fixture) -> [String: Any] {
    var value = fixture.value
    var reserve = value["reserveOption"] as? [String: Any] ?? [:]
    reserve["enable"] = fixture.enabled
    value["reserveOption"] = reserve
    return value
  }

  private static func rule(
    id: Int,
    userID: Int,
    keyword: String,
    enabled: Bool,
    reserves: Int,
    annictID: Int?,
    encoded: Bool
  ) -> [String: Any] {
    var search: [String: Any] = [
      "keyword": keyword,
      "name": true,
      "description": true,
      "extended": false,
      "channelIds": [1],
      "times": [["week": 127]],
      "searchPeriods": [["startAt": 0, "endAt": 253402300799999]],
    ]
    if keyword == "Alpha" { search["ignoreKeyword"] = "skip this" }
    var value: [String: Any] = [
      "id": id,
      "userId": userID,
      "isTimeSpecification": false,
      "searchOption": search,
      "reserveOption": [
        "enable": enabled,
        "allowEndLack": true,
        "avoidDuplicate": id == 1001,
        "periodToAvoidDuplicate": id == 1001 ? 7 : 0,
        "tags": [1, 2],
      ],
      "saveOption": [
        "parentDirectoryName": "Fixture",
        "directory": "Rules",
        "recordedFormat": "%TITLE%",
      ],
      "reservesCnt": reserves,
    ]
    if let annictID { value["annictId"] = annictID }
    if encoded {
      value["encodeOption"] = [
        "mode1": "H.264",
        "channelIds1": [1, 2],
        "directory1": "encoded",
        "startDelayMinutes": 3,
      ]
    }
    return value
  }
}

@MainActor enum NeoRulesSmoke {
  static func run(shell: NeoShell) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let oldStopWatching = NeoAnnictPreferences.stopWatchingOnRuleDisable
    NeoAnnictPreferences.stopWatchingOnRuleDisable = false
    NeoRulesSmokeProtocol.reset()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeoRulesSmokeProtocol.self]
    let api = NeoAPI(base: URL(string: "https://rules.invalid")!, session: URLSession(configuration: configuration))
    let oldRulesLength = api.rulesLength
    api.rulesLength = 2
    api.activate(user: "7", headers: [
      "X-Viewer-Profile-Id": "77",
      "X-Viewer-Session": "rules-fixture",
    ])
    defer {
      NeoAnnictPreferences.stopWatchingOnRuleDisable = oldStopWatching
      api.rulesLength = oldRulesLength
    }

    shell.smokeUseAPI(api)
    shell.showRoute("rule")
    shell.view.layoutIfNeeded()
    NotificationCenter.default.post(name: .neoAccountChanged, object: api)

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

    func control(in root: UIView, _ identifier: String) -> UIControl? {
      views(in: root).compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == identifier }
    }

    func button(in root: UIView, label: String) -> UIButton? {
      views(in: root).compactMap { $0 as? UIButton }.first {
        $0.accessibilityLabel == label || $0.title(for: .normal) == label
      }
    }

    func query(_ values: [String: String]?, _ expected: [String: String]) -> Bool {
      guard let values else { return false }
      return expected.allSatisfy { values[$0.key] == $0.value }
    }

    guard let navigation = shell.children.compactMap({ $0 as? UINavigationController }).first(where: {
      $0.viewControllers.first is NeoRulesPage
    }), let page = navigation.viewControllers.first as? NeoRulesPage,
      await waitFor({
        page.viewIfLoaded?.window != nil
          && identified(page.view, "rules.list") != nil
          && page.smokeRules.map(\.id) == [1001, 1002]
      }) else {
      checks["rulesPageReady"] = false
      return checks
    }
    checks["rulesPageReady"] = true
    page.view.layoutIfNeeded()
    if let first = control(in: page.view, "rules.toggle.1001"),
       let second = control(in: page.view, "rules.toggle.1002") {
      let firstX = first.convert(CGPoint(x: first.bounds.midX, y: 0), to: page.view).x
      let secondX = second.convert(CGPoint(x: second.bounds.midX, y: 0), to: page.view).x
      checks["rulesCardSwitchesAreAligned"] = abs(firstX - secondX) < 1
        && abs(first.bounds.width - 58) < 1 && abs(second.bounds.width - 58) < 1
    } else {
      checks["rulesCardSwitchesAreAligned"] = false
    }
    if let notice = shell.view.viewWithTag(80921) {
      _ = await waitFor { notice.superview == nil }
    }
    if let window = page.view.window, !window.bounds.isEmpty {
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try? image.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent("rules-list.png"))
    }

    let requiredIDs = [
      "rules.list", "rules.keyword", "rules.hasReserve", "rules.user",
      "rules.select", "rules.selectAll", "rules.deleteSelection", "rules.add",
    ]
    checks["rulesPublicAccessibilityIDs"] = requiredIDs.allSatisfy { identified(page.view, $0) != nil }
    checks["rulesInitialRows"] = page.smokeRules.map(\.id) == [1001, 1002]
    checks["rulesInitialGETUsesNormalOffsetLimitUser"] = query(
      NeoRulesSmokeProtocol.rulesQueries().last,
      ["type": "normal", "offset": "0", "limit": "2", "userId": "7"]
    )

    if let selector = control(in: page.view, "rules.user") as? NeoDropdownButton {
      let expectedWidth: CGFloat
      if page.view.bounds.width >= 600 {
        expectedWidth = 180
      } else {
        expectedWidth = max(84, min(112, page.view.bounds.width - 188 - ceil(page.titleLabel.intrinsicContentSize.width)))
      }
      checks["rulesUserSelectorResponsiveWidth"] = abs(selector.bounds.width - expectedWidth) < 1
    } else {
      checks["rulesUserSelectorResponsiveWidth"] = false
    }

    func selectUser(row: Int, expectedUser: Int?, expectedIDs: [Int]) async -> Bool {
      guard let selector = control(in: page.view, "rules.user") as? NeoDropdownButton else { return false }
      selector.sendActions(for: .touchUpInside)
      let opened = await waitFor { selector.smokeDropdown?.isOpen == true }
      guard opened, let dropdown = selector.smokeDropdown else { return false }
      let table = dropdown.smokeList
      guard table.numberOfRows(inSection: 0) > row else { return false }
      table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: row, section: 0))
      return await waitFor {
        page.smokeQuery.userID == expectedUser && page.smokeQuery.page == 1
          && page.smokeRules.map(\.id) == expectedIDs
      }
    }

    checks["rulesUserFilterSendsUserID"] = await selectUser(row: 2, expectedUser: 8, expectedIDs: [1004])
    let userQuery = NeoRulesSmokeProtocol.rulesQueries().last
    checks["rulesUserFilterGETIncludesUser"] = query(userQuery, ["type": "normal", "offset": "0", "limit": "2", "userId": "8"])
    let userRestored = await selectUser(row: 1, expectedUser: 7, expectedIDs: [1001, 1002])
    let masterSelected = await selectUser(row: 0, expectedUser: nil, expectedIDs: [1001, 1002])
    if let selector = control(in: page.view, "rules.user") as? NeoDropdownButton {
      checks["rulesMasterClosedValueIsShort"] = masterSelected && selector.accessibilityValue == "master"
      checks["rulesMasterDropdownKeepsWebLabel"] = selector.dropdownRows.first?.title == "master（すべて）"
    } else {
      checks["rulesMasterClosedValueIsShort"] = false
      checks["rulesMasterDropdownKeepsWebLabel"] = false
    }
    let userRestoredAgain = await selectUser(row: 1, expectedUser: 7, expectedIDs: [1001, 1002])
    checks["rulesUserFilterRestoresActiveUser"] = userRestored && masterSelected && userRestoredAgain
    page.view.layoutIfNeeded()

    if let footer = identified(page.view, "rules.pagination"),
       let next = button(in: footer, label: "次のページ") {
      next.sendActions(for: .touchUpInside)
      checks["rulesPagingChangesPageAndOffset"] = await waitFor {
        page.smokeQuery.page == 2 && page.smokeRules.map(\.id) == [1003]
          && query(NeoRulesSmokeProtocol.rulesQueries().last, ["type": "normal", "offset": "2", "limit": "2", "userId": "7"])
      }
    } else {
      checks["rulesPagingChangesPageAndOffset"] = false
    }
    page.view.layoutIfNeeded()

    if let keyword = identified(page.view, "rules.keyword") as? UITextField {
      keyword.text = "Beta"
      keyword.sendActions(for: .editingChanged)
      keyword.sendActions(for: .editingDidEndOnExit)
      if page.smokeQuery.keyword != "Beta" { _ = page.textFieldShouldReturn(keyword) }
      checks["rulesKeywordResetsPageAndFilters"] = await waitFor {
        page.smokeQuery.keyword == "Beta" && page.smokeQuery.page == 1
          && page.smokeRules.map(\.id) == [1002]
          && query(NeoRulesSmokeProtocol.rulesQueries().last, ["type": "normal", "offset": "0", "limit": "2", "userId": "7", "keyword": "Beta"])
      }

      keyword.text = ""
      keyword.sendActions(for: .editingChanged)
      keyword.sendActions(for: .editingDidEndOnExit)
      if !page.smokeQuery.keyword.isEmpty { _ = page.textFieldShouldReturn(keyword) }
      _ = await waitFor { page.smokeQuery.keyword.isEmpty && page.smokeRules.map(\.id) == [1001, 1002] }
    } else {
      checks["rulesKeywordResetsPageAndFilters"] = false
    }

    page.view.layoutIfNeeded()
    if let reserve = control(in: page.view, "rules.hasReserve") {
      reserve.sendActions(for: .touchUpInside)
      checks["rulesHasReserveFiltersAndResetsPage"] = await waitFor {
        page.smokeQuery.hasReserve && page.smokeQuery.page == 1
          && page.smokeRules.map(\.id) == [1001, 1003]
          && query(NeoRulesSmokeProtocol.rulesQueries().last, ["type": "normal", "offset": "0", "limit": "2", "userId": "7", "hasReserve": "true"])
      }
      reserve.sendActions(for: .touchUpInside)
      _ = await waitFor { !page.smokeQuery.hasReserve && page.smokeRules.map(\.id) == [1001, 1002] }
    } else {
      checks["rulesHasReserveFiltersAndResetsPage"] = false
    }

    page.view.layoutIfNeeded()
    let toggleBefore = NeoRulesSmokeProtocol.count("PUT /api/rules/1001/disable")
    if let toggle = control(in: page.view, "rules.toggle.1001") {
      toggle.sendActions(for: .touchUpInside)
      let changed = await waitFor {
        NeoRulesSmokeProtocol.count("PUT /api/rules/1001/disable") > toggleBefore
          && page.smokeIdle
          && page.smokeRules.first(where: { $0.id == 1001 })?.reserveOption.enable == false
      }
      let putQuery = NeoRulesSmokeProtocol.latestPutQuery()
      checks["rulesToggleSendsDisableAndReloads"] = changed
        && query(putQuery, ["syncAnnictStopWatching": "false"])
    } else {
      checks["rulesToggleSendsDisableAndReloads"] = false
    }

    page.view.layoutIfNeeded()
    if let menuButton = control(in: page.view, "rules.menu.1001") {
      menuButton.sendActions(for: .touchUpInside)
      let menuReady = await waitFor {
        views(in: shell.view).compactMap { $0 as? NeoAnchoredMenu }.first != nil
      }
      let menu = views(in: shell.view).compactMap { $0 as? NeoAnchoredMenu }.first
      checks["rulesMenuActionUsesMenuAnchor"] = menuReady && menu?.titles == ["録画済み", "編集", "削除"]
      shell.dismissPopup()
    } else {
      checks["rulesMenuActionUsesMenuAnchor"] = false
    }

    page.view.layoutIfNeeded()
    let selectedForDelete: Bool
    if let select = control(in: page.view, "rules.select"),
       let selectAll = control(in: page.view, "rules.selectAll"),
       let deleteSelection = control(in: page.view, "rules.deleteSelection") {
      select.sendActions(for: .touchUpInside)
      let selectingReady = await waitFor { page.smokeSelecting }
      selectAll.sendActions(for: .touchUpInside)
      let selectedReady = await waitFor { page.smokeSelectedIDs == Set([1001, 1002]) }
      deleteSelection.sendActions(for: .touchUpInside)
      let dialogReady = await waitFor {
        page.presentedViewController?.viewIfLoaded.flatMap { identified($0, "rules.confirmDelete") } != nil
      }
      if dialogReady, let dialogView = page.presentedViewController?.view,
         let confirm = control(in: dialogView, "rules.confirmDelete") {
        confirm.sendActions(for: .touchUpInside)
      }
      let deleted = await waitFor {
        page.smokeIdle
          && page.smokeSelectedIDs == Set([1002])
          && page.smokeSelecting
          && page.smokeRules.map(\.id) == [1002, 1003]
          && NeoRulesSmokeProtocol.count("DELETE /api/rules/1001") == 1
          && NeoRulesSmokeProtocol.count("DELETE /api/rules/1002") == 1
      }
      selectedForDelete = selectingReady && selectedReady && dialogReady && deleted
      checks["rulesBulkDeleteUsesConfirmAndKeepsFailedSelection"] = selectedForDelete
      page.view.layoutIfNeeded()
    } else {
      selectedForDelete = false
      checks["rulesBulkDeleteUsesConfirmAndKeepsFailedSelection"] = false
    }

    page.view.layoutIfNeeded()
    if page.smokeSelecting, let select = control(in: page.view, "rules.select") {
      select.sendActions(for: .touchUpInside)
      _ = await waitFor { !page.smokeSelecting }
    }

    // Leave the rules list through the sidebar Search root, create a rule,
    // and verify that the retained rules controller comes back unchanged.
    var preservedQuery: NeoRuleListQuery?
    var preservedIDs: [Int] = []
    if let keyword = identified(page.view, "rules.keyword") as? UITextField,
       let reserve = control(in: page.view, "rules.hasReserve") {
      keyword.text = "Gamma"
      keyword.sendActions(for: .editingChanged)
      keyword.sendActions(for: .editingDidEndOnExit)
      if page.smokeQuery.keyword != "Gamma" { _ = page.textFieldShouldReturn(keyword) }
      let keywordReady = await waitFor {
        page.smokeQuery.keyword == "Gamma" && page.smokeQuery.page == 1
          && page.smokeRules.map(\.id) == [1003]
      }
      if keywordReady {
        reserve.sendActions(for: .touchUpInside)
        let filterReady = await waitFor {
          page.smokeQuery.keyword == "Gamma" && page.smokeQuery.hasReserve
            && page.smokeQuery.page == 1 && page.smokeRules.map(\.id) == [1003]
        }
        if filterReady {
          preservedQuery = page.smokeQuery
          preservedIDs = page.smokeRules.map(\.id)
        }
      }
    }

    var crossTabPosted = false
    var crossTabReturned = false
    var searchPage: NeoProgramSearchPage?
    if let preservedQuery {
      shell.smokeSelectDestination("search")
      let searchNavigationReady = await waitFor {
        shell.children.compactMap { $0 as? UINavigationController }.contains {
          $0.topViewController is NeoProgramSearchPage
        }
      }
      if searchNavigationReady,
         let searchNavigation = shell.children.compactMap({ $0 as? UINavigationController }).first(where: {
           $0.topViewController is NeoProgramSearchPage
         }),
         let candidate = searchNavigation.topViewController as? NeoProgramSearchPage {
        searchPage = candidate
        let searchReady = await waitFor {
          candidate.viewIfLoaded?.window != nil
            && identified(candidate.view, "programSearch.keyword") != nil
            && identified(candidate.view, "programSearch.rule") != nil
        }
        if searchReady,
           let searchKeyword = identified(candidate.view, "programSearch.keyword") as? UITextField,
           let create = identified(candidate.view, "programSearch.rule") as? UIControl {
          searchKeyword.text = "CrossTabCreate"
          searchKeyword.sendActions(for: .editingChanged)
          candidate.view.layoutIfNeeded()
          create.sendActions(for: .touchUpInside)
          let editorReady = await waitFor {
            guard let editor = candidate.presentedViewController as? NeoProgramRuleEditor else { return false }
            editor.view.layoutIfNeeded()
            return editor.view.window != nil && identified(editor.view, "ruleEditor.card") != nil
          }
          if editorReady, let editor = candidate.presentedViewController as? NeoProgramRuleEditor {
            control(in: editor.view, "ruleEditor.tab.recording")?.sendActions(for: .touchUpInside)
            control(in: editor.view, "ruleEditor.save")?.sendActions(for: .touchUpInside)
            crossTabReturned = await waitFor {
              page.viewIfLoaded?.window != nil && navigation.topViewController === page
                && candidate.presentedViewController == nil && page.smokeQuery == preservedQuery
            }
            crossTabPosted = NeoRulesSmokeProtocol.count("POST /api/rules") == 1
              && crossTabReturned
              && page.smokeQuery.keyword == preservedQuery.keyword
              && page.smokeQuery.hasReserve == preservedQuery.hasReserve
              && page.smokeQuery.page == preservedQuery.page
              && page.smokeRules.map(\.id) == preservedIDs
              && (identified(page.view, "rules.keyword") as? UITextField)?.text == preservedQuery.keyword
          }
        }
      }
    }
    checks["rulesCrossTabRuleCreatePostsAndReturns"] = crossTabPosted
    checks["rulesCrossTabRuleCreatePreservesQuery"] = crossTabPosted && crossTabReturned
    if page.viewIfLoaded?.window == nil {
      searchPage?.presentedViewController?.dismiss(animated: false)
      shell.smokeSelectDestination("rule")
      _ = await waitFor { page.viewIfLoaded?.window != nil && navigation.topViewController === page }
    }

    if let add = control(in: page.view, "rules.add") {
      add.sendActions(for: .touchUpInside)
      let navigated = await waitFor { navigation.topViewController is NeoProgramSearchPage }
      checks["rulesAddNavigatesToSearch"] = navigated
      if navigated {
        shell.goBack()
        _ = await waitFor { navigation.topViewController === page }
      }
    } else {
      checks["rulesAddNavigatesToSearch"] = false
    }

    let allQueries = NeoRulesSmokeProtocol.rulesQueries()
    checks["rulesGETCoversRequestedFilters"] = allQueries.contains {
      query($0, ["type": "normal", "offset": "0", "limit": "2", "userId": "7", "keyword": "Beta"])
    } && allQueries.contains {
      query($0, ["type": "normal", "offset": "0", "limit": "2", "userId": "7", "hasReserve": "true"])
    }
    return checks
  }
}
#endif
