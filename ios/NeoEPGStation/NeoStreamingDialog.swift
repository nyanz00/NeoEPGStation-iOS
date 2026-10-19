import UIKit

// RecordedSelectStreamDialog: source, stream type, quality, cancel/start.
final class NeoStreamingDialog: UIViewController {
  private let file: NeoVideoFile, qualities: [String], start: (Int) -> Void
  private var mode: Int
  init(file: NeoVideoFile, qualities: [String], start: @escaping (Int) -> Void) {
    self.file = file; self.qualities = qualities; self.start = start
    let saved = UserDefaults.standard.integer(forKey: "player.streaming.mode."+file.type)
    mode = qualities.indices.contains(saved) && !qualities[saved].isEmpty ? saved : (qualities.firstIndex(where: { !$0.isEmpty }) ?? 0)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .formSheet; preferredContentSize = CGSize(width: 480, height: 300)
    if let sheet = sheetPresentationController { sheet.detents = [.medium()] }
  }
  private func updateQuality(_ button: UIButton) {
    button.setTitle("画質：\(qualities[mode]) ▾", for: .normal)
    button.menu = UIMenu(children: qualities.enumerated().filter { !$0.element.isEmpty }.map { index, name in
      UIAction(title: name, state: index == mode ? .on : .off) { [weak self, weak button] _ in
        guard let self, let button else { return }; self.mode = index; self.updateQuality(button)
      }
    })
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = NeoStyle.paper
    let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)])
    let title = NeoStyle.label(file.name+" - STREAMING", size: 20, bold: true); title.numberOfLines = 2; stack.addArrangedSubview(title)
    stack.addArrangedSubview(NeoStyle.label("ストリーム："+(file.type == "ts" ? "HLS-TS" : "HLS")))
    let button = UIButton(type: .system); button.tintColor = NeoStyle.accent
    button.contentHorizontalAlignment = .left; button.showsMenuAsPrimaryAction = true
    updateQuality(button); stack.addArrangedSubview(button)
    let row = UIStackView(); row.spacing = 24; row.distribution = .fillEqually
    row.addArrangedSubview(NeoStyle.button("キャンセル") { [weak self] in self?.dismiss(animated: true) })
    row.addArrangedSubview(NeoStyle.button("再生") { [weak self] in
      guard let self else { return }; UserDefaults.standard.set(mode, forKey: "player.streaming.mode."+file.type)
      dismiss(animated: true) { [start, mode] in start(mode) }
    }); stack.addArrangedSubview(row)
  }
}
