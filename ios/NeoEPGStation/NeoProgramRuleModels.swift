import Foundation

struct NeoProgramRule: Decodable, Equatable {
  let id: Int
  let userId: Int?
  let isTimeSpecification: Bool
  let searchOption: NeoProgramSearchOption
  let reserveOption: NeoProgramRuleReserveOption
  let saveOption: NeoProgramRuleSaveOption?
  let encodeOption: NeoProgramRuleEncodeOption?
  var reservesCnt: Int? = nil
  var annictId: Int? = nil

  var listTitle: String {
    let keyword = searchOption.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return keyword.isEmpty ? (isTimeSpecification ? "時刻指定ルール" : "キーワード指定なし") : keyword
  }

  func listConditions(channelNames: [Int: String]) -> String {
    var types = searchOption.channelTypes ?? []
    if searchOption.BS4K == true && !types.contains("BS4K") { types.append("BS4K") }
    let channels: [String]
    if let ids = searchOption.channelIds, !ids.isEmpty {
      channels = ids.map { channelNames[$0] ?? String($0) }
    } else if !types.isEmpty {
      channels = types.map(NeoProgramSearchMetadata.channelTypeLabel)
    } else {
      channels = [("GR", searchOption.GR), ("BS", searchOption.BS), ("CS", searchOption.CS),
        ("SKY", searchOption.SKY), ("BS4K", searchOption.BS4K)].compactMap { $0.1 == true ? $0.0 : nil }
    }
    var seen = Set<String>()
    let genres = (searchOption.genres ?? []).map { NeoProgramSearchMetadata.genreLabel($0.genre, sub: $0.subGenre) }
      .filter { seen.insert($0).inserted }
    let channelLabel = channels.isEmpty ? "全局" : channels.joined(separator: "、")
    let genreLabel = genres.isEmpty ? "全ジャンル" : genres.joined(separator: "、")
    return "\(channelLabel) / \(genreLabel)"
  }

  var listEncodeSummary: String? {
    guard let encodeOption, encodeOption.mode1 != nil else { return nil }
    let modes = [encodeOption.mode1, encodeOption.mode2, encodeOption.mode3]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "、")
    let delay = encodeOption.startDelayMinutes ?? 0
    return "エンコード: \(modes)" + (delay > 0 ? "（録画完了後\(delay)分待機）" : "")
  }

  var scheduleLabel: String {
    guard let time = searchOption.times?.first, let start = time.start, let range = time.range else { return "時刻情報なし" }
    let weekdays = NeoProgramSearchMetadata.weekItems.filter { time.week & $0.bit != 0 }.map(\.label)
    let days = weekdays.count == 7 ? "毎日" : weekdays.joined(separator: "・")
    let window = NeoProgramRuleTime.text(start) + "～" + NeoProgramRuleTime.endText(start: start, range: range)
    return days.isEmpty ? window : "\(days) \(window)"
  }
}

struct NeoRuleListQuery: Equatable {
  var userID: Int?
  var keyword = ""
  var hasReserve = false
  var page = 1
  var limit = 24

  var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = [.init(name: "type", value: "normal"),
      .init(name: "offset", value: String((max(1, page) - 1) * limit)), .init(name: "limit", value: String(limit))]
    if let userID, userID > 0 { items.append(.init(name: "userId", value: String(userID))) }
    if !keyword.isEmpty { items.append(.init(name: "keyword", value: keyword)) }
    if hasReserve { items.append(.init(name: "hasReserve", value: "true")) }
    return items
  }

  func pageCount(total: Int) -> Int { total > 0 ? (total - 1) / limit + 1 : 1 }
}

struct NeoRuleList: Decodable, Equatable {
  let rules: [NeoProgramRule]
  let total: Int
}

struct NeoRuleMutationResult: Decodable {
  let annictStatusError: String?
  let annictLinkError: String?
}

struct NeoProgramRuleWrite: Encodable {
  let userId: Int
  let isTimeSpecification: Bool
  let searchOption: NeoProgramSearchOption
  let reserveOption: NeoProgramRuleReserveOption
  let saveOption: NeoProgramRuleSaveOption?
  let encodeOption: NeoProgramRuleEncodeOption?
}

struct NeoProgramRuleReserveOption: Codable, Equatable {
  var enable: Bool
  var allowEndLack: Bool
  var avoidDuplicate: Bool
  var periodToAvoidDuplicate: Double?
  var tags: [Int]?
}

struct NeoProgramRuleSaveOption: Codable, Equatable {
  var parentDirectoryName: String?
  var directory: String?
  var recordedFormat: String?
}

struct NeoProgramRuleEncodeOption: Codable, Equatable {
  var mode1: String?, mode2: String?, mode3: String?
  var channelIds1: [Int]?, channelIds2: [Int]?, channelIds3: [Int]?
  var channelId1: Int?, channelId2: Int?, channelId3: Int?
  var encodeParentDirectoryName1: String?, encodeParentDirectoryName2: String?, encodeParentDirectoryName3: String?
  var directory1: String?, directory2: String?, directory3: String?
  var isDeleteOriginalAfterEncode: Bool?
  var updateThumbnail: Bool?
  var startDelayMinutes: Int?

  var rows: [NeoProgramRuleEncodeDraft] {
    let slots = [
      row(mode1, channelIds1, channelId1, encodeParentDirectoryName1, directory1),
      row(mode2, channelIds2, channelId2, encodeParentDirectoryName2, directory2),
      row(mode3, channelIds3, channelId3, encodeParentDirectoryName3, directory3),
    ]
    return Array(slots.prefix((slots.lastIndex { !$0.mode.isEmpty } ?? 0) + 1))
  }

  private func row(_ mode: String?, _ channelIDs: [Int]?, _ legacyChannelID: Int?, _ parent: String?, _ path: String?) -> NeoProgramRuleEncodeDraft {
    .init(mode: mode ?? "", channelIDs: channelIDs ?? legacyChannelID.map { [$0] } ?? [],
      parentDirectoryName: parent ?? "", directory: path ?? "")
  }

  mutating func apply(_ row: NeoProgramRuleEncodeDraft, at index: Int) {
    guard !row.mode.isEmpty else { return }
    let channels = row.channelIDs.isEmpty ? nil : row.channelIDs
    let channel = row.channelIDs.count == 1 ? row.channelIDs.first : nil
    let parent = row.parentDirectoryName.isEmpty ? nil : row.parentDirectoryName
    let path = row.directory.ruleText
    switch index {
    case 0:
      mode1 = row.mode; channelIds1 = channels; channelId1 = channel; encodeParentDirectoryName1 = parent; directory1 = path
    case 1:
      mode2 = row.mode; channelIds2 = channels; channelId2 = channel; encodeParentDirectoryName2 = parent; directory2 = path
    case 2:
      mode3 = row.mode; channelIds3 = channels; channelId3 = channel; encodeParentDirectoryName3 = parent; directory3 = path
    default: break
    }
  }
}

struct NeoProgramRuleEncodeDraft: Equatable {
  var mode = ""
  var channelIDs: [Int] = []
  var parentDirectoryName = ""
  var directory = ""
}

struct NeoProgramRuleDraft {
  var userID: Int?
  var isTimeSpecification = false
  var timeName = ""
  var timeChannelID: Int?
  var startTime = "00:00"
  var endTime = "00:30"
  var week = 0x7f
  var enabled = true
  var allowEndLack = true
  var avoidDuplicate = false
  var duplicateDays = ""
  var parentDirectoryName = ""
  var directory = ""
  var recordedFormat = ""
  var encodes = [NeoProgramRuleEncodeDraft()]
  var deleteOriginal = false
  var updateThumbnail = false
  var delayMinutes = ""

  init(rule: NeoProgramRule? = nil, activeUserID: Int? = nil) {
    userID = rule?.userId ?? activeUserID
    guard let rule else { return }
    isTimeSpecification = rule.isTimeSpecification
    if isTimeSpecification {
      timeName = rule.searchOption.keyword ?? ""
      timeChannelID = rule.searchOption.channelIds?.first
      if let time = rule.searchOption.times?.first {
        let start = time.start ?? 0
        startTime = NeoProgramRuleTime.text(start)
        endTime = NeoProgramRuleTime.endText(start: start, range: time.range ?? 0)
        week = time.week
      }
    }
    enabled = rule.reserveOption.enable
    allowEndLack = rule.reserveOption.allowEndLack
    avoidDuplicate = rule.reserveOption.avoidDuplicate
    if let days = rule.reserveOption.periodToAvoidDuplicate {
      duplicateDays = Int(exactly: days).map { String($0) } ?? String(days)
    }
    parentDirectoryName = rule.saveOption?.parentDirectoryName ?? ""
    directory = rule.saveOption?.directory ?? ""
    recordedFormat = rule.saveOption?.recordedFormat ?? ""
    if let encode = rule.encodeOption {
      encodes = encode.rows
      deleteOriginal = encode.isDeleteOriginalAfterEncode == true
      updateThumbnail = encode.updateThumbnail == true
      if let delay = encode.startDelayMinutes, delay != 0 { delayMinutes = String(delay) }
    }
  }

  func write(searchOption: NeoProgramSearchOption, existing: NeoProgramRule? = nil) throws -> NeoProgramRuleWrite {
    guard let userID, userID > 0 else { throw invalid("ルールを作成するユーザーを選択してください") }
    if let existing, existing.isTimeSpecification != isTimeSpecification {
      throw invalid("既存ルールの種類は変更できません")
    }
    let baseline = Self(rule: existing)
    let reserve = NeoProgramRuleReserveOption(enable: enabled, allowEndLack: allowEndLack, avoidDuplicate: avoidDuplicate,
      periodToAvoidDuplicate: try duplicatePeriod(), tags: existing?.reserveOption.tags)
    let save = existing != nil && parentDirectoryName == baseline.parentDirectoryName && directory == baseline.directory
      && recordedFormat == baseline.recordedFormat ? existing?.saveOption : saveOptions()
    let encode = try encodeOptions(preserving: existing?.encodeOption, baseline: baseline)
    let conditions: NeoProgramSearchOption
    if isTimeSpecification {
      conditions = try timeOption(preserving: existing?.searchOption, baseline: baseline)
    } else {
      conditions = searchOption
    }
    return .init(userId: userID, isTimeSpecification: isTimeSpecification, searchOption: conditions,
      reserveOption: reserve, saveOption: save, encodeOption: encode)
  }

  private func duplicatePeriod() throws -> Double? {
    guard let value = duplicateDays.ruleText else { return nil }
    guard let days = Double(value.precomposedStringWithCompatibilityMapping), days.isFinite, days >= 0 else {
      throw invalid("重複回避日数を正しく入力してください")
    }
    return days
  }

  private func saveOptions() -> NeoProgramRuleSaveOption? {
    let parent = parentDirectoryName.isEmpty ? nil : parentDirectoryName
    let path = directory.ruleText, format = recordedFormat.ruleText
    guard parent != nil || path != nil || format != nil else { return nil }
    return .init(parentDirectoryName: parent, directory: path, recordedFormat: format)
  }

  private func encodeOptions(preserving original: NeoProgramRuleEncodeOption?, baseline: Self) throws -> NeoProgramRuleEncodeOption? {
    guard encodes.count <= 3 else { throw invalid("エンコードは最大3件です") }
    if var original, encodes == baseline.encodes, deleteOriginal == baseline.deleteOriginal,
       updateThumbnail == baseline.updateThumbnail, delayMinutes == baseline.delayMinutes {
      original.isDeleteOriginalAfterEncode = original.isDeleteOriginalAfterEncode ?? deleteOriginal
      return original
    }
    guard encodes.contains(where: { !$0.mode.isEmpty }) else { return nil }
    let text = delayMinutes.ruleText?.precomposedStringWithCompatibilityMapping ?? "0"
    guard let delay = Int(text), delay >= 0 else { throw invalid("エンコード開始待機時間を0以上の整数で入力してください") }
    var encode = NeoProgramRuleEncodeOption(isDeleteOriginalAfterEncode: deleteOriginal, updateThumbnail: updateThumbnail, startDelayMinutes: delay)
    for (index, row) in encodes.enumerated() { encode.apply(row, at: index) }
    return encode
  }

  private func timeOption(preserving original: NeoProgramSearchOption?, baseline: Self) throws -> NeoProgramSearchOption {
    guard let name = timeName.ruleText else { throw invalid("番組名を入力してください") }
    guard let timeChannelID, timeChannelID > 0 else { throw invalid("放送局を選択してください") }
    guard (1...0x7f).contains(week) else { throw invalid("曜日を1つ以上選択してください") }
    var option = original ?? NeoProgramSearchOption()
    if original == nil || timeName != baseline.timeName { option.keyword = name }
    if original == nil || timeChannelID != baseline.timeChannelID { option.channelIds = [timeChannelID] }
    let originalTime = original?.times?.first
    if originalTime?.start == nil || originalTime?.range == nil
       || startTime != baseline.startTime || endTime != baseline.endTime || week != baseline.week {
      let time = try NeoProgramRuleTime.window(start: startTime, end: endTime)
      option.times = [.init(week: week, start: time.start, range: time.range)]
    }
    return option
  }

  private func invalid(_ message: String) -> NeoProgramSearchForm.ValidationError { .init(message) }
}

enum NeoProgramRuleTime {
  private static let day = 86_400

  static func text(_ seconds: Int) -> String {
    let time = (seconds % day + day) % day
    return String(format: "%02d:%02d", time / 3_600, time % 3_600 / 60)
  }

  static func endText(start: Int, range: Int) -> String {
    text(start % day + range % day)
  }

  static func window(start: String, end: String) throws -> (start: Int, range: Int) {
    guard let from = NeoProgramSearchTime.parse(start), let to = NeoProgramSearchTime.parse(end) else {
      throw NeoProgramSearchForm.ValidationError("時刻を正しく入力してください")
    }
    let startSeconds = from.hour * 3_600 + from.minute * 60
    let endSeconds = to.hour * 3_600 + to.minute * 60
    guard startSeconds != endSeconds else { throw NeoProgramSearchForm.ValidationError("開始時刻と終了時刻を変えてください") }
    return (startSeconds, (endSeconds - startSeconds + day) % day)
  }
}

extension NeoProgramSearchForm {
  init(restoring option: NeoProgramSearchOption) {
    self.init()
    keyword = option.keyword ?? ""
    keywordFields = .init(caseSensitive: option.keyCS == true, regexp: option.keyRegExp == true,
      name: option.name != false, description: option.description != false, extended: option.extended == true)
    ignoreKeyword = option.ignoreKeyword ?? ""
    ignoreFields = .init(caseSensitive: option.ignoreKeyCS == true, regexp: option.ignoreKeyRegExp == true,
      name: option.ignoreName != false, description: option.ignoreDescription != false, extended: option.ignoreExtended == true)
    channelIDs = option.channelIds ?? []
    let legacyWaves = [("GR", option.GR), ("BS", option.BS), ("CS", option.CS), ("SKY", option.SKY)]
    channelTypes = option.channelTypes ?? legacyWaves.compactMap { $0.1 == true ? $0.0 : nil }
    if option.BS4K == true, !channelTypes.contains("BS4K") { channelTypes.append("BS4K") }
    let savedGenres = option.genres ?? []
    let fullGenres = Set(savedGenres.filter { $0.subGenre == nil }.map(\.genre))
    var seenGenres = Set<Int>(), seenSubGenres = Set<String>()
    genres = savedGenres.map(\.genre).filter { seenGenres.insert($0).inserted }
    subGenres = savedGenres.compactMap { item -> String? in
      guard let sub = item.subGenre, !fullGenres.contains(item.genre) else { return nil }
      return "\(item.genre):\(sub)"
    }.filter { seenSubGenres.insert($0).inserted }
    if let time = option.times?.first { startHour = time.start; rangeHour = time.range; week = time.week }
    durationMin = Self.minutesText(option.durationMin)
    durationMax = Self.minutesText(option.durationMax)
    if let period = option.searchPeriods?.first {
      if period.startAt != 0 { (startDate, startTime) = Self.dateFields(period.startAt) }
      if period.endAt != NeoProgramSearchTime.openPeriodEnd { (endDate, endTime) = Self.dateFields(period.endAt) }
    }
    isFree = option.isFree == true
  }

  /// Retain conditions that the user did not edit, including additional
  /// periods/time ranges and historical broadcast flags.
  func ruleOption(preserving original: NeoProgramSearchOption?) throws -> NeoProgramSearchOption {
    guard var option = original else { return try prepared().option }
    let baseline = Self(restoring: option)
    if self == baseline { return option }
    var changed = self
    if durationMin == baseline.durationMin { changed.durationMin = "" }
    if durationMax == baseline.durationMax { changed.durationMax = "" }
    let prepared = try changed.prepared().option
    if keyword != baseline.keyword || keywordFields != baseline.keywordFields {
      option.keyword = prepared.keyword; option.keyCS = prepared.keyCS; option.keyRegExp = prepared.keyRegExp
      option.name = prepared.name; option.description = prepared.description; option.extended = prepared.extended
    }
    if ignoreKeyword != baseline.ignoreKeyword || ignoreFields != baseline.ignoreFields {
      option.ignoreKeyword = prepared.ignoreKeyword; option.ignoreKeyCS = prepared.ignoreKeyCS; option.ignoreKeyRegExp = prepared.ignoreKeyRegExp
      option.ignoreName = prepared.ignoreName; option.ignoreDescription = prepared.ignoreDescription; option.ignoreExtended = prepared.ignoreExtended
    }
    if channelIDs != baseline.channelIDs || channelTypes != baseline.channelTypes {
      option.channelIds = prepared.channelIds; option.channelTypes = prepared.channelTypes; option.BS4K = prepared.BS4K
      option.GR = nil; option.BS = nil; option.CS = nil; option.SKY = nil
    }
    if genres != baseline.genres || subGenres != baseline.subGenres { option.genres = prepared.genres }
    if startHour != baseline.startHour || rangeHour != baseline.rangeHour || week != baseline.week { option.times = prepared.times }
    if durationMin != baseline.durationMin { option.durationMin = prepared.durationMin }
    if durationMax != baseline.durationMax { option.durationMax = prepared.durationMax }
    if isFree != baseline.isFree { option.isFree = prepared.isFree }
    if startDate != baseline.startDate || startTime != baseline.startTime || endDate != baseline.endDate || endTime != baseline.endTime {
      option.searchPeriods = prepared.searchPeriods
    }
    return option
  }

  private static func minutesText(_ seconds: Int?) -> String {
    guard let seconds else { return "" }
    return seconds.isMultiple(of: 60) ? String(seconds / 60) : String(Double(seconds) / 60)
  }

  private static func dateFields(_ milliseconds: Int64) -> (String, String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let fields = formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)).split(separator: " ")
    return fields.count == 2 ? (String(fields[0]), String(fields[1])) : ("", "")
  }
}

private extension String {
  var ruleText: String? {
    let text = trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}

struct NeoProgramRuleReservationList: Decodable {
  let reserves: [NeoProgramRuleReservation]
  let total: Int
}

struct NeoProgramRuleReservation: Decodable {
  let id: Int, channelId: Int, name: String, startAt: Double, endAt: Double
  let userId: Int?, ruleId: Int?, programId: Int?
  let description: String?, extended: String?
  let isConflict: Bool?, isSkip: Bool?, isOverlap: Bool?

  var displayProgram: NeoScheduledProgram {
    .init(id: id, channelId: channelId, startAt: startAt, endAt: endAt, isFree: false, name: name, description: description, extended: extended)
  }

  var status: NeoProgramReserveStatus {
    let kind: NeoProgramReserveKind = isConflict == true ? .conflict : isSkip == true ? .skip : isOverlap == true ? .overlap : .normal
    return .init(entries: [.init(kind: kind, item: .init(reserveId: id, userId: userId, programId: programId, ruleId: ruleId))])
  }
}
