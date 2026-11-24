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
  private static var urls: [String: [URL]] = [:]
  private static var reservationFailures = 0
  private static var ruleCreateFailures = 0
  private static var nonSearchWrites = 0
  private static var exercisesReservations = false
  private static var warningCounts = (conflicts: 0, overlaps: 0)
  private static var manualReservations: [Int: [String: Any]] = [:]
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
    calls.removeAll(); bodies.removeAll(); urls.removeAll(); reservationFailures = 1; ruleCreateFailures = 1; nonSearchWrites = 0
    exercisesReservations = false; warningCounts = (0, 0); manualReservations.removeAll()
  }

  static func enableReservationFlow() {
    lock.lock(); defer { lock.unlock() }
    exercisesReservations = true
  }

  static func setWarningCounts(conflicts: Int, overlaps: Int) {
    lock.lock(); defer { lock.unlock() }
    warningCounts = (conflicts, overlaps)
  }

  static func count(_ key: String) -> Int {
    lock.lock(); defer { lock.unlock() }
    return calls[key, default: 0]
  }

  static func searchBodies() -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return bodies["POST /api/schedules/search"] ?? []
  }

  static func requestBodies(_ key: String) -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return bodies[key] ?? []
  }

  static func lastURL(_ key: String) -> URL? {
    lock.lock(); defer { lock.unlock() }
    return urls[key]?.last
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
    if let url = request.url { urls[key, default: []].append(url) }
    if request.httpMethod != "GET", path != "/api/schedules/search" { nonSearchWrites += 1 }
    if !body.isEmpty { bodies[key, default: []].append(body) }

    var status = 200
    let value: Any
    if path == "/api/channels", request.httpMethod == "GET" {
      value = Array(1...18).map { id -> [String: Any] in
        [
          "id": id,
          "name": id == 1 ? "Fixture Station" : String(format: "Fixture Station %02d", id),
          "channelType": "GR",
          "hasLogoData": false
        ]
      }
    } else if path == "/api/reserves/cnts", request.httpMethod == "GET" {
      value = ["normal": manualReservations.count, "conflicts": warningCounts.conflicts,
        "overlaps": warningCounts.overlaps, "skips": 0]
    } else if path == "/api/config", request.httpMethod == "GET" {
      value = ["encode": exercisesReservations ? ["Fixture AVC"] : [], "recorded": ["Archive"], "broadcast": ["GR": true]] as [String: Any]
    } else if path == "/api/rules/41", request.httpMethod == "GET" {
      value = Self.normalRule()
    } else if path == "/api/rules/42", request.httpMethod == "GET" {
      value = Self.timeRule()
    } else if path == "/api/rules", request.httpMethod == "POST" {
      if ruleCreateFailures > 0 {
        ruleCreateFailures -= 1
        status = 503
        value = ["message": "fixture rule create failure"]
      } else {
        value = ["ruleId": 43]
      }
    } else if path == "/api/rules/41", request.httpMethod == "PUT" {
      value = ["code": 200]
    } else if path == "/api/schedules/search", request.httpMethod == "POST" {
      let option = body["option"] as? [String: Any] ?? [:]
      let hasRelatedChannel = (option["channelIds"] as? [Any])?.contains { ($0 as? NSNumber)?.intValue == 1 } == true
      value = [Self.program(hasRelatedChannel ? 9002 : 9001, related: hasRelatedChannel,
        longDetails: exercisesReservations && hasRelatedChannel)]
    } else if exercisesReservations, path.hasPrefix("/api/schedules/detail/"),
      let id = path.split(separator: "/").last.flatMap({ Int($0) }) {
      value = Self.program(id, related: id == 9002, longDetails: true)
    } else if exercisesReservations, path == "/api/reserves", request.httpMethod == "POST" {
      let id = 6100 + calls[key, default: 0]
      let time = body["timeSpecifiedOption"] as? [String: Any]
      let programID = body["programId"] as? Int
      var item = Self.program(programID ?? 9002, related: true, longDetails: true)
      item["id"] = id; item["programId"] = programID
      for field in ["name", "channelId", "startAt", "endAt"] {
        if let value = time?[field] { item[field] = value }
      }
      manualReservations[id] = editReservation(item, body: body)
      status = 201; value = ["reserveId": id]
    } else if exercisesReservations, path.hasPrefix("/api/reserves/"),
      let id = path.split(separator: "/").last.flatMap({ Int($0) }), let item = manualReservations[id] {
      switch request.httpMethod {
      case "PUT":
        manualReservations[id] = editReservation(item, body: body)
        value = ["code": 201]
      case "DELETE":
        manualReservations[id] = nil
        value = ["code": 200]
      default: value = item
      }
    } else if path == "/api/reserves", request.httpMethod == "GET" {
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let ruleID = query.first(where: { $0.name == "ruleId" })?.value.flatMap(Int.init)
      if ruleID == 42 {
        value = [
          "reserves": [[
            "id": 5200, "userId": 7, "ruleId": 42, "programId": 9001, "channelId": 1,
            "startAt": 1791025200000.0, "endAt": 1791027000000.0,
            "name": "Time fixture", "description": "時刻指定予約",
            "isConflict": false, "isSkip": false, "isOverlap": false
          ] as [String: Any]],
          "total": 1
        ] as [String: Any]
      } else if exercisesReservations {
        let type = query.first(where: { $0.name == "type" })?.value
        let values = type == "normal" ? manualReservations.keys.sorted().compactMap { manualReservations[$0] } : []
        let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? 0
        let limit = query.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 24
        value = ["reserves": Array(values.dropFirst(offset).prefix(limit)), "total": values.count] as [String: Any]
      } else {
        status = 404
        value = ["message": "unexpected reserve fixture"]
      }
    } else if path == "/api/reserves/lists", request.httpMethod == "GET" {
      if reservationFailures > 0 {
        reservationFailures -= 1
        status = 503
        value = ["message": "fixture reservation failure"]
      } else if exercisesReservations {
        let normal: [[String: Any]] = manualReservations.values.compactMap { item in
          guard let programID = item["programId"] else { return nil }
          return ["reserveId": item["id"]!, "userId": item["userId"]!, "programId": programID]
        }
        value = ["normal": normal, "conflicts": [[String: Any]](), "overlaps": [[String: Any]](), "skips": [[String: Any]]()]
      } else {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = query.first(where: { $0.name == "startAt" })?.value.flatMap(Int64.init) ?? 0
        let id = start == 1791025200000 ? 9002 : 9001
        value = [
          "normal": [[String: Any]](),
          "conflicts": id == 9002 ? [[String: Any]]() : [["reserveId": 5000 + id, "userId": 7, "programId": id] as [String: Any]],
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

  private static func editReservation(_ input: [String: Any], body: [String: Any]) -> [String: Any] {
    var item = input
    item["allowEndLack"] = body["allowEndLack"]
    item["userId"] = body["userId"]
    let save = body["saveOption"] as? [String: Any], encode = body["encodeOption"] as? [String: Any]
    for key in ["parentDirectoryName", "directory", "recordedFormat"] { item[key] = save?[key] }
    for index in 1...3 {
      item["encodeMode\(index)"] = encode?["mode\(index)"]
      item["encodeParentDirectoryName\(index)"] = encode?["encodeParentDirectoryName\(index)"]
      item["encodeDirectory\(index)"] = encode?["directory\(index)"]
    }
    item["isDeleteOriginalAfterEncode"] = encode?["isDeleteOriginalAfterEncode"]
    item["updateThumbnail"] = encode?["updateThumbnail"]
    return item
  }

  private static func program(_ id: Int, related: Bool, longDetails: Bool = false) -> [String: Any] {
    let start = related ? 1791025200000.0 : 1791021600000.0
    let reservationFixture = longDetails && id == 9002
    return [
      "id": id,
      "channelId": 1,
      "startAt": start,
      "endAt": start + 1_800_000,
      "isFree": true,
      "name": reservationFixture ? "長い番組名でも画面内で折り返して表示できる予約テスト番組" : "Fixture program",
      "description": reservationFixture
        ? "これは狭い画面で番組情報が横にはみ出さず折り返されることを確認するための予約テスト用の長い概要です。放送内容、出演者、関連情報が続いても予約画面の幅を超えないように表示します。"
        : "概要とリンク https://program-search.invalid/details",
      "extended": reservationFixture
        ? "◇見どころ\n長い日本語の拡張情報を複数行で表示します。空白のない文章やURLを含む番組情報でも、カードとフォームの中に収まり、左右のスクロールを発生させないことを確認します。\nhttps://program-search.invalid/extended"
        : "◇見どころ\n拡張情報とリンク https://program-search.invalid/extended",
      "genre1": 3,
      "subGenre1": 0,
      "videoType": "h.264",
      "videoResolution": "1920x1080",
      "audioSamplingRate": 48_000,
      "audioComponentType": 3
    ]
  }

  private static func normalRule() -> [String: Any] {
    [
      "id": 41,
      "userId": 7,
      "isTimeSpecification": false,
      "searchOption": [
        "keyword": "Edited Rule", "name": true, "description": true,
        "channelIds": [1], "times": [["week": 127]],
        "durationMin": 1800, "searchPeriods": [["startAt": 0, "endAt": 253402300799999]]
      ] as [String: Any],
      "reserveOption": ["enable": true, "allowEndLack": true, "avoidDuplicate": true, "periodToAvoidDuplicate": 7] as [String: Any],
      "saveOption": ["parentDirectoryName": "Fixture", "directory": "Edited", "recordedFormat": "%TITLE%"] as [String: Any]
    ]
  }

  private static func timeRule() -> [String: Any] {
    [
      "id": 42,
      "userId": 7,
      "isTimeSpecification": true,
      "searchOption": [
        "keyword": "Time fixture", "channelIds": [1],
        "times": [["week": 127, "start": 84600, "range": 3600]]
      ] as [String: Any],
      "reserveOption": ["enable": true, "allowEndLack": true, "avoidDuplicate": false] as [String: Any]
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
    api.isHalfWidthDisplayed = false
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

    func finite(_ rect: CGRect) -> Bool {
      [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite }
    }

    func tableCell(_ table: UITableView, identifier: String) -> (UITableViewCell, IndexPath)? {
      for section in 0..<table.numberOfSections {
        for row in 0..<table.numberOfRows(inSection: section) {
          let indexPath = IndexPath(row: row, section: section)
          guard let cell = table.cellForRow(at: indexPath) else { continue }
          if cell.accessibilityIdentifier == identifier { return (cell, indexPath) }
        }
      }
      return nil
    }

    func revealTableCell(_ table: UITableView, identifier: String) -> (UITableViewCell, IndexPath)? {
      for section in 0..<table.numberOfSections {
        for row in 0..<table.numberOfRows(inSection: section) {
          let indexPath = IndexPath(row: row, section: section)
          table.scrollToRow(at: indexPath, at: .middle, animated: false)
          table.layoutIfNeeded()
          if let cell = table.cellForRow(at: indexPath), cell.accessibilityIdentifier == identifier {
            return (cell, indexPath)
          }
        }
      }
      return nil
    }

    func optionText(in table: UITableView, identifier: String) -> String? {
      guard let (cell, _) = tableCell(table, identifier: identifier) ?? revealTableCell(table, identifier: identifier) else { return nil }
      return (cell.contentConfiguration as? UIListContentConfiguration)?.text
    }

    func visibleViewport(of root: UIView) -> CGRect {
      root.layoutIfNeeded()
      let keyboardFrame = root.keyboardLayoutGuide.layoutFrame
      let bottom = keyboardFrame.minY.isFinite && keyboardFrame.minY > 0
        && keyboardFrame.minY < root.bounds.maxY - 1 ? keyboardFrame.minY : root.bounds.maxY
      return CGRect(x: 0, y: 0, width: root.bounds.width, height: max(0, bottom))
    }

    func wrapFits(_ wrap: UIView, count: Int, minimum: Bool = false) -> Bool {
      wrap.layoutIfNeeded()
      guard finite(wrap.frame), finite(wrap.bounds), wrap.bounds.width > 0, wrap.bounds.height > 0 else { return false }
      let buttons = wrap.subviews.compactMap { $0 as? UIButton }
      guard minimum ? buttons.count >= count : buttons.count == count else { return false }
      let bounds = wrap.bounds.insetBy(dx: -1, dy: -1)
      return buttons.allSatisfy { button in
        button.layoutIfNeeded()
        let frame = button.frame
        return finite(frame) && frame.width > 0 && frame.height > 0 && bounds.contains(frame)
      }
    }

    func formWrapChecks(in root: UIView) -> [String: Bool] {
      root.layoutIfNeeded()
      let list = identified(root, "programSearch.list") as? UITableView
      list?.layoutIfNeeded()
      list?.tableHeaderView?.layoutIfNeeded()
      let requirements: [(String, String, Int, Bool)] = [
        ("programSearch.keywordOptions", "programSearchKeywordOptionsGeometry", 5, false),
        ("programSearch.ignoreOptions", "programSearchIgnoreOptionsGeometry", 5, false),
        ("programSearch.channelWaveOptions", "programSearchChannelWaveOptionsGeometry", 1, true),
        ("programSearch.weekOptions", "programSearchWeekOptionsGeometry", 7, false)
      ]
      return Dictionary(uniqueKeysWithValues: requirements.map { identifier, key, count, minimum in
        (key, identified(root, identifier).map { wrapFits($0, count: count, minimum: minimum) } ?? false)
      })
    }

    func statusChipFitsIntrinsicWidth(in root: UIView) -> Bool {
      guard let marked = identified(root, "programSearch.statusChip") else { return false }
      marked.layoutIfNeeded()
      let label = (marked as? UILabel) ?? views(in: marked).compactMap { $0 as? UILabel }.first
      guard let label, label.text == "競合", let container = marked is UILabel ? marked.superview : marked else { return false }
      container.layoutIfNeeded()
      label.layoutIfNeeded()
      let expected = label.intrinsicContentSize.width + 16
      return finite(container.bounds) && expected.isFinite && expected > 0 && abs(container.bounds.width - expected) <= 1
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
    let formWrapReady = await waitFor({
      let results = formWrapChecks(in: page.view)
      return results.values.allSatisfy { $0 }
    }, attempts: 90)
    checks.merge(formWrapChecks(in: page.view), uniquingKeysWith: { _, new in new })
    checks["programSearchFormWrapGeometry"] = formWrapReady
    _ = await waitFor({
      views(in: page.view).compactMap { $0 as? NeoOutlinedFieldLabel }.allSatisfy { $0.smokeMotionDuration == nil }
    }, attempts: 20)
    capture("form")

    func viewWithID(_ identifier: String) -> UIView? {
      identified(page.view, identifier) ?? identified(shell.view, identifier)
    }

    func queryValue(_ url: URL?, _ name: String) -> String? {
      URLComponents(url: url ?? URL(string: "https://program-search.invalid")!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func intValue(_ value: Any?) -> Int? {
      if let value = value as? NSNumber { return value.intValue }
      return value as? Int
    }

    func revealControl(_ control: UIView, in searchPage: NeoProgramSearchPage? = nil) {
      let activePage = searchPage ?? page
      guard let list = identified(activePage.view, "programSearch.list") as? UITableView else { return }
      activePage.view.layoutIfNeeded()
      list.scrollRectToVisible(control.convert(control.bounds, to: list).insetBy(dx: 0, dy: -24), animated: false)
      activePage.view.layoutIfNeeded()
    }

    func popupState(anchorID: String, menuID: String) -> (anchor: CGRect, menu: CGRect, viewport: CGRect)? {
      guard let anchor = viewWithID(anchorID), let menu = viewWithID(menuID) else { return nil }
      let root: UIView = anchor.isDescendant(of: page.view) && menu.isDescendant(of: page.view) ? page.view : shell.view
      let anchorRect = anchor.convert(anchor.bounds, to: root)
      let menuRect = menu.convert(menu.bounds, to: root)
      let viewport = root === page.view ? visibleViewport(of: root) : root.bounds
      guard finite(anchorRect), finite(menuRect), finite(viewport) else { return nil }
      return (anchorRect, menuRect, viewport)
    }

    func waitForMenu(_ identifier: String, minimumRows: Int = 1) async -> UITableView? {
      let ready = await waitFor {
        page.view.layoutIfNeeded()
        guard let menu = viewWithID(identifier) as? UITableView,
          menu.superview?.isHidden == false, !menu.bounds.isEmpty else { return false }
        menu.layoutIfNeeded()
        return menu.numberOfRows(inSection: 0) >= minimumRows
      }
      return ready ? viewWithID(identifier) as? UITableView : nil
    }

    func waitForPicker() async -> NeoProgramSearchPickerController? {
      for _ in 0..<180 {
        if let picker = page.presentedViewController as? NeoProgramSearchPickerController,
          picker.viewIfLoaded?.window != nil, !picker.isBeingPresented {
          picker.view.layoutIfNeeded()
          return picker
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return nil
    }

    func outlinedLabel(near control: UIView) -> NeoOutlinedFieldLabel? {
      var current: UIView? = control
      while let view = current {
        if let label = view.subviews.compactMap({ $0 as? NeoOutlinedFieldLabel }).first {
          return label
        }
        current = view.superview
      }
      return nil
    }

    func closeEnough(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
      [abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY), abs(lhs.width - rhs.width), abs(lhs.height - rhs.height)]
        .allSatisfy { $0 <= tolerance }
    }

    // Exercise the public form surface before the first search.  These checks
    // intentionally restore the form afterwards so the wire assertions below
    // continue to describe the original Fixture search.
    if let channel = viewWithID("programSearch.channel") as? UITextField,
      let channelControl = viewWithID("programSearch.channelControl"),
      let channelToggle = button(in: page.view, identifier: "programSearch.channelToggle"),
      let formList = viewWithID("programSearch.list") as? UITableView,
      let clearForm = button(in: page.view, identifier: "programSearch.clear") {
      checks["programSearchFormPublicIDs"] = true
      checks["programSearch.channelFieldHandlesTaps"] = channel.isDescendant(of: channelControl)
        && channelControl.gestureRecognizers?.contains { $0 is UITapGestureRecognizer && !$0.cancelsTouchesInView } == true
      formList.setContentOffset(.zero, animated: false)
      formList.layoutIfNeeded()
      _ = channel.becomeFirstResponder()
      page.view.layoutIfNeeded()
      let keyboardShown = await waitFor({
        page.view.bounds.maxY - visibleViewport(of: page.view).maxY > 80
      }, attempts: 30)
      channelToggle.sendActions(for: .touchUpInside)
      let firstMenu = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18)
      if let firstMenu, let state = popupState(anchorID: "programSearch.channelControl", menuID: "programSearch.channelSuggestions") {
        checks["programSearch.channelMenuHasManyRows"] = firstMenu.numberOfRows(inSection: 0) >= 18
        checks["programSearch.channelMenuScrollKeepsKeyboard"] = firstMenu.keyboardDismissMode == .none
        checks["programSearch.channelFocusOnOpen"] = channel.isFirstResponder
        checks["programSearch.channelMenuBoundsAndAnchorVisible"] = state.viewport.contains(state.menu)
          && state.viewport.intersects(state.anchor) && state.menu.width > 0 && state.menu.height > 0
        checks["programSearch.channelMenuChoosesAvailableSide"] = (state.menu.minY >= state.anchor.maxY - 2)
          || (state.menu.maxY <= state.anchor.minY + 2)
        capture("channel-menu")
        if keyboardShown { capture("channel-keyboard") }
      } else {
        checks["programSearch.channelMenuHasManyRows"] = false
        checks["programSearch.channelMenuScrollKeepsKeyboard"] = false
        checks["programSearch.channelFocusOnOpen"] = false
        checks["programSearch.channelMenuBoundsAndAnchorVisible"] = false
        checks["programSearch.channelMenuChoosesAvailableSide"] = false
      }

      channelToggle.sendActions(for: .touchUpInside)
      let closed = await waitFor { viewWithID("programSearch.channelSuggestions") == nil }
      checks["programSearch.channelFocusRetainedAfterClose"] = closed && channel.isFirstResponder
      channelToggle.sendActions(for: .touchUpInside)
      let reopened = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18)
      checks["programSearch.channelFocusRetainedOnReopen"] = reopened != nil && channel.isFirstResponder

      // The fixture form is normally long enough to try a second anchor
      // direction.  If this viewport cannot place the station field near an
      // edge, record the skip rather than turning an iPad/small-window layout
      // into a brittle failure.
      if reopened != nil {
        channelToggle.sendActions(for: .touchUpInside)
        _ = await waitFor { viewWithID("programSearch.channelSuggestions") == nil }
      }
      formList.layoutIfNeeded()
      let anchorInList = channelControl.convert(channelControl.bounds, to: formList)
      let maxOffset = max(0, formList.contentSize.height - formList.bounds.height)
      let canTryAbove = maxOffset > 1 && anchorInList.maxY > formList.bounds.height * 0.55
      if canTryAbove {
        let desiredOffset = anchorInList.maxY - formList.bounds.height * 0.82
        formList.setContentOffset(CGPoint(x: 0, y: min(maxOffset, max(0, desiredOffset))), animated: false)
        formList.layoutIfNeeded()
        page.view.layoutIfNeeded()
        channel.becomeFirstResponder()
        channelToggle.sendActions(for: .touchUpInside)
        let aboveMenu = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18)
        if aboveMenu != nil, let state = popupState(anchorID: "programSearch.channelControl", menuID: "programSearch.channelSuggestions") {
          checks["programSearch.channelMenuFlipsAbove"] = state.menu.maxY <= state.anchor.minY - 7
            && state.viewport.contains(state.menu) && state.viewport.intersects(state.anchor)
        } else {
          checks["programSearch.channelMenuFlipsAbove"] = false
        }
        channelToggle.sendActions(for: .touchUpInside)
        _ = await waitFor { viewWithID("programSearch.channelSuggestions") == nil }
      } else {
        checks["programSearch.channelMenuFlipsAbove"] = true
        checks["programSearch.channelMenuFlipAboveSkipped"] = true
      }
      formList.setContentOffset(.zero, animated: false)
      formList.layoutIfNeeded()
      page.view.layoutIfNeeded()

      channel.becomeFirstResponder()
      channelToggle.sendActions(for: .touchUpInside)
      if let stationMenu = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18) {
        // The keyboard layout guide can still be moving the search form after
        // the candidate rows first become visible. Measure scroll independence
        // once both viewports have settled.
        var previousFormBounds = formList.bounds
        var previousMenuBounds = stationMenu.bounds
        var stableSamples = 0
        let settled = await waitFor({
          page.view.layoutIfNeeded()
          stationMenu.layoutIfNeeded()
          let formBounds = formList.bounds, menuBounds = stationMenu.bounds
          stableSamples = formBounds == previousFormBounds && menuBounds == previousMenuBounds ? stableSamples + 1 : 0
          previousFormBounds = formBounds
          previousMenuBounds = menuBounds
          return stableSamples >= 4
        }, attempts: 35)
        stationMenu.layoutIfNeeded()
        let initialOffset = stationMenu.contentOffset.y
        let formOffset = formList.contentOffset
        let lastRow = IndexPath(row: stationMenu.numberOfRows(inSection: 0) - 1, section: 0)
        stationMenu.scrollToRow(at: lastRow, at: .bottom, animated: false)
        page.view.layoutIfNeeded()
        stationMenu.layoutIfNeeded()
        checks["programSearch.channelCandidateScrollRetainsFocus"] = stationMenu.keyboardDismissMode == .none
          && channel.isFirstResponder
        checks["programSearch.channelCandidateMenuScrolls"] = stationMenu.contentOffset.y > initialOffset + 1
        checks["programSearch.channelCandidateScrollLeavesFormInPlace"] = settled
          && abs(formList.contentOffset.x - formOffset.x) < 0.5 && abs(formList.contentOffset.y - formOffset.y) < 0.5
        if let (_, row2) = revealTableCell(stationMenu, identifier: "programSearch.channelOption.2") {
          stationMenu.delegate?.tableView?(stationMenu, didSelectRowAt: row2)
          let selected2 = await waitFor {
            guard let menu = viewWithID("programSearch.channelSuggestions") as? UITableView,
              let (cell, _) = tableCell(menu, identifier: "programSearch.channelOption.2") else { return false }
            return viewWithID("programSearch.channelChip.2") != nil
              && menu.superview?.isHidden == false
              && menu.numberOfRows(inSection: 0) >= 18
              && cell.accessibilityTraits.contains(.selected)
          }
          checks["programSearch.channelCandidateSelection"] = selected2 && channel.isFirstResponder
          if let (_, row3) = revealTableCell(stationMenu, identifier: "programSearch.channelOption.3") {
            stationMenu.delegate?.tableView?(stationMenu, didSelectRowAt: row3)
            let selected3 = await waitFor {
              guard let menu = viewWithID("programSearch.channelSuggestions") as? UITableView,
                let (cell, _) = tableCell(menu, identifier: "programSearch.channelOption.3") else { return false }
              return viewWithID("programSearch.channelChip.2") != nil
                && viewWithID("programSearch.channelChip.3") != nil
                && menu.superview?.isHidden == false
                && menu.numberOfRows(inSection: 0) >= 18
                && cell.accessibilityTraits.contains(.selected)
            }
            checks["programSearch.channelMultiSelect"] = selected2 && selected3 && channel.isFirstResponder
              && viewWithID("programSearch.channelSuggestions") != nil
            let waveButtons = viewWithID("programSearch.channelWaveOptions").map { views(in: $0).compactMap { $0 as? UIButton } } ?? []
            checks["programSearch.channelSelectionDisablesWave"] = !waveButtons.isEmpty && waveButtons.allSatisfy { !$0.isEnabled }
          } else {
            checks["programSearch.channelMultiSelect"] = false
            checks["programSearch.channelSelectionDisablesWave"] = false
          }
        } else {
          checks["programSearch.channelCandidateSelection"] = false
          checks["programSearch.channelMultiSelect"] = false
          checks["programSearch.channelSelectionDisablesWave"] = false
        }
      } else {
        checks["programSearch.channelCandidateScrollRetainsFocus"] = false
        checks["programSearch.channelCandidateMenuScrolls"] = false
        checks["programSearch.channelCandidateScrollLeavesFormInPlace"] = false
        checks["programSearch.channelCandidateSelection"] = false
        checks["programSearch.channelMultiSelect"] = false
        checks["programSearch.channelSelectionDisablesWave"] = false
      }

      clearForm.sendActions(for: .touchUpInside)
      _ = await waitFor {
        (viewWithID("programSearch.channelChip.2") == nil && viewWithID("programSearch.channelChip.3") == nil)
          && channel.text?.isEmpty == true
          && viewWithID("programSearch.channelSuggestions") == nil
      }
      page.view.endEditing(true)

      // Blurring the station field must not discard the open candidates or
      // the query.  A candidate remains selectable after the keyboard closes;
      // the caret is also a pure open/close control when focus is absent.
      channel.text = "Fixture"
      _ = channel.becomeFirstResponder()
      channel.sendActions(for: .editingChanged)
      var blurMenu = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18)
      if blurMenu == nil {
        channelToggle.sendActions(for: .touchUpInside)
        blurMenu = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18)
      }
      let retainedQuery = channel.text ?? ""
      _ = channel.resignFirstResponder()
      let menuAndQueryRetained = await waitFor {
        viewWithID("programSearch.channelSuggestions") != nil
          && channel.text == retainedQuery && !channel.isFirstResponder
      }
      checks["programSearchChannelBlurRetainsMenuAndQuery"] = menuAndQueryRetained
      if let blurMenu,
        let (_, row4) = revealTableCell(blurMenu, identifier: "programSearch.channelOption.4") {
        blurMenu.delegate?.tableView?(blurMenu, didSelectRowAt: row4)
        checks["programSearchChannelBlurSelectsWithoutKeyboard"] = await waitFor {
          guard let menu = viewWithID("programSearch.channelSuggestions") as? UITableView,
            let (cell, _) = tableCell(menu, identifier: "programSearch.channelOption.4") else { return false }
          return viewWithID("programSearch.channelChip.4") != nil
            && menu.superview?.isHidden == false
            && menu.numberOfRows(inSection: 0) >= 18
            && cell.accessibilityTraits.contains(.selected)
            && channel.text == retainedQuery
            && !channel.isFirstResponder
        }
      } else {
        checks["programSearchChannelBlurSelectsWithoutKeyboard"] = false
      }

      _ = channel.resignFirstResponder()
      let closedAfterBlurSelection: Bool
      if viewWithID("programSearch.channelSuggestions") != nil {
        channelToggle.sendActions(for: .touchUpInside)
        closedAfterBlurSelection = await waitFor {
          viewWithID("programSearch.channelSuggestions") == nil && !channel.isFirstResponder
        }
      } else {
        closedAfterBlurSelection = true
      }
      channelToggle.sendActions(for: .touchUpInside)
      let caretOpened = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18)
      checks["programSearchChannelCaretOpensWithoutFocus"] = closedAfterBlurSelection
        && caretOpened != nil && !channel.isFirstResponder
      channelToggle.sendActions(for: .touchUpInside)
      checks["programSearchChannelCaretClosesWithoutFocus"] = await waitFor {
        viewWithID("programSearch.channelSuggestions") == nil && !channel.isFirstResponder
      }
      clearForm.sendActions(for: .touchUpInside)
      page.view.endEditing(true)
    } else {
      checks["programSearchFormPublicIDs"] = false
    }

    if let genreButton = button(in: page.view, identifier: "programSearch.genre"),
      let subGenreButton = button(in: page.view, identifier: "programSearch.subGenre"),
      let startHourButton = button(in: page.view, identifier: "programSearch.startHour"),
      let rangeHourButton = button(in: page.view, identifier: "programSearch.rangeHour"),
      let clearForm = button(in: page.view, identifier: "programSearch.clear") {
      checks["programSearchDetailButtonsReady"] = true
      checks["programSearchSubGenreInitiallyDisabled"] = !subGenreButton.isEnabled
      if subGenreButton.bounds.height <= 0 || subGenreButton.isHidden {
        button(in: page.view, label: "詳細条件")?.sendActions(for: .touchUpInside)
        _ = await waitFor { !subGenreButton.isHidden && subGenreButton.bounds.height > 0 }
      }

      revealControl(genreButton)
      genreButton.sendActions(for: .touchUpInside)
      if let genreMenu = await waitForMenu("programSearch.options.genre", minimumRows: 14) {
        capture("genre-menu")
        checks["programSearchGenreLabels"] = optionText(in: genreMenu, identifier: "programSearch.option.genre.all") == "すべて"
          && optionText(in: genreMenu, identifier: "programSearch.option.genre.3") == "ドラマ"
        checks["programSearchGenreAnchorVisible"] = popupState(anchorID: "programSearch.genre", menuID: "programSearch.options.genre").map {
          $0.viewport.intersects($0.anchor) && $0.viewport.contains($0.menu)
        } ?? false
        if let (_, drama) = revealTableCell(genreMenu, identifier: "programSearch.option.genre.3") {
          genreMenu.delegate?.tableView?(genreMenu, didSelectRowAt: drama)
        }
        if let genreMenu = await waitForMenu("programSearch.options.genre", minimumRows: 14),
          let (_, anime) = revealTableCell(genreMenu, identifier: "programSearch.option.genre.7") {
          genreMenu.delegate?.tableView?(genreMenu, didSelectRowAt: anime)
          let title = genreButton.title(for: .normal) ?? ""
          checks["programSearchGenreMultiSelect"] = title.contains("ドラマ") && title.contains("アニメ・特撮")
        } else {
          checks["programSearchGenreMultiSelect"] = false
        }
      } else {
        checks["programSearchGenreLabels"] = false
        checks["programSearchGenreAnchorVisible"] = false
        checks["programSearchGenreMultiSelect"] = false
      }

      revealControl(subGenreButton)
      subGenreButton.sendActions(for: .touchUpInside)
      if let subMenu = await waitForMenu("programSearch.options.subGenre", minimumRows: 1) {
        checks["programSearchSubGenreLabels"] = optionText(in: subMenu, identifier: "programSearch.option.subGenre.3.header") == "ドラマ"
          && optionText(in: subMenu, identifier: "programSearch.option.subGenre.3.all") == "すべて"
        checks["programSearchSubGenreAnchorVisible"] = popupState(anchorID: "programSearch.subGenre", menuID: "programSearch.options.subGenre").map {
          $0.viewport.intersects($0.anchor) && $0.viewport.contains($0.menu)
        } ?? false
        if let (_, domestic) = revealTableCell(subMenu, identifier: "programSearch.option.subGenre.3.0") {
          subMenu.delegate?.tableView?(subMenu, didSelectRowAt: domestic)
        }
        if let subMenu = await waitForMenu("programSearch.options.subGenre", minimumRows: 1),
          let (_, overseas) = revealTableCell(subMenu, identifier: "programSearch.option.subGenre.3.1") {
          subMenu.delegate?.tableView?(subMenu, didSelectRowAt: overseas)
          let title = subGenreButton.title(for: .normal) ?? ""
          checks["programSearchSubGenreMultiSelect"] = title.contains("国内ドラマ") && title.contains("海外ドラマ")
        } else {
          checks["programSearchSubGenreMultiSelect"] = false
        }
      } else {
        checks["programSearchSubGenreLabels"] = false
        checks["programSearchSubGenreAnchorVisible"] = false
        checks["programSearchSubGenreMultiSelect"] = false
      }
      page.view.endEditing(true)
      clearForm.sendActions(for: .touchUpInside)

      revealControl(startHourButton)
      startHourButton.sendActions(for: .touchUpInside)
      if let startMenu = await waitForMenu("programSearch.options.startHour", minimumRows: 25) {
        capture("start-hour-menu")
        checks["programSearchStartHourLabels"] = optionText(in: startMenu, identifier: "programSearch.option.startHour.none") == "指定なし"
          && optionText(in: startMenu, identifier: "programSearch.option.startHour.0") == "0時"
          && optionText(in: startMenu, identifier: "programSearch.option.startHour.23") == "23時"
        checks["programSearchStartHourAnchorVisible"] = popupState(anchorID: "programSearch.startHour", menuID: "programSearch.options.startHour").map {
          $0.viewport.contains($0.anchor) && $0.viewport.contains($0.menu)
        } ?? false
        if let (_, hour23) = tableCell(startMenu, identifier: "programSearch.option.startHour.23") ?? revealTableCell(startMenu, identifier: "programSearch.option.startHour.23") {
          startMenu.delegate?.tableView?(startMenu, didSelectRowAt: hour23)
        }
        checks["programSearchStartHourSelect"] = (startHourButton.title(for: .normal) ?? "").contains("23時")
      } else {
        checks["programSearchStartHourLabels"] = false
        checks["programSearchStartHourAnchorVisible"] = false
        checks["programSearchStartHourSelect"] = false
      }

      revealControl(rangeHourButton)
      rangeHourButton.sendActions(for: .touchUpInside)
      if let rangeMenu = await waitForMenu("programSearch.options.rangeHour", minimumRows: 24) {
        capture("range-hour-menu")
        checks["programSearchRangeHourLabels"] = optionText(in: rangeMenu, identifier: "programSearch.option.rangeHour.none") == "指定なし"
          && optionText(in: rangeMenu, identifier: "programSearch.option.rangeHour.1") == "1時間"
          && optionText(in: rangeMenu, identifier: "programSearch.option.rangeHour.23") == "23時間"
        checks["programSearchRangeHourAnchorVisible"] = popupState(anchorID: "programSearch.rangeHour", menuID: "programSearch.options.rangeHour").map {
          $0.viewport.contains($0.anchor) && $0.viewport.contains($0.menu)
        } ?? false
        if let (_, hour2) = revealTableCell(rangeMenu, identifier: "programSearch.option.rangeHour.2") {
          rangeMenu.delegate?.tableView?(rangeMenu, didSelectRowAt: hour2)
        }
        checks["programSearchRangeHourSelect"] = (rangeHourButton.title(for: .normal) ?? "").contains("2時間")
      } else {
        checks["programSearchRangeHourLabels"] = false
        checks["programSearchRangeHourAnchorVisible"] = false
        checks["programSearchRangeHourSelect"] = false
      }
      clearForm.sendActions(for: .touchUpInside)
    } else {
      checks["programSearchDetailButtonsReady"] = false
    }

    func openPicker(accessoryID: String) async -> NeoProgramSearchPickerController? {
      guard let accessory = button(in: page.view, identifier: accessoryID) else { return nil }
      page.view.endEditing(true)
      revealControl(viewWithID("programSearch.period") ?? accessory)
      if accessoryID == "programSearch.startDate.picker" { capture("period-fields") }
      accessory.sendActions(for: .touchUpInside)
      return await waitForPicker()
    }

    if let startDateField = viewWithID("programSearch.startDate") as? UITextField,
      let datePicker = await openPicker(accessoryID: "programSearch.startDate.picker") {
      let card = identified(datePicker.view, "programSearch.picker.card")
      let dateGrid = identified(datePicker.view, "programSearch.picker.date")
      let cardRect = card?.convert(card?.bounds ?? .zero, to: datePicker.view) ?? .null
      let bounds = datePicker.view.safeAreaLayoutGuide.layoutFrame
      let expectedWidth = bounds.width >= 600 ? 400 : max(0, bounds.width - 24)
      checks["programSearchDatePickerCardContainedAndCentered"] = card != nil && finite(cardRect)
        && bounds.contains(cardRect)
        && abs(cardRect.width - expectedWidth) <= 1
        && abs(cardRect.midX - bounds.midX) <= 2 && abs(cardRect.midY - bounds.midY) <= 2
        && dateGrid != nil
      capture("picker-date")
      if let dateGrid,
        let day = views(in: dateGrid).compactMap({ $0 as? UIButton }).first(where: {
          $0.isEnabled && $0.accessibilityLabel?.hasSuffix("日") == true
        }),
        let select = button(in: datePicker.view, identifier: "programSearch.picker.select") {
        day.sendActions(for: .touchUpInside)
        select.sendActions(for: .touchUpInside)
        let selected = await waitFor { page.presentedViewController == nil }
        checks["programSearchDatePickerSelect"] = selected && !(startDateField.text ?? "").isEmpty
      } else {
        checks["programSearchDatePickerSelect"] = false
      }

      let beforeCancel = startDateField.text ?? ""
      if let picker = await openPicker(accessoryID: "programSearch.startDate.picker"),
        let cancel = button(in: picker.view, identifier: "programSearch.picker.cancel") {
        cancel.sendActions(for: .touchUpInside)
        let cancelled = await waitFor { page.presentedViewController == nil }
        checks["programSearchDatePickerCancel"] = cancelled && (startDateField.text ?? "") == beforeCancel
      } else {
        checks["programSearchDatePickerCancel"] = false
      }
      if let picker = await openPicker(accessoryID: "programSearch.startDate.picker"),
        let clear = button(in: picker.view, identifier: "programSearch.picker.clear") {
        clear.sendActions(for: .touchUpInside)
        let cleared = await waitFor { page.presentedViewController == nil }
        checks["programSearchDatePickerClear"] = cleared && (startDateField.text ?? "").isEmpty
      } else {
        checks["programSearchDatePickerClear"] = false
      }
    } else {
      checks["programSearchDatePickerCardContainedAndCentered"] = false
      checks["programSearchDatePickerSelect"] = false
      checks["programSearchDatePickerCancel"] = false
      checks["programSearchDatePickerClear"] = false
    }

    if let startTimeField = viewWithID("programSearch.startTime") as? UITextField,
      let timePickerController = await openPicker(accessoryID: "programSearch.startTime.picker"),
      let timePicker = identified(timePickerController.view, "programSearch.picker.time") as? UIPickerView {
      let card = identified(timePickerController.view, "programSearch.picker.card")
      let cardRect = card?.convert(card?.bounds ?? .zero, to: timePickerController.view) ?? .null
      let bounds = timePickerController.view.safeAreaLayoutGuide.layoutFrame
      let expectedWidth = bounds.width >= 600 ? 400 : max(0, bounds.width - 24)
      checks["programSearchTimePickerCardContainedAndCentered"] = card != nil && finite(cardRect)
        && bounds.contains(cardRect)
        && abs(cardRect.width - expectedWidth) <= 1
        && abs(cardRect.midX - bounds.midX) <= 2 && abs(cardRect.midY - bounds.midY) <= 2
        && timePicker.numberOfComponents == 2
        && timePicker.numberOfRows(inComponent: 0) == 24
        && timePicker.numberOfRows(inComponent: 1) == 60
      capture("picker-time")
      timePicker.selectRow(23, inComponent: 0, animated: false)
      timePicker.selectRow(45, inComponent: 1, animated: false)
      timePicker.delegate?.pickerView?(timePicker, didSelectRow: 23, inComponent: 0)
      timePicker.delegate?.pickerView?(timePicker, didSelectRow: 45, inComponent: 1)
      if let select = button(in: timePickerController.view, identifier: "programSearch.picker.select") {
        select.sendActions(for: .touchUpInside)
        let selected = await waitFor { page.presentedViewController == nil }
        checks["programSearchTimePickerSelect"] = selected && startTimeField.text == "23:45"
      } else {
        checks["programSearchTimePickerSelect"] = false
      }
      let beforeCancel = startTimeField.text ?? ""
      if let picker = await openPicker(accessoryID: "programSearch.startTime.picker"),
        let cancel = button(in: picker.view, identifier: "programSearch.picker.cancel") {
        cancel.sendActions(for: .touchUpInside)
        let cancelled = await waitFor { page.presentedViewController == nil }
        checks["programSearchTimePickerCancel"] = cancelled && startTimeField.text == beforeCancel
      } else {
        checks["programSearchTimePickerCancel"] = false
      }
      if let picker = await openPicker(accessoryID: "programSearch.startTime.picker"),
        let clear = button(in: picker.view, identifier: "programSearch.picker.clear") {
        clear.sendActions(for: .touchUpInside)
        let cleared = await waitFor { page.presentedViewController == nil }
        checks["programSearchTimePickerClear"] = cleared && (startTimeField.text ?? "").isEmpty
      } else {
        checks["programSearchTimePickerClear"] = false
      }
    } else {
      checks["programSearchTimePickerCardContainedAndCentered"] = false
      checks["programSearchTimePickerSelect"] = false
      checks["programSearchTimePickerCancel"] = false
      checks["programSearchTimePickerClear"] = false
    }

    button(in: page.view, identifier: "programSearch.clear")?.sendActions(for: .touchUpInside)
    page.view.endEditing(true)

    // Exercise label focus and blur after the candidate and date checks.
    if let keyword = viewWithID("programSearch.keyword") as? UITextField,
      let ignore = viewWithID("programSearch.ignoreKeyword") as? UITextField,
      let durationMin = viewWithID("programSearch.durationMin") as? UITextField,
      let durationMax = viewWithID("programSearch.durationMax") as? UITextField,
      let genre = viewWithID("programSearch.genre") as? UIButton,
      let startHour = viewWithID("programSearch.startHour") as? UIButton,
      let clearForm = button(in: page.view, identifier: "programSearch.clear") {
      clearForm.sendActions(for: .touchUpInside)
      page.view.endEditing(true)
      _ = await waitFor {
        keyword.text?.isEmpty == true && ignore.text?.isEmpty == true
          && durationMin.text?.isEmpty == true && durationMax.text?.isEmpty == true
      }
      page.view.layoutIfNeeded()

      let keywordOutline = outlinedLabel(near: keyword)
      let ignoreOutline = outlinedLabel(near: ignore)
      let durationMinOutline = outlinedLabel(near: durationMin)
      let durationMaxOutline = outlinedLabel(near: durationMax)
      let genreOutline = outlinedLabel(near: genre)
      let startOutline = outlinedLabel(near: startHour)
      checks["programSearchOutlinedBlankStates"] = keywordOutline?.smokeCaption.text == "キーワード"
        && ignoreOutline?.smokeCaption.text == "除外キーワード"
        && durationMinOutline?.smokeCaption.text == "最小（分）"
        && durationMaxOutline?.smokeCaption.text == "最大（分）"
        && keywordOutline?.smokeFloated == false && ignoreOutline?.smokeFloated == false
        && durationMinOutline?.smokeFloated == false && durationMaxOutline?.smokeFloated == false
      checks["programSearchGenreForcedFloat"] = genreOutline?.smokeCaption.text == "大ジャンル"
        && genreOutline?.smokeFloated == true
      checks["programSearchStartHourBlankLabel"] = (startHour.title(for: .normal) ?? "").isEmpty
        && startOutline?.smokeCaption.text == "開始時刻"
        && startOutline?.smokeFloated == false

      if startHour.isHidden || startHour.bounds.isEmpty {
        button(in: page.view, label: "詳細条件")?.sendActions(for: .touchUpInside)
        _ = await waitFor { !startHour.isHidden && !startHour.bounds.isEmpty }
      }
      revealControl(startHour)
      startHour.sendActions(for: .touchUpInside)
      if let startMenu = await waitForMenu("programSearch.options.startHour", minimumRows: 25) {
        page.view.layoutIfNeeded()
        checks["programSearchStartHourFloatsWhileOpen"] = startOutline?.smokeFloated == true
        if let (_, hour23) = tableCell(startMenu, identifier: "programSearch.option.startHour.23")
          ?? revealTableCell(startMenu, identifier: "programSearch.option.startHour.23") {
          startMenu.delegate?.tableView?(startMenu, didSelectRowAt: hour23)
        }
        checks["programSearchStartHourFloatsAfterSelection"] = await waitFor {
          (startHour.title(for: .normal) ?? "") == "23時" && startOutline?.smokeFloated == true
        }
      } else {
        checks["programSearchStartHourFloatsWhileOpen"] = false
        checks["programSearchStartHourFloatsAfterSelection"] = false
      }

      // A blank text field must animate both directions.  The selected hour
      // is kept as a sentinel so a focus/blur relayout cannot silently reset
      // another control's value.  Reduce Motion (or globally disabled
      // animations in a test host) still exercises the final states.
      if let keywordOutline,
        let startOutline,
        let keywordField = viewWithID("programSearch.keyword") as? UITextField {
        keywordField.text = ""
        keywordField.sendActions(for: .editingChanged)
        keywordField.resignFirstResponder()
        keywordField.superview?.layoutIfNeeded()
        let fieldBefore = keywordField.frame
        let outlineBefore = keywordOutline.frame
        let selectedHour = startHour.title(for: .normal) ?? ""
        let animationExpected = UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled

        _ = keywordField.becomeFirstResponder()
        page.view.layoutIfNeeded()
        let focusDuration = keywordOutline.smokeMotionDuration
        let openingNotch = keywordOutline.smokeNotchAnimation
        let focused = await waitFor { keywordOutline.smokeFloated && keywordField.isFirstResponder }
        let fieldDuring = keywordField.frame

        _ = keywordField.resignFirstResponder()
        page.view.layoutIfNeeded()
        let blurDuration = keywordOutline.smokeMotionDuration
        let closingNotch = keywordOutline.smokeNotchAnimation
        let blurred = await waitFor { !keywordOutline.smokeFloated && !keywordField.isFirstResponder }
        let fieldAfter = keywordField.frame
        let animationDurationOK: Bool = {
          guard animationExpected, let focusDuration, let blurDuration else { return !animationExpected }
          return abs(focusDuration - 0.2) <= 0.03 && abs(blurDuration - 0.2) <= 0.03
        }()
        checks["programSearchOutlinedLabelFocusBlur"] = focused && blurred
          && keywordField.text?.isEmpty == true
          && (startHour.title(for: .normal) ?? "") == selectedHour
        checks["programSearchOutlinedLabelMotionDuration"] = animationDurationOK
        checks["programSearchOutlinedNotchTiming"] = {
          guard animationExpected, let openingNotch, let closingNotch else {
            return !animationExpected && openingNotch == nil && closingNotch == nil
          }
          return openingNotch.duration == 0.05 && closingNotch.duration == 0.05
            && openingNotch.fillMode != .backwards && closingNotch.fillMode == .backwards
            && closingNotch.beginTime > 0
        }()
        checks["programSearchOutlinedLabelNoLayoutShift"] = closeEnough(fieldBefore, fieldDuring)
          && closeEnough(fieldBefore, fieldAfter) && closeEnough(outlineBefore, keywordOutline.frame)
      } else {
        checks["programSearchOutlinedLabelFocusBlur"] = false
        checks["programSearchOutlinedLabelMotionDuration"] = false
        checks["programSearchOutlinedNotchTiming"] = false
        checks["programSearchOutlinedLabelNoLayoutShift"] = false
      }

      clearForm.sendActions(for: .touchUpInside)
      page.view.endEditing(true)
      _ = await waitFor {
        (keyword.text ?? "").isEmpty && (ignore.text ?? "").isEmpty
          && (durationMin.text ?? "").isEmpty && (durationMax.text ?? "").isEmpty
          && (startHour.title(for: .normal) ?? "").isEmpty
      }
    } else {
      checks["programSearchOutlinedBlankStates"] = false
      checks["programSearchGenreForcedFloat"] = false
      checks["programSearchStartHourBlankLabel"] = false
      checks["programSearchStartHourFloatsWhileOpen"] = false
      checks["programSearchStartHourFloatsAfterSelection"] = false
      checks["programSearchOutlinedLabelFocusBlur"] = false
      checks["programSearchOutlinedLabelMotionDuration"] = false
      checks["programSearchOutlinedNotchTiming"] = false
      checks["programSearchOutlinedLabelNoLayoutShift"] = false
    }

    guard let keyword = identified(page.view, "programSearch.keyword") as? UITextField,
      let search = button(in: page.view, identifier: "programSearch.search") else {
      checks["programSearchFormControlsReady"] = false
      return checks
    }
    checks["programSearchFormControlsReady"] = true

    checks["programSearchKeywordClearOnlyOwnsField"] = false
    checks["programSearchIgnoreKeywordClearOnlyOwnsField"] = false
    if let ignoreKeyword = identified(page.view, "programSearch.ignoreKeyword") as? UITextField {
      page.view.endEditing(true)
      keyword.text = "clear-me"
      keyword.sendActions(for: .editingChanged)
      ignoreKeyword.text = "exclude-me"
      ignoreKeyword.sendActions(for: .editingChanged)
      let clearsVisible = await waitFor {
        page.view.layoutIfNeeded()
        return keyword.rightViewMode == .always && ignoreKeyword.rightViewMode == .always
          && button(in: keyword, identifier: "programSearch.keyword.clear")?.isEnabled == true
          && button(in: ignoreKeyword, identifier: "programSearch.ignoreKeyword.clear")?.isEnabled == true
      }
      if clearsVisible,
        let keywordClear = button(in: keyword, identifier: "programSearch.keyword.clear"),
        let ignoreClear = button(in: ignoreKeyword, identifier: "programSearch.ignoreKeyword.clear") {
        revealControl(keyword)
        keywordClear.sendActions(for: .touchUpInside)
        checks["programSearchKeywordClearOnlyOwnsField"] = keyword.text?.isEmpty == true
          && ignoreKeyword.text == "exclude-me" && keyword.rightViewMode == .never && ignoreKeyword.rightViewMode == .always
        revealControl(ignoreKeyword)
        ignoreClear.sendActions(for: .touchUpInside)
        checks["programSearchIgnoreKeywordClearOnlyOwnsField"] = keyword.text?.isEmpty == true
          && ignoreKeyword.text?.isEmpty == true && ignoreKeyword.rightViewMode == .never
      }
    }

    // Exercise a new-rule POST before the normal search.  The first response
    // fails while retaining the same editor and draft; retrying succeeds and
    // resets the root form without issuing a schedule search.
    if let createRule = button(in: page.view, identifier: "programSearch.rule") {
      keyword.text = "CreateDraft"
      keyword.sendActions(for: .editingChanged)
      revealControl(createRule)
      createRule.sendActions(for: .touchUpInside)
      let createEditorReady = await waitFor {
        guard let editor = page.presentedViewController as? NeoProgramRuleEditor else { return false }
        editor.view.layoutIfNeeded()
        return editor.view.window != nil && identified(editor.view, "ruleEditor.card") != nil
      }
      checks["programSearchRuleCreateOpensEditor"] = createEditorReady
      if createEditorReady, let editor = page.presentedViewController as? NeoProgramRuleEditor {
        capture("rule-editor-recording")
        if let directory = identified(editor.view, "ruleEditor.recording.directory") as? UITextField,
          let directoryOutline = outlinedLabel(near: directory) {
          checks["ruleEditorRecordingDirectoryLabel"] = directory.text?.isEmpty == true
            && directoryOutline.smokeCaption.text == "サブディレクトリ"
            && !directoryOutline.smokeFloated
        } else {
          checks["ruleEditorRecordingDirectoryLabel"] = false
        }
        let encodeTab = button(in: editor.view, identifier: "ruleEditor.tab.encode")
        encodeTab?.sendActions(for: .touchUpInside)
        _ = await waitFor { identified(editor.view, "ruleEditor.encode.1") != nil }
        if let mode = identified(editor.view, "ruleEditor.encode.1.mode"),
          let modeOutline = outlinedLabel(near: mode) {
          checks["ruleEditorEncodePresetLabel"] = modeOutline.smokeCaption.text == "エンコードプリセット"
            && !modeOutline.smokeFloated
        } else {
          checks["ruleEditorEncodePresetLabel"] = false
        }
        capture("rule-editor-encode")
        button(in: editor.view, identifier: "ruleEditor.encode.add")?.sendActions(for: .touchUpInside)
        let secondEncodeAdded = await waitFor { identified(editor.view, "ruleEditor.encode.2") != nil }
        if secondEncodeAdded {
          button(in: editor.view, identifier: "ruleEditor.encode.2.remove")?.sendActions(for: .touchUpInside)
        }
        let secondEncodeRemoved: Bool
        if secondEncodeAdded {
          secondEncodeRemoved = await waitFor { identified(editor.view, "ruleEditor.encode.2") == nil }
        } else {
          secondEncodeRemoved = false
        }
        checks["programSearchRuleEncodeAddRemove"] = secondEncodeAdded && secondEncodeRemoved
        button(in: editor.view, identifier: "ruleEditor.tab.recording")?.sendActions(for: .touchUpInside)

        let save = button(in: editor.view, identifier: "ruleEditor.save")
        save?.sendActions(for: .touchUpInside)
        let createFailed = await waitFor {
          guard let current = page.presentedViewController as? NeoProgramRuleEditor else { return false }
          current.view.layoutIfNeeded()
          let error = identified(current.view, "ruleEditor.error") as? UILabel
          return current.view.window != nil && error?.isHidden == false && !(error?.text ?? "").isEmpty
        }
        checks["programSearchRuleCreateFailureRetainsEditorDraft"] = createFailed
          && (page.presentedViewController as? NeoProgramRuleEditor) === editor
          && (identified(page.view, "programSearch.keyword") as? UITextField)?.text == "CreateDraft"
        let createBodies = NeoProgramSearchSmokeProtocol.requestBodies("POST /api/rules")
        let firstCreate = createBodies.first
        let firstOption = firstCreate?["searchOption"] as? [String: Any]
        checks["programSearchRuleCreateSendsExpectedBody"] = createBodies.count == 1
          && intValue(firstCreate?["userId"]) == 7
          && firstCreate?["isTimeSpecification"] as? Bool == false
          && firstOption?["keyword"] as? String == "CreateDraft"
        button(in: editor.view, identifier: "ruleEditor.save")?.sendActions(for: .touchUpInside)
        let rootReset = await waitFor {
          page.presentedViewController == nil
            && (identified(page.view, "programSearch.keyword") as? UITextField)?.text?.isEmpty == true
            && (identified(page.view, "programSearch.list") as? UITableView)?.numberOfRows(inSection: 0) == 0
        }
        checks["programSearchRuleCreateRetryResetsRoot"] = rootReset
          && NeoProgramSearchSmokeProtocol.count("POST /api/rules") == 2
      } else {
        checks["programSearchRuleCreateFailureRetainsEditorDraft"] = false
        checks["programSearchRuleEncodeAddRemove"] = false
        checks["programSearchRuleCreateSendsExpectedBody"] = false
        checks["programSearchRuleCreateRetryResetsRoot"] = false
        checks["ruleEditorRecordingDirectoryLabel"] = false
        checks["ruleEditorEncodePresetLabel"] = false
      }
    } else {
      checks["programSearchRuleCreateOpensEditor"] = false
      checks["programSearchRuleEncodeAddRemove"] = false
      checks["programSearchRuleCreateFailureRetainsEditorDraft"] = false
      checks["programSearchRuleCreateSendsExpectedBody"] = false
      checks["programSearchRuleCreateRetryResetsRoot"] = false
      checks["ruleEditorRecordingDirectoryLabel"] = false
      checks["ruleEditorEncodePresetLabel"] = false
    }

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
    checks["programSearchStatusChipFitsIntrinsicWidth"] = await waitFor({
      list.layoutIfNeeded()
      list.cellForRow(at: IndexPath(row: 0, section: 0))?.layoutIfNeeded()
      return statusChipFitsIntrinsicWidth(in: list)
    }, attempts: 60)
    capture("results")
    page.tableView(list, didSelectRowAt: IndexPath(row: 0, section: 0))

    let detailReady = await waitFor {
      guard let detail = page.presentedViewController as? NeoProgramDetailDialog else { return false }
      return detail.viewIfLoaded?.window != nil && !detail.isBeingPresented
    }
    checks["programDetailOpensFromResult"] = detailReady
    guard let detail = page.presentedViewController as? NeoProgramDetailDialog, detailReady else {
      checks["programDetailConflictHasDetailsWithoutBookingActions"] = false
      return checks
    }
    detail.view.layoutIfNeeded()

    let detailButtons = views(in: detail.view).compactMap { $0 as? UIButton }
    let buttonTitles = Set(detailButtons.filter { !$0.isHidden }.compactMap { $0.title(for: .normal) })
    let forbidden = Set(["予約", "削除", "編集", "解除", "除外"])
    checks["programDetailConflictHasDetailsWithoutBookingActions"] = Set(["検索", "閉じる", "詳細"]).isSubset(of: buttonTitles)
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

    let timeLabel = identified(detail.view, "program-detail-time") as? UILabel
    let durationLabel = identified(detail.view, "program-detail-duration") as? UILabel
    let card = identified(detail.view, "program-detail-card")
    checks["programDetailShowsTimeBeforeExpansion"] = timeLabel?.text?.contains("19:00") == true
      && timeLabel?.text?.contains("19:30") == true && durationLabel?.text == "(30分)"
      && (timeLabel?.bounds.width ?? 0) >= (timeLabel?.intrinsicContentSize.width ?? 1) - 1
      && (durationLabel?.bounds.width ?? 0) >= (durationLabel?.intrinsicContentSize.width ?? 1) - 1
    let initialTimeFrame = timeLabel.map { $0.convert($0.bounds, to: detail.view) }
    let initialCardFrame = card?.frame
    capture("detail-collapsed")

    let expand = detailButtons.first { $0.accessibilityIdentifier == "program-detail-broadcast-toggle" }
    let initiallyCollapsed = expand?.accessibilityValue == "非表示"
    expand?.sendActions(for: .touchUpInside)
    let expanded = await waitFor {
      detail.view.layoutIfNeeded()
      return detailButtons.first { $0.accessibilityLabel?.contains("情報を閉じる") == true }?.accessibilityValue == "表示中"
    }
    checks["programDetailBroadcastDetailsExpand"] = initiallyCollapsed && expanded
    checks["programDetailExpansionKeepsCardAndTimeInPlace"] = expanded && initialCardFrame != nil && initialCardFrame == card?.frame
      && initialTimeFrame != nil && initialTimeFrame == timeLabel.map { $0.convert($0.bounds, to: detail.view) }
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

    if let relatedPage = navigation.topViewController as? NeoProgramSearchPage,
       let relatedList = identified(relatedPage.view, "programSearch.list") as? UITableView,
       await waitFor({ relatedList.numberOfRows(inSection: 0) == 1 && navigation.transitionCoordinator == nil }) {
      relatedList.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
      relatedPage.tableView(relatedList, didSelectRowAt: IndexPath(row: 0, section: 0))
      let arrived = await waitFor {
        guard let dialog = relatedPage.presentedViewController as? NeoProgramDetailDialog else { return false }
        return dialog.viewIfLoaded?.window != nil && !dialog.isBeingPresented
      }
      if arrived, let dialog = relatedPage.presentedViewController as? NeoProgramDetailDialog {
        dialog.view.layoutIfNeeded()
        let mode = button(in: dialog.view, identifier: "program-detail-booking-mode")
        let user = button(in: dialog.view, identifier: "program-detail-booking-viewer")
        let checkboxes = ["program-detail-booking-delete", "program-detail-booking-thumbnail"].compactMap { button(in: dialog.view, identifier: $0) }
        let footer = ["program-detail-search", "program-detail-footer-close", "program-detail-details", "program-detail-reserve"].compactMap {
          button(in: dialog.view, identifier: $0)
        }
        checks["programDetailUnreservedBookingLayout"] = mode?.title(for: .normal) == "TS" && user?.title(for: .normal)?.isEmpty == false
          && mode?.isUserInteractionEnabled == true && user?.isUserInteractionEnabled == true
          && checkboxes.count == 2 && checkboxes.allSatisfy { !$0.isEnabled && !$0.frame.isEmpty }
          && footer.count == 4 && footer.allSatisfy(\.isEnabled)
          && footer.allSatisfy { !$0.isHidden && !$0.frame.isEmpty }
          && zip(footer, footer.dropFirst()).allSatisfy { $0.0.frame.maxX <= $0.1.frame.minX }
        capture("detail-unreserved")
        button(in: dialog.view, identifier: "program-detail-footer-close")?.sendActions(for: .touchUpInside)
        checks["programDetailUnreservedCloses"] = await waitFor { relatedPage.presentedViewController == nil }
      } else {
        checks["programDetailUnreservedBookingLayout"] = false
      }
    } else {
      checks["programDetailUnreservedBookingLayout"] = false
    }
    _ = await waitFor { navigation.transitionCoordinator == nil }
    shell.goBack()
    let returned = await waitFor {
      navigation.topViewController === page
        && navigation.transitionCoordinator == nil
        && NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") >= 3
        && (identified(page.view, "programSearch.keyword") as? UITextField)?.text == "Fixture"
    }
    checks["relatedSearchBackRetainsOriginalForm"] = returned
    checks["relatedSearchBackRetainsOriginalResults"] = returned
      && (identified(page.view, "programSearch.count") as? UILabel)?.text == "1件ヒット"
    let clear = button(in: page.view, identifier: "programSearch.clear")
    let writesBeforeClear = NeoProgramSearchSmokeProtocol.mutationWriteCount()
    clear?.sendActions(for: .touchUpInside)
    let cleared = await waitFor {
      (identified(page.view, "programSearch.keyword") as? UITextField)?.text?.isEmpty == true
        && (identified(page.view, "programSearch.list") as? UITableView)?.numberOfRows(inSection: 0) == 0
    }
    checks["clearResetsResultWithoutMutation"] = cleared
      && NeoProgramSearchSmokeProtocol.mutationWriteCount() == writesBeforeClear

    let recordingJSON = #"{"id":300,"name":"Edited recording","startAt":1791021600000,"endAt":1791023400000,"isRecording":false,"channelId":1,"channelName":"Fixture Station","ruleId":41}"#
    if let recording = try? JSONDecoder().decode(NeoRecording.self, from: Data(recordingJSON.utf8)) {
      let searchCountBeforeEdit = NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search")
      page.openProgramRule(for: recording)
      let editPageReady = await waitFor {
        guard let editPage = navigation.topViewController as? NeoProgramSearchPage else { return false }
        return editPage !== page && editPage.viewIfLoaded?.window != nil && navigation.transitionCoordinator == nil
          && NeoProgramSearchSmokeProtocol.count("GET /api/rules/41") > 0
      }
      checks["recordingRuleActionOpensEditPage"] = editPageReady
      if let editPage = navigation.topViewController as? NeoProgramSearchPage, editPage !== page, editPageReady {
        let restored = await waitFor {
          editPage.view.layoutIfNeeded()
          return (identified(editPage.view, "programSearch.keyword") as? UITextField)?.text == "Edited Rule"
            && identified(editPage.view, "programSearch.channelChip.1") != nil
            && (identified(editPage.view, "programSearch.durationMin") as? UITextField)?.text == "30"
        }
        let autoSearch = await waitFor {
          NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") >= searchCountBeforeEdit + 1
        }
        checks["recordingRuleEditRestoresFieldsAndAutoSearches"] = restored && autoSearch
          && editPage.titleLabel.text == "ルール編集"
        if let ruleButton = button(in: editPage.view, identifier: "programSearch.rule") {
          revealControl(ruleButton, in: editPage)
          ruleButton.sendActions(for: .touchUpInside)
          let editorReady = await waitFor {
            guard let editor = editPage.presentedViewController as? NeoProgramRuleEditor else { return false }
            editor.view.layoutIfNeeded()
            return editor.view.window != nil && identified(editor.view, "ruleEditor.card") != nil
          }
          checks["recordingRuleEditOpensSettingsEntry"] = editorReady
          if editorReady, let editor = editPage.presentedViewController as? NeoProgramRuleEditor {
            let save = button(in: editor.view, identifier: "ruleEditor.save")
            checks["recordingRuleEditShowsEditTitle"] = (identified(editor.view, "ruleEditor.title") as? UILabel)?.attributedText?.string == "ルール編集"
              && save?.configuration?.title == "更新"
            capture("rule-editor-edit-recording")
            button(in: editor.view, identifier: "ruleEditor.tab.encode")?.sendActions(for: .touchUpInside)
            _ = await waitFor { identified(editor.view, "ruleEditor.encode.1") != nil }
            capture("rule-editor-edit-encode")
            button(in: editor.view, identifier: "ruleEditor.tab.recording")?.sendActions(for: .touchUpInside)
            save?.sendActions(for: .touchUpInside)
            let returnedToOrigin = await waitFor {
              navigation.topViewController === page
                && editPage.presentedViewController == nil
                && NeoProgramSearchSmokeProtocol.count("PUT /api/rules/41") == 1
            }
            let updateBody = NeoProgramSearchSmokeProtocol.requestBodies("PUT /api/rules/41").first
            let updateOption = updateBody?["searchOption"] as? [String: Any]
            checks["recordingRuleEditPutsOnceAndReturns"] = returnedToOrigin
              && intValue(updateBody?["userId"]) == 7
              && updateBody?["isTimeSpecification"] as? Bool == false
              && updateOption?["keyword"] as? String == "Edited Rule"
          } else {
            checks["recordingRuleEditShowsEditTitle"] = false
            checks["recordingRuleEditPutsOnceAndReturns"] = false
          }
        } else {
          checks["recordingRuleEditOpensSettingsEntry"] = false
          checks["recordingRuleEditShowsEditTitle"] = false
          checks["recordingRuleEditPutsOnceAndReturns"] = false
        }
      } else {
        checks["recordingRuleEditRestoresFieldsAndAutoSearches"] = false
        checks["recordingRuleEditOpensSettingsEntry"] = false
        checks["recordingRuleEditShowsEditTitle"] = false
        checks["recordingRuleEditPutsOnceAndReturns"] = false
      }
    } else {
      checks["recordingRuleActionOpensEditPage"] = false
      checks["recordingRuleEditRestoresFieldsAndAutoSearches"] = false
      checks["recordingRuleEditOpensSettingsEntry"] = false
      checks["recordingRuleEditShowsEditTitle"] = false
      checks["recordingRuleEditPutsOnceAndReturns"] = false
    }

    _ = await waitFor { navigation.transitionCoordinator == nil }
    let scheduleCountBeforeTimeRule = NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search")
    shell.pushPage { NeoProgramSearchPage(shell: shell, ruleID: 42) }
    let timePageReady = await waitFor {
      guard let timePage = navigation.topViewController as? NeoProgramSearchPage else { return false }
      return timePage !== page && timePage.viewIfLoaded?.window != nil && navigation.transitionCoordinator == nil
        && NeoProgramSearchSmokeProtocol.count("GET /api/rules/42") > 0
        && NeoProgramSearchSmokeProtocol.count("GET /api/reserves") > 0
    }
    if let timePage = navigation.topViewController as? NeoProgramSearchPage, timePage !== page, timePageReady {
      let timeSummaryReady = await waitFor {
        identified(timePage.view, "programSearch.timeRule.summary") != nil
          && button(in: timePage.view, identifier: "programSearch.timeRule.settings")?.configuration?.title == "ルール設定"
          && (identified(timePage.view, "programSearch.count") as? UILabel)?.text == "予約数 1件"
          && (identified(timePage.view, "programSearch.list") as? UITableView)?.numberOfRows(inSection: 0) == 1
      }
      let reserveURL = NeoProgramSearchSmokeProtocol.lastURL("GET /api/reserves")
      checks["programSearchTimeRuleRequestAndNoScheduleSearch"] = timeSummaryReady
        && queryValue(reserveURL, "type") == "all"
        && queryValue(reserveURL, "ruleId") == "42"
        && queryValue(reserveURL, "isHalfWidth") == "false"
        && NeoProgramSearchSmokeProtocol.count("POST /api/schedules/search") == scheduleCountBeforeTimeRule
      capture("time-rule")
    } else {
      checks["programSearchTimeRuleRequestAndNoScheduleSearch"] = false
    }
    if navigation.topViewController !== page { shell.goBack() }
    _ = await waitFor { navigation.topViewController === page && navigation.transitionCoordinator == nil }
    checks.merge(await reservationFlow(shell: shell, api: api, navigation: navigation)) { _, new in new }
    return checks
  }

  private static func reservationFlow(shell: NeoShell, api: NeoAPI, navigation: UINavigationController) async -> [String: Bool] {
    var checks = [String: Bool]()
    func find(_ root: UIView, _ id: String) -> UIView? {
      if root.accessibilityIdentifier == id { return root }
      return root.subviews.lazy.compactMap { find($0, id) }.first
    }
    func wait(_ ready: () -> Bool) async -> Bool {
      for _ in 0..<200 {
        if ready() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return ready()
    }
    func tap(_ root: UIView, _ id: String) { (find(root, id) as? UIButton)?.sendActions(for: .touchUpInside) }
    func capture(_ name: String) {
      guard let window = shell.view.window else { return }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try? image.pngData()?.write(to: NeoPiPSmoke.directory.appendingPathComponent("program-search-\(name).png"))
    }
    func labels(in root: UIView) -> [UILabel] {
      let own = root as? UILabel
      return (own.map { [$0] } ?? []) + root.subviews.flatMap { labels(in: $0) }
    }
    func firstSwitch(in root: UIView) -> UISwitch? {
      if let control = root as? UISwitch { return control }
      return root.subviews.lazy.compactMap { firstSwitch(in: $0) }.first
    }
    func manualReservationLayoutFitsViewport(_ editor: NeoManualReservationPage, requireTimeFields: Bool = false) -> Bool {
      editor.view.layoutIfNeeded()
      guard let scroll = find(editor.view, "manualReserve.form") as? UIScrollView,
        let stack = find(editor.view, "manualReserve.formStack"),
        let summary = find(editor.view, "manualReserve.summary") else { return false }
      scroll.layoutIfNeeded()
      let frame = stack.convert(stack.bounds, to: scroll)
      let tolerance: CGFloat = 1
      let insideViewport = frame.width > 0 && frame.minX >= -tolerance && frame.maxX <= scroll.bounds.width + tolerance
      let hasWrappedProgramInfo = labels(in: summary).contains { label in
        label.numberOfLines == 0 && label.bounds.width > 0 && label.bounds.height > label.font.lineHeight * 1.25
      }
      let timeFieldsVisible = (find(editor.view, "manualReserve.timeFields") as? UIStackView)?.isHidden == false
      return insideViewport && hasWrappedProgramInfo && (!requireTimeFields || timeFieldsVisible)
    }

    NeoProgramSearchSmokeProtocol.enableReservationFlow()
    let originalSettings = api.quickReservationSettings
    api.quickReservationSettings = .init()
    defer { api.quickReservationSettings = originalSettings; shell.showRoute("search") }
    let seed = NeoScheduledProgram(id: 9002, channelId: 1, startAt: 1_791_025_200_000,
      endAt: 1_791_027_000_000, isFree: true, name: "Fixture reservation")
    let form = NeoProgramSearchForm.related(to: seed, includeChannel: true, includeGenre: false)
    let search = NeoProgramSearchPage(shell: shell, relatedForm: form)
    shell.pushPage { search }
    guard await wait({
      navigation.topViewController === search && navigation.transitionCoordinator == nil
        && (find(search.view, "programSearch.list") as? UITableView)?.numberOfRows(inSection: 0) == 1
    }), let results = find(search.view, "programSearch.list") as? UITableView else {
      return ["reservationSearchResultsReady": false]
    }

    let row = IndexPath(row: 0, section: 0)
    results.scrollToRow(at: row, at: .top, animated: false)
    search.tableView(results, didSelectRowAt: row)
    guard await wait({
      guard let dialog = search.presentedViewController as? NeoProgramDetailDialog else { return false }
      return !dialog.isBeingPresented && dialog.viewIfLoaded?.window != nil
    }), let quick = search.presentedViewController as? NeoProgramDetailDialog,
      let mode = find(quick.view, "program-detail-booking-mode") as? NeoDropdownButton,
      let preset = mode.dropdownRows.first(where: { $0.title == "Fixture AVC" }) else {
      return ["quickReservationShowsServerPresets": false]
    }
    preset.action?()
    tap(quick.view, "program-detail-booking-delete")
    tap(quick.view, "program-detail-booking-thumbnail")
    capture("quick-reservation")
    let reads = NeoProgramSearchSmokeProtocol.count("GET /api/reserves/lists")
    tap(quick.view, "program-detail-reserve")
    let booked = await wait {
      search.presentedViewController == nil && NeoProgramSearchSmokeProtocol.count("POST /api/reserves") == 1
        && NeoProgramSearchSmokeProtocol.count("GET /api/reserves/lists") > reads && search.smokeReservationKind(9002) == .normal
    }
    let booking = NeoProgramSearchSmokeProtocol.requestBodies("POST /api/reserves").first
    let encode = booking?["encodeOption"] as? [String: Any]
    checks["quickReservationSendsPresetAndRefreshesSearch"] = booked && booking?["programId"] as? Int == 9002
      && booking?["userId"] as? Int == 7 && encode?["mode1"] as? String == "Fixture AVC"
      && encode?["isDeleteOriginalAfterEncode"] as? Bool == true && encode?["updateThumbnail"] as? Bool == true
      && api.quickReservationSettings.mode == "Fixture AVC"

    shell.showRoute("reserves")
    guard await wait({
      shell.children.compactMap { $0 as? UINavigationController }.contains { nav in
        guard let page = nav.topViewController as? NeoReservationsPage else { return false }
        return (find(page.view, "reserves.list") as? UITableView)?.numberOfRows(inSection: 0) == 1
      }
    }), let reservesNav = shell.children.compactMap({ $0 as? UINavigationController }).first(where: { $0.topViewController is NeoReservationsPage }),
      let reserves = reservesNav.topViewController as? NeoReservationsPage, let table = find(reserves.view, "reserves.list") as? UITableView else {
      checks["reservationTabShowsCreatedReservation"] = false
      return checks
    }
    checks["reservationTabShowsCreatedReservation"] = true
    checks["reservationTabShowsSelectedTitleAndCount"] = await wait {
      guard let tab = find(reserves.view, "reserves.tab.normal") as? UIButton else { return false }
      tab.layoutIfNeeded()
      return tab.titleLabel?.text == "予約 1" && tab.accessibilityTraits.contains(.selected)
        && (tab.titleLabel?.bounds.width ?? 0) > 0
    }
    capture("reservation-list")
    reserves.tableView(table, didSelectRowAt: row)
    let detailReady = await wait { reserves.presentedViewController is NeoProgramDetailDialog && reserves.presentedViewController?.isBeingPresented == false }
    if detailReady, let detail = reserves.presentedViewController { tap(detail.view, "program-detail-details") }
    let editReady = await wait {
      guard let editor = reservesNav.topViewController as? NeoManualReservationPage else { return false }
      return reservesNav.transitionCoordinator == nil && (find(editor.view, "manualReserve.save") as? UIButton)?.isEnabled == true
    }
    var editLayout = false
    if editReady, let editor = reservesNav.topViewController as? NeoManualReservationPage {
      editLayout = manualReservationLayoutFitsViewport(editor)
      capture("manual-reservation-edit")
      tap(editor.view, "manualReserve.save")
    }
    checks["manualReservationEditFitsViewport"] = editReady && editLayout
    let edited = await wait {
      reservesNav.topViewController === reserves && reservesNav.transitionCoordinator == nil
        && NeoProgramSearchSmokeProtocol.count("PUT /api/reserves/6101") == 1
    }
    checks["reservationListOpensAndUpdatesManualReservation"] = editReady && edited
    if reservesNav.topViewController !== reserves {
      shell.goBack()
      _ = await wait { reservesNav.topViewController === reserves && reservesNav.transitionCoordinator == nil }
    }
    tap(reserves.view, "reserves.edit"); tap(reserves.view, "reserves.selectAll"); tap(reserves.view, "reserves.bulkAction")
    let confirmed = await wait { reserves.presentedViewController?.isBeingPresented == false && reserves.presentedViewController != nil }
    if confirmed, let prompt = reserves.presentedViewController { tap(prompt.view, "reserves.confirm") }
    let cancelled = await wait {
      NeoProgramSearchSmokeProtocol.count("DELETE /api/reserves/6101") == 1 && table.numberOfRows(inSection: 0) == 0
        && reserves.presentedViewController == nil
    }
    checks["reservationBulkCancelUpdatesList"] = confirmed && cancelled

    shell.showRoute("search")
    let returned = await wait { navigation.topViewController === search && navigation.transitionCoordinator == nil }
    if returned {
      NotificationCenter.default.post(name: .neoReservationsChanged, object: api)
      _ = await wait { search.smokeReservationKind(9002) == nil }
    }
    if returned, results.numberOfRows(inSection: 0) == 1 { search.tableView(results, didSelectRowAt: row) }
    let newReady = await wait { search.presentedViewController is NeoProgramDetailDialog && search.presentedViewController?.isBeingPresented == false }
    if newReady, let dialog = search.presentedViewController { tap(dialog.view, "program-detail-details") }
    let newEditor = await wait {
      guard let editor = navigation.topViewController as? NeoManualReservationPage else { return false }
      return navigation.transitionCoordinator == nil && (find(editor.view, "manualReserve.save") as? UIButton)?.isEnabled == true
    }
    var newLayout = false, newTimeLayout = false
    if newEditor, let editor = navigation.topViewController as? NeoManualReservationPage {
      newLayout = manualReservationLayoutFitsViewport(editor)
      if let timeRow = find(editor.view, "manualReserve.timeSpecified"), let timeSwitch = firstSwitch(in: timeRow) {
        timeSwitch.isOn = true
        timeSwitch.sendActions(for: .valueChanged)
        newTimeLayout = manualReservationLayoutFitsViewport(editor, requireTimeFields: true)
        capture("manual-reservation-new")
        timeSwitch.isOn = false
        timeSwitch.sendActions(for: .valueChanged)
      }
      tap(editor.view, "manualReserve.save")
    }
    checks["manualReservationNewFitsViewport"] = newEditor && newLayout
    checks["manualReservationNewTimeFieldsFitViewport"] = newEditor && newTimeLayout
    let added = await wait {
      navigation.topViewController === search && NeoProgramSearchSmokeProtocol.count("POST /api/reserves") == 2
    }
    let detailed = NeoProgramSearchSmokeProtocol.requestBodies("POST /api/reserves").last
    checks["searchOpensDetailedReservationAndAdds"] = newEditor && added && detailed?["programId"] as? Int == 9002
      && detailed?["encodeOption"] == nil

    NeoProgramSearchSmokeProtocol.setWarningCounts(conflicts: 2, overlaps: 3)
    shell.showRoute("reserves")
    let menu = shell.smokeReservationMenu(true)
    func menuRow(_ id: String) -> UITableViewCell? {
      menu.layoutIfNeeded()
      return menu.visibleCells.first { $0.accessibilityIdentifier == "menu-" + id }
    }
    let warningRows = await wait {
      menuRow("reserves-conflict")?.accessibilityValue == "2件" && menuRow("reserves-overlap")?.accessibilityValue == "3件"
    }
    let regularIndex = menuRow("reserves").flatMap { menu.indexPath(for: $0)?.row }
    let conflictIndex = menuRow("reserves-conflict").flatMap { menu.indexPath(for: $0)?.row }
    let overlapPath = menuRow("reserves-overlap").flatMap { menu.indexPath(for: $0) }
    checks["reservationSidebarShowsWarningCountsInOrder"] = warningRows
      && regularIndex.map { $0 + 1 } == conflictIndex && conflictIndex.map { $0 + 1 } == overlapPath?.row
    if let overlapPath { menu.delegate?.tableView?(menu, didSelectRowAt: overlapPath) }
    checks["reservationSidebarOpensRequestedTab"] = overlapPath != nil && reserves.kind == .overlap
    _ = shell.smokeReservationMenu(false)

    let edge = shell.view.safeAreaInsets.left + 2
    let edgeSwipe = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: 500, y: 0), translation: 80, edgeX: edge)
    let verticalSwipe = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: 100, y: 450), translation: 10)
    let cancelledSwipe = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: -500, y: 0), translation: -60, cancelled: true)
    checks["reservationTabSwipePreservesEdgeScrollAndCancellation"] = edgeSwipe.menu && !edgeSwipe.tab
      && !verticalSwipe.tab && cancelledSwipe.tab && reserves.kind == .overlap && table.isScrollEnabled

    let left = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: -500, y: 0), translation: -80)
    let movedToSkip = left.tab && reserves.kind == .skip
    let noWrap = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: -500, y: 0), translation: -80)
    let stayedOnSkip = !noWrap.tab && reserves.kind == .skip
    let right = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: 500, y: 0), translation: 80)
    let movedToOverlap = right.tab && reserves.kind == .overlap
    let rightAgain = shell.smokeReservationSwipe(in: table, velocity: CGPoint(x: 500, y: 0), translation: 80)
    checks["reservationTabSwipeMovesOneTabAndDoesNotWrap"] = movedToSkip && stayedOnSkip
      && movedToOverlap && rightAgain.tab && reserves.kind == .conflict

    _ = shell.smokeReservationMenu(true)
    checks["reservationSidebarHighlightsSwipedTab"] = await wait {
      menuRow("reserves-conflict")?.accessibilityTraits.contains(.selected) == true
        && menuRow("reserves-overlap")?.accessibilityTraits.contains(.selected) == false
    }
    capture("reservation-sidebar")
    NeoProgramSearchSmokeProtocol.setWarningCounts(conflicts: 0, overlaps: 3)
    NotificationCenter.default.post(name: .neoReservationsChanged, object: api)
    checks["reservationSidebarHidesZeroCountOnly"] = await wait {
      menuRow("reserves-conflict") == nil && menuRow("reserves-overlap")?.accessibilityValue == "3件"
    }
    return checks
  }
}
#endif
