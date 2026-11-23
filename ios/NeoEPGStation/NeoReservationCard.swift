import UIKit

/// Self-sizing native counterpart of the Web ReservesPage ReserveCard.
///
/// The containing table owns row selection and reservation mutations. This
/// cell only presents the reservation and reports the menu anchor.
final class NeoReservationCard: UITableViewCell {
  private static let conflictColor = UIColor(red: 244 / 255, green: 67 / 255, blue: 54 / 255, alpha: 1)

  var onMenu: ((UIView) -> Void)?

  private let card = UIView()
  private let contentStack = UIStackView()
  private let selectionImage = UIImageView()
  private let bodyStack = UIStackView()
  private let headerFlow = NeoReservationHeaderFlow()
  private let titleLabel = NeoStyle.label(size: 16, bold: true)
  private let statusChip = NeoReservationChip()
  private let sourceChip = NeoReservationChip()
  private let channelLabel = NeoStyle.label(size: 14, muted: true)
  private let timeLabel = NeoStyle.label(size: 12, muted: true)
  private let summaryLabel = NeoStyle.label(size: 14)
  private let menuButton = UIButton(type: .system)
  private var editingMode = false

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

    selectionImage.contentMode = .scaleAspectFit
    selectionImage.isAccessibilityElement = false
    selectionImage.setContentHuggingPriority(.required, for: .horizontal)
    selectionImage.setContentCompressionResistancePriority(.required, for: .horizontal)
    selectionImage.widthAnchor.constraint(equalToConstant: 40).isActive = true
    selectionImage.heightAnchor.constraint(equalToConstant: 40).isActive = true
    contentStack.addArrangedSubview(selectionImage)

    titleLabel.numberOfLines = 0
    titleLabel.lineBreakMode = .byWordWrapping
    titleLabel.isAccessibilityElement = false
    channelLabel.numberOfLines = 0
    channelLabel.lineBreakMode = .byWordWrapping
    timeLabel.numberOfLines = 0
    timeLabel.lineBreakMode = .byWordWrapping
    summaryLabel.numberOfLines = 0
    summaryLabel.lineBreakMode = .byWordWrapping

    bodyStack.axis = .vertical
    bodyStack.alignment = .fill
    bodyStack.spacing = 4
    bodyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    bodyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    bodyStack.addArrangedSubview(headerFlow)
    bodyStack.addArrangedSubview(channelLabel)
    bodyStack.addArrangedSubview(timeLabel)
    bodyStack.addArrangedSubview(summaryLabel)
    bodyStack.setCustomSpacing(8, after: timeLabel)
    contentStack.addArrangedSubview(bodyStack)

    menuButton.setImage(NeoIcon.image("MoreVert"), for: .normal)
    menuButton.tintColor = .white
    menuButton.accessibilityIdentifier = "reserves.menu"
    menuButton.accessibilityLabel = "予約の操作"
    menuButton.accessibilityHint = "メニューを表示"
    menuButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
    menuButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
    menuButton.addTarget(self, action: #selector(menuPressed), for: .touchUpInside)
    contentStack.addArrangedSubview(menuButton)

    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      card.topAnchor.constraint(equalTo: contentView.topAnchor),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
    ])

    headerFlow.setItems([titleLabel, sourceChip])
    summaryLabel.isHidden = true
    selectionImage.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  func configure(
    title: String,
    source: String,
    status: String?,
    conflict: Bool,
    subdued: Bool,
    channel: String,
    time: String,
    summary: String?,
    editing: Bool,
    selected: Bool
  ) {
    editingMode = editing
    titleLabel.text = title
    channelLabel.text = channel
    timeLabel.text = time
    summaryLabel.text = summary
    summaryLabel.isHidden = summary == nil || summary?.isEmpty == true

    statusChip.configure(text: status, style: conflict ? .conflict : .standard)
    sourceChip.configure(text: source.isEmpty ? nil : source, style: .outlined)
    var headerItems: [UIView] = [titleLabel]
    if let status, !status.isEmpty { headerItems.append(statusChip) }
    if !source.isEmpty { headerItems.append(sourceChip) }
    headerFlow.setItems(headerItems)

    selectionImage.isHidden = !editing
    selectionImage.image = NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank")
    selectionImage.tintColor = selected ? NeoStyle.accent : NeoStyle.muted
    menuButton.isHidden = editing
    menuButton.isEnabled = !editing

    card.layer.borderColor = conflict ? Self.conflictColor.cgColor : selected ? NeoStyle.accent.cgColor : NeoStyle.border.cgColor
    card.backgroundColor = selected ? UIColor.white.withAlphaComponent(0.16)
      : subdued ? UIColor.white.withAlphaComponent(0.12) : NeoStyle.paper

    let accessibilityParts: [String] = [title, status, source, channel, time, summary].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    accessibilityIdentifier = "reserves.card"
    accessibilityLabel = accessibilityParts.joined(separator: "、")
    accessibilityValue = editing ? (selected ? "選択中" : "未選択") : nil
    accessibilityHint = editing ? (selected ? "選択を解除" : "選択") : "予約の詳細を表示"
    setNeedsLayout()
  }

  override func layoutSubviews() {
    updateHeaderWidth(for: contentView.bounds.width)
    super.layoutSubviews()
  }

  override func systemLayoutSizeFitting(
    _ targetSize: CGSize,
    withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
    verticalFittingPriority: UILayoutPriority
  ) -> CGSize {
    updateHeaderWidth(for: targetSize.width)
    return super.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: horizontalFittingPriority,
      verticalFittingPriority: verticalFittingPriority
    )
  }

  private func updateHeaderWidth(for totalWidth: CGFloat) {
    let width = totalWidth > 0 ? totalWidth : contentView.bounds.width
    let visibleSideCount = (selectionImage.isHidden ? 0 : 1) + (menuButton.isHidden ? 0 : 1)
    let cardWidth = max(0, width - 24)
    let bodyWidth = cardWidth - 32 - CGFloat(visibleSideCount * 40) - CGFloat(visibleSideCount * 12)
    headerFlow.preferredWidth = max(1, bodyWidth)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onMenu = nil
    editingMode = false
    titleLabel.text = nil
    channelLabel.text = nil
    timeLabel.text = nil
    summaryLabel.text = nil
    summaryLabel.isHidden = true
    statusChip.configure(text: nil, style: .standard)
    sourceChip.configure(text: nil, style: .outlined)
    headerFlow.setItems([])
    selectionImage.image = nil
    selectionImage.isHidden = true
    menuButton.isHidden = false
    menuButton.isEnabled = false
    card.layer.borderColor = NeoStyle.border.cgColor
    card.backgroundColor = NeoStyle.paper
    accessibilityIdentifier = nil
    accessibilityLabel = nil
    accessibilityValue = nil
    accessibilityHint = nil
  }

  @objc private func menuPressed() {
    guard !editingMode else { return }
    onMenu?(menuButton)
  }
}

private final class NeoReservationChip: UILabel {
  enum Style { case conflict, standard, outlined }

  private var horizontalInset: CGFloat = 7

  func configure(text: String?, style: Style) {
    self.text = text
    isHidden = text == nil || text?.isEmpty == true
    isAccessibilityElement = !isHidden
    accessibilityLabel = text
    horizontalInset = style == .outlined ? 7 : 8
    textAlignment = .center
    font = .systemFont(ofSize: 13)
    textColor = .white
    switch style {
    case .conflict:
      backgroundColor = UIColor(red: 244 / 255, green: 67 / 255, blue: 54 / 255, alpha: 1)
      layer.borderWidth = 0
    case .standard:
      backgroundColor = UIColor.white.withAlphaComponent(0.16)
      layer.borderWidth = 0
    case .outlined:
      backgroundColor = .clear
      layer.borderWidth = 1
      layer.borderColor = UIColor(white: 97 / 255, alpha: 1).cgColor
    }
    layer.cornerRadius = 12
    clipsToBounds = true
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: ceil(size.width) + horizontalInset * 2 + layer.borderWidth * 2, height: 24)
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.insetBy(dx: horizontalInset, dy: 0))
  }
}

private final class NeoReservationHeaderFlow: UIView {
  private(set) var items: [UIView] = []
  var preferredWidth: CGFloat = 0 {
    didSet {
      if abs(oldValue - preferredWidth) > 0.5 {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
      }
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
      let itemHeight: CGFloat
      if let label = item as? UILabel {
        itemHeight = max(1, label.sizeThatFits(CGSize(width: itemWidth, height: .greatestFiniteMagnitude)).height)
      } else {
        itemHeight = max(1, natural.height)
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
