// Only the unrelated app shell/style/image loader are replaced here. Actual
// models, shared marquee and encode card (including simulator diagnostics) are
// type checked with the simulator SDK before native dependencies are built.
import UIKit

enum NeoStyle {
  static let background = UIColor.black, paper = UIColor.black, border = UIColor.gray
  static let accent = UIColor.cyan, muted = UIColor.gray, successText = UIColor.black
  static func label(_ text: String? = nil, size: CGFloat = 14, bold: Bool = false, muted: Bool = false) -> UILabel {
    let label = UILabel(); label.text = text; return label
  }
}
enum NeoIcon { static func image(_ name:String) -> UIImage? { nil } }
final class NeoThumbnail: UIImageView { func load(_ url:URL?) {} }
@MainActor final class NeoShell {
  var api: NeoAPI?
  private(set) var channels: [Int:String] = [:]
}
