import UIKit

/// Read-only program information used by search results and the mobile guide.
///
/// The presenter owns the selected program and navigation.  This controller
/// only renders the program, dismisses itself, and reports a related-search
/// request through `onRelatedSearch`.
final class NeoProgramDetailDialog: UIViewController, UIGestureRecognizerDelegate, UITextViewDelegate {
  private let program: NeoScheduledProgram
  private let channel: NeoLiveChannel?
  private let logoURL: URL?
  private let reservationLabel: String?
  private let reservationConflict: Bool
  private var reservationUsers: [String]
  private let alwaysShowBroadcastDetails: Bool
  private let onRelatedSearch: () -> Void

  private let card = UIView()
  private let titleLabel = NeoStyle.dialogTitle("")
  private lazy var closeButton = NeoStyle.iconButton("Close", label: "閉じる") { [weak self] in self?.close() }
  private let bodyScroll = UIScrollView()
  private let bodyContent = UIView()
  private let broadcastView: NeoProgramBroadcastView
  private var textViews: [UITextView] = []
  private let reservationScroll = UIScrollView()
  private let reservationView = NeoProgramChipWrap()
  private lazy var searchButton: UIButton = {
    let button = NeoStyle.button("検索", action: { [weak self] in self?.searchRelated() })
    button.setImage(NeoIcon.image("SearchOutlined"), for: .normal)
    button.tintColor = NeoStyle.accent
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    button.contentHorizontalAlignment = .left
    button.imageView?.contentMode = .scaleAspectFit
    button.accessibilityLabel = "関連番組を検索"
    return button
  }()
  private lazy var footerCloseButton: UIButton = {
    let button = NeoStyle.button("閉じる", action: { [weak self] in self?.close() })
    button.tintColor = .white
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    button.accessibilityLabel = "閉じる"
    return button
  }()
  private let headerLine = UIView()
  private let reservationLine = UIView()
  private let footerLine = UIView()
  private var closeRequested = false

  init(
    program: NeoScheduledProgram,
    channel: NeoLiveChannel?,
    logoURL: URL?,
    reservationLabel: String?,
    reservationConflict: Bool,
    reservationUsers: [String],
    alwaysShowBroadcastDetails: Bool,
    onRelatedSearch: @escaping () -> Void
  ) {
    self.program = program
    self.channel = channel
    self.logoURL = logoURL
    self.reservationLabel = reservationLabel
    self.reservationConflict = reservationConflict
    self.reservationUsers = reservationUsers
    self.alwaysShowBroadcastDetails = alwaysShowBroadcastDetails
    self.onRelatedSearch = onRelatedSearch

    let data = NeoProgramDetailData(
      channelName: channel?.name ?? String(program.channelId),
      logoURL: logoURL,
      startAt: program.startAt,
      endAt: program.endAt,
      genreLabels: program.genreLabels,
      videoType: Self.videoTypeLabel(program.videoType),
      videoResolution: program.videoResolution,
      audioSamplingRate: Self.audioSamplingRateLabel(program.audioSamplingRate),
      audioComponentType: Self.audioComponentLabel(program.audioComponentType),
      initiallyExpanded: alwaysShowBroadcastDetails
    )
    broadcastView = NeoProgramBroadcastView(data: data)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
    modalPresentationCapturesStatusBarAppearance = true
    broadcastView.onToggle = { [weak self] in
      guard let self else { return }
      UIView.animate(withDuration: 0.18) {
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Replaces the read-only reservation user chips after an asynchronous user
  /// lookup.  The dialog can therefore open with a loading/error label and be
  /// updated without rebuilding or losing its expanded details and scroll
  /// position.
  func updateReservationUsers(_ labels: [String]) {
    reservationUsers = labels
    guard isViewLoaded else { return }
    let offset = bodyScroll.contentOffset
    reservationView.entries = Self.reservationChips(label: reservationLabel, conflict: reservationConflict, users: labels)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    bodyScroll.setContentOffset(offset, animated: false)
  }

  override func loadView() {
    view = UIView()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    view.isAccessibilityElement = false
    view.accessibilityViewIsModal = true

    card.backgroundColor = NeoStyle.paper
    card.layer.cornerRadius = 12
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.35
    card.layer.shadowRadius = 28
    card.layer.shadowOffset = CGSize(width: 0, height: 16)
    card.clipsToBounds = false

    titleLabel.attributedText = NeoStyle.dialogTitle(program.name).attributedText
    titleLabel.numberOfLines = 0
    titleLabel.accessibilityTraits = .header
    titleLabel.accessibilityLabel = program.name

    closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    closeButton.tintColor = NeoStyle.muted
    closeButton.layer.cornerRadius = 18
    closeButton.accessibilityIdentifier = "program-detail-close"

    bodyScroll.backgroundColor = .clear
    bodyScroll.alwaysBounceVertical = true
    bodyScroll.showsVerticalScrollIndicator = true
    bodyScroll.showsHorizontalScrollIndicator = false
    bodyScroll.delaysContentTouches = false
    bodyScroll.addSubview(bodyContent)
    bodyContent.backgroundColor = .clear

    headerLine.backgroundColor = NeoStyle.border
    reservationLine.backgroundColor = NeoStyle.border
    footerLine.backgroundColor = NeoStyle.border

    reservationView.entries = Self.reservationChips(
      label: reservationLabel,
      conflict: reservationConflict,
      users: reservationUsers
    )
    reservationView.accessibilityIdentifier = "program-detail-reservations"
    reservationScroll.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    reservationScroll.addSubview(reservationView)

    view.addSubview(card)
    [titleLabel, closeButton, bodyScroll, broadcastView, headerLine, reservationScroll, reservationLine, searchButton, footerCloseButton, footerLine].forEach(card.addSubview)

    makeTextViews()

    let tap = UITapGestureRecognizer(target: self, action: #selector(tappedBackground(_:)))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    view.addGestureRecognizer(tap)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutDialog()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard let touchedView = touch.view else { return true }
    // The recognizer is only for the dimmed area.  Let scroll views, links,
    // buttons, and the expandable details control receive their own touches.
    return !touchedView.isDescendant(of: card)
  }

  func textView(
    _ textView: UITextView,
    shouldInteractWith URL: URL,
    in characterRange: NSRange,
    interaction: UITextItemInteraction
  ) -> Bool {
    if let scheme = URL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
      UIApplication.shared.open(URL)
    }
    return false
  }

  private func makeTextViews() {
    textViews.removeAll()
    let values: [(String, Bool)] = [
      (program.description ?? "", false),
      (program.extended ?? "", true)
    ].filter { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    for (text, extended) in values {
      let textView = Self.makeTextView(text, extended: extended)
      textView.delegate = self
      textViews.append(textView)
      bodyContent.addSubview(textView)
    }
  }

  private func layoutDialog() {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }

    let wide = view.bounds.width >= 600
    let horizontalInset: CGFloat = wide ? 24 : 16
    let screenInset: CGFloat = wide ? 32 : 12
    let cardWidth = min(640, max(0, view.bounds.width - screenInset * 2))
    let titleWidth = max(0, cardWidth - horizontalInset - (wide ? 64 : 56))
    let titleSize = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude))
    let titleBottom: CGFloat = titleSize.height <= 30.5 ? 12 : 8
    let headerHeight = 12 + titleSize.height + titleBottom
    let footerHeight: CGFloat = 60

    let safeTop = view.safeAreaInsets.top
    let safeBottom = view.safeAreaInsets.bottom
    let availableHeight = max(200, view.bounds.height - safeTop - safeBottom - 24)
    let heightCap = min(820, view.bounds.height * 0.92, availableHeight)
    let broadcastHeight = broadcastView.sizeThatFits(CGSize(width: cardWidth, height: .greatestFiniteMagnitude)).height
    let bodyNaturalHeight = layoutBody(width: cardWidth, horizontalInset: horizontalInset)
    let chipWidth = max(0, cardWidth - horizontalInset * 2)
    let chipHeight = reservationView.sizeThatFits(CGSize(width: chipWidth, height: .greatestFiniteMagnitude)).height
    let reservationHeight = reservationView.entries.isEmpty ? 0 : min(chipHeight + 16, max(48, heightCap / 4))
    let desiredHeight = headerHeight + broadcastHeight + bodyNaturalHeight + reservationHeight + footerHeight
    let cardHeight = min(heightCap, max(200, desiredHeight))
    let x = (view.bounds.width - cardWidth) / 2
    let centeredY = (view.bounds.height - cardHeight) / 2
    let y = max(safeTop + 12, min(centeredY, view.bounds.height - safeBottom - cardHeight - 12))
    card.frame = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)

    titleLabel.frame = CGRect(x: horizontalInset, y: 12, width: titleWidth, height: titleSize.height)
    let closeInset: CGFloat = wide ? 16 : 12
    closeButton.frame = CGRect(x: cardWidth - closeInset - 36, y: titleSize.height <= 30.5 ? 9 : 11, width: 36, height: 36)
    headerLine.frame = CGRect(x: 0, y: headerHeight - 1, width: cardWidth, height: 1)

    broadcastView.frame = CGRect(x: 0, y: headerHeight, width: cardWidth, height: broadcastHeight)
    let bodyY = headerHeight + broadcastHeight
    let bodyHeight = max(0, cardHeight - bodyY - reservationHeight - footerHeight)
    bodyScroll.frame = CGRect(x: 0, y: bodyY, width: cardWidth, height: bodyHeight)
    bodyScroll.contentSize = CGSize(width: cardWidth, height: bodyNaturalHeight)
    bodyScroll.isScrollEnabled = bodyNaturalHeight > bodyHeight + 0.5

    reservationScroll.isHidden = reservationHeight == 0
    if reservationHeight > 0 {
      let reservationY = cardHeight - footerHeight - reservationHeight
      reservationLine.frame = CGRect(x: 0, y: reservationY, width: cardWidth, height: 1)
      reservationScroll.frame = CGRect(x: 0, y: reservationY, width: cardWidth, height: reservationHeight)
      reservationView.frame = CGRect(x: horizontalInset, y: 8, width: chipWidth, height: chipHeight)
      reservationScroll.contentSize = CGSize(width: cardWidth, height: chipHeight + 16)
      reservationScroll.isScrollEnabled = chipHeight + 16 > reservationHeight
    } else {
      reservationLine.frame = .zero
      reservationView.frame = .zero
    }

    let footerY = cardHeight - footerHeight
    footerLine.frame = CGRect(x: 0, y: footerY, width: cardWidth, height: 1)
    searchButton.frame = CGRect(x: horizontalInset, y: footerY + 9, width: max(80, cardWidth - horizontalInset * 2 - 92), height: 42)
    footerCloseButton.frame = CGRect(x: cardWidth - horizontalInset - 76, y: footerY + 9, width: 76, height: 42)
  }

  private func layoutBody(width: CGFloat, horizontalInset: CGFloat) -> CGFloat {
    var y: CGFloat = textViews.isEmpty ? 0 : 12
    let textWidth = max(0, width - horizontalInset * 2)
    for (index, textView) in textViews.enumerated() {
      let textHeight = max(22, textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
      textView.frame = CGRect(x: horizontalInset, y: y, width: textWidth, height: textHeight)
      y += textHeight
      if index + 1 < textViews.count { y += 16 }
    }
    if !textViews.isEmpty { y += 12 }
    bodyContent.frame = CGRect(x: 0, y: 0, width: width, height: max(1, y))
    return max(1, y)
  }

  private func close() {
    guard !closeRequested else { return }
    closeRequested = true
    dismiss(animated: true)
  }

  private func searchRelated() {
    guard !closeRequested else { return }
    closeRequested = true
    let callback = onRelatedSearch
    dismiss(animated: true) { callback() }
  }

  @objc private func tappedBackground(_ gesture: UITapGestureRecognizer) {
    // The gesture delegate filters card descendants, but retaining this guard
    // also protects against a changed view hierarchy or synthetic test taps.
    guard !card.frame.contains(gesture.location(in: view)) else { return }
    close()
  }

  private static func makeTextView(_ text: String, extended: Bool) -> UITextView {
    let value = UITextView()
    value.backgroundColor = .clear
    value.textColor = .white
    value.font = .systemFont(ofSize: 16)
    value.isEditable = false
    value.isSelectable = true
    value.isScrollEnabled = false
    value.textContainerInset = .zero
    value.textContainer.lineFragmentPadding = 0
    value.linkTextAttributes = [
      .foregroundColor: NeoStyle.accent,
      .underlineStyle: NSUnderlineStyle.single.rawValue
    ]
    value.attributedText = attributedProgramText(text, extended: extended)
    return value
  }

  private static func attributedProgramText(_ text: String, extended: Bool) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 28.8
    paragraph.lineBreakMode = .byCharWrapping
    let result = NSMutableAttributedString(string: text, attributes: [
      .font: UIFont.systemFont(ofSize: 16),
      .foregroundColor: UIColor.white,
      .paragraphStyle: paragraph
    ])

    if extended {
      let lines = text.components(separatedBy: "\n")
      var offset = 0
      for line in lines {
        let lineLength = (line as NSString).length
        if line.hasPrefix("◇") || line.hasPrefix("◆") {
          let headerParagraph = NSMutableParagraphStyle()
          headerParagraph.minimumLineHeight = 28.8
          headerParagraph.paragraphSpacingBefore = 8
          headerParagraph.lineBreakMode = .byCharWrapping
          let range = NSRange(location: offset, length: lineLength)
          result.addAttributes([
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .paragraphStyle: headerParagraph
          ], range: range)
        }
        offset += lineLength + 1
      }
    }

    let detector = try? NSRegularExpression(pattern: #"https?://[!-~]+"#, options: .caseInsensitive)
    let fullRange = NSRange(location: 0, length: result.length)
    detector?.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
      guard let range = match?.range, let url = URL(string: (text as NSString).substring(with: range)) else { return }
      result.addAttribute(.link, value: url, range: range)
    }
    return result
  }

  private static func reservationChips(label: String?, conflict: Bool, users: [String]) -> [NeoProgramChipWrap.Chip] {
    var result: [NeoProgramChipWrap.Chip] = []
    if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
      result.append(.init(
        text: label,
        fill: conflict ? UIColor(red: 1, green: 82 / 255, blue: 82 / 255, alpha: 1) : NeoStyle.accent,
        textColor: NeoStyle.successText,
        border: nil
      ))
    }
    for user in users {
      let value = user.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { continue }
      result.append(.init(text: value, fill: .clear, textColor: .white, border: UIColor.white.withAlphaComponent(0.23)))
    }
    return result
  }

  private static func videoTypeLabel(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    switch value.lowercased() {
    case "mpeg2", "mpeg-2", "mpeg_2": return "MPEG-2"
    case "h.264", "h264", "avc": return "H.264"
    case "h.265", "h265", "hevc": return "H.265"
    default: return value
    }
  }

  private static func audioComponentLabel(_ value: Int?) -> String? {
    guard let value else { return nil }
    let labels: [Int: String] = [
      0x01: "1/0モード（モノラル）", 0x02: "1/0＋1/0モード（デュアルモノ）", 0x03: "2/0モード（ステレオ）",
      0x04: "2/1モード", 0x05: "3/0モード", 0x06: "2/2モード", 0x07: "3/1モード", 0x08: "3/2モード",
      0x09: "3/2＋LFEモード（5.1ch）", 0x0a: "3/3.1モード", 0x0b: "2/0/0-2/0/2-0.1モード",
      0x0c: "5/2.1モード", 0x0d: "3/2/2.1モード", 0x0e: "2/0/0-3/0/2-0.1モード",
      0x0f: "0/2/0-3/0/2-0.1モード", 0x10: "2/0/0-3/2/3-0.2モード", 0x11: "3/3/3-5/2/3-3/0/0.2モード"
    ]
    return labels[value] ?? String(format: "音声モード 0x%02x", value)
  }

  private static func audioSamplingRateLabel<T>(_ value: T?) -> String? {
    guard let value else { return nil }
    if let number = value as? NSNumber {
      return samplingRateText(number.doubleValue)
    }
    let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !string.isEmpty else { return nil }
    let lower = string.lowercased()
    if lower.hasSuffix("khz"), let number = Double(lower.dropLast(3)) {
      return samplingRateText(number)
    }
    if lower.hasSuffix("hz"), let number = Double(lower.dropLast(2)) {
      return samplingRateText(number)
    }
    guard let number = Double(string) else { return string }
    return samplingRateText(number)
  }

  private static func samplingRateText(_ value: Double) -> String? {
    guard value.isFinite, value > 0 else { return nil }
    let kiloHertz = value >= 1000 ? value / 1000 : value
    let formatted = kiloHertz.rounded() == kiloHertz ? String(format: "%.0f", kiloHertz) : String(format: "%.2f", kiloHertz).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    return formatted + "kHz"
  }
}

private struct NeoProgramDetailData {
  let channelName: String
  let logoURL: URL?
  let startAt: Double
  let endAt: Double
  let genreLabels: [String]
  let videoType: String?
  let videoResolution: String?
  let audioSamplingRate: String?
  let audioComponentType: String?
  let initiallyExpanded: Bool
}

private final class NeoProgramBroadcastView: UIView {
  private let data: NeoProgramDetailData
  private let logo = NeoThumbnail()
  private let station = NeoStyle.label(size: 14, bold: true)
  private let timeIcon = UIImageView(image: NeoIcon.image("ScheduleOutlined"))
  private let date = NeoStyle.label(size: 14, muted: true)
  private let duration = NeoStyle.label(size: 12, muted: true)
  private let toggle = UIButton(type: .system)
  private let separator = UIView()
  private var detailRows: [(UIImageView, UILabel, UILabel)] = []
  private(set) var expanded: Bool
  var onToggle: (() -> Void)?

  init(data: NeoProgramDetailData) {
    self.data = data
    expanded = data.initiallyExpanded
    super.init(frame: .zero)
    backgroundColor = .clear
    station.text = data.channelName
    station.numberOfLines = 1
    station.lineBreakMode = .byTruncatingTail
    date.numberOfLines = 1
    duration.numberOfLines = 1
    timeIcon.tintColor = NeoStyle.muted
    timeIcon.contentMode = .scaleAspectFit
    logo.backgroundColor = .clear
    logo.contentMode = .scaleAspectFit
    logo.isHidden = data.logoURL == nil
    if let logoURL = data.logoURL { logo.load(logoURL) }

    toggle.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    toggle.tintColor = NeoStyle.muted
    toggle.accessibilityTraits = .button
    toggle.addAction(UIAction { [weak self] _ in self?.toggleDetails() }, for: .touchUpInside)
    refreshToggleAccessibility()

    separator.backgroundColor = NeoStyle.border
    addSubview(logo); addSubview(station); addSubview(timeIcon); addSubview(date); addSubview(duration); addSubview(toggle); addSubview(separator)
    makeDetailRows()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    CGSize(width: size.width, height: height(for: size.width))
  }

  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height(for: bounds.width)) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    guard width > 0 else { return }
    let inset: CGFloat = width >= 600 ? 24 : 16
    let right = width - inset
    let toggleX = right - 36
    let compact = width < 600
    let stationY: CGFloat = 8
    let stationHeight: CGFloat = 32
    let logoX = inset
    if !logo.isHidden { logo.frame = CGRect(x: logoX, y: stationY, width: 48, height: 32) }
    let stationX = logo.isHidden ? inset : logoX + 60
    station.frame = CGRect(x: stationX, y: stationY + 6, width: max(0, toggleX - stationX - 8), height: 22)
    toggle.frame = CGRect(x: toggleX, y: 6, width: 36, height: 36)

    let timeY: CGFloat
    if compact {
      timeY = stationY + stationHeight + 5
    } else {
      let stationEnd = stationX + min(station.intrinsicContentSize.width, max(0, toggleX - stationX - 8))
      timeY = stationY + 6
      let timeX = min(toggleX - 170, stationEnd + 16)
      timeIcon.frame = CGRect(x: max(inset, timeX), y: timeY, width: 18, height: 18)
      date.frame = CGRect(x: timeIcon.frame.maxX + 6, y: timeY, width: max(0, toggleX - timeIcon.frame.maxX - 60), height: 20)
      duration.frame = CGRect(x: toggleX - 50, y: timeY + 1, width: 50, height: 18)
    }
    if compact {
      timeIcon.frame = CGRect(x: inset, y: timeY, width: 18, height: 18)
      let dateX = timeIcon.frame.maxX + 4
      let durationWidth = ceil(duration.intrinsicContentSize.width)
      let dateWidth = min(ceil(date.intrinsicContentSize.width), max(0, right - dateX - durationWidth - 4))
      date.frame = CGRect(x: dateX, y: timeY, width: dateWidth, height: 20)
      duration.frame = CGRect(x: date.frame.maxX + 4, y: timeY + 1, width: durationWidth, height: 18)
    }

    if expanded {
      let detailsTop = compact ? timeY + 27 : stationY + stationHeight + 8
      separator.frame = CGRect(x: inset, y: detailsTop, width: max(0, width - inset * 2), height: 1)
      var y = detailsTop + 9
      let valueX = inset + 24 + 56 + 8
      let valueWidth = max(0, width - inset - valueX)
      for (icon, title, value) in detailRows {
        let valueHeight = max(20, value.sizeThatFits(CGSize(width: valueWidth, height: .greatestFiniteMagnitude)).height)
        let rowHeight = max(22, valueHeight)
        icon.frame = CGRect(x: inset, y: y + 2, width: 18, height: 18)
        title.frame = CGRect(x: inset + 24, y: y, width: 56, height: rowHeight)
        value.frame = CGRect(x: valueX, y: y, width: valueWidth, height: valueHeight)
        icon.isHidden = false; title.isHidden = false; value.isHidden = false
        y += rowHeight + 6
      }
    } else {
      separator.frame = .zero
      detailRows.forEach { $0.0.isHidden = true; $0.1.isHidden = true; $0.2.isHidden = true }
    }
    date.text = compact ? neoProgramCompactDate(data.startAt) + "–" + neoProgramTime(data.endAt) : neoProgramDate(data.startAt) + " – " + neoProgramTime(data.endAt)
    duration.text = "(\(neoProgramDuration(start: data.startAt, end: data.endAt))分)"
  }

  private func height(for width: CGFloat) -> CGFloat {
    guard width > 0 else { return 80 }
    let inset: CGFloat = width >= 600 ? 24 : 16
    let compact = width < 600
    var result: CGFloat = compact ? 8 + 32 + 5 + 20 + 8 : 8 + 32 + 8
    if expanded {
      let valueWidth = max(0, width - inset - (inset + 24 + 56 + 8))
      result += 1 + 9
      for (_, _, value) in detailRows {
        result += max(22, value.sizeThatFits(CGSize(width: valueWidth, height: .greatestFiniteMagnitude)).height) + 6
      }
      result += 2
    }
    return result
  }

  private func makeDetailRows() {
    let rows: [(String, String, String)] = [
      ("square.grid.2x2", "ジャンル", data.genreLabels.isEmpty ? "情報なし" : data.genreLabels.joined(separator: "\n")),
      ("video", "映像", [data.videoType, data.videoResolution].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ").isEmpty ? "情報なし" : [data.videoType, data.videoResolution].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")),
      ("headphones", "主音声", [data.audioComponentType, data.audioSamplingRate].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ").isEmpty ? "情報なし" : [data.audioComponentType, data.audioSamplingRate].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / "))
    ]
    for (symbol, titleText, valueText) in rows {
      let icon = UIImageView(image: UIImage(systemName: symbol))
      icon.tintColor = NeoStyle.muted
      icon.contentMode = .scaleAspectFit
      let title = NeoStyle.label(titleText, size: 14, bold: true)
      let value = NeoStyle.label(valueText, size: 14)
      value.numberOfLines = 0
      value.lineBreakMode = .byWordWrapping
      addSubview(icon); addSubview(title); addSubview(value)
      detailRows.append((icon, title, value))
    }
  }

  private func toggleDetails() {
    expanded.toggle()
    refreshToggleAccessibility()
    setNeedsLayout()
    invalidateIntrinsicContentSize()
    onToggle?()
  }

  private func refreshToggleAccessibility() {
    toggle.accessibilityLabel = expanded ? "ジャンルと映像・音声情報を閉じる" : "ジャンルと映像・音声情報を表示"
    toggle.accessibilityValue = expanded ? "表示中" : "非表示"
    toggle.accessibilityTraits = expanded ? [.button, .selected] : [.button]
    toggle.transform = CGAffineTransform(rotationAngle: expanded ? .pi : 0)
  }
}

private final class NeoProgramChipWrap: UIView {
  struct Chip {
    let text: String
    let fill: UIColor
    let textColor: UIColor
    let border: UIColor?
  }

  var entries: [Chip] = [] { didSet { rebuild() } }
  private var labels: [UILabel] = []

  override var intrinsicContentSize: CGSize { sizeThatFits(CGSize(width: bounds.width > 0 ? bounds.width : 320, height: .greatestFiniteMagnitude)) }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let width = max(1, size.width)
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
    for label in labels {
      let chipWidth = min(width, max(32, label.sizeThatFits(CGSize(width: width, height: 32)).width + 24))
      if x > 0, x + chipWidth > width { y += lineHeight + 8; x = 0; lineHeight = 0 }
      x += chipWidth + 8
      lineHeight = max(lineHeight, 32)
    }
    return CGSize(width: width, height: labels.isEmpty ? 0 : y + lineHeight)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    guard width > 0 else { return }
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 32
    for label in labels {
      let chipWidth = min(width, max(32, label.sizeThatFits(CGSize(width: width, height: 32)).width + 24))
      if x > 0, x + chipWidth > width { y += lineHeight + 8; x = 0; lineHeight = 32 }
      label.frame = CGRect(x: x, y: y, width: chipWidth, height: 32)
      x += chipWidth + 8
      lineHeight = max(lineHeight, 32)
    }
  }

  private func rebuild() {
    labels.forEach { $0.removeFromSuperview() }
    labels = entries.map { entry in
      let label = NeoStyle.label(entry.text, size: 13, bold: true)
      label.textColor = entry.textColor
      label.textAlignment = .center
      label.lineBreakMode = .byTruncatingTail
      label.layer.cornerRadius = 16
      label.layer.masksToBounds = true
      label.backgroundColor = entry.fill
      if let border = entry.border { label.layer.borderWidth = 1; label.layer.borderColor = border.cgColor }
      label.accessibilityLabel = entry.text
      addSubview(label)
      return label
    }
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }
}

private func neoProgramDate(_ milliseconds: Double) -> String {
  NeoProgramDetailFormatter.full.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
}

private func neoProgramCompactDate(_ milliseconds: Double) -> String {
  NeoProgramDetailFormatter.compact.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
}

private func neoProgramTime(_ milliseconds: Double) -> String {
  NeoProgramDetailFormatter.time.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
}

private func neoProgramDuration(start: Double, end: Double) -> Int {
  guard start.isFinite, end.isFinite else { return 0 }
  return max(0, Int(((end - start) / 60_000).rounded()))
}

private enum NeoProgramDetailFormatter {
  static let full: DateFormatter = make("yyyy/MM/dd(EEE) HH:mm")
  static let compact: DateFormatter = make("M/d(EEE) HH:mm")
  static let time: DateFormatter = make("HH:mm")

  private static func make(_ format: String) -> DateFormatter {
    let value = DateFormatter()
    value.locale = Locale(identifier: "ja_JP")
    value.timeZone = TimeZone(identifier: "Asia/Tokyo")
    value.dateFormat = format
    return value
  }
}
