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
final class NeoProgramSearchInput: UIView {
  private static let leadingInset: CGFloat = 14
  private static let trailingInset: CGFloat = 4
  private static let accessoryWidth: CGFloat = 40
  private let outline = UIView()
  private let field: UITextField
  private let floatingLabel: UILabel
  private let placeholder: String
  let fieldLabel: String

  init(label: String, placeholder: String, field: UITextField, accessory: UIView, fieldContent: UIView? = nil, verticalInset: CGFloat = 8) {
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
      contents.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
      contents.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
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
