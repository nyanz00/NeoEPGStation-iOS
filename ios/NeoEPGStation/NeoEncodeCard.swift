import UIKit

/// Queue row presentation for the Web EncodeCard. Queue mutations and drag
/// state remain owned by the containing page.
final class NeoEncodeCard: UITableViewCell {
  var onSelect: (() -> Void)?, onCancel: (() -> Void)?, onMoveUp: (() -> Void)?, onMoveDown: (() -> Void)?
  let dragHandle = UIView()
  private let card = UIView(), thumbnail = NeoThumbnail(), chip = UILabel(), title = NeoMarqueeTitle()
  private let channel = NeoStyle.label(size: 14, muted: true), date = NeoStyle.label(size: 12, muted: true)
  private let percentLabel = NeoStyle.label(size: 14), percentValue = NeoStyle.label(size:14), progress = UIProgressView(progressViewStyle: .default)
  private let log = NeoStyle.label(size: 12, muted: true), cancel = UIButton(type: .system)
  private let up = UIButton(type: .system), down = UIButton(type: .system), check = UIImageView()
  private let indeterminate = UIActivityIndicatorView(style: .medium)
  private var mobile = true, waiting = false, selectionMode = false, reordering = false, selectedCard = false
  private var canMoveUp = false, canMoveDown = false, disabled = false
  private var touch = UITapGestureRecognizer()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = NeoStyle.background; selectionStyle = .none
    card.backgroundColor = NeoStyle.paper; card.layer.cornerRadius = 4; card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor; contentView.addSubview(card)
    thumbnail.contentMode = .scaleAspectFill; thumbnail.clipsToBounds = true; thumbnail.layer.cornerRadius = 4
    chip.font = .systemFont(ofSize: 12); chip.textAlignment = .center; chip.numberOfLines = 1
    chip.layer.cornerRadius = 12; chip.clipsToBounds = true
    channel.numberOfLines = 1; date.numberOfLines = 1
    progress.progressTintColor = NeoStyle.accent; progress.trackTintColor = NeoStyle.accent.withAlphaComponent(0.25)
    log.numberOfLines = 1
    cancel.setTitle("キャンセル", for: .normal); cancel.tintColor = UIColor(red: 244/255, green: 67/255, blue: 54/255, alpha: 1)
    cancel.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    cancel.setImage(NeoIcon.image("CancelOutlined"), for: .normal); cancel.setTitle(nil, for: .normal)
    cancel.accessibilityLabel = "エンコードをキャンセル"
    up.setImage(NeoIcon.image("ArrowUpwardOutlined"), for: .normal)
    down.setImage(NeoIcon.image("ArrowDownwardOutlined"), for: .normal)
    [up, down].forEach { $0.tintColor = .white }
    dragHandle.backgroundColor = .clear
    let grip = UIImageView(image: NeoIcon.image("DragIndicatorOutlined")); grip.tintColor = NeoStyle.muted; grip.frame = CGRect(x: 6, y: 8, width: 24, height: 24); dragHandle.addSubview(grip)
    check.contentMode = .scaleAspectFit; indeterminate.color = NeoStyle.accent
    [thumbnail, chip, title, channel, date, percentLabel, percentValue, progress, log, indeterminate, cancel, up, down, dragHandle, check].forEach(card.addSubview)
    cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
    up.addAction(UIAction { [weak self] _ in self?.onMoveUp?() }, for: .touchUpInside)
    down.addAction(UIAction { [weak self] _ in self?.onMoveDown?() }, for: .touchUpInside)
    touch.addTarget(self, action: #selector(selectCard)); card.addGestureRecognizer(touch)
  }
  required init?(coder: NSCoder) { fatalError() }

  static func height(width: CGFloat, mobile: Bool, waiting: Bool, editing: Bool) -> CGFloat {
    let wide = !mobile && width >= 600
    if wide { return waiting ? 186 : 226 }
    return waiting ? 166 : 208
  }

  func configure(_ item: NeoEncodeItem, shell: NeoShell, mobile: Bool, waiting: Bool, editing: Bool,
                 reordering: Bool, selected: Bool, canMoveUp: Bool, canMoveDown: Bool, disabled: Bool) {
    self.mobile = mobile; self.waiting = waiting; self.selectionMode = editing; self.reordering = reordering
    selectedCard = selected; self.canMoveUp = canMoveUp; self.canMoveDown = canMoveDown; self.disabled = disabled
    let scheduled = item.scheduledAt != nil
    let mode = scheduled ? (item.scheduledAtLabel ?? "開始予約") : item.mode
    title.text = item.recorded.name
    let start = Date(timeIntervalSince1970: item.recorded.startAt / 1000), end = Date(timeIntervalSince1970: item.recorded.endAt / 1000)
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyy/MM/dd(EEE) HH:mm"
    let mins = max(0, Int((item.recorded.endAt - item.recorded.startAt) / 60000))
    f.dateFormat = "HH:mm"
    date.text = "\(f.string(from: start)) - \(f.string(from: end))（\(mins)分）"
    channel.text = item.recorded.channelName ?? item.recorded.channelId.flatMap { shell.channels[$0] } ?? item.recorded.channelId.map(String.init) ?? ""
    chip.text = "  \(mode)  "; chip.backgroundColor = waiting ? UIColor.white.withAlphaComponent(0.12) : NeoStyle.accent
    chip.textColor = waiting ? .white : NeoStyle.successText
    thumbnail.load(item.recorded.thumbnails?.first.flatMap { shell.api?.url("/thumbnails/\($0)") })
    cancel.isHidden = editing || reordering; cancel.isEnabled = !disabled
    up.isHidden = !reordering || !waiting; down.isHidden = !reordering || !waiting
    up.isEnabled = canMoveUp && !disabled; down.isEnabled = canMoveDown && !disabled
    dragHandle.isHidden = !reordering || !waiting || mobile
    check.isHidden = !editing; check.image = NeoIcon.image(selected ? "CheckBox" : "CheckBoxOutlineBlank")
    check.tintColor = selected ? NeoStyle.accent : NeoStyle.muted
    progress.isHidden = waiting || item.percent == nil; indeterminate.isHidden = waiting || item.percent != nil
    if item.percent == nil && !waiting { indeterminate.startAnimating() } else { indeterminate.stopAnimating() }
    percentLabel.isHidden = waiting; percentValue.isHidden = waiting; log.isHidden = waiting || item.log == nil
    let p = min(1, max(0, item.percent ?? 0)); percentLabel.text = item.mode; percentValue.text = "\(Int(floor(p * 100)))%"
    if let value = item.percent { progress.setProgress(Float(min(1, max(0, value))), animated: false); progress.isHidden = waiting }
    else { progress.setProgress(0, animated: false); progress.isHidden = true; progress.accessibilityLabel = "エンコード中" }
    log.text = item.log; alpha = disabled ? 0.55 : 1
    card.layer.borderColor = selected ? NeoStyle.accent.cgColor : NeoStyle.border.cgColor
    card.backgroundColor = selected ? UIColor.white.withAlphaComponent(0.16) : NeoStyle.paper
    touch.isEnabled = editing
    accessibilityLabel = "\(item.recorded.name)、\(mode)"
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let wide = !mobile && contentView.bounds.width >= 600
    card.frame = contentView.bounds.insetBy(dx: 12, dy: 6)
    let w = card.bounds.width, pad: CGFloat = 12
    let thumbW: CGFloat = wide ? 200 : 120, thumbH = thumbW * 9 / 16
    check.frame = selectionMode ? CGRect(x:8,y:10,width:28,height:28) : .zero
    dragHandle.frame = CGRect(x:4,y:40,width:36,height:40)
    let left = pad + (selectionMode ? 36 : 0) + (dragHandle.isHidden ? 0 : 38)
    let badgeWidth = min(chip.intrinsicContentSize.width+16,max(0,w-left-pad))
    chip.frame = CGRect(x:left,y:10,width:badgeWidth,height:24)
    let mediaY: CGFloat = 40, infoHeight: CGFloat = 59
    let tx = left+thumbW+10, textW = max(0,w-tx-pad)
    let infoY = mediaY+(thumbH-infoHeight)/2
    thumbnail.frame = CGRect(x:left,y:mediaY,width:thumbW,height:thumbH)
    title.frame = CGRect(x:tx,y:infoY,width:textW,height:23)
    channel.frame = CGRect(x:tx,y:infoY+23,width:textW,height:18)
    date.frame = CGRect(x:tx,y:infoY+41,width:textW,height:18)
    let percentY = max(mediaY+thumbH+4,infoY+infoHeight+32)
    let percentCenter = w-pad-ceil(percentValue.intrinsicContentSize.width)/2
    cancel.frame = CGRect(x:percentCenter-16,y:percentY-28,width:32,height:28)
    if reordering && waiting {
      up.frame = CGRect(x:w-90,y:percentY-32,width:38,height:32)
      down.frame = CGRect(x:w-48,y:percentY-32,width:38,height:32)
    }
    progressFrame(y:percentY,x:pad,width:w-pad*2)
  }

  private func progressFrame(y: CGFloat, x: CGFloat, width: CGFloat) {
    percentLabel.frame = CGRect(x: x, y: y, width: max(0,width-60), height: 18)
    percentValue.frame = CGRect(x:x+max(0,width-60),y:y,width:60,height:18); percentValue.textAlignment = .right
    progress.frame = CGRect(x: x, y: y+19, width: width, height: 8)
    indeterminate.frame = CGRect(x: x, y: y+19, width: width, height: 8)
    log.frame = CGRect(x: x, y: y+28, width: width, height: 16)
  }
#if targetEnvironment(simulator)
  var smokeChannel: String? { channel.text }
  var smokeTitle: NeoMarqueeTitle { title }
  var smokeGeometry: [String:Any] {
    ["thumbnail":String(describing:thumbnail.frame),"title":String(describing:title.frame),"date":String(describing:date.frame),
      "badge":String(describing:chip.frame),"badgeIntrinsicWidth":chip.intrinsicContentSize.width,"cancel":String(describing:cancel.frame),
      "percent":String(describing:percentValue.frame),"log":String(describing:log.frame),"card":String(describing:card.bounds),"waiting":waiting,"fits":smokeLayoutFits]
  }
  var smokeLayoutFits: Bool {
    let infoMid = (title.frame.minY+date.frame.maxY)/2
    return abs(thumbnail.frame.midY-infoMid) < 0.5 && abs(chip.frame.minX-thumbnail.frame.minX) < 0.01
      && chip.frame.width <= chip.intrinsicContentSize.width+17
      && title.frame.width > 0 && date.frame.width > 0
      && (waiting || (abs(cancel.frame.maxY-percentValue.frame.minY)<0.5 && log.frame.maxY <= card.bounds.height))
  }
#endif
  @objc private func selectCard() { if selectionMode { onSelect?() } }
  override func prepareForReuse() {
    super.prepareForReuse(); thumbnail.load(nil); onSelect = nil; onCancel = nil; onMoveUp = nil; onMoveDown = nil
  }
}
