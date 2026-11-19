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
      value = Array(1...18).map { id -> [String: Any] in
        [
          "id": id,
          "name": id == 1 ? "Fixture Station" : String(format: "Fixture Station %02d", id),
          "channelType": "GR",
          "hasLogoData": false
        ]
      }
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
    capture("form")

    func viewWithID(_ identifier: String) -> UIView? {
      identified(page.view, identifier) ?? identified(shell.view, identifier)
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
        guard let menu = viewWithID(identifier) as? UITableView else { return false }
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
      if !keyboardShown { checks["programSearchKeyboardViewportNotAvailable"] = true }
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
          checks["programSearch.channelMenuFlipsAbove"] = state.menu.maxY <= state.anchor.minY + 2
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
        stationMenu.layoutIfNeeded()
        let initialOffset = stationMenu.contentOffset.y
        let formOffset = formList.contentOffset
        let bottomOffset = stationMenu.contentSize.height + stationMenu.contentInset.bottom - stationMenu.bounds.height
        stationMenu.setContentOffset(CGPoint(x: 0, y: min(initialOffset + 96, bottomOffset)), animated: false)
        stationMenu.layoutIfNeeded()
        checks["programSearch.channelCandidateScrollRetainsFocus"] = stationMenu.keyboardDismissMode == .none
          && channel.isFirstResponder && stationMenu.contentOffset.y > initialOffset
          && formList.contentOffset == formOffset
        if let (_, row2) = revealTableCell(stationMenu, identifier: "programSearch.channelOption.2") {
          stationMenu.delegate?.tableView?(stationMenu, didSelectRowAt: row2)
          let selected2 = await waitFor {
            viewWithID("programSearch.channelChip.2") != nil
              && viewWithID("programSearch.channelSuggestions") == nil
          }
          checks["programSearch.channelCandidateSelection"] = selected2 && channel.isFirstResponder
        } else {
          checks["programSearch.channelCandidateSelection"] = false
        }
        channelToggle.sendActions(for: .touchUpInside)
        if let secondMenu = await waitForMenu("programSearch.channelSuggestions", minimumRows: 18),
          let (_, row3) = revealTableCell(secondMenu, identifier: "programSearch.channelOption.3") {
          secondMenu.delegate?.tableView?(secondMenu, didSelectRowAt: row3)
          let selected3 = await waitFor {
            viewWithID("programSearch.channelChip.3") != nil
              && viewWithID("programSearch.channelSuggestions") == nil
          }
          checks["programSearch.channelMultiSelect"] = selected3 && viewWithID("programSearch.channelChip.2") != nil
          let waveButtons = viewWithID("programSearch.channelWaveOptions").map { views(in: $0).compactMap { $0 as? UIButton } } ?? []
          checks["programSearch.channelSelectionDisablesWave"] = !waveButtons.isEmpty && waveButtons.allSatisfy { !$0.isEnabled }
        } else {
          checks["programSearch.channelMultiSelect"] = false
          checks["programSearch.channelSelectionDisablesWave"] = false
        }
      } else {
        checks["programSearch.channelCandidateScrollRetainsFocus"] = false
        checks["programSearch.channelCandidateSelection"] = false
        checks["programSearch.channelMultiSelect"] = false
        checks["programSearch.channelSelectionDisablesWave"] = false
      }

      clearForm.sendActions(for: .touchUpInside)
      _ = await waitFor {
        (viewWithID("programSearch.channelChip.2") == nil && viewWithID("programSearch.channelChip.3") == nil)
          && channel.text?.isEmpty == true
      }
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

      genreButton.sendActions(for: .touchUpInside)
      if let genreMenu = await waitForMenu("programSearch.options.genre", minimumRows: 14) {
        checks["programSearchGenreLabels"] = tableCell(genreMenu, identifier: "programSearch.option.genre.all")?.0.textLabel?.text == "すべて"
          && tableCell(genreMenu, identifier: "programSearch.option.genre.3")?.0.textLabel?.text == "ドラマ"
        checks["programSearchGenreAnchorVisible"] = popupState(anchorID: "programSearch.genre", menuID: "programSearch.options.genre").map {
          $0.viewport.intersects($0.anchor) && $0.viewport.contains($0.menu)
        } ?? false
        capture("genre-menu")
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

      subGenreButton.sendActions(for: .touchUpInside)
      if let subMenu = await waitForMenu("programSearch.options.subGenre", minimumRows: 1) {
        checks["programSearchSubGenreLabels"] = tableCell(subMenu, identifier: "programSearch.option.subGenre.3.header")?.0.textLabel?.text == "ドラマ"
          && tableCell(subMenu, identifier: "programSearch.option.subGenre.3.all")?.0.textLabel?.text == "すべて"
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

      startHourButton.sendActions(for: .touchUpInside)
      if let startMenu = await waitForMenu("programSearch.options.startHour", minimumRows: 25) {
        checks["programSearchStartHourLabels"] = tableCell(startMenu, identifier: "programSearch.option.startHour.none")?.0.textLabel?.text == "指定なし"
          && tableCell(startMenu, identifier: "programSearch.option.startHour.0")?.0.textLabel?.text == "0時"
          && revealTableCell(startMenu, identifier: "programSearch.option.startHour.23")?.0.textLabel?.text == "23時"
        checks["programSearchStartHourAnchorVisible"] = popupState(anchorID: "programSearch.startHour", menuID: "programSearch.options.startHour").map {
          $0.viewport.intersects($0.anchor) && $0.viewport.contains($0.menu)
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

      rangeHourButton.sendActions(for: .touchUpInside)
      if let rangeMenu = await waitForMenu("programSearch.options.rangeHour", minimumRows: 24) {
        checks["programSearchRangeHourLabels"] = tableCell(rangeMenu, identifier: "programSearch.option.rangeHour.none")?.0.textLabel?.text == "指定なし"
          && tableCell(rangeMenu, identifier: "programSearch.option.rangeHour.1")?.0.textLabel?.text == "1時間"
          && revealTableCell(rangeMenu, identifier: "programSearch.option.rangeHour.23")?.0.textLabel?.text == "23時間"
        checks["programSearchRangeHourAnchorVisible"] = popupState(anchorID: "programSearch.rangeHour", menuID: "programSearch.options.rangeHour").map {
          $0.viewport.intersects($0.anchor) && $0.viewport.contains($0.menu)
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
      checks["programDetailReadOnly"] = false
      return checks
    }
    detail.view.layoutIfNeeded()

    let detailButtons = views(in: detail.view).compactMap { $0 as? UIButton }
    let buttonTitles = Set(detailButtons.filter { !$0.isHidden }.compactMap { $0.title(for: .normal) })
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
          && !(mode?.isUserInteractionEnabled ?? true) && !(user?.isUserInteractionEnabled ?? true)
          && checkboxes.count == 2 && checkboxes.allSatisfy { !$0.isEnabled && !$0.frame.isEmpty }
          && footer.count == 4 && footer.prefix(2).allSatisfy(\.isEnabled) && footer.suffix(2).allSatisfy { !$0.isEnabled }
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
