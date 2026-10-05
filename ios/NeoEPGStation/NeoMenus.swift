import UIKit

struct NeoMenuEntry {
  let title: String
  var icon: String? = nil
  let action: () -> Void
}

// A lightweight UIKit overlay: no system sheet, blur, navigation transition,
// or waiting for a modal dismissal before presenting the player.
final class NeoAnchoredMenu: UIView {
  enum Appearance { case actions, files, pageActions }
  private weak var anchor: UIView?
  private let surface = UIView(), scroll = UIScrollView()
  private let entries: [NeoMenuEntry]
  private let appearance: Appearance
  private var buttons: [UIButton] = []
  private var animator: UIViewPropertyAnimator?
  var onDismiss: (() -> Void)?
  private(set) var menuFrame = CGRect.zero
  var titles: [String] { entries.map(\.title) }
#if targetEnvironment(simulator)
  var smokeFileStyle: Bool {
    buttons.forEach { $0.layoutIfNeeded() }
    let webSuccess = UIColor(red: 102/255, green: 187/255, blue: 106/255, alpha: 1)
    return appearance == .files && surface.backgroundColor == NeoStyle.popupPaper && buttons.allSatisfy {
      $0.backgroundColor == webSuccess && $0.tintColor == NeoStyle.successText
        && $0.bounds.width >= 64 && $0.bounds.height == 31 && $0.layer.cornerRadius == 6
        && $0.contentHorizontalAlignment == .center
        && abs(($0.titleLabel?.frame.midX ?? 0) - $0.bounds.midX) < 1
        && $0.frame.minX == 8 && menuFrame.width <= 220
    }
  }
#endif

  init(anchor: UIView, entries: [NeoMenuEntry], appearance: Appearance) {
    self.anchor = anchor; self.entries = entries; self.appearance = appearance
    super.init(frame: .zero)
    let backdrop = UIButton(type: .custom); backdrop.tag = 1
    backdrop.accessibilityLabel = "メニューを閉じる"
    backdrop.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)
    addSubview(backdrop); addSubview(surface); surface.addSubview(scroll)
    surface.backgroundColor = NeoStyle.popupPaper
    surface.layer.cornerRadius = 6; surface.layer.shadowColor = UIColor.black.cgColor
    surface.layer.shadowOpacity = 0.3; surface.layer.shadowRadius = 5; surface.layer.shadowOffset = CGSize(width: 0, height: 3)
    scroll.clipsToBounds = true; scroll.layer.cornerRadius = 6
    for (index, entry) in entries.enumerated() {
      let button = UIButton(type: .system)
      button.setTitle(entry.title, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: appearance == .files ? 13 : 16, weight: appearance == .files ? .medium : .regular)
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.tintColor = .white
      button.contentHorizontalAlignment = appearance == .files ? .center : .left
      if let icon = entry.icon { button.setImage(NeoIcon.image(icon), for: .normal) }
      if appearance == .files { button.backgroundColor = NeoStyle.success; button.tintColor = NeoStyle.successText; button.layer.cornerRadius = 6 }
      button.accessibilityIdentifier = "anchored-menu-item-\(index)"
      button.addAction(UIAction { [weak self] _ in self?.select(index) }, for: .touchUpInside)
      scroll.addSubview(button); buttons.append(button)
    }
    accessibilityViewIsModal = true; accessibilityIdentifier = "anchored-menu"
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews()
    guard let anchor, let host = superview, anchor.window != nil else { return }
    viewWithTag(1)?.frame = bounds
    let safe = host.safeAreaInsets
    let available = bounds.inset(by: UIEdgeInsets(top: safe.top + 8, left: safe.left + 8, bottom: safe.bottom + 8, right: safe.right + 8))
    let rect = anchor.convert(anchor.bounds, to: self)
    let textWidth = entries.map { ($0.title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: appearance == .files ? 13 : 16, weight: appearance == .files ? .medium : .regular)]).width }.max() ?? 0
    let desiredWidth: CGFloat = appearance == .files ? min(220, max(64, ceil(textWidth) + 20) + 16) : max(180, ceil(textWidth) + 68)
    let width = min(desiredWidth, available.width)
    let rowHeight: CGFloat = appearance == .files ? 31 : 48
    let gap: CGFloat = appearance == .files ? 8 : 0
    let contentHeight = 16 + CGFloat(entries.count) * rowHeight + CGFloat(max(0, entries.count - 1)) * gap
    let height = min(contentHeight, available.height)
    let x = min(max(available.minX, appearance == .files ? rect.minX : rect.maxX - width), available.maxX - width)
    // Keep PLAY directly under the button; move upward only if it cannot fit.
    let y = min(max(available.minY, appearance == .pageActions ? rect.minY : rect.maxY), available.maxY - height)
    surface.frame = CGRect(x: x, y: y, width: width, height: height); menuFrame = surface.frame
    surface.layer.shadowPath = UIBezierPath(roundedRect: surface.bounds, cornerRadius: 6).cgPath
    scroll.frame = surface.bounds; scroll.contentSize = CGSize(width: width, height: contentHeight)
    var rowY: CGFloat = 8
    for (index, button) in buttons.enumerated() {
      let entry = entries[index]
      if appearance == .files {
        let textWidth = (entry.title as NSString).size(withAttributes: [.font: button.titleLabel!.font!]).width
        button.frame = CGRect(x: 8, y: rowY, width: min(width - 16, max(64, ceil(textWidth) + 20)), height: rowHeight)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
      } else {
        button.frame = CGRect(x: 0, y: rowY, width: width, height: rowHeight)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        button.imageEdgeInsets = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 4)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: entry.icon == nil ? 0 : 12, bottom: 0, right: 0)
      }
      rowY += rowHeight + gap
    }
  }
  func show(in host: UIView, animated: Bool = true) {
    frame = host.bounds; autoresizingMask = [.flexibleWidth, .flexibleHeight]; host.addSubview(self); layoutIfNeeded()
    if animated && !UIAccessibility.isReduceMotionEnabled {
      surface.alpha = 0
      let animation = UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) { [weak self] in self?.surface.alpha = 1 }
      animation.addCompletion { [weak self] _ in self?.animator = nil }
      animator = animation; animation.startAnimation()
    }
    UIAccessibility.post(notification: .screenChanged, argument: buttons.first)
  }
  func dismiss() {
    if animator?.state == .active { animator?.stopAnimation(true) }; animator = nil
    removeFromSuperview(); onDismiss?(); onDismiss = nil
    UIAccessibility.post(notification: .screenChanged, argument: anchor)
  }
  func select(_ index: Int) {
    guard superview != nil, entries.indices.contains(index) else { return }
    let action = entries[index].action; dismiss(); action()
  }
#if targetEnvironment(simulator)
  static func runSmoke(in host: UIView) -> Bool {
    let anchor = UIView(frame: CGRect(x: 12, y: 180, width: 100, height: 36)); host.addSubview(anchor)
    defer { anchor.removeFromSuperview() }
    var selected = 0
    for _ in 0..<10 {
      let menu = NeoAnchoredMenu(anchor: anchor, entries: [NeoMenuEntry(title: "TS") { selected += 1 }], appearance: .files)
      menu.show(in: host, animated: false)
      menu.layoutIfNeeded(); menu.buttons.forEach { $0.layoutIfNeeded() }
      guard menu.menuFrame.minX == 12, menu.menuFrame.minY == anchor.frame.maxY, menu.titles == ["TS"],
        menu.menuFrame.width == 80, menu.buttons.first?.bounds.width == 64, menu.smokeFileStyle else { menu.dismiss(); return false }
      menu.select(0)
      guard menu.superview == nil else { return false }
    }
    return selected == 10 && !host.subviews.contains(where: { $0 is NeoAnchoredMenu })
  }
#endif
}

extension NeoRecordingCommand {
  var icon: String {
    switch self {
    case .download: return "DownloadOutlined"
    case .rule: return "CalendarMonthOutlined"
    case .search: return "SearchOutlined"
    case .user: return "AccountCircleOutlined"
    case .encode: return "SyncOutlined"
    case .thumbnail: return "ImageOutlined"
    case .info: return "InfoOutlined"
    case .protect: return "LockOutlined"
    case .unprotect: return "LockOpenOutlined"
    case .subtitle: return "SubtitlesOutlined"
    case .delete: return "DeleteOutlineOutlined"
    }
  }
}

extension NeoPage {
  func showRecordingMenu(_ item: NeoRecording, anchor: UIView, detail: Bool) {
    guard let shell else { return }
    if shell.serverConfig == nil {
      Task { [weak shell] in await shell?.refreshServerConfig() }
    }
    presentRecordingMenu(item, anchor: anchor, detail: detail)
  }
  private func presentRecordingMenu(_ item: NeoRecording, anchor: UIView, detail: Bool) {
    guard let shell else { return }
    let commands = NeoRecordingMenu.commands(item: item, detail: detail, config: shell.serverConfig,
      hideThumbnailButton: shell.storage.hideRecordedThumbnailButton)
    shell.showPopup(anchor: anchor, entries: commands.map { command in
      NeoMenuEntry(title: command.rawValue, icon: command.icon) { [weak self] in
        // Operation dialogs will be ported separately; never run a destructive
        // server operation from a UI-only placeholder.
        self?.alert("\(command.rawValue) の操作は準備中です。")
      }
    }, appearance: .actions)
  }
}
