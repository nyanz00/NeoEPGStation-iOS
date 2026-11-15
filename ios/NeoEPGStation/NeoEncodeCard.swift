import UIKit

/// Queue row presentation for the Web EncodeCard. Queue mutations and drag
/// state remain owned by the containing page.
final class NeoEncodeCard: UITableViewCell {
  var onSelect: (() -> Void)?, onCancel: (() -> Void)?, onMoveUp: (() -> Void)?, onMoveDown: (() -> Void)?
  let dragHandle = UIView()
  private let card = UIView(), thumbnail = NeoThumbnail(), chip = UILabel(), title = NeoStyle.label(size: 16, bold: true)
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
    chip.font = .systemFont(ofSize: 12); chip.textAlignment = .center; chip.numberOfLines = 0
    chip.layer.cornerRadius = 12; chip.clipsToBounds = true
    title.numberOfLines = 2; title.lineBreakMode = .byTruncatingTail
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
    if wide { return waiting ? (editing ? 164 : 148) : (editing ? 232 : 216) }
    return waiting ? (editing ? 194 : 178) : 244
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
    channel.text = item.recorded.channelName ?? item.recorded.channelId.map(String.init) ?? ""
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
    let controlsX = w - 44, thumbW: CGFloat = wide ? 200 : 120, thumbH = thumbW * 9 / 16
    check.frame = selectionMode ? CGRect(x: 8, y: 12, width: 28, height: 28) : .zero
    dragHandle.frame = CGRect(x: 4, y: 20, width: 36, height: 40)
    if wide {
      let left = pad + (selectionMode ? 38 : 0) + (dragHandle.isHidden ? 0 : 38)
      thumbnail.frame = CGRect(x: left, y: 12, width: thumbW, height: thumbH)
      let infoX = left + thumbW + 10, chipWidth = min(130, max(90, w-left-thumbW-90))
      chip.frame = CGRect(x: max(infoX, w-chipWidth-58), y: 14, width: chipWidth, height: 26)
      title.frame = CGRect(x: infoX, y: 14, width: max(0, chip.frame.minX-infoX-8), height: 27)
      channel.frame = CGRect(x: title.frame.minX, y: 45, width: title.frame.width, height: 20)
      date.frame = CGRect(x: title.frame.minX, y: 68, width: title.frame.width, height: 18)
      if reordering && waiting { up.frame = CGRect(x: w-46, y: 18, width: 38, height: 38); down.frame = CGRect(x: w-46, y: 58, width: 38, height: 38) }
      else { cancel.frame = CGRect(x: controlsX-15, y: 48, width: 50, height: 40) }
      progressFrame(y: 132, x: pad, width: w-pad*2)
    } else {
      let top = CGFloat(12), left = pad + (selectionMode ? 36 : 0)
      chip.frame = CGRect(x: left, y: top, width: min(thumbW, w-left-pad), height: 24)
      thumbnail.frame = CGRect(x: left, y: top+32, width: thumbW, height: thumbH)
      let tx = left + thumbW + 10, textW = max(0, w-tx-pad)
      title.frame = CGRect(x: tx, y: top+30, width: textW, height: 36)
      channel.frame = CGRect(x: tx, y: top+68, width: textW, height: 18)
      date.frame = CGRect(x: tx, y: top+88, width: textW, height: 30)
      cancel.frame = CGRect(x: w-100, y: top+thumbH+39, width: 88, height: 38)
      if reordering && waiting { up.frame = CGRect(x: w-90, y: top+thumbH+35, width: 38, height: 38); down.frame = CGRect(x: w-48, y: top+thumbH+35, width: 38, height: 38) }
      progressFrame(y: top+thumbH+86, x: pad, width: w-pad*2)
    }
  }
  private func progressFrame(y: CGFloat, x: CGFloat, width: CGFloat) {
    percentLabel.frame = CGRect(x: x, y: y, width: max(0,width-60), height: 20)
    percentValue.frame = CGRect(x:x+max(0,width-60),y:y,width:60,height:20); percentValue.textAlignment = .right
    progress.frame = CGRect(x: x, y: y+22, width: width, height: 8)
    indeterminate.frame = CGRect(x: x, y: y+22, width: width, height: 8)
    log.frame = CGRect(x: x, y: y+33, width: width, height: 18)
  }
  @objc private func selectCard() { if selectionMode { onSelect?() } }
  override func prepareForReuse() {
    super.prepareForReuse(); thumbnail.load(nil); onSelect = nil; onCancel = nil; onMoveUp = nil; onMoveDown = nil
  }
}
