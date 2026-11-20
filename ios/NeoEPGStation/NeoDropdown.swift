import UIKit

class NeoDropdownButton: UIButton {
  private var dropdown: NeoDropdownList?
  var dropdownRows: [NeoDropdownList.Row] = [] {
    didSet {
      if dropdown?.isOpen == true { dropdown?.update(dropdownRows) }
    }
  }
  var loadDropdownRows: ((@escaping ([NeoDropdownList.Row]) -> Void) -> Void)?
  var keepsDropdownOpenAfterSelection = false
  var hasDropdown: Bool { !dropdownRows.isEmpty || loadDropdownRows != nil }

  override init(frame: CGRect) {
    super.init(frame: frame)
    addTarget(self, action: #selector(toggleDropdown), for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isEnabled: Bool {
    didSet { if !isEnabled { dropdown?.dismiss() } }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil, dropdown?.isOpen == true { dropdown?.dismiss(animated: false) }
  }

  private var dropdownHost: UIView? {
    guard let window else { return nil }
    var responder = next
    while let current = responder {
      if let controller = current as? UIViewController { return controller.viewIfLoaded }
      responder = current.next
    }
    return window
  }

  @objc private func toggleDropdown() {
    guard isEnabled, hasDropdown, let host = dropdownHost else { return }
    if dropdown?.isOpen == true { dropdown?.dismiss(); return }

    dropdown?.dismiss(animated: false)
    let list = NeoDropdownList()
    dropdown = list
    list.onDismiss = { [weak list] in list?.dismiss() }
    let rows = loadDropdownRows == nil ? dropdownRows : [.init(title: "読み込み中…", style: .empty)]
    list.show(in: host, anchor: self, rows: rows,
      identifier: accessibilityIdentifier.map { "\($0).options" }, blocksOutsideTouches: true,
      closesOnSelection: !keepsDropdownOpenAfterSelection)

    loadDropdownRows? { [weak self, weak list] rows in
      guard let self, let list, dropdown === list, list.isOpen else { return }
      if rows.isEmpty { list.dismiss() }
      else { list.update(rows, resetScroll: true) }
    }
  }

#if targetEnvironment(simulator)
  var smokeDropdown: NeoDropdownList? { dropdown }
#endif
}

// MUI small outlined Select surface.
final class NeoSelectButton: NeoDropdownButton {
  private let value = NeoStyle.label(size:16), arrow = UIImageView()
  override init(frame: CGRect) {
    super.init(frame:frame)
    layer.cornerRadius = 6; layer.borderWidth = 1
    layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
    value.numberOfLines = 2
    arrow.image = UIGraphicsImageRenderer(size:CGSize(width:24,height:24)).image { _ in
      UIColor.white.withAlphaComponent(0.7).setFill(); let path = UIBezierPath()
      path.move(to:CGPoint(x:7,y:10)); path.addLine(to:CGPoint(x:12,y:15)); path.addLine(to:CGPoint(x:17,y:10)); path.close(); path.fill()
    }
    [value,arrow].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
    heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func setTitle(_ title: String?, for state: UIControl.State) {
    super.setTitle(title,for:state)
    guard state == .normal else { return }
    let text = title?.hasSuffix(" ▾") == true ? String(title!.dropLast(2)) : title
    value.text = text; accessibilityValue = text; invalidateIntrinsicContentSize(); setNeedsLayout()
  }
  override var intrinsicContentSize: CGSize { CGSize(width:180,height:44) }
  override var isEnabled: Bool { didSet { value.alpha = isEnabled ? 1 : 0.38; arrow.alpha = isEnabled ? 1 : 0.38 } }
  override func layoutSubviews() {
    super.layoutSubviews(); titleLabel?.isHidden = true
    value.frame = CGRect(x:14,y:3,width:max(0,bounds.width-46),height:max(0,bounds.height-6))
    arrow.frame = CGRect(x:bounds.width-31,y:(bounds.height-24)/2,width:24,height:24)
  }
}

final class NeoDropdownList: UIView, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
  struct Row {
    enum Style { case choice, checkbox, heading, empty }
    let title: String
    var identifier: String? = nil
    var style: Style = .choice
    var selected = false
    var action: (() -> Void)? = nil
  }

  private let surface = UIView()
  private let list = UITableView(frame: .zero, style: .plain)
  private weak var anchor: UIView?
  private var rows: [Row] = []
  private var isStationList = false
  private var blocksOutsideTouches = false
  private var closesOnSelection = false
  private var minimumWidth: CGFloat = 0
  private var presentation = 0
  private var outsideTap: UITapGestureRecognizer?
  private(set) var isOpen = false
  var onDismiss: (() -> Void)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    surface.layer.cornerRadius = 6
    surface.layer.shadowColor = UIColor.black.cgColor
    surface.layer.shadowOpacity = 0.28
    surface.layer.shadowRadius = 5
    surface.layer.shadowOffset = CGSize(width: 0, height: 3)
    addSubview(surface)
    list.dataSource = self
    list.delegate = self
    list.register(UITableViewCell.self, forCellReuseIdentifier: "option")
    list.layer.cornerRadius = 6
    list.clipsToBounds = true
    list.rowHeight = 48
    list.estimatedRowHeight = 0
    list.separatorStyle = .none
    list.sectionHeaderTopPadding = 0
    list.keyboardDismissMode = .none
    list.scrollsToTop = false
    list.contentInsetAdjustmentBehavior = .never
    list.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    surface.addSubview(list)
    list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(in host: UIView, anchor: UIView, rows: [Row], identifier: String?, isStationList: Bool = false,
    blocksOutsideTouches: Bool = false, closesOnSelection: Bool = false) {
    removeFromHost()
    self.anchor = anchor
    self.isStationList = isStationList
    self.blocksOutsideTouches = blocksOutsideTouches
    self.closesOnSelection = closesOnSelection
    isOpen = true
    isUserInteractionEnabled = true
    accessibilityViewIsModal = blocksOutsideTouches
    accessibilityElementsHidden = false
    let paper = isStationList ? UIColor(white: 1, alpha: 0.051) : .clear
    // Autocomplete Paper uses elevation 1, while the select menus use elevation 8.
    surface.backgroundColor = isStationList ? NeoStyle.paper : NeoStyle.popupPaper
    list.backgroundColor = paper
    list.accessibilityIdentifier = identifier
    list.accessibilityLabel = isStationList ? "放送局の候補" : anchor.accessibilityLabel
    let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    outsideTap = tap
    host.addGestureRecognizer(tap)
    host.addSubview(self)
    NSLayoutConstraint.activate([
      topAnchor.constraint(equalTo: host.topAnchor),
      leadingAnchor.constraint(equalTo: host.leadingAnchor),
      trailingAnchor.constraint(equalTo: host.trailingAnchor),
      bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
    ])
    update(rows, resetScroll: true)
    host.layoutIfNeeded()
    if blocksOutsideTouches, !surface.isHidden, let selected = rows.firstIndex(where: { $0.selected }) {
      list.scrollToRow(at: IndexPath(row: selected, section: 0), at: .middle, animated: false)
    }
    if !UIAccessibility.isReduceMotionEnabled {
      surface.alpha = 0
      UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
        self.surface.alpha = 1
      }
    }
    if blocksOutsideTouches && UIAccessibility.isVoiceOverRunning {
      UIAccessibility.post(notification: .layoutChanged, argument: list)
    }
  }

  func update(_ rows: [Row], resetScroll: Bool = false) {
    self.rows = rows
    if blocksOutsideTouches {
      minimumWidth = rows.reduce(CGFloat.zero) { width, row in
        let textWidth = (row.title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 16)]).width
        return max(width, ceil(textWidth) + (row.style == .checkbox ? 64 : 32))
      }
    }
    list.reloadData()
    if resetScroll { list.setContentOffset(CGPoint(x: 0, y: -list.contentInset.top), animated: false) }
    setNeedsLayout()
  }

  func dismiss(animated: Bool = true) {
    if !animated { removeFromHost(); return }
    guard isOpen else { return }
    isOpen = false
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    removeOutsideTap()
    guard !UIAccessibility.isReduceMotionEnabled, !surface.isHidden else { removeFromHost(); return }

    let closing = presentation
    UIView.animate(withDuration: 0.08, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
      self.surface.alpha = 0
    } completion: { [weak self] _ in
      guard let self, presentation == closing else { return }
      removeFromHost()
    }
  }

  private func removeOutsideTap() {
    if let outsideTap { superview?.removeGestureRecognizer(outsideTap) }
    outsideTap = nil
  }

  private func removeFromHost() {
    presentation += 1
    isOpen = false
    removeOutsideTap()
    removeFromSuperview()
    anchor = nil
    rows = []
    minimumWidth = 0
    surface.layer.removeAllAnimations()
    surface.alpha = 1
    surface.isHidden = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard isOpen else { return }
    guard let anchor, anchor.window != nil else { surface.isHidden = true; return }
    let rect = anchor.convert(anchor.bounds, to: self)
    let viewport = blocksOutsideTouches ? bounds.inset(by: safeAreaInsets) : bounds
    let available = viewport.insetBy(dx: blocksOutsideTouches ? 8 : 0, dy: 8)
    guard available.intersects(rect), rect.width > 0 else { surface.isHidden = true; return }
    let heightLimit = isStationList ? (window?.bounds.height ?? bounds.height) * 0.4 : 360
    let desired = min(heightLimit, CGFloat(rows.count) * list.rowHeight + list.contentInset.top + list.contentInset.bottom)
    let upperEdge = rect.minY - (isStationList ? 8 : 0)
    let above = max(0, upperEdge - available.minY)
    let below = max(0, available.maxY - rect.maxY)
    let opensBelow = below >= desired || below >= above
    let height = min(desired, opensBelow ? below : above)
    let width = min(max(rect.width, minimumWidth), available.width)
    let x = min(max(available.minX, rect.minX), available.maxX - width)
    surface.frame = CGRect(x: x, y: opensBelow ? rect.maxY : upperEdge - height, width: width, height: height)
    surface.layer.shadowPath = UIBezierPath(roundedRect: surface.bounds, cornerRadius: 6).cgPath
    list.frame = surface.bounds
    surface.isHidden = height <= 0
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard isOpen, !surface.isHidden, bounds.contains(point) else { return false }
    if surface.frame.contains(point) { return true }
    guard blocksOutsideTouches, let anchor else { return false }
    return !anchor.convert(anchor.bounds, to: self).contains(point)
  }

  override func accessibilityPerformEscape() -> Bool {
    guard isOpen else { return false }
    onDismiss?()
    return true
  }

  @objc private func tappedOutside(_ tap: UITapGestureRecognizer) {
    if tap === outsideTap { onDismiss?() }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard let anchor, let touchedView = touch.view else { return false }
    return touchedView !== anchor && !touchedView.isDescendant(of: anchor)
      && touchedView !== surface && !touchedView.isDescendant(of: surface)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = rows[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "option", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = row.title
    let secondary = row.style == .heading || row.style == .empty
    content.textProperties.font = .systemFont(ofSize: secondary ? 14 : 16, weight: row.style == .heading ? .medium : .regular)
    content.textProperties.color = secondary ? NeoStyle.muted : .white
    content.textProperties.numberOfLines = 1
    content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    if row.style == .checkbox {
      content.image = NeoIcon.image(row.selected ? "CheckBox" : "CheckBoxOutlineBlank")
      content.imageProperties.tintColor = row.selected ? NeoStyle.accent : NeoStyle.muted
      content.imageToTextPadding = 12
    }
    cell.contentConfiguration = content
    var background = UIBackgroundConfiguration.clear()
    background.backgroundColor = row.selected ? NeoStyle.accent.withAlphaComponent(0.16) : .clear
    cell.backgroundConfiguration = background
    cell.selectionStyle = row.action == nil ? .none : .default
    cell.accessibilityIdentifier = row.identifier
    cell.accessibilityLabel = row.title
    cell.accessibilityTraits = secondary ? (row.style == .heading ? .header : .staticText) : (row.selected ? [.button, .selected] : .button)
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    guard isOpen, rows.indices.contains(indexPath.row), let action = rows[indexPath.row].action else { return }
    if closesOnSelection { dismiss() }
    action()
  }

#if targetEnvironment(simulator)
  var smokeList: UITableView { list }
#endif
}
