import UIKit

enum NeoProgramRuleButton {
  static func make(_ title: String, filled: Bool, identifier: String, icon: String = "PlaylistAddOutlined", action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    var configuration: UIButton.Configuration = filled ? .filled() : .plain()
    configuration.title = title
    configuration.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
      NeoIcon.image(icon).draw(in: CGRect(x: 0, y: 0, width: 20, height: 20))
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
/// Shared outline and label for the Web-style text fields and selects.
final class NeoOutlinedFieldLabel: UIView {
  private let outline = CAShapeLayer()
  private let caption: UILabel
  private let trailingInset: CGFloat
  private var floated = false
  private var laidOutSize = CGSize.zero
  private let timing = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
  private static let animationKeys = ["position", "transform", "bounds"]

  init(_ label: String, trailingInset: CGFloat) {
    self.trailingInset = trailingInset
    caption = NeoStyle.label(label, size: 16, muted: true)
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    outline.fillColor = UIColor.clear.cgColor
    layer.addSublayer(outline)
    caption.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
    addSubview(caption)
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(floated: Bool, focused: Bool, enabled: Bool, invalid: Bool = false) {
    let moved = self.floated != floated
    self.floated = floated
    let errorColor = UIColor(red: 244 / 255, green: 67 / 255, blue: 54 / 255, alpha: 1)
    let color = !enabled ? UIColor.white.withAlphaComponent(0.5) : invalid ? errorColor : focused ? NeoStyle.accent : NeoStyle.muted
    caption.textColor = color
    let border = !enabled ? UIColor.white.withAlphaComponent(0.3)
      : focused || invalid ? color : UIColor.white.withAlphaComponent(0.23)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    outline.strokeColor = border.cgColor
    outline.lineWidth = enabled && focused ? 2 : 1
    CATransaction.commit()
    if moved, !bounds.isEmpty {
      layoutLabel(animated: window != nil && laidOutSize == bounds.size && UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if laidOutSize != bounds.size { layoutLabel(animated: false) }
  }

  private func layoutLabel(animated: Bool) {
    let captionLayer = caption.layer
    let displayed = captionLayer.presentation() ?? captionLayer
    let previousPosition = displayed.position
    let previousTransform = displayed.transform
    let previousBounds = displayed.bounds
    let previousOutline = outline.presentation()?.path ?? outline.path
    let scale: CGFloat = floated ? 0.75 : 1
    let size = caption.intrinsicContentSize
    let textWidth = min(size.width, max(0, bounds.width - 14 - trailingInset) / scale)

    CATransaction.begin(); CATransaction.setDisableActions(true)
    captionLayer.bounds = CGRect(x: 0, y: 0, width: textWidth, height: size.height)
    captionLayer.position = CGPoint(x: 14, y: floated ? 0 : bounds.midY)
    captionLayer.transform = CATransform3DMakeScale(scale, scale, 1)
    outline.frame = bounds
    outline.path = outlinePath(notchWidth: floated ? textWidth * scale + 8 : 0)
    CATransaction.commit()
    laidOutSize = bounds.size

    if animated {
      animate(captionLayer, key: "position", from: NSValue(cgPoint: previousPosition))
      animate(captionLayer, key: "transform", from: NSValue(caTransform3D: previousTransform))
      if previousBounds != captionLayer.bounds {
        animate(captionLayer, key: "bounds", from: NSValue(cgRect: previousBounds))
      }
      if let previousOutline {
        // Clear the upper edge before the label reaches it. On the way
        // down, keep the gap open until the label has moved below the stroke.
        animate(outline, key: "path", from: previousOutline, duration: 0.05, delay: floated ? 0 : 0.06)
      }
    } else {
      Self.animationKeys.forEach(captionLayer.removeAnimation(forKey:))
      outline.removeAnimation(forKey: "path")
    }
  }

  private func animate(_ layer: CALayer, key: String, from value: Any, duration: CFTimeInterval = 0.2,
    delay: CFTimeInterval = 0) {
    let animation = CABasicAnimation(keyPath: key)
    animation.fromValue = value
    animation.duration = duration
    animation.timingFunction = timing
    if delay > 0 {
      animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
      animation.fillMode = .backwards
    }
    layer.add(animation, forKey: key)
  }

  // The gap is part of the outline path.
  private func outlinePath(notchWidth: CGFloat) -> CGPath {
    let rect = bounds.insetBy(dx: 1, dy: 1)
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    let radius = max(0, min(6, rect.width / 2, rect.height / 2))
    let notchLeft = min(maxX - radius, max(minX + radius, 10))
    let notchRight = min(maxX - radius, notchLeft + notchWidth)
    let path = UIBezierPath()
    path.move(to: CGPoint(x: notchRight, y: minY))
    path.addLine(to: CGPoint(x: maxX - radius, y: minY))
    path.addQuadCurve(to: CGPoint(x: maxX, y: minY + radius), controlPoint: CGPoint(x: maxX, y: minY))
    path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
    path.addQuadCurve(to: CGPoint(x: maxX - radius, y: maxY), controlPoint: CGPoint(x: maxX, y: maxY))
    path.addLine(to: CGPoint(x: minX + radius, y: maxY))
    path.addQuadCurve(to: CGPoint(x: minX, y: maxY - radius), controlPoint: CGPoint(x: minX, y: maxY))
    path.addLine(to: CGPoint(x: minX, y: minY + radius))
    path.addQuadCurve(to: CGPoint(x: minX + radius, y: minY), controlPoint: CGPoint(x: minX, y: minY))
    path.addLine(to: CGPoint(x: notchLeft, y: minY))
    return path.cgPath
  }

#if targetEnvironment(simulator)
  var smokeFloated: Bool { floated }
  var smokeCaption: UILabel { caption }
  var smokeMotionDuration: CFTimeInterval? { caption.layer.animation(forKey: "position")?.duration }
  var smokeNotchAnimation: CAAnimation? { outline.animation(forKey: "path") }
#endif
}

final class NeoProgramSearchInput: UIView {
  private static let leadingInset: CGFloat = 14
  private static let trailingInset: CGFloat = 4
  private static let accessoryWidth: CGFloat = 40
  private let decoration: NeoOutlinedFieldLabel
  private let field: UITextField
  private let placeholder: String
  private let alwaysFloated: Bool
  private var hasSelection = false
  private var active = false
  private var invalid = false
  let fieldLabel: String

  init(label: String, placeholder: String = "", field: UITextField, accessory: UIView? = nil, fieldContent: UIView? = nil,
       verticalInset: CGFloat = 8, minimumHeight: CGFloat? = nil, alwaysFloated: Bool = false) {
    fieldLabel = label
    self.field = field
    self.placeholder = placeholder
    self.alwaysFloated = alwaysFloated
    decoration = NeoOutlinedFieldLabel(label, trailingInset: accessory == nil ? Self.leadingInset : Self.trailingInset + Self.accessoryWidth)
    super.init(frame: .zero)
    field.accessibilityLabel = label
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.addTarget(self, action: #selector(refreshFieldAppearance), for: [.editingDidBegin, .editingChanged, .editingDidEnd])

    let contents = UIStackView(arrangedSubviews: [fieldContent ?? field])
    contents.alignment = accessory == nil ? .fill : .center
    if let accessory {
      contents.addArrangedSubview(accessory)
      accessory.widthAnchor.constraint(equalToConstant: Self.accessoryWidth).isActive = true
      accessory.heightAnchor.constraint(equalToConstant: Self.accessoryWidth).isActive = true
    }
    contents.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contents)
    addSubview(decoration)
    let padding = accessory == nil ? 0 : verticalInset
    let height = heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight ?? (2 * verticalInset + Self.accessoryWidth))
    height.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      height,
      contents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
      contents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
      contents.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      contents.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
    ])
    updateAppearance()
  }

  required init?(coder: NSCoder) { fatalError() }

  static func contentWidth(in width: CGFloat) -> CGFloat {
    max(0, width - leadingInset - trailingInset - accessoryWidth)
  }

  func updateAppearance(hasSelection: Bool = false, active: Bool = false, invalid: Bool = false) {
    self.hasSelection = hasSelection
    self.active = active
    self.invalid = invalid
    refreshFieldAppearance()
  }

  @objc private func refreshFieldAppearance() {
    let focused = field.isEnabled && (field.isFirstResponder || active)
    let floated = alwaysFloated || focused || hasSelection || !(field.text ?? "").isEmpty
    let hint = floated ? placeholder : ""
    if (field.placeholder ?? "") != hint {
      field.attributedPlaceholder = NSAttributedString(string: hint, attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.5)])
    }
    decoration.update(floated: floated, focused: focused, enabled: field.isEnabled, invalid: invalid)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    decoration.frame = bounds
  }
}

/// A sibling of the form's table so its list can scroll without dragging the
/// form or dismissing the keyboard. The anchor remains interactive behind it.
