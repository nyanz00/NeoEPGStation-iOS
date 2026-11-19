import UIKit

// Let the job type-check the search UIKit code before running the two whole-app
// builds. Only the shell and simulator output directory are replaced here.
class NeoPage: UIViewController {
  weak var shell: NeoShell?
  let body = UIView()
  init(title: String, shell: NeoShell) {
    self.shell = shell
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }
  required init?(coder: NSCoder) { fatalError() }
  func alert(_ text: String) {}
}

final class NeoShell: UIViewController {
  var api: NeoAPI?
  func pushPage(requestedAt: CFTimeInterval = CACurrentMediaTime(), _ make: () -> NeoPage) {}
  func smokeUseAPI(_ value: NeoAPI?) { api = value }
  func showRoute(_ id: String) {}
  func goBack() {}
}

enum NeoPiPSmoke {
  static let directory = FileManager.default.temporaryDirectory
}
