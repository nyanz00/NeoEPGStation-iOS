import UIKit

// Native renderer for one side of RecordedSubtitleTransferPage. All loading,
// searching and edits are owned by the page; this view only keeps local editor
// and ordering state while rendering the supplied snapshot.
final class NeoTrackPane: UIStackView, UITextFieldDelegate, UIScrollViewDelegate {
  var sourceIsLeft = true { didSet { updateQueueButtonImages() } }

  var onSearch: ((String) -> Void)?
  var onSelectRecording: ((NeoRecording?) -> Void)?
  var onMoreSearch: (() -> Void)?
  var onSelectFile: ((Int) -> Void)?
  var onQueue: ((NeoManagedTrack) -> Void)?
  var onRename: ((NeoManagedTrack, String) -> Void)?
  var onReorder: (([Int]) -> Void)?
  var onPendingTitle: ((String) -> Void)?
  var onPendingCancel: (() -> Void)?
  var onRetry: (() -> Void)?
  var onHeightChange: (() -> Void)?

  private let searchTitle = NeoStyle.label("録画を検索", size: 14)
  private let searchField = UITextField()
  private let clearSelectionButton = UIButton(type: .system)
  private let searchResultsPanel = UIStackView()
  private let searchResultsStatus = NeoStyle.label(size: 14, muted: true)
  private let searchRetryButton = UIButton(type: .system)
  private let searchResultsScroll = UIScrollView()
  private let searchResultsList = UIStackView()
  private let moreSearchButton = UIButton(type: .system)
  private var searchResultsHeight: NSLayoutConstraint!

  private let fileTitle = NeoStyle.label("録画ファイルタイプ", size: 14)
  private let fileSelect = NeoSelectButton()
  private let noMkvNotice = NeoTrackPane.notice("この録画にはMKVファイルがありません。", warning: false)
  private let protectedNotice = NeoTrackPane.notice("この録画は保護されています。字幕の移植先、名前変更、並び替えの対象にする場合は先に保護を解除してください。", warning: true)

  private let tracksSection = UIStackView()
  private let tracksHeader = UIStackView()
  private let tracksTitle = NeoStyle.label("字幕一覧", size: 20, bold: true)
  private let reorderButton = UIButton(type: .system)
  private let trackLoadingStack = UIStackView()
  private let trackLoadingIndicator = UIActivityIndicatorView(style: .medium)
  private let trackStatusLabel = NeoStyle.label(size: 14, muted: true)
  private let trackErrorStack = UIStackView()
  private let trackErrorLabel = NeoStyle.label(size: 14)
  private let trackRetryButton = UIButton(type: .system)
  private let noFileLabel = NeoStyle.label("MKVファイルを選択してください。", size: 14, muted: true)
  private let noTracksLabel = NeoStyle.label("字幕トラックはありません。", size: 14, muted: true)
  private let trackList = UIStackView()
  private let saveOrderButton = UIButton(type: .system)

  private let pendingEditor = UIStackView()
  private let pendingTitleLabel = NeoStyle.label("移植後の字幕名", size: 14)
  private let pendingTitleRow = UIStackView()
  private let pendingTitleField = UITextField()
  private let pendingCancelButton = UIButton(type: .system)

  private struct TrackRow {
    let card: UIStackView
    let title: UILabel
    let chips: NeoTrackChipFlow
    let reorderButtons: UIStackView
    let moveUp: UIButton
    let moveDown: UIButton
    let renameButton: UIButton
    let queueButton: UIButton
    let editRow: UIStackView
    let editField: UITextField
    let saveEdit: UIButton
    let cancelEdit: UIButton
  }

  private var rows: [Int: TrackRow] = [:]
  private var recording: NeoRecording?
  private var fileID: Int?
  private var tracks: [NeoManagedTrack] = []
  private var isLoading = false
  private var processing = false
  private var canQueue = false
  private var tracksError: String?
  private var isReordering = false
  private var localOrder: [Int] = []
  private var editingSubtitleIndex: Int?
  private var editingTitle = ""
  private var pendingTitle: String?
  private var selectedRecordingID: Int?
  private var suggestionsDismissed = false
  private var candidateRecords: [NeoRecording] = []
  private var candidateChannels: [Int: String] = [:]
  private var candidateMore = false
  private var candidateLoading = false
  private var candidateError: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    axis = .vertical
    alignment = .fill
    distribution = .fill
    spacing = 16
    isLayoutMarginsRelativeArrangement = true
    directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    backgroundColor = NeoStyle.paper
    layer.cornerRadius = 6
    layer.borderWidth = 1
    layer.borderColor = NeoStyle.border.cgColor

    configureSearch()
    configureFileSelector()
    configureTrackSection()
    configurePendingEditor()

    let searchSection = UIStackView(arrangedSubviews: [searchTitle, searchField, searchResultsPanel])
    searchSection.axis = .vertical
    searchSection.alignment = .fill
    searchSection.spacing = 8

    let fileSection = UIStackView(arrangedSubviews: [fileTitle, fileSelect])
    fileSection.axis = .vertical
    fileSection.alignment = .fill
    fileSection.spacing = 8

    [searchSection, fileSection, noMkvNotice, protectedNotice, tracksSection, pendingEditor].forEach(addArrangedSubview)
    noMkvNotice.isHidden = true
    protectedNotice.isHidden = true
    pendingEditor.isHidden = true
    refreshTrackState()
  }

  required init(coder: NSCoder) { fatalError() }

  func update(recording: NeoRecording?, fileID: Int?, tracks: [NeoManagedTrack], loading: Bool, error: String?, processing: Bool, canQueue: Bool, targetTitle: String?) {
    let nextRecordingID = recording?.id
    let recordingChanged = selectedRecordingID != nextRecordingID
    let fileChanged = self.fileID != fileID
    let tracksChanged = self.tracks != tracks

    if recordingChanged {
      selectedRecordingID = nextRecordingID
      suggestionsDismissed = recording != nil
      if !searchField.isFirstResponder { searchField.text = recording?.name ?? "" }
    } else if recording != nil, !searchField.isFirstResponder, searchField.text != recording?.name, candidateRecords.isEmpty {
      searchField.text = recording?.name
    }

    if fileChanged {
      editingSubtitleIndex = nil
      editingTitle = ""
      isReordering = false
      localOrder = []
    }
    if tracksChanged || fileChanged {
      // The Web pane resets these local modes when the server track snapshot
      // changes. Ordinary same-file status/processing updates leave them alone.
      editingSubtitleIndex = nil
      editingTitle = ""
      isReordering = false
      self.tracks = tracks
      localOrder = tracks.map(\.subtitleIndex)
      rebuildTrackRows()
    }

    self.recording = recording
    self.fileID = fileID
    self.isLoading = loading
    self.tracksError = error
    self.processing = processing
    self.canQueue = canQueue
    pendingCancelButton.isEnabled = !processing

    let mkvFiles = NeoMediaTools.mkvFiles(recording)
    noMkvNotice.isHidden = recording == nil || !mkvFiles.isEmpty
    protectedNotice.isHidden = recording?.isProtected != true
    fileSelect.isEnabled = recording != nil && !mkvFiles.isEmpty
    if let selected = mkvFiles.first(where: { $0.id == fileID }) {
      fileSelect.setTitle(Self.fileLabel(selected), for: .normal)
    } else {
      fileSelect.setTitle("ファイルを選択", for: .normal)
    }
    fileSelect.menu = UIMenu(title: "録画ファイルタイプ", children: mkvFiles.map { video in
      UIAction(title: Self.fileLabel(video), state: video.id == fileID ? .on : .off) { [weak self] _ in
        self?.onSelectFile?(video.id)
      }
    })

    if targetTitle == nil {
      if pendingTitle != nil { pendingTitleField.resignFirstResponder() }
      pendingTitle = nil
      pendingTitleField.text = ""
      pendingEditor.isHidden = true
    } else {
      let wasHidden = pendingTitle == nil
      pendingTitle = targetTitle
      pendingEditor.isHidden = false
      // The parent echoes every keystroke through update(). Leave a focused
      // field untouched so its cursor and active IME composition stay intact.
      if wasHidden || !pendingTitleField.isFirstResponder {
        if pendingTitleField.text != targetTitle { pendingTitleField.text = targetTitle }
      }
    }

    refreshTrackState()
    refreshRowControls()
    refreshSearchResultsPanel()
    onHeightChange?()
  }

  func searchResults(_ records: [NeoRecording], more: Bool, loading: Bool, error: String?, channels: [Int: String]) {
    candidateRecords = records
    candidateMore = more
    candidateLoading = loading
    candidateError = error
    candidateChannels = channels
    rebuildSearchResults()
    onHeightChange?()
  }

  private func configureSearch() {
    searchField.borderStyle = .none
    searchField.font = .systemFont(ofSize: 16)
    searchField.textColor = .white
    searchField.tintColor = NeoStyle.accent
    searchField.attributedPlaceholder = NSAttributedString(string: "番組名を入力", attributes: [.foregroundColor: NeoStyle.muted])
    searchField.returnKeyType = .search
    searchField.clearButtonMode = .never
    searchField.layer.cornerRadius = 6
    searchField.layer.borderWidth = 1
    searchField.layer.borderColor = NeoStyle.border.cgColor
    searchField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    searchField.leftViewMode = .always
    searchField.delegate = self
    searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
    searchField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

    clearSelectionButton.setImage(NeoIcon.image("Close"), for: .normal)
    clearSelectionButton.tintColor = NeoStyle.muted
    clearSelectionButton.accessibilityLabel = "選択中の録画を解除"
    clearSelectionButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
    clearSelectionButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
    clearSelectionButton.addAction(UIAction { [weak self] _ in self?.clearRecordingSelection() }, for: .touchUpInside)
    searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    searchResultsPanel.axis = .vertical
    searchResultsPanel.alignment = .fill
    searchResultsPanel.spacing = 0
    searchResultsPanel.layer.cornerRadius = 6
    searchResultsPanel.layer.borderWidth = 1
    searchResultsPanel.layer.borderColor = NeoStyle.border.cgColor
    searchResultsPanel.clipsToBounds = true

    searchResultsStatus.numberOfLines = 0
    searchResultsStatus.textAlignment = .center
    searchResultsStatus.isHidden = true
    searchResultsPanel.addArrangedSubview(searchResultsStatus)

    searchResultsList.axis = .vertical
    searchResultsList.alignment = .fill
    searchResultsList.spacing = 0
    searchResultsList.translatesAutoresizingMaskIntoConstraints = false
    searchResultsScroll.translatesAutoresizingMaskIntoConstraints = false
    searchResultsScroll.delegate = self
    searchResultsScroll.addSubview(searchResultsList)
    NSLayoutConstraint.activate([
      searchResultsList.leadingAnchor.constraint(equalTo: searchResultsScroll.contentLayoutGuide.leadingAnchor),
      searchResultsList.trailingAnchor.constraint(equalTo: searchResultsScroll.contentLayoutGuide.trailingAnchor),
      searchResultsList.topAnchor.constraint(equalTo: searchResultsScroll.contentLayoutGuide.topAnchor),
      searchResultsList.bottomAnchor.constraint(equalTo: searchResultsScroll.contentLayoutGuide.bottomAnchor),
      searchResultsList.widthAnchor.constraint(equalTo: searchResultsScroll.frameLayoutGuide.widthAnchor)
    ])
    searchResultsHeight = searchResultsScroll.heightAnchor.constraint(equalToConstant: 0)
    searchResultsHeight.isActive = true
    searchResultsScroll.isHidden = true
    searchResultsPanel.addArrangedSubview(searchResultsScroll)

    moreSearchButton.setTitle("さらに読み込む", for: .normal)
    moreSearchButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    moreSearchButton.tintColor = NeoStyle.accent
    moreSearchButton.contentHorizontalAlignment = .leading
    moreSearchButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    moreSearchButton.addAction(UIAction { [weak self] _ in self?.onMoreSearch?() }, for: .touchUpInside)
    moreSearchButton.isHidden = true
    searchResultsPanel.addArrangedSubview(moreSearchButton)

    searchRetryButton.setTitle("再検索", for: .normal)
    searchRetryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    searchRetryButton.tintColor = NeoStyle.accent
    searchRetryButton.contentHorizontalAlignment = .leading
    searchRetryButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
    searchRetryButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.onSearch?(self.searchField.text ?? "")
    }, for: .touchUpInside)
    searchRetryButton.isHidden = true
    searchResultsPanel.addArrangedSubview(searchRetryButton)
    searchResultsPanel.isHidden = true

    searchTitle.isHidden = false
    searchField.accessibilityLabel = "録画を検索"
    clearSelectionButton.isHidden = true
    searchResultsPanel.setContentHuggingPriority(.defaultLow, for: .vertical)
    searchField.rightView = clearSelectionButton
    searchField.rightViewMode = .never
    searchField.rightView?.translatesAutoresizingMaskIntoConstraints = false
  }

  private func configureFileSelector() {
    fileSelect.accessibilityLabel = "録画ファイルタイプ"
    fileSelect.setTitle("ファイルを選択", for: .normal)
    fileSelect.isEnabled = false
  }

  private func configureTrackSection() {
    tracksSection.axis = .vertical
    tracksSection.alignment = .fill
    tracksSection.spacing = 8

    tracksHeader.axis = .horizontal
    tracksHeader.alignment = .center
    tracksHeader.spacing = 8
    tracksTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    tracksHeader.addArrangedSubview(tracksTitle)

    reorderButton.setTitle("並び替え", for: .normal)
    reorderButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    reorderButton.tintColor = NeoStyle.accent
    reorderButton.setImage(NeoIcon.image("ReorderOutlined"), for: .normal)
    reorderButton.imageView?.tintColor = NeoStyle.accent
    reorderButton.semanticContentAttribute = .forceLeftToRight
    reorderButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    reorderButton.addAction(UIAction { [weak self] _ in self?.toggleReordering() }, for: .touchUpInside)
    tracksHeader.addArrangedSubview(reorderButton)
    tracksSection.addArrangedSubview(tracksHeader)

    trackLoadingStack.axis = .horizontal
    trackLoadingStack.alignment = .center
    trackLoadingStack.spacing = 10
    trackLoadingIndicator.color = NeoStyle.muted
    trackLoadingStack.addArrangedSubview(trackLoadingIndicator)
    trackStatusLabel.text = "読み込み中…"
    trackLoadingStack.addArrangedSubview(trackStatusLabel)
    trackLoadingStack.isLayoutMarginsRelativeArrangement = true
    trackLoadingStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 0, bottom: 24, trailing: 0)
    tracksSection.addArrangedSubview(trackLoadingStack)

    trackErrorStack.axis = .vertical
    trackErrorStack.alignment = .fill
    trackErrorStack.spacing = 8
    trackErrorStack.isLayoutMarginsRelativeArrangement = true
    trackErrorStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    trackErrorStack.layer.cornerRadius = 6
    trackErrorStack.backgroundColor = UIColor(red: 22/255, green: 11/255, blue: 11/255, alpha: 1)
    trackErrorLabel.numberOfLines = 0
    trackErrorLabel.textColor = UIColor(red: 244/255, green: 199/255, blue: 199/255, alpha: 1)
    trackErrorStack.addArrangedSubview(trackErrorLabel)
    trackRetryButton.setTitle("再読み込み", for: .normal)
    trackRetryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    trackRetryButton.tintColor = NeoStyle.accent
    trackRetryButton.contentHorizontalAlignment = .leading
    trackRetryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
    trackErrorStack.addArrangedSubview(trackRetryButton)
    tracksSection.addArrangedSubview(trackErrorStack)

    [noFileLabel, noTracksLabel].forEach {
      $0.numberOfLines = 0
      tracksSection.addArrangedSubview($0)
    }

    trackList.axis = .vertical
    trackList.alignment = .fill
    trackList.spacing = 8
    tracksSection.addArrangedSubview(trackList)

    saveOrderButton.setTitle("字幕順序を保存", for: .normal)
    saveOrderButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    saveOrderButton.setTitleColor(.black, for: .normal)
    saveOrderButton.backgroundColor = NeoStyle.accent
    saveOrderButton.setImage(NeoIcon.image("SaveOutlined"),for:.normal)
    saveOrderButton.layer.cornerRadius = 6
    saveOrderButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    saveOrderButton.addAction(UIAction { [weak self] _ in self?.saveOrder() }, for: .touchUpInside)
    trackList.addArrangedSubview(saveOrderButton)
  }

  private func configurePendingEditor() {
    pendingEditor.axis = .vertical
    pendingEditor.alignment = .fill
    pendingEditor.spacing = 6
    pendingTitleLabel.numberOfLines = 1
    pendingEditor.addArrangedSubview(pendingTitleLabel)

    pendingTitleRow.axis = .horizontal
    pendingTitleRow.alignment = .center
    pendingTitleRow.spacing = 8
    configureTextField(pendingTitleField, placeholder: "移植後の字幕名")
    pendingTitleField.delegate = self
    pendingTitleField.addTarget(self, action: #selector(pendingTitleChanged), for: .editingChanged)
    pendingTitleField.accessibilityLabel = "移植後の字幕名"
    pendingTitleRow.addArrangedSubview(pendingTitleField)
    pendingTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    pendingCancelButton.setImage(NeoIcon.image("Close"), for: .normal)
    pendingCancelButton.tintColor = .white
    pendingCancelButton.accessibilityLabel = "移植予定から外す"
    pendingCancelButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
    pendingCancelButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
    pendingCancelButton.addAction(UIAction { [weak self] _ in self?.onPendingCancel?() }, for: .touchUpInside)
    pendingTitleRow.addArrangedSubview(pendingCancelButton)
    pendingEditor.addArrangedSubview(pendingTitleRow)

    pendingEditor.isLayoutMarginsRelativeArrangement = true
    pendingEditor.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    pendingEditor.layer.cornerRadius = 6
    pendingEditor.layer.borderWidth = 1
    pendingEditor.layer.borderColor = NeoStyle.accent.cgColor
  }

  private func configureTextField(_ field: UITextField, placeholder: String) {
    field.borderStyle = .none
    field.font = .systemFont(ofSize: 16)
    field.textColor = .white
    field.tintColor = NeoStyle.accent
    field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NeoStyle.muted])
    field.layer.cornerRadius = 6
    field.layer.borderWidth = 1
    field.layer.borderColor = NeoStyle.border.cgColor
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
    field.leftViewMode = .always
    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    field.delegate = self
  }

  private func refreshTrackState() {
    let hasFile = fileID != nil
    let hasTracks = !tracks.isEmpty
    let showLoading = isLoading && hasFile
    trackLoadingStack.isHidden = !showLoading
    trackErrorStack.isHidden = showLoading || tracksError == nil
    if let tracksError, !showLoading {
      trackErrorLabel.text = tracksError.hasPrefix("字幕一覧を取得できません") ? tracksError : "字幕一覧を取得できません: \(tracksError)"
    }
    noFileLabel.isHidden = showLoading || tracksError != nil || hasFile
    noTracksLabel.isHidden = showLoading || tracksError != nil || !hasFile || !tracks.isEmpty
    trackList.isHidden = showLoading || tracksError != nil || !hasFile || !hasTracks
    reorderButton.isHidden = tracks.count <= 1
    refreshRowControls()
    if showLoading { trackLoadingIndicator.startAnimating() } else { trackLoadingIndicator.stopAnimating() }
    trackRetryButton.isEnabled = !processing
  }

  private func rebuildTrackRows() {
    for child in trackList.arrangedSubviews where child !== saveOrderButton {
      trackList.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    rows.removeAll()
    let orderedTracks: [NeoManagedTrack]
    if isReordering {
      let byIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.subtitleIndex, $0) })
      orderedTracks = localOrder.compactMap { byIndex[$0] }
    } else {
      orderedTracks = tracks
    }
    for (position, track) in orderedTracks.enumerated() {
      let row = makeTrackRow(track, position: position, count: orderedTracks.count)
      rows[track.subtitleIndex] = row
      trackList.insertArrangedSubview(row.card, at: position)
    }
    saveOrderButton.isHidden = !isReordering
    refreshRowControls()
    onHeightChange?()
  }

  private func makeTrackRow(_ track: NeoManagedTrack, position: Int, count: Int) -> TrackRow {
    let card = UIStackView()
    card.axis = .vertical
    card.alignment = .fill
    card.spacing = 8
    card.isLayoutMarginsRelativeArrangement = true
    card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    card.layer.cornerRadius = 6
    card.layer.borderWidth = 1
    card.layer.borderColor = NeoStyle.border.cgColor

    let title = NeoStyle.label(track.name, size: 14)
    title.numberOfLines = 1
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let chips = NeoTrackChipFlow()
    chips.setValues([track.codecName, track.language, track.isDefault ? "default" : nil, track.isForced ? "forced" : nil].compactMap { $0 })

    let moveUp = iconButton("chevron.up", label: "一つ上へ移動") { [weak self] in self?.moveTrack(track.subtitleIndex, direction: -1) }
    let moveDown = iconButton("chevron.down", label: "一つ下へ移動") { [weak self] in self?.moveTrack(track.subtitleIndex, direction: 1) }
    let reorderButtons = UIStackView(arrangedSubviews: [moveUp, moveDown])
    reorderButtons.axis = .horizontal
    reorderButtons.alignment = .center
    reorderButtons.spacing = 0

    let renameButton = iconButton("square.and.pencil", label: "字幕名を変更") { [weak self] in self?.beginRename(track) }
    let queueButton = iconButton(sourceIsLeft ? "arrow.right" : "arrow.left", label: sourceIsLeft ? "右のMKVへ移植" : "左のMKVへ移植") { [weak self] in
      self?.onQueue?(track)
    }

    let topRow = UIStackView(arrangedSubviews: [title, reorderButtons, renameButton, queueButton])
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.spacing = 4
    card.addArrangedSubview(topRow)
    card.addArrangedSubview(chips)

    let editRow = UIStackView()
    editRow.axis = .horizontal
    editRow.alignment = .center
    editRow.spacing = 8
    let editField = UITextField()
    configureTextField(editField, placeholder: "字幕名")
    editField.accessibilityLabel = "字幕名"
    editField.text = editingSubtitleIndex == track.subtitleIndex ? editingTitle : track.name
    editField.addTarget(self, action: #selector(renameTextChanged(_:)), for: .editingChanged)
    editRow.addArrangedSubview(editField)
    editField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let saveEdit = iconButton("square.and.arrow.down", label: "字幕名を保存") { [weak self] in self?.saveRename(track) }
    let cancelEdit = iconButton("xmark", label: "名前変更を取り消す") { [weak self] in self?.cancelRename() }
    editRow.addArrangedSubview(saveEdit)
    editRow.addArrangedSubview(cancelEdit)
    editRow.isHidden = editingSubtitleIndex != track.subtitleIndex
    card.addArrangedSubview(editRow)

    // The row stores its position controls; refresh after all rows exist so the
    // first/last arrows and save action reflect the entire ordered list.
    _ = position
    _ = count
    return TrackRow(card: card, title: title, chips: chips, reorderButtons: reorderButtons, moveUp: moveUp,
      moveDown: moveDown, renameButton: renameButton, queueButton: queueButton, editRow: editRow,
      editField: editField, saveEdit: saveEdit, cancelEdit: cancelEdit)
  }

  private func refreshRowControls() {
    let ordered = orderedTrackIndices()
    for index in ordered.indices {
      guard let row = rows[ordered[index]] else { continue }
      row.reorderButtons.isHidden = !isReordering
      row.renameButton.isHidden = isReordering
      row.queueButton.isHidden = isReordering
      row.editRow.isHidden = editingSubtitleIndex != ordered[index]
      row.moveUp.isEnabled = !processing && index > 0
      row.moveDown.isEnabled = !processing && index < ordered.count - 1
      row.renameButton.isEnabled = !processing
      row.queueButton.isEnabled = canQueue && !processing
      row.saveEdit.isEnabled = !processing && NeoMediaTools.validTitle(row.editField.text ?? "")
      row.cancelEdit.isEnabled = !processing
      if editingSubtitleIndex == ordered[index], !row.editField.isFirstResponder, row.editField.text != editingTitle {
        row.editField.text = editingTitle
      }
    }
    reorderButton.isEnabled = !processing
    reorderButton.setTitle(isReordering ? "取消" : "並び替え", for: .normal)
    reorderButton.setImage(NeoIcon.image(isReordering ? "Close" : "ReorderOutlined"), for: .normal)
    saveOrderButton.isHidden = !isReordering
    saveOrderButton.isEnabled = !processing && NeoMediaTools.validOrder(localOrder, tracks: tracks)
    saveOrderButton.alpha = saveOrderButton.isEnabled ? 1 : 0.55
    updateQueueButtonImages()
  }

  private func updateQueueButtonImages() {
    for row in rows.values {
      row.queueButton.setImage(NeoIcon.image(sourceIsLeft ? "ArrowForwardOutlined" : "ArrowBackOutlined"), for: .normal)
      row.queueButton.accessibilityLabel = sourceIsLeft ? "右のMKVへ移植" : "左のMKVへ移植"
    }
  }

  private func orderedTrackIndices() -> [Int] {
    if isReordering { return localOrder }
    return tracks.map(\.subtitleIndex)
  }

  private func toggleReordering() {
    guard !processing, tracks.count > 1 else { return }
    editingSubtitleIndex = nil
    editingTitle = ""
    isReordering.toggle()
    localOrder = tracks.map(\.subtitleIndex)
    rebuildTrackRows()
  }

  private func moveTrack(_ subtitleIndex: Int, direction: Int) {
    guard !processing, isReordering, let position = localOrder.firstIndex(of: subtitleIndex) else { return }
    let target = position + direction
    guard target >= 0, target < localOrder.count else { return }
    localOrder.swapAt(position, target)
    rebuildTrackRows()
  }

  private func saveOrder() {
    guard !processing, NeoMediaTools.validOrder(localOrder, tracks: tracks) else { return }
    onReorder?(localOrder)
  }

  private func beginRename(_ track: NeoManagedTrack) {
    guard !processing, !isReordering else { return }
    editingSubtitleIndex = track.subtitleIndex
    editingTitle = track.name
    rebuildTrackRows()
    rows[track.subtitleIndex]?.editField.becomeFirstResponder()
  }

  private func saveRename(_ track: NeoManagedTrack) {
    guard !processing, NeoMediaTools.validTitle(editingTitle) else { return }
    onRename?(track, editingTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    editingSubtitleIndex = nil
    editingTitle = ""
    rebuildTrackRows()
  }

  private func cancelRename() {
    guard !processing else { return }
    editingSubtitleIndex = nil
    editingTitle = ""
    rebuildTrackRows()
  }

  private func refreshSearchResultsPanel() {
    clearSelectionButton.isHidden = recording == nil
    searchField.rightViewMode = recording == nil ? .never : .always
    let hasQuery = !(searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasContent = !candidateRecords.isEmpty || candidateLoading || candidateError != nil || (hasQuery && !suggestionsDismissed)
    searchResultsPanel.isHidden = suggestionsDismissed || !hasContent
  }

  private func rebuildSearchResults() {
    for child in searchResultsList.arrangedSubviews {
      searchResultsList.removeArrangedSubview(child)
      child.removeFromSuperview()
    }

    for (position, item) in candidateRecords.enumerated() {
      let option = makeRecordingOption(item)
      searchResultsList.addArrangedSubview(option)
      if position < candidateRecords.count - 1 {
        let separator = UIView()
        separator.backgroundColor = NeoStyle.border
        separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        searchResultsList.addArrangedSubview(separator)
      }
    }

    searchResultsScroll.isHidden = candidateRecords.isEmpty
    let rowHeight: CGFloat = 60
    searchResultsHeight.constant = candidateRecords.isEmpty ? 0 : min(220, CGFloat(candidateRecords.count) * rowHeight)
    moreSearchButton.isHidden = !candidateMore || !UIAccessibility.isVoiceOverRunning
    moreSearchButton.isEnabled = !candidateLoading
    moreSearchButton.setTitle(candidateLoading ? "読み込み中…" : "さらに読み込む", for: .normal)
    searchRetryButton.isHidden = candidateError == nil

    let message: String?
    let color: UIColor
    if let candidateError {
      message = candidateError
      color = UIColor(red: 244/255, green: 199/255, blue: 199/255, alpha: 1)
    } else if candidateLoading && candidateRecords.isEmpty {
      message = "検索中…"
      color = NeoStyle.muted
    } else if candidateRecords.isEmpty && !(searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !suggestionsDismissed {
      message = "録画が見つかりません。"
      color = NeoStyle.muted
    } else {
      message = nil
      color = NeoStyle.muted
    }
    searchResultsStatus.text = message
    searchResultsStatus.textColor = color
    searchResultsStatus.isHidden = message == nil
    refreshSearchResultsPanel()
  }

  private func makeRecordingOption(_ item: NeoRecording) -> UIView {
    let optionButton = UIButton(type: .system)
    optionButton.backgroundColor = .clear
    optionButton.contentHorizontalAlignment = .leading
    optionButton.accessibilityLabel = "\(item.name), \(candidateChannels[item.channelId ?? -1] ?? item.channelName ?? "チャンネル不明"), \(Self.recordingDate(item.startAt))"
    optionButton.addAction(UIAction { [weak self] _ in self?.selectRecording(item) }, for: .touchUpInside)
    let title = NeoStyle.label(item.name, size: 14)
    title.numberOfLines = 1
    let channel = item.channelId.flatMap { candidateChannels[$0] } ?? item.channelName ?? item.channelId.map { "チャンネル \($0)" } ?? "チャンネル不明"
    let details = NeoStyle.label("\(channel) ・ \(Self.recordingDate(item.startAt))", size: 12, muted: true)
    details.numberOfLines = 1
    let labels = UIStackView(arrangedSubviews: [title, details])
    labels.axis = .vertical
    labels.alignment = .fill
    labels.spacing = 3
    labels.translatesAutoresizingMaskIntoConstraints = false
    optionButton.addSubview(labels)
    NSLayoutConstraint.activate([
      labels.leadingAnchor.constraint(equalTo: optionButton.leadingAnchor, constant: 12),
      labels.trailingAnchor.constraint(equalTo: optionButton.trailingAnchor, constant: -12),
      labels.centerYAnchor.constraint(equalTo: optionButton.centerYAnchor),
      optionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
    ])
    return optionButton
  }

  private func selectRecording(_ item: NeoRecording) {
    suggestionsDismissed = true
    searchResultsPanel.isHidden = true
    searchField.resignFirstResponder()
    onSelectRecording?(item)
  }

  private func clearRecordingSelection() {
    guard recording != nil else { return }
    suggestionsDismissed = false
    searchField.text = ""
    candidateRecords = []
    candidateMore = false
    candidateLoading = false
    candidateError = nil
    rebuildSearchResults()
    onSearch?("")
    onSelectRecording?(nil)
    searchField.becomeFirstResponder()
  }

  private static func fileLabel(_ video: NeoVideoFile) -> String {
    let filename = video.filename ?? video.name
    return "\(video.name) — \(filename) (\(Self.formatBytes(video.size)))"
  }

  private static func formatBytes(_ size: Double) -> String {
    let safeSize = max(0, size)
    if safeSize >= 1024 * 1024 * 1024 { return String(format: "%.2f GB", safeSize / 1024 / 1024 / 1024) }
    if safeSize >= 1024 * 1024 { return String(format: "%.1f MB", safeSize / 1024 / 1024) }
    return "\(Int((safeSize / 1024).rounded())) KB"
  }

  private static func recordingDate(_ startAt: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy/MM/dd(E) HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: startAt / 1000))
  }

  private static func notice(_ text: String, warning: Bool) -> UIView {
    let label = NeoStyle.label(text, size: 14)
    label.numberOfLines = 0
    if warning {
      label.textColor = UIColor(red: 255/255, green: 226/255, blue: 183/255, alpha: 1)
    } else {
      label.textColor = UIColor(red: 184/255, green: 231/255, blue: 251/255, alpha: 1)
    }
    let box = UIStackView(arrangedSubviews: [label])
    box.axis = .vertical
    box.alignment = .fill
    box.isLayoutMarginsRelativeArrangement = true
    box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    box.layer.cornerRadius = 6
    box.backgroundColor = warning
      ? UIColor(red: 25/255, green: 18/255, blue: 7/255, alpha: 1)
      : UIColor(red: 7/255, green: 19/255, blue: 24/255, alpha: 1)
    return box
  }

  private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    let names = ["chevron.up":"KeyboardArrowUpOutlined","chevron.down":"KeyboardArrowDownOutlined","square.and.pencil":"EditOutlined","arrow.right":"ArrowForwardOutlined","arrow.left":"ArrowBackOutlined","square.and.arrow.down":"SaveOutlined","xmark":"Close"]
    button.setImage(NeoIcon.image(names[symbol] ?? symbol), for: .normal)
    button.tintColor = .white
    button.accessibilityLabel = label
    button.widthAnchor.constraint(equalToConstant: 38).isActive = true
    button.heightAnchor.constraint(equalToConstant: 38).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  @objc private func searchTextChanged() {
    suggestionsDismissed = false
    onSearch?(searchField.text ?? "")
    refreshSearchResultsPanel()
  }

  @objc private func pendingTitleChanged() {
    guard pendingTitleField.markedTextRange == nil else { return }
    let value = Self.limitUTF16(pendingTitleField.text ?? "")
    if value != pendingTitleField.text { pendingTitleField.text = value }
    pendingTitle = value
    onPendingTitle?(value)
  }

  @objc private func renameTextChanged(_ sender: UITextField) {
    guard sender.markedTextRange == nil else { return }
    let value = Self.limitUTF16(sender.text ?? "")
    if value != sender.text { sender.text = value }
    editingTitle = value
    refreshRowControls()
  }

  private static func limitUTF16(_ value: String) -> String {
    let source = value as NSString
    guard source.length > 128 else { return value }
    var end = 0
    while end < source.length {
      let sequence = source.rangeOfComposedCharacterSequence(at: end)
      guard NSMaxRange(sequence) <= 128 else { break }
      end = NSMaxRange(sequence)
    }
    return source.substring(to: end)
  }

  func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
    if textField === searchField { return true }
    if textField.markedTextRange != nil { return true }
    let current = (textField.text ?? "") as NSString
    let nextLength = current.length - range.length + (string as NSString).length
    return nextLength <= 128
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === searchField {
      onSearch?(searchField.text ?? "")
    }
    textField.resignFirstResponder()
    return true
  }
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === searchResultsScroll, scrollView.isDragging || scrollView.isDecelerating,
      !searchResultsPanel.isHidden, !suggestionsDismissed, candidateMore, !candidateLoading else { return }
    if scrollView.contentOffset.y+scrollView.bounds.height >= scrollView.contentSize.height-48 { onMoreSearch?() }
  }
}

private final class NeoTrackChipFlow: UIView {
  private var labels: [NeoTrackChipLabel] = []
  private var measuredHeight: CGFloat = 0

  func setValues(_ values: [String]) {
    labels.forEach { $0.removeFromSuperview() }
    labels = values.map { value in
      let label = NeoTrackChipLabel()
      label.text = value
      label.sizeToFit()
      addSubview(label)
      return label
    }
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let gap: CGFloat = 4
    let rowGap: CGFloat = 4
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for label in labels {
      let width = min(label.intrinsicContentSize.width, bounds.width)
      let height = label.intrinsicContentSize.height
      if x > 0, x + width > bounds.width {
        x = 0
        y += rowHeight + rowGap
        rowHeight = 0
      }
      label.frame = CGRect(x: x, y: y, width: width, height: height)
      x += width + gap
      rowHeight = max(rowHeight, height)
    }
    let nextHeight = labels.isEmpty ? 0 : y + rowHeight
    if abs(nextHeight - measuredHeight) > 0.5 {
      measuredHeight = nextHeight
      invalidateIntrinsicContentSize()
    }
  }
}

private final class NeoTrackChipLabel: UILabel {
  private let insets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
  override init(frame: CGRect) {
    super.init(frame: frame)
    font = .systemFont(ofSize: 13)
    textColor = .white
    backgroundColor = UIColor.white.withAlphaComponent(0.16)
    layer.cornerRadius = 12
    clipsToBounds = true
    lineBreakMode = .byTruncatingTail
  }
  required init?(coder: NSCoder) { fatalError() }
  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + insets.left + insets.right, height: max(24, size.height + insets.top + insets.bottom))
  }
}
