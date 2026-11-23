import Foundation

struct NeoReservationValidationError: LocalizedError {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}

struct NeoReservationList: Decodable, Equatable {
  let reserves: [NeoReservationItem]
  let total: Int
}

struct NeoReservationItem: Decodable, Equatable {
  let id: Int, channelId: Int, name: String, startAt: Double, endAt: Double
  var userId: Int?, ruleId: Int?, programId: Int?
  var isSkip: Bool?, isOverlap: Bool?, isConflict: Bool?, isTimeSpecified: Bool?, allowEndLack: Bool?
  var description: String?, extended: String?
  var genre1: Int?, subGenre1: Int?, genre2: Int?, subGenre2: Int?, genre3: Int?, subGenre3: Int?
  var videoType: String?, videoResolution: String?, audioSamplingRate: Int?, audioComponentType: Int?
  var parentDirectoryName: String?, directory: String?, recordedFormat: String?
  var encodeMode1: String?, encodeParentDirectoryName1: String?, encodeDirectory1: String?
  var encodeMode2: String?, encodeParentDirectoryName2: String?, encodeDirectory2: String?
  var encodeMode3: String?, encodeParentDirectoryName3: String?, encodeDirectory3: String?
  var isDeleteOriginalAfterEncode: Bool?, updateThumbnail: Bool?

  var kind: NeoProgramReserveKind {
    if isConflict == true { return .conflict }
    if isSkip == true { return .skip }
    if isOverlap == true { return .overlap }
    return .normal
  }

  var action: NeoReservationAction {
    if isSkip == true { return .restoreSkip }
    if isOverlap == true { return .restoreOverlap }
    return .cancel
  }

  var program: NeoScheduledProgram {
    NeoScheduledProgram(id: programId ?? id, channelId: channelId, startAt: startAt, endAt: endAt, isFree: true,
      name: name, description: description, extended: extended, genre1: genre1, subGenre1: subGenre1,
      genre2: genre2, subGenre2: subGenre2, genre3: genre3, subGenre3: subGenre3, videoType: videoType,
      videoResolution: videoResolution, audioSamplingRate: audioSamplingRate, audioComponentType: audioComponentType)
  }
}

enum NeoReservationAction: Hashable {
  case cancel, restoreSkip, restoreOverlap

  init(kind: NeoProgramReserveKind) {
    switch kind {
    case .skip: self = .restoreSkip
    case .overlap: self = .restoreOverlap
    case .normal, .conflict: self = .cancel
    }
  }
  var suffix: String {
    switch self { case .cancel: return ""; case .restoreSkip: return "/skip"; case .restoreOverlap: return "/overlap" }
  }
  var label: String {
    switch self {
    case .cancel: return "予約をキャンセル"
    case .restoreSkip: return "予約に戻す"
    case .restoreOverlap: return "重複状態を解除"
    }
  }
  var confirmation: String {
    switch self {
    case .cancel: return "予約をキャンセルしますか？"
    case .restoreSkip: return "除外から予約に戻しますか？"
    case .restoreOverlap: return "重複状態を解除しますか？"
    }
  }
  func success(count: Int? = nil) -> String {
    let prefix = count.map { "\($0)件の" } ?? ""
    switch self {
    case .cancel: return "\(prefix)予約をキャンセルしました"
    case .restoreSkip: return (count.map { "\($0)件を" } ?? "") + "除外から予約に戻しました"
    case .restoreOverlap: return (count.map { "\($0)件の" } ?? "") + "重複状態を解除して予約に戻しました"
    }
  }
}

extension NeoProgramReserveKind {
  var queryType: String {
    switch self {
    case .normal: return "normal"
    case .conflict: return "conflict"
    case .overlap: return "overlap"
    case .skip: return "skip"
    }
  }
}

struct NeoReservationOptions: Equatable {
  struct Encode: Equatable {
    var mode = "", parentDirectory = "", directory = ""
  }
  var userID: Int?
  var allowEndLack = true
  var parentDirectory = "", directory = "", recordedFormat = ""
  var encodes = [Encode(), Encode(), Encode()]
  var deleteOriginal = false, updateThumbnail = false

  init(userID: Int?) { self.userID = userID }

  init(reservation: NeoReservationItem) {
    userID = reservation.userId
    allowEndLack = reservation.allowEndLack ?? true
    parentDirectory = reservation.parentDirectoryName ?? ""
    directory = reservation.directory ?? ""
    recordedFormat = reservation.recordedFormat ?? ""
    encodes = [
      .init(mode: reservation.encodeMode1 ?? "", parentDirectory: reservation.encodeParentDirectoryName1 ?? "", directory: reservation.encodeDirectory1 ?? ""),
      .init(mode: reservation.encodeMode2 ?? "", parentDirectory: reservation.encodeParentDirectoryName2 ?? "", directory: reservation.encodeDirectory2 ?? ""),
      .init(mode: reservation.encodeMode3 ?? "", parentDirectory: reservation.encodeParentDirectoryName3 ?? "", directory: reservation.encodeDirectory3 ?? ""),
    ]
    deleteOriginal = reservation.isDeleteOriginalAfterEncode == true
    updateThumbnail = reservation.updateThumbnail == true
  }

  func body() throws -> [String: Any] {
    guard let userID, userID > 0 else { throw NeoReservationValidationError("予約するユーザーを選択してください") }
    var result: [String: Any] = ["userId": userID, "allowEndLack": allowEndLack]
    var save: [String: String] = [:]
    if !parentDirectory.isEmpty { save["parentDirectoryName"] = parentDirectory }
    if let value = Self.nonBlank(directory) { save["directory"] = value }
    if let value = Self.nonBlank(recordedFormat) { save["recordedFormat"] = value }
    if !save.isEmpty { result["saveOption"] = save }
    var encode: [String: Any] = [:]
    for (offset, option) in encodes.enumerated() where !option.mode.isEmpty {
      let index = offset + 1
      encode["mode\(index)"] = option.mode
      if !option.parentDirectory.isEmpty { encode["encodeParentDirectoryName\(index)"] = option.parentDirectory }
      if let value = Self.nonBlank(option.directory) { encode["directory\(index)"] = value }
    }
    if !encode.isEmpty {
      encode["isDeleteOriginalAfterEncode"] = deleteOriginal
      encode["updateThumbnail"] = updateThumbnail
      result["encodeOption"] = encode
    }
    return result
  }

  static func nonBlank(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

struct NeoReservationTime {
  var name: String
  var channelID: Int
  var startDay: String, startClock: String, endDay: String, endClock: String
  private let timeZone: TimeZone

  init(_ program: NeoScheduledProgram, timeZone: TimeZone = .current) {
    self.timeZone = timeZone
    name = program.name; channelID = program.channelId
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = timeZone
    let start = Date(timeIntervalSince1970: program.startAt / 1000)
    let end = Date(timeIntervalSince1970: program.endAt / 1000)
    format.dateFormat = "yyyy/MM/dd"
    startDay = format.string(from: start); endDay = format.string(from: end)
    format.dateFormat = "HH:mm"
    startClock = format.string(from: start); endClock = format.string(from: end)
  }

  func body() throws -> [String: Any] {
    guard let name = NeoReservationOptions.nonBlank(name), channelID > 0 else { throw NeoReservationValidationError("番組名と放送局を入力してください") }
    guard let start = epoch(startDay, startClock), let end = epoch(endDay, endClock), start < end else {
      throw NeoReservationValidationError("開始・終了日時が正しくありません")
    }
    return ["name": name, "channelId": channelID, "startAt": start, "endAt": end]
  }

  private func epoch(_ day: String, _ clock: String) -> Int64? {
    guard let date = NeoDateInput.parse(day), let clock = NeoProgramSearchTime.parse(clock) else { return nil }
    let parts = date.split(separator: "-").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
      hour: clock.hour, minute: clock.minute)).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
  }
}

struct NeoQuickReservationSettings: Codable {
  var mode = "", deleteOriginal = false, updateThumbnail = false

  func options(userID: Int?) -> NeoReservationOptions {
    var options = NeoReservationOptions(userID: userID)
    options.encodes[0].mode = mode
    options.deleteOriginal = deleteOriginal
    options.updateThumbnail = updateThumbnail
    return options
  }
}
