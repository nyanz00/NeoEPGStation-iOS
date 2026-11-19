import UIKit

enum NeoProgramRuleButton {
  static func make(_ title: String, filled: Bool, identifier: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    var configuration: UIButton.Configuration = filled ? .filled() : .plain()
    configuration.title = title
    configuration.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
      NeoIcon.image("PlaylistAddOutlined").draw(in: CGRect(x: 0, y: 0, width: 20, height: 20))
    }.withRenderingMode(.alwaysTemplate)
    configuration.baseForegroundColor = filled ? NeoStyle.successText : NeoStyle.accent
    configuration.baseBackgroundColor = filled ? NeoStyle.accent : .clear
    configuration.imagePadding = 4
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = 6
    if !filled {
      configuration.background.strokeColor = NeoStyle.accent.withAlphaComponent(0.5)
      configuration.background.strokeWidth = 1
    }
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 14, weight: .medium)
      return attributes
    }
    button.configuration = configuration
    button.accessibilityIdentifier = identifier
    button.accessibilityLabel = title
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }
}

/// The outlined input used for the channel and date/time fields in program search.
final class NeoProgramSearchInput: UIView {
  private static let leadingInset: CGFloat = 14
  private static let trailingInset: CGFloat = 4
  private static let accessoryWidth: CGFloat = 40
  private let outline = UIView()
  private let field: UITextField
  private let floatingLabel: UILabel
  private let placeholder: String
  let fieldLabel: String

  init(label: String, placeholder: String, field: UITextField, accessory: UIView, fieldContent: UIView? = nil) {
    fieldLabel = label
    self.field = field
    self.placeholder = placeholder
    floatingLabel = NeoStyle.label(label, size: 12, muted: true)
    super.init(frame: .zero)
    outline.layer.cornerRadius = 6
    outline.isUserInteractionEnabled = false
    addSubview(outline)
    floatingLabel.backgroundColor = NeoStyle.paper
    floatingLabel.textAlignment = .center
    floatingLabel.isAccessibilityElement = false
    floatingLabel.isUserInteractionEnabled = false
    field.accessibilityLabel = label
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let contents = UIStackView(arrangedSubviews: [fieldContent ?? field, accessory])
    contents.alignment = .center
    contents.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contents)
    addSubview(floatingLabel)
    NSLayoutConstraint.activate([
      accessory.widthAnchor.constraint(equalToConstant: Self.accessoryWidth),
      accessory.heightAnchor.constraint(equalToConstant: Self.accessoryWidth),
      contents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
      contents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
      contents.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      contents.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
    updateAppearance()
  }

  required init?(coder: NSCoder) { fatalError() }

  static func contentWidth(in width: CGFloat) -> CGFloat {
    max(0, width - leadingInset - trailingInset - accessoryWidth)
  }

  func updateAppearance(hasSelection: Bool = false, active: Bool = false, invalid: Bool = false) {
    let focused = field.isFirstResponder || active
    let floated = focused || hasSelection || !(field.text ?? "").isEmpty
    let error = UIColor(red: 244 / 255, green: 67 / 255, blue: 54 / 255, alpha: 1)
    let color = invalid ? error : focused ? NeoStyle.accent : NeoStyle.muted
    outline.layer.borderWidth = focused ? 2 : 1
    outline.layer.borderColor = (focused || invalid ? color : UIColor.white.withAlphaComponent(0.23)).cgColor
    floatingLabel.isHidden = !floated
    floatingLabel.textColor = color
    let hint = floated ? placeholder : fieldLabel
    let hintColor = floated ? UIColor.white.withAlphaComponent(0.5) : NeoStyle.muted
    field.attributedPlaceholder = NSAttributedString(string: hint, attributes: [.foregroundColor: hintColor])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    outline.frame = bounds
    let size = floatingLabel.intrinsicContentSize
    floatingLabel.frame = CGRect(x: 10, y: -size.height / 2, width: size.width + 8, height: size.height)
  }
}

/// A sibling of the form's table so its list can scroll without dragging the
/// form or dismissing the keyboard. The anchor remains interactive behind it.
final class NeoProgramSearchDropdown: UIView, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
  struct Row {
    enum Style { case choice, checkbox, heading, empty }
    let title: String
    let identifier: String
    var style: Style = .choice
    var selected = false
    var action: (() -> Void)? = nil
  }

  private let surface = UIView()
  private let list = UITableView(frame: .zero, style: .plain)
  private weak var anchor: UIView?
  private var rows: [Row] = []
  private var isStationList = false
  private var outsideTap: UITapGestureRecognizer?
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

  func show(in host: UIView, anchor: UIView, rows: [Row], identifier: String, isStationList: Bool) {
    dismiss()
    self.anchor = anchor
    self.isStationList = isStationList
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
  }

  func update(_ rows: [Row], resetScroll: Bool = false) {
    self.rows = rows
    list.reloadData()
    if resetScroll { list.setContentOffset(CGPoint(x: 0, y: -list.contentInset.top), animated: false) }
    setNeedsLayout()
  }

  func dismiss() {
    if let outsideTap { superview?.removeGestureRecognizer(outsideTap) }
    outsideTap = nil
    anchor = nil
    rows = []
    surface.isHidden = true
    removeFromSuperview()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let anchor, anchor.window != nil else { surface.isHidden = true; return }
    let rect = anchor.convert(anchor.bounds, to: self)
    let available = bounds.insetBy(dx: 0, dy: 8)
    guard available.intersects(rect), rect.width > 0 else { surface.isHidden = true; return }
    let heightLimit = isStationList ? (window?.bounds.height ?? bounds.height) * 0.4 : 360
    let desired = min(heightLimit, CGFloat(rows.count) * list.rowHeight + list.contentInset.top + list.contentInset.bottom)
    let upperEdge = rect.minY - (isStationList ? 8 : 0)
    let above = max(0, upperEdge - available.minY)
    let below = max(0, available.maxY - rect.maxY)
    let opensBelow = below >= desired || below >= above
    let height = min(desired, opensBelow ? below : above)
    let width = min(rect.width, bounds.width)
    let x = min(max(0, rect.minX), bounds.width - width)
    surface.frame = CGRect(x: x, y: opensBelow ? rect.maxY : upperEdge - height, width: width, height: height)
    surface.layer.shadowPath = UIBezierPath(roundedRect: surface.bounds, cornerRadius: 6).cgPath
    list.frame = surface.bounds
    surface.isHidden = height <= 0
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    !surface.isHidden && surface.frame.contains(point)
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
    guard rows.indices.contains(indexPath.row) else { return }
    rows[indexPath.row].action?()
  }
}
