import UIKit
import ImageIO

enum NeoStyle {
  static let background = UIColor(red: 16/255, green: 20/255, blue: 24/255, alpha: 1)
  static let paper = UIColor(red: 25/255, green: 30/255, blue: 35/255, alpha: 1)
  static let accent = UIColor(red: 32/255, green: 168/255, blue: 154/255, alpha: 1)
  static let muted = UIColor.white.withAlphaComponent(0.7)
  static let border = UIColor.white.withAlphaComponent(0.12)
  static func label(_ text: String = "", size: CGFloat = 14, bold: Bool = false, muted: Bool = false) -> UILabel {
    let label = UILabel(); label.text = text; label.textColor = muted ? self.muted : .white
    label.font = .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    label.lineBreakMode = .byTruncatingTail; return label
  }
  static func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system); button.setImage(NeoIcon.image(name), for: .normal)
    button.tintColor = .white; button.accessibilityLabel = label
    button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button
  }
  static func button(_ text: String, filled: Bool = false, action: @escaping () -> Void) -> UIButton {
    let b = UIButton(type: .system); b.setTitle(text, for: .normal); b.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    b.tintColor = filled ? .black : accent; b.backgroundColor = filled ? accent : .clear
    b.layer.cornerRadius = 6; b.addAction(UIAction { _ in action() }, for: .touchUpInside); return b
  }
  static func border(_ parent: UIView, y: CGFloat) {
    let line = UIView(frame: CGRect(x: 0, y: y, width: parent.bounds.width, height: 1 / UIScreen.main.scale))
    line.backgroundColor = border; parent.addSubview(line)
  }
}

// Decoding/resizing runs off the main thread. Cache is shared across cards and
// details; reused cells cancel requests and never display another record's image.
final class NeoThumbnail: UIImageView {
  private static let cache: NSCache<NSURL, UIImage> = {
    let cache = NSCache<NSURL, UIImage>(); cache.totalCostLimit = 48 * 1024 * 1024; cache.countLimit = 120; return cache
  }()
  private var task: URLSessionDataTask?
  private var requested: URL?
  init() { super.init(frame: .zero); contentMode = .scaleAspectFill; clipsToBounds = true; backgroundColor = .black }
  required init?(coder: NSCoder) { fatalError() }
  func load(_ url: URL?) {
    task?.cancel(); task = nil; requested = url; image = nil
    guard let url else { return }
    if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
    task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
      guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 1000,
          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
      let image = UIImage(cgImage: cg)
      Self.cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
      DispatchQueue.main.async { if self?.requested == url { self?.image = image } }
    }; task?.resume()
  }
  deinit { task?.cancel() }
#if targetEnvironment(simulator)
  func showFixture(_ index: Int) {
    load(nil)
    image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
      let colors: [UIColor] = [.systemTeal, .systemIndigo, .systemBlue, .systemOrange]
      colors[(index - 1) % colors.count].withAlphaComponent(0.35).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
      colors[(index - 1) % colors.count].setFill()
      context.fill(CGRect(x: 0, y: 250, width: 640, height: 110))
      ("SAMPLE  \(index)" as NSString).draw(at: CGPoint(x: 36, y: 140), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.white])
    }
  }
#endif
}
