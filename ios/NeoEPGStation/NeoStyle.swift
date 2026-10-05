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
  private var requested: URL?
  private var subscription: UUID?
  private static var downloads: [URL: URLSessionDataTask] = [:]
  private static var downloadIDs: [URL: UUID] = [:]
  private static var listeners: [URL: [UUID: (UIImage?) -> Void]] = [:]
#if targetEnvironment(simulator)
  private static var fixtureSession: URLSession?
#endif
  init() { super.init(frame: .zero); contentMode = .scaleAspectFill; clipsToBounds = true; backgroundColor = .black }
  required init?(coder: NSCoder) { fatalError() }
  func load(_ url: URL?, fadeIn: Bool = false) {
    if url == requested, image != nil { return }
    if let requested, let subscription { Self.unsubscribe(requested, subscription) }
    subscription = nil; requested = url; image = nil; layer.removeAllAnimations(); alpha = 1
    guard let url else { return }
    if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
    subscription = Self.request(url) { [weak self] image in
      guard let self, self.requested == url else { return }
      if fadeIn && image != nil && !UIAccessibility.isReduceMotionEnabled {
        // Fade the image contents, keeping the thumbnail's black backing solid.
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        self.layer.add(fade, forKey: "late-thumbnail-fade-in")
      }
      self.image = image; self.subscription = nil
    }
  }
  private static func request(_ url: URL, completion: @escaping (UIImage?) -> Void) -> UUID? {
    if let cached = cache.object(forKey: url as NSURL) { completion(cached); return nil }
    let id = UUID(); listeners[url, default: [:]][id] = completion
    if downloads[url] != nil { return id }
    var session = URLSession.shared
#if targetEnvironment(simulator)
    if url.host == "thumbnail-fixture.invalid", let fixtureSession { session = fixtureSession }
#endif
    let download = session.dataTask(with: url) { data, response, _ in
      var decoded: UIImage?
      if let data, (response as? HTTPURLResponse)?.statusCode == 200,
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 1000,
          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
        decoded = UIImage(cgImage: cg)
        cache.setObject(decoded!, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
      }
      let image = decoded
      DispatchQueue.main.async {
        // A cancelled request may have been replaced for the same URL.
        guard downloadIDs[url] == id else { return }
        downloads.removeValue(forKey: url)
        downloadIDs.removeValue(forKey: url)
        let callbacks = listeners.removeValue(forKey: url)?.values
        callbacks?.forEach { $0(image) }
      }
    }
    downloads[url] = download; downloadIDs[url] = id; download.resume(); return id
  }
  private static func unsubscribe(_ url: URL, _ id: UUID) {
    listeners[url]?.removeValue(forKey: id)
    if listeners[url]?.isEmpty == true {
      downloads.removeValue(forKey: url)?.cancel(); downloadIDs.removeValue(forKey: url); listeners.removeValue(forKey: url)
    }
  }
  // Match Web's 400ms image readiness window. The downloads are shared with
  // visible cells, so late images do not start a duplicate network request.
  static func prepare(_ urls: [URL]) async throws -> Set<URL> {
    let subscriptions: [(URL, UUID)] = Set(urls).compactMap { url in
      request(url, completion: { _ in }).map { (url, $0) }
    }
    defer { subscriptions.forEach { unsubscribe($0.0, $0.1) } }
    for _ in 0..<40 {
      try Task.checkCancellation()
      if subscriptions.allSatisfy({ downloads[$0.0] == nil }) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    // Keep outstanding warm-up downloads alive until cells can subscribe.
    for (url, _) in subscriptions where downloads[url] != nil { _ = request(url) { _ in } }
    return Set(subscriptions.filter { downloads[$0.0] != nil }.map { $0.0 })
  }
  deinit {
    let url = requested, id = subscription
    DispatchQueue.main.async { if let url, let id { NeoThumbnail.unsubscribe(url, id) } }
  }
#if targetEnvironment(simulator)
  static func runSmoke() async -> Bool {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NeoThumbnailFixtureProtocol.self]
    let session = URLSession(configuration: configuration); fixtureSession = session
    defer { session.invalidateAndCancel(); fixtureSession = nil }
    let url = URL(string: "https://thumbnail-fixture.invalid/slow-shared")!
    let old = URL(string: "https://thumbnail-fixture.invalid/slow-reused")!
    let replacement = URL(string: "https://thumbnail-fixture.invalid/fast")!
    let failed = URL(string: "https://thumbnail-fixture.invalid/failed")!
    NeoThumbnailFixtureProtocol.imageData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
      UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }.pngData()!
    do {
      let late = try await prepare([url, failed])
      let first = NeoThumbnail(), second = NeoThumbnail(), reused = NeoThumbnail()
      first.load(url, fadeIn: true); second.load(url, fadeIn: true)
      reused.load(old, fadeIn: true); reused.load(replacement)
      try await Task.sleep(nanoseconds: 800_000_000)
      let cached = NeoThumbnail(); cached.load(url, fadeIn: true)
      return late == [url] && first.image != nil && second.image === first.image && cached.image === first.image
        && cached.alpha == 1 && cached.layer.animationKeys() == nil
        && reused.image != nil && reused.image === cache.object(forKey: replacement as NSURL)
        && NeoThumbnailFixtureProtocol.count(for: "/slow-shared") == 1
    } catch { return false }
  }
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

#if targetEnvironment(simulator)
private final class NeoThumbnailFixtureProtocol: URLProtocol {
  static var imageData = Data()
  private static let lock = NSLock()
  private static var counts: [String: Int] = [:]
  static func count(for path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "thumbnail-fixture.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    Self.lock.lock(); Self.counts[url.path, default: 0] += 1; Self.lock.unlock()
    DispatchQueue.global().asyncAfter(deadline: .now() + (url.path.hasPrefix("/slow") ? 0.65 : 0.01)) { [self] in
      let status = url.path == "/failed" ? 500 : 200
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      if status == 200 { client?.urlProtocol(self, didLoad: Self.imageData) }
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}
#endif
