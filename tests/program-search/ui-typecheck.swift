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
  func pushPage(requestedAt: CFTimeInterval = CACurrentMediaTime(), _ make: () -> NeoPage) {}
  func smokeUseAPI(_ value: NeoAPI?) { api = value }
  func showRoute(_ id: String) {}
  func goBack() {}
  func recordingNotice(_ message: String, error: Bool = false) {}
}

struct NeoAccountCoordinator { var currentName: String }

enum NeoPiPSmoke {
  static let directory = FileManager.default.temporaryDirectory
}
