import UIKit

/// The compact row used by RecordingPage while a program is being recorded.
///
/// Keep the drop-log slot in the layout even when there is no response yet.  The
/// active-recording page polls that value, and changing only the text must not
/// change the row's height or move the table's scroll position.
final class NeoActiveRecordingCard: UITableViewCell {
  var onMenu: ((UIView) -> Void)?

  private static let verticalPadding: CGFloat = 12
  private static let badgeHeight: CGFloat = 22

  private let card = UIView()
  private let thumbnail = NeoThumbnail()
  private let body = UIStackView()
  private let title = NeoStyle.label(size: 15, bold: true)
  private let channelLabel = NeoStyle.label(size: 12, muted: true)
  private let timeLabel = NeoStyle.label(size: 12, muted: true)
  private let summaryLabel = NeoStyle.label(size: 13)
  private let summarySlot = UIView()
  private let dropLabel = NeoStyle.label(size: 12)
  private let dropSlot = UIView()
  private let recordingBadge = NeoStyle.label("録画中", size: 11, bold: true)
  private let editCheck = UIImageView()
  private let menuButton: UIButton
  private var thumbnailWidth: NSLayoutConstraint!
  private var compactActions: [NSLayoutConstraint] = []
  private var wideActions: [NSLayoutConstraint] = []
  private var isWide = false
  private var isSelectedCard = false

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    menuButton = UIButton(type: .system)
    super.init(style: style, reuseIdentifier: reuseIdentifier)

    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = NeoStyle.paper
    card.layer.cornerRadius = 6
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor
    card.clipsToBounds = true
    contentView.addSubview(card)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
    ])

    thumbnail.translatesAutoresizingMaskIntoConstraints = false
    thumbnail.backgroundColor = .black
    thumbnail.contentMode = .scaleAspectFill
    card.addSubview(thumbnail)
    thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: 120)
    NSLayoutConstraint.activate([
      thumbnail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
      thumbnail.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      thumbnail.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: Self.verticalPadding),
      thumbnailWidth,
      thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9 / 16)
    ])

    body.translatesAutoresizingMaskIntoConstraints = false
    body.axis = .vertical
    body.alignment = .fill
    body.distribution = .fill
    body.spacing = 4
    card.addSubview(body)
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
      body.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.verticalPadding),
      body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.verticalPadding)
    ])

    title.numberOfLines = 1
    channelLabel.numberOfLines = 1
    timeLabel.numberOfLines = 1
    summaryLabel.numberOfLines = 1
    dropLabel.numberOfLines = 1
    dropLabel.adjustsFontSizeToFitWidth = true
    dropLabel.minimumScaleFactor = 0.8
    dropLabel.accessibilityIdentifier = "recording.drop"
    dropSlot.translatesAutoresizingMaskIntoConstraints = false
    dropLabel.translatesAutoresizingMaskIntoConstraints = false
    dropSlot.addSubview(dropLabel)
    NSLayoutConstraint.activate([
      dropSlot.heightAnchor.constraint(equalToConstant: 18),
      dropLabel.leadingAnchor.constraint(equalTo: dropSlot.leadingAnchor),
      dropLabel.trailingAnchor.constraint(equalTo: dropSlot.trailingAnchor),
      dropLabel.topAnchor.constraint(equalTo: dropSlot.topAnchor),
      dropLabel.bottomAnchor.constraint(equalTo: dropSlot.bottomAnchor)
    ])

    body.addArrangedSubview(title)
    body.addArrangedSubview(channelLabel)
    body.addArrangedSubview(timeLabel)
    body.addArrangedSubview(dropSlot)
    summaryLabel.translatesAutoresizingMaskIntoConstraints = false
    summarySlot.addSubview(summaryLabel)
    NSLayoutConstraint.activate([
      summarySlot.heightAnchor.constraint(equalToConstant: 17),
      summaryLabel.leadingAnchor.constraint(equalTo: summarySlot.leadingAnchor),
      summaryLabel.topAnchor.constraint(equalTo: summarySlot.topAnchor),
      summaryLabel.bottomAnchor.constraint(equalTo: summarySlot.bottomAnchor)
    ])
    body.addArrangedSubview(summarySlot)

    recordingBadge.textAlignment = .center
    recordingBadge.textColor = .white
    recordingBadge.backgroundColor = NeoStyle.error
    recordingBadge.layer.cornerRadius = Self.badgeHeight / 2
    recordingBadge.clipsToBounds = true
    recordingBadge.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(recordingBadge)

    menuButton.translatesAutoresizingMaskIntoConstraints = false
    menuButton.setImage(NeoIcon.image("BookEditOutline"), for: .normal)
    menuButton.tintColor = .white
    menuButton.accessibilityLabel = "録画操作"
    menuButton.accessibilityIdentifier = "recording.card.menu"
    menuButton.imageView?.transform = CGAffineTransform(scaleX: 20 / 24, y: 20 / 24)
    menuButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.onMenu?(self.menuButton)
    }, for: .touchUpInside)
    card.addSubview(menuButton)
    NSLayoutConstraint.activate([
      menuButton.widthAnchor.constraint(equalToConstant: 32),
      menuButton.heightAnchor.constraint(equalToConstant: 32),
      recordingBadge.widthAnchor.constraint(equalToConstant: 54),
      recordingBadge.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
      body.heightAnchor.constraint(greaterThanOrEqualToConstant: 82)
    ])
    compactActions = [
      body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
      summaryLabel.trailingAnchor.constraint(equalTo: summarySlot.trailingAnchor, constant: -88),
      menuButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
      menuButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
      recordingBadge.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2),
      recordingBadge.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor)
    ]
    wideActions = [
      body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -76),
      summaryLabel.trailingAnchor.constraint(equalTo: summarySlot.trailingAnchor),
      recordingBadge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
      recordingBadge.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
      menuButton.centerXAnchor.constraint(equalTo: recordingBadge.centerXAnchor),
      menuButton.topAnchor.constraint(equalTo: recordingBadge.bottomAnchor, constant: 1)
    ]
    NSLayoutConstraint.activate(compactActions)

    editCheck.translatesAutoresizingMaskIntoConstraints = false
    editCheck.isUserInteractionEnabled = false
    editCheck.contentMode = .center
    editCheck.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    editCheck.layer.cornerRadius = 15
    editCheck.clipsToBounds = true
    editCheck.isHidden = true
    card.addSubview(editCheck)
    NSLayoutConstraint.activate([
      editCheck.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
      editCheck.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
      editCheck.widthAnchor.constraint(equalToConstant: 30),
      editCheck.heightAnchor.constraint(equalToConstant: 30)
    ])

    accessibilityTraits = .button
    card.accessibilityIdentifier = "recording.card"
    updateAppearance()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    let wide = contentView.bounds.width >= 600
    if wide != isWide {
      NSLayoutConstraint.deactivate(isWide ? wideActions : compactActions)
      isWide = wide
      thumbnailWidth.constant = wide ? 180 : 120
      NSLayoutConstraint.activate(wide ? wideActions : compactActions)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    thumbnail.load(nil)
    thumbnail.contentMode = .scaleAspectFill
    title.text = nil
    channelLabel.text = nil
    timeLabel.text = nil
    summaryLabel.text = nil
    dropLabel.text = nil
    dropLabel.accessibilityValue = nil
    onMenu = nil
    isSelectedCard = false
    recordingBadge.isHidden = false
    menuButton.isHidden = false
    editCheck.isHidden = true
    updateAppearance()
  }

  /// Configures the row without changing the table's data source or its height.
  func configure(_ item: NeoRecording, channel: String, logoURL: URL?, api: NeoAPI?, editing: Bool, selected: Bool) {
    title.text = item.name
    channelLabel.text = channel
    timeLabel.text = NeoProgramText.interval(start: item.startAt, end: item.endAt, japaneseDuration: true)
    summaryLabel.text = (item.description ?? item.extended)?.replacingOccurrences(of: "\n", with: " ")
    recordingBadge.isHidden = !item.isRecording
    updateSelection(editing: editing, selected: selected)

    let thumbnailURL = item.thumbnails?.first.flatMap { api?.url("/thumbnails/\($0)") }
    let imageURL = thumbnailURL ?? logoURL
    thumbnail.contentMode = thumbnailURL == nil ? .scaleAspectFit : .scaleAspectFill
    thumbnail.load(imageURL, fadeIn: false)
    updateDrop(item.dropLogFile)
    updateAppearance()
    accessibilityIdentifier = "recording.card.\(item.id)"
    accessibilityLabel = "\(item.name)、\(channel)、\(timeLabel.text ?? "")"
    accessibilityValue = item.isRecording ? "録画中" : nil
    setNeedsLayout()
  }

  /// Changes only the selection affordance.  The page can call this for visible
  /// cells without reloading the thumbnail or replacing the text content.
  func updateSelection(editing: Bool, selected: Bool) {
    isSelectedCard = selected
    menuButton.isHidden = editing
    editCheck.isHidden = !editing
    editCheck.image = NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank")
    editCheck.tintColor = selected ? NeoStyle.accent : UIColor.white.withAlphaComponent(0.7)
    updateAppearance()
  }

  /// Updates only the fixed-height drop-log slot.  No stack item is inserted or
  /// removed, so a polling response cannot alter the table row geometry.
  func updateDrop(_ value: NeoDropLog?) {
    guard let value else {
      dropLabel.text = nil
      dropLabel.textColor = NeoStyle.muted
      dropLabel.accessibilityValue = nil
      return
    }
    dropLabel.text = "drop: \(value.dropCnt) / error: \(value.errorCnt) / scrambling: \(value.scramblingCnt)"
    dropLabel.textColor = value.hasErrors ? NeoStyle.error : NeoStyle.muted
    dropLabel.accessibilityValue = dropLabel.text
  }

  private func updateAppearance() {
    card.layer.borderWidth = isSelectedCard ? 2 : 1
    card.layer.borderColor = (isSelectedCard ? NeoStyle.accent : NeoStyle.border).cgColor
    if isSelectedCard { accessibilityTraits.insert(.selected) }
    else { accessibilityTraits.remove(.selected) }
  }
}
