import UIKit

/// A compact, self-sizing native equivalent of the Web RulesPage card.
///
/// The card only presents a rule and reports user intent. Rule mutation,
/// selection state, and the menu itself remain owned by the containing page.
final class NeoRuleCard: UITableViewCell {
  struct Content {
    let id: Int
    let title: String
    let ignoredKeyword: String?
    let conditions: String
    let encodeSummary: String?
    let enabled: Bool
    let reserveCount: Int
    let hasAnnict: Bool
  }

  var onSelect: (() -> Void)?
  var onToggle: ((Bool) -> Void)?
  var onMenu: ((UIView) -> Void)?

  private let card = UIView()
  private let contentStack = UIStackView()
  private let selectionButton = UIButton(type: .system)
  private let textStack = UIStackView()
  private let headerFlow = NeoRuleHeaderFlow()
  private let ignoredLabel = NeoStyle.label(size: 14, muted: true)
  private let conditionsLabel = NeoStyle.label(size: 14, muted: true)
  private let encodeLabel = NeoStyle.label(size: 12, muted: true)
  private let controlsStack = UIStackView()
  private let toggle = NeoRuleEnableSwitch()
  private let menuButton = UIButton(type: .system)
  private var cardLeading: NSLayoutConstraint!
  private var cardTrailing: NSLayoutConstraint!
  private var selecting = false
  private var controlsEnabled = false

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = NeoStyle.background
    contentView.backgroundColor = .clear
    selectionStyle = .none

    card.backgroundColor = NeoStyle.paper
    card.layer.cornerRadius = 6
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor
    card.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(card)

    contentStack.axis = .horizontal
    contentStack.alignment = .top
    contentStack.spacing = 12
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(contentStack)

    selectionButton.setContentHuggingPriority(.required, for: .horizontal)
    selectionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    let selectionWidth = selectionButton.widthAnchor.constraint(equalToConstant: 44)
    selectionWidth.priority = .defaultHigh
    selectionWidth.isActive = true
    selectionButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
    selectionButton.addTarget(self, action: #selector(selectButtonPressed), for: .touchUpInside)
    contentStack.addArrangedSubview(selectionButton)

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.distribution = .fill
    textStack.spacing = 4
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textStack.addArrangedSubview(headerFlow)
    textStack.addArrangedSubview(ignoredLabel)
    textStack.addArrangedSubview(conditionsLabel)
    textStack.addArrangedSubview(encodeLabel)
    contentStack.addArrangedSubview(textStack)

    controlsStack.axis = .horizontal
    controlsStack.alignment = .center
    controlsStack.spacing = 4
    controlsStack.setContentHuggingPriority(.required, for: .horizontal)
    controlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    contentStack.addArrangedSubview(controlsStack)

    toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    controlsStack.addArrangedSubview(toggle)

    menuButton.setImage(NeoIcon.image("MoreVert"), for: .normal)
    menuButton.tintColor = .white
    let menuWidth = menuButton.widthAnchor.constraint(equalToConstant: 40)
    menuWidth.priority = .defaultHigh
    menuWidth.isActive = true
    menuButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
    menuButton.addTarget(self, action: #selector(menuPressed), for: .touchUpInside)
    controlsStack.addArrangedSubview(menuButton)

    cardLeading = card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
    cardTrailing = card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
    NSLayoutConstraint.activate([
      cardLeading,
      cardTrailing,
      card.topAnchor.constraint(equalTo: contentView.topAnchor),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
    ])

    ignoredLabel.numberOfLines = 0
    ignoredLabel.lineBreakMode = .byWordWrapping
    conditionsLabel.numberOfLines = 0
    conditionsLabel.lineBreakMode = .byWordWrapping
    encodeLabel.numberOfLines = 0
    encodeLabel.lineBreakMode = .byWordWrapping

  }

  required init?(coder: NSCoder) { fatalError() }

  func configure(
    _ item: Content,
    selecting: Bool,
    selected: Bool,
    controlsEnabled: Bool,
    tableWidth: CGFloat,
    sideInset: CGFloat
  ) {
    self.selecting = selecting
    self.controlsEnabled = controlsEnabled

    let safeInset = max(0, sideInset)
    cardLeading.constant = safeInset
    cardTrailing.constant = -safeInset

    let estimatedTableWidth = tableWidth > 0 ? tableWidth : 320
    let bodyWidth = max(1, estimatedTableWidth - safeInset * 2 - 32 - (selecting ? 56 : 114))
    headerFlow.preferredWidth = bodyWidth
    var headerItems: [UIView] = [
      NeoRuleHeaderTitle(item.title),
      NeoRuleChip(text: item.enabled ? "有効" : "無効", style: item.enabled ? .primary : .standard),
      NeoRuleChip(text: "予約 " + String(max(0, item.reserveCount)), style: .outlined),
    ]
    if item.hasAnnict { headerItems.append(NeoRuleChip(text: "annict", style: .outlined)) }
    headerFlow.setItems(headerItems)

    ignoredLabel.text = item.ignoredKeyword.map { "除外: \($0)" }
    ignoredLabel.isHidden = item.ignoredKeyword == nil
    conditionsLabel.text = item.conditions
    conditionsLabel.isHidden = item.conditions.isEmpty
    encodeLabel.text = item.encodeSummary
    encodeLabel.isHidden = item.encodeSummary == nil || item.encodeSummary?.isEmpty == true

    selectionButton.isHidden = !selecting
    selectionButton.isEnabled = controlsEnabled
    selectionButton.setImage(NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank"), for: .normal)
    selectionButton.tintColor = selected ? NeoStyle.accent : NeoStyle.muted
    selectionButton.accessibilityIdentifier = "rules.select.\(item.id)"
    selectionButton.accessibilityLabel = "\(item.title)を選択"
    selectionButton.accessibilityValue = selected ? "選択中" : "未選択"
    selectionButton.accessibilityTraits = selected ? [.button, .selected] : [.button]

    controlsStack.isHidden = selecting
    toggle.isOn = item.enabled
    toggle.isEnabled = controlsEnabled && !selecting
    toggle.accessibilityIdentifier = "rules.toggle.\(item.id)"
    toggle.accessibilityLabel = "\(item.title)のルール有効"
    toggle.accessibilityValue = item.enabled ? "有効" : "無効"
    menuButton.isEnabled = controlsEnabled && !selecting
    menuButton.accessibilityIdentifier = "rules.menu.\(item.id)"
    menuButton.accessibilityLabel = "\(item.title)の操作"
    menuButton.accessibilityHint = "メニューを表示"

    card.layer.borderColor = selected ? NeoStyle.accent.cgColor : NeoStyle.border.cgColor
    card.backgroundColor = selected ? UIColor.white.withAlphaComponent(0.16) : NeoStyle.paper
    accessibilityIdentifier = "rules.card.\(item.id)"
    card.accessibilityIdentifier = "rules.card.\(item.id)"
    accessibilityLabel = item.title
    accessibilityHint = selecting ? (selected ? "選択を解除" : "選択") : nil
    setNeedsLayout()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onSelect = nil
    onToggle = nil
    onMenu = nil
    selecting = false
    controlsEnabled = false
    selectionButton.isHidden = true
    controlsStack.isHidden = false
    ignoredLabel.text = nil
    ignoredLabel.isHidden = true
    conditionsLabel.text = nil
    conditionsLabel.isHidden = true
    encodeLabel.text = nil
    encodeLabel.isHidden = true
    headerFlow.setItems([])
    accessibilityIdentifier = nil
    accessibilityLabel = nil
    card.accessibilityIdentifier = nil
  }

  @objc private func selectButtonPressed() {
    guard selecting, controlsEnabled else { return }
    onSelect?()
  }

  @objc private func toggleChanged() {
    guard controlsEnabled, !selecting else { return }
    onToggle?(toggle.isOn)
  }

  @objc private func menuPressed() {
    guard controlsEnabled, !selecting else { return }
    onMenu?(menuButton)
  }
}

/// Recreates the 58×38 Material UI switch used on the Web rule cards.
private final class NeoRuleEnableSwitch: UIControl {
  private let track = UIView(), thumb = UIView()
  var isOn = false {
    didSet {
      accessibilityValue = isOn ? "有効" : "無効"
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    track.layer.cornerRadius = 7
    thumb.layer.cornerRadius = 10
    thumb.layer.shadowOpacity = 0.24
    thumb.layer.shadowRadius = 1
    thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
    for item in [track, thumb] { item.isUserInteractionEnabled = false; addSubview(item) }
    isAccessibilityElement = true
    accessibilityTraits = .button
    addTarget(self, action: #selector(tapped), for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: CGSize { CGSize(width: 58, height: 38) }
  override var isEnabled: Bool { didSet { setNeedsLayout() } }

  override func layoutSubviews() {
    super.layoutSubviews()
    track.frame = CGRect(x: bounds.midX - 17, y: bounds.midY - 7, width: 34, height: 14)
    thumb.frame = CGRect(x: bounds.midX + (isOn ? 0 : -20), y: bounds.midY - 10, width: 20, height: 20)
    track.backgroundColor = (isOn ? NeoStyle.accent : .white).withAlphaComponent(isEnabled ? (isOn ? 0.5 : 0.3) : 0.2)
    if isOn {
      thumb.backgroundColor = isEnabled ? NeoStyle.accent : UIColor(red: 32/255 * 0.45, green: 168/255 * 0.45, blue: 154/255 * 0.45, alpha: 1)
    } else {
      thumb.backgroundColor = UIColor(white: isEnabled ? 224/255 : 117/255, alpha: 1)
    }
  }

  override func accessibilityActivate() -> Bool {
    guard isEnabled else { return false }
    tapped()
    return true
  }

  @objc private func tapped() {
    guard isEnabled else { return }
    isOn.toggle()
    sendActions(for: .valueChanged)
  }
}

private final class NeoRuleHeaderTitle: UILabel {
  override init(frame: CGRect) {
    super.init(frame: frame)
    textColor = .white
    font = .systemFont(ofSize: 16, weight: .bold)
    numberOfLines = 0
    lineBreakMode = .byWordWrapping
  }

  convenience init(_ text: String) {
    self.init(frame: .zero)
    self.text = text
  }

  required init?(coder: NSCoder) { fatalError() }
}

private final class NeoRuleChip: UILabel {
  enum Style { case primary, standard, outlined }
  private let inset: CGFloat

  init(text: String, style: Style) {
    inset = style == .outlined ? 7 : 8
    super.init(frame: .zero)
    self.text = text
    font = .systemFont(ofSize: 13)
    textAlignment = .center
    textColor = style == .primary ? NeoStyle.successText : .white
    switch style {
    case .primary: backgroundColor = NeoStyle.accent
    case .standard: backgroundColor = UIColor.white.withAlphaComponent(0.16)
    case .outlined: backgroundColor = .clear
    }
    layer.cornerRadius = 12
    layer.borderWidth = style == .outlined ? 1 : 0
    layer.borderColor = UIColor(white: 97/255, alpha: 1).cgColor
    clipsToBounds = true
    isAccessibilityElement = true
    accessibilityLabel = text
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: ceil(size.width) + inset * 2 + layer.borderWidth * 2, height: 24)
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.insetBy(dx: inset, dy: 0))
  }
}

private final class NeoRuleHeaderFlow: UIView {
  private(set) var items: [UIView] = []
  var preferredWidth: CGFloat = 0 {
    didSet {
      if abs(oldValue - preferredWidth) > 0.5 { invalidateIntrinsicContentSize() }
    }
  }

  private let itemSpacing: CGFloat = 8
  private let lineSpacing: CGFloat = 4
  private var lastHeight: CGFloat = 24

  func setItems(_ newItems: [UIView]) {
    items.forEach { $0.removeFromSuperview() }
    items = newItems
    items.forEach { addSubview($0) }
    lastHeight = measuredHeight(for: availableWidth)
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override var intrinsicContentSize: CGSize {
    let width = availableWidth
    guard width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: lastHeight) }
    return CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight(for: width))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = availableWidth
    guard width > 0 else { return }
    let height = layoutItems(in: width, applyingFrames: true)
    if abs(height - lastHeight) > 0.5 {
      lastHeight = height
      invalidateIntrinsicContentSize()
    }
  }

  private var availableWidth: CGFloat {
    let width = bounds.width > 0 ? bounds.width : preferredWidth
    return max(0, width)
  }

  private func measuredHeight(for width: CGFloat) -> CGFloat {
    guard width > 0, !items.isEmpty else { return items.isEmpty ? 0 : 24 }
    return layoutItems(in: width, applyingFrames: false)
  }

  private func layoutItems(in width: CGFloat, applyingFrames: Bool) -> CGFloat {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    let usableWidth = max(1, width)

    for item in items {
      let natural = item.intrinsicContentSize
      let itemWidth = min(usableWidth, max(1, natural.width))
      var itemHeight = max(1, natural.height)
      if let label = item as? NeoRuleHeaderTitle {
        itemHeight = max(1, label.sizeThatFits(CGSize(width: itemWidth, height: .greatestFiniteMagnitude)).height)
      }

      if x > 0, x + itemWidth > usableWidth {
        y += rowHeight + lineSpacing
        x = 0
        rowHeight = 0
      }
      if applyingFrames {
        item.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
      }
      x += itemWidth + itemSpacing
      rowHeight = max(rowHeight, itemHeight)
    }
    return max(0, y + rowHeight)
  }
}
