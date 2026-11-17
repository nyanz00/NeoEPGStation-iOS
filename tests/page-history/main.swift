import Foundation

@main
struct PageHistoryTests {
  static var assertions = 0

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    assert(condition(), message)
  }

  static func actionIs(_ expected: NeoSwipeAction?, _ actual: NeoSwipeAction?, _ message: String) {
    switch (expected, actual) {
    case (nil, nil): check(true, message)
    case (.some(.menu), .some(.menu)), (.some(.back), .some(.back)), (.some(.forward), .some(.forward)):
      check(true, message)
    default: check(false, message)
    }
  }

  static func main() {
    var history = NeoRecordedPageHistory()
    history.visit(20, offset: 120.5)
    history.visit(3, offset: 17)
    check(history.entries == [.init(page: 1, offset: 0), .init(page: 20, offset: 120.5), .init(page: 3, offset: 17)], "1 → 20 → 3 remains in order")
    check(history.current == .init(page: 3, offset: 17) && history.index == 2, "latest visit is current")

    history.updateOffset(23.75)
    check(history.entries[2].offset == 23.75, "offset updates current entry")
    check(history.target(-1)?.entry == .init(page: 20, offset: 120.5), "back target restores saved page and offset")
    check(history.target(1) == nil && history.index == 2 && history.current.page == 3, "requesting back target alone does not move cursor")
    check(history.restore(at: 1, page: 20, offset: 120.5), "restore accepts valid destination")
    check(history.index == 1 && history.current == .init(page: 20, offset: 120.5), "restore selects destination and saved offset")
    check(history.target(1)?.entry == .init(page: 3, offset: 23.75), "forward target returns updated forward entry")
    check(history.restore(at: 2, page: 3, offset: 23.75) && history.index == 2, "forward restore selects target")

    check(history.restore(at: 1, page: 20, offset: 120.5), "reposition before branching")
    history.visit(7, offset: 4)
    check(history.entries.map(\.page) == [1, 20, 7] && !history.canForward, "new visit truncates forward branch")

    var refreshHistory = NeoRecordedPageHistory()
    refreshHistory.visit(20, offset: 80)
    refreshHistory.visit(3, offset: 12)
    _ = refreshHistory.restore(at: 1, page: 20, offset: 80)
    refreshHistory.visit(20, offset: 91)
    check(refreshHistory.entries.map(\.page) == [1, 20, 3] && refreshHistory.current.offset == 91 && refreshHistory.canForward,
      "refreshing same page updates entry and preserves forward history")

    let beforeInvalidEntries = history.entries
    let beforeInvalidIndex = history.index
    check(!history.restore(at: 9, page: 99, offset: 999) && history.entries == beforeInvalidEntries && history.index == beforeInvalidIndex, "invalid destination leaves history unchanged")

    var isolated = NeoRecordedPageHistory()
    isolated.visit(4, offset: 56)
    isolated.reset(page: 8, offset: 3)
    check(isolated.entries == [.init(page: 8, offset: 3)] && isolated.index == 0 && !isolated.canBack && !isolated.canForward,
      "reset isolates changed query or user context")
    isolated.reset(page: -2, offset: .nan)
    check(isolated.entries == [.init(page: 1, offset: 0)], "reset clamps page and sanitizes nonfinite offset")
    isolated.updateOffset(.infinity)
    isolated.visit(5, offset: -.infinity)
    check(isolated.entries == [.init(page: 1, offset: 0), .init(page: 5, offset: 0)], "offset updates and visits sanitize nonfinite values")
    isolated.visit(0, offset: 2)
    check(isolated.current == .init(page: 1, offset: 2), "visit clamps invalid page")

    func gesture(_ y: Double, _ horizontal: Double, _ vertical: Double, back: Bool, tablet: Bool = false,
      fullScreen: Bool = false, forward: Bool = false) -> NeoSwipeAction? {
      NeoNavigationGesture.action(startY: y, height: 100, canGoBack: back, tablet: tablet,
        horizontal: horizontal, vertical: vertical, fullScreenBack: fullScreen, canGoForward: forward)
    }
    actionIs(.back, gesture(0, 10, 0, back: true, fullScreen: true), "full-screen back works from top")
    actionIs(.back, gesture(100, 10, 0, back: true, fullScreen: true), "full-screen back works from bottom")
    actionIs(.menu, gesture(0, 10, 0, back: false), "phone without back shows menu at top")
    actionIs(.menu, gesture(100, 10, 0, back: false), "phone without back shows menu at bottom")
    actionIs(.forward, gesture(50, -10, 0, back: false, fullScreen: true, forward: true), "left swipe goes forward when history exists")
    actionIs(nil, gesture(50, -10, 0, back: false, fullScreen: true, forward: false), "left swipe ignored without forward history")
    actionIs(nil, gesture(50, 10, 20, back: true, fullScreen: true), "vertical dominant swipe ignored")

    actionIs(.menu, gesture(39, 10, 0, back: true), "legacy phone 40 percent threshold shows menu above threshold")
    actionIs(.back, gesture(40, 10, 0, back: true), "legacy phone 40 percent threshold navigates at threshold")
    actionIs(nil, gesture(29, 10, 0, back: true, tablet: true), "legacy tablet 30 percent threshold is not reached")
    actionIs(.back, gesture(30, 10, 0, back: true, tablet: true), "legacy tablet 30 percent threshold is inclusive")
    actionIs(.menu, gesture(100, 10, 0, back: false, tablet: false), "legacy phone still offers menu when back is unavailable")
    actionIs(nil, gesture(100, 10, 0, back: false, tablet: true), "legacy tablet still has no menu when back is unavailable")

    print("Page history and navigation gestures: \(assertions) assertions passed")
  }
}
