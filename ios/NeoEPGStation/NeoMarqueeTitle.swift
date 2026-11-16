import UIKit

// Animate only overflowing, visible titles. Updating force/progress does not
// restart the text; reuse and width changes invalidate the old animation.
final class NeoMarqueeTitle: UIView {
  private let label = NeoStyle.label(size:16,bold:true)
  private var measuredWidth: CGFloat = -1
  private var activeObserver: NSObjectProtocol?
  private(set) var animationGeneration = 0
  var text: String? {
    get { label.text }
    set { guard label.text != newValue else { return }; label.text = newValue; measuredWidth = -1; setNeedsLayout() }
  }
  override init(frame: CGRect) {
    super.init(frame:frame); clipsToBounds = true; isUserInteractionEnabled = false; addSubview(label)
    activeObserver = NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
      guard let self, self.window != nil else { return }
      self.measuredWidth = -1; self.setNeedsLayout()
    }
  }
  deinit { if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) } }
  required init?(coder: NSCoder) { fatalError() }
  override func didMoveToWindow() { super.didMoveToWindow(); measuredWidth = -1; setNeedsLayout(); if window == nil { label.layer.removeAllAnimations() } }
  override func layoutSubviews() {
    super.layoutSubviews()
    guard measuredWidth != bounds.width else { return }; measuredWidth = bounds.width
    label.layer.removeAllAnimations(); label.transform = .identity
    let width = ceil(label.intrinsicContentSize.width)
    label.frame = CGRect(x:0,y:0,width:max(bounds.width,width),height:bounds.height)
    guard window != nil, width > bounds.width+1, bounds.width > 0, !UIAccessibility.isReduceMotionEnabled else { return }
    let distance = width-bounds.width, travel = Double(distance/28), duration = travel+3
    let animation = CAKeyframeAnimation(keyPath:"transform.translation.x")
    animation.values = [0,0,-distance,-distance]
    animation.keyTimes = [0,NSNumber(value:1.5/duration),NSNumber(value:(1.5+travel)/duration),1]
    animation.duration = duration; animation.repeatCount = .infinity; animation.calculationMode = .linear
    label.layer.add(animation,forKey:"onair.title.marquee")
    animationGeneration += 1
    accessibilityLabel = text
  }
  var scrolling: Bool { label.layer.animation(forKey:"onair.title.marquee") != nil }
#if targetEnvironment(simulator)
  func smokeInterrupt() { label.layer.removeAllAnimations() }
  var smokeOneWay: Bool {
    guard let values = (label.layer.animation(forKey:"onair.title.marquee") as? CAKeyframeAnimation)?.values as? [NSNumber], values.count > 2 else { return false }
    return zip(values,values.dropFirst()).allSatisfy { $0.doubleValue >= $1.doubleValue } && values.last!.doubleValue < 0
  }
#endif
}

