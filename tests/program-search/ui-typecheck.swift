import UIKit

// Let the job type-check the search UIKit code before running the two whole-app
// builds. Only the shell and simulator output directory are replaced here.
class NeoPage: UIViewController {
  weak var shell: NeoShell?
  let body = UIView()
  let titleLabel = NeoStyle.label()
  var actions: [UIView] = []
  func width(forHeaderAction action: UIView) -> CGFloat { 44 }
  init(title: String, shell: NeoShell) {
    self.shell = shell
    super.init(nibName: nil, bundle: nil)
    self.title = title
    titleLabel.text = title
  }
  required init?(coder: NSCoder) { fatalError() }
  func alert(_ text: String) {}
}

final class NeoShell: UIViewController {
  var api: NeoAPI?
  var account: NeoAccountCoordinator?
  var serverConfig: NeoServerConfig?
  func pushPage(requestedAt: CFTimeInterval = CACurrentMediaTime(), _ make: () -> NeoPage) {}
  func smokeUseAPI(_ value: NeoAPI?) { api = value }
  func showRoute(_ id: String) {}
  func smokeSelectDestination(_ id: String) {}
  func returnAfterRuleSave(from page: NeoProgramSearchPage) -> Bool { false }
  func goBack() {}
  func recordingNotice(_ message: String, error: Bool = false, warning: Bool = false) {}
  func showPopup(anchor: UIView, entries: [NeoMenuEntry], appearance: NeoAnchoredMenu.Appearance) {}
  func dismissPopup() {}
}

struct NeoAccountCoordinator { var currentName: String }
struct NeoMenuEntry { let title: String; var icon: String? = nil; let action: () -> Void }
final class NeoAnchoredMenu: UIView {
  enum Appearance { case pageActions }
  var titles: [String] { [] }
}

final class NeoUserSelector: NeoDropdownButton {
  func setValue(_ text: String) {}
  func setCaptionVisible(_ visible: Bool) {}
}

final class NeoPaginationFooter: UIView {
  func configure(page: Int, count: Int, mobile: Bool, extended: Bool = false,
    jump: (() -> Void)? = nil, action: @escaping (Int) -> Void) {}
}

class NeoLiveDialog: UIViewController {
  var contentBackground: UIColor { .clear }
  var contentHorizontalInset: CGFloat { 24 }
  init(title: String) { super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError() }
  func addView(_ view: UIView) {}
  func addText(_ text: String, bold: Bool = false) {}
  func addAction(_ title: String, filled: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> UIButton { UIButton() }
  func cancel() {}
  func setCloseEnabled(_ enabled: Bool) {}
}

@MainActor final class NeoDeferredScrollUpdate {
  @discardableResult func submit(in scrollView: UIScrollView, _ update: @escaping () -> Void) -> Bool {
    update()
    return false
  }
  func cancel() {}
}

final class NeoPageJumpDialog: NeoLiveDialog {
  init(page: Int, count: Int, onMove: @escaping (Int) -> Void) { super.init(title: "ページを指定") }
  required init?(coder: NSCoder) { fatalError() }
}

final class NeoRecordedPage: NeoPage {
  init(shell: NeoShell, filters: NeoRecordedFilters, viewerFilter: String) { super.init(title: "録画済み", shell: shell) }
  required init?(coder: NSCoder) { fatalError() }
}

enum NeoPiPSmoke {
  static let directory = FileManager.default.temporaryDirectory
}
