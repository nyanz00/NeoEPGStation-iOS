import Foundation

struct NeoProgramKeywordFields: Equatable {
  var caseSensitive = false, regexp = false, name = true, description = true, extended = false
  mutating func normalize(for keyword: String) {
    if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name, !description, !extended {
      name = true; description = true
    }
  }
}

// The same conditions can later be sent as Rule.searchOption. They do not
// depend on the result limit, current user, or presentation state.
struct NeoProgramSearchOption: Codable, Equatable {
  struct Genre: Codable, Equatable { let genre: Int; let subGenre: Int? }
  struct Time: Codable, Equatable { let week: Int; let start: Int?; let range: Int? }
  struct Period: Codable, Equatable { let startAt: Int64; let endAt: Int64 }
  var keyword: String?, ignoreKeyword: String?
  var keyCS: Bool?, keyRegExp: Bool?, name: Bool?, description: Bool?, extended: Bool?
  var ignoreKeyCS: Bool?, ignoreKeyRegExp: Bool?, ignoreName: Bool?, ignoreDescription: Bool?, ignoreExtended: Bool?
  var channelIds: [Int]?, channelTypes: [String]?, BS4K: Bool?
  var genres: [Genre]?, times: [Time]?, searchPeriods: [Period]?
  var durationMin: Int?, durationMax: Int?, isFree: Bool?
}

struct NeoProgramSearchForm: Equatable {
  var keyword = "", ignoreKeyword = ""
  var keywordFields = NeoProgramKeywordFields(), ignoreFields = NeoProgramKeywordFields()
  var channelIDs: [Int] = [], channelTypes: [String] = []
  var genres: [Int] = [], subGenres: [String] = []
  var startHour: Int?, rangeHour: Int?
  var week = 0x7f
  var durationMin = "", durationMax = "", startDate = "", startTime = "", endDate = "", endTime = ""
  var isFree = false

  static func related(to program: NeoScheduledProgram, includeChannel: Bool, includeGenre: Bool) -> Self {
    var form = Self()
    form.keyword = NeoProgramSearchMetadata.relatedKeyword(program.name)
    if includeChannel { form.channelIDs = [program.channelId] }
    if includeGenre, let (genre, subGenre) = program.genrePairs.first, (0...15).contains(genre) {
      form.genres = [genre]
      if let subGenre, (0...15).contains(subGenre) { form.subGenres = ["\(genre):\(subGenre)"] }
    }
    return form
  }

  func prepared() throws -> (form: Self, option: NeoProgramSearchOption) {
    var form = self, option = NeoProgramSearchOption()
    let keyword = form.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    let ignored = form.ignoreKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    form.keywordFields.normalize(for: keyword); form.ignoreFields.normalize(for: ignored)
    if !keyword.isEmpty {
      let f = form.keywordFields
      option.keyword = keyword; option.keyCS = f.caseSensitive; option.keyRegExp = f.regexp
      option.name = f.name; option.description = f.description; option.extended = f.extended
    }
    if !ignored.isEmpty {
      let f = form.ignoreFields
      option.ignoreKeyword = ignored; option.ignoreKeyCS = f.caseSensitive; option.ignoreKeyRegExp = f.regexp
      option.ignoreName = f.name; option.ignoreDescription = f.description; option.ignoreExtended = f.extended
    }
    if !channelIDs.isEmpty { option.channelIds = channelIDs }
    else if !channelTypes.isEmpty {
      let types = channelTypes.filter { $0 != "BS4K" }
      if !types.isEmpty { option.channelTypes = types }
      if channelTypes.contains("BS4K") { option.BS4K = true }
    }
    if !genres.isEmpty {
      option.genres = genres.flatMap { genre -> [NeoProgramSearchOption.Genre] in
        let prefix = "\(genre):"
        let sub = subGenres.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
        return sub.isEmpty ? [.init(genre: genre, subGenre: nil)] : sub.map { .init(genre: genre, subGenre: $0) }
      }
    }
    let completeHours = startHour != nil && rangeHour != nil
    option.times = [.init(week: week == 0 ? 0x7f : week, start: completeHours ? startHour : nil, range: completeHours ? rangeHour : nil)]
    option.durationMin = try Self.durationSeconds(durationMin)
    option.durationMax = try Self.durationSeconds(durationMax)
    if isFree { option.isFree = true }

    let datesValid = [startDate, endDate].allSatisfy { $0.isEmpty || NeoDateInput.parse($0) != nil }
    let timesValid = [startTime, endTime].allSatisfy { $0.isEmpty || NeoProgramSearchTime.parse($0) != nil }
    guard datesValid && timesValid else { throw ValidationError("検索期間の日時を正しく入力してください") }
    let start = NeoProgramSearchTime.epoch(date: startDate, time: startTime.isEmpty ? "00:00" : startTime)
    let end = NeoProgramSearchTime.epoch(date: endDate, time: endTime.isEmpty ? "23:59" : endTime)
    if let start, let end, start > end { throw ValidationError("開始日時は終了日時以前にしてください") }
    if start != nil || end != nil { option.searchPeriods = [.init(startAt: start ?? 0, endAt: end ?? 253_402_300_799_999)] }
    return (form, option)
  }

  private static func durationSeconds(_ text: String) throws -> Int? {
    guard !text.isEmpty else { return nil }
    let raw = text.precomposedStringWithCompatibilityMapping
    guard let number = Double(raw), number.rounded() == number, let minutes = Int(exactly: number) else {
      throw ValidationError("番組の長さは分単位の整数で入力してください")
    }
    let seconds = minutes.multipliedReportingOverflow(by: 60)
    guard !seconds.overflow else { throw ValidationError("番組の長さを正しく入力してください") }
    return seconds.partialValue
  }

  struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

enum NeoProgramSearchTime {
  static func editing(_ raw: String, previous: String) -> String {
    guard raw.utf16.count >= previous.utf16.count else { return raw }
    let digits = String(raw.precomposedStringWithCompatibilityMapping.filter { $0 >= "0" && $0 <= "9" }.prefix(4))
    guard digits.count >= 2 else { return digits }
    return String(digits.prefix(2)) + ":" + String(digits.dropFirst(2))
  }

  static func parse(_ value: String) -> (hour: Int, minute: Int)? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
          let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 else { return nil }
    return (hour, minute)
  }

  static func epoch(date: String, time: String) -> Int64? {
    guard let iso = NeoDateInput.parse(date), let (hour, minute) = parse(time) else { return nil }
    let parts = iso.split(separator: "-").compactMap { Int($0) }
    let year = parts[0], month = parts[1], day = parts[2], previousYear = year - 1
    let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let daysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][month - 1]
    // Proleptic Gregorian days since 1970-01-01, minus the JST offset.
    let days = previousYear * 365 + previousYear / 4 - previousYear / 100 + previousYear / 400
      + daysBeforeMonth + (leap && month > 2 ? 1 : 0) + day - 1 - 719_162
    return Int64(days) * 86_400_000 + Int64(hour * 60 + minute - 9 * 60) * 60_000
  }
}

struct NeoScheduledProgram: Decodable, Equatable {
  let id: Int, channelId: Int, startAt: Double, endAt: Double, isFree: Bool, name: String
  var description: String?, extended: String?
  var genre1: Int?, subGenre1: Int?, genre2: Int?, subGenre2: Int?, genre3: Int?, subGenre3: Int?
  var videoType: String?, videoResolution: String?, audioSamplingRate: Int?, audioComponentType: Int?
  var genrePairs: [(Int, Int?)] {
    [(genre1, subGenre1), (genre2, subGenre2), (genre3, subGenre3)].compactMap { genre, sub in genre.map { ($0, sub) } }
  }
  var genreLabels: [String] { genrePairs.map { NeoProgramSearchMetadata.genreLabel($0.0, sub: $0.1) } }
  var durationMinutes: Int { max(0, Int(exactly: ((endAt - startAt) / 60_000).rounded(.toNearestOrAwayFromZero)) ?? 0) }
}

enum NeoProgramReserveKind: Int, Hashable, CaseIterable {
  // Highest priority first, matching the Web's result and dialog chips.
  case normal, conflict, overlap, skip
  var label: String {
    switch self { case .normal: return "予約"; case .conflict: return "競合"; case .overlap: return "重複"; case .skip: return "除外" }
  }
}

struct NeoProgramReserveEntry: Equatable {
  struct Item: Decodable, Equatable { let reserveId: Int; let userId: Int?; let programId: Int?; let ruleId: Int? }
  let kind: NeoProgramReserveKind, item: Item
}

struct NeoProgramReserveStatus: Equatable {
  let entries: [NeoProgramReserveEntry]
  var primary: NeoProgramReserveKind { entries[0].kind }
  func label(inResult: Bool) -> String {
    let main = primary == .normal && inResult ? "予約済み" : primary.label
    let secondary = NeoProgramReserveKind.allCases.filter { kind in kind != primary && entries.contains { $0.kind == kind } }
    return secondary.isEmpty ? main : main + "＋" + secondary.map { $0.label + "あり" }.joined(separator: "・")
  }
}

struct NeoProgramReserveLists: Decodable {
  let normal: [NeoProgramReserveEntry.Item], conflicts: [NeoProgramReserveEntry.Item]
  let overlaps: [NeoProgramReserveEntry.Item], skips: [NeoProgramReserveEntry.Item]

  var index: [Int: NeoProgramReserveStatus] {
    var programs: [Int: [NeoProgramReserveEntry]] = [:]
    let groups: [(NeoProgramReserveKind, [NeoProgramReserveEntry.Item])] = [(.normal, normal), (.conflict, conflicts), (.overlap, overlaps), (.skip, skips)]
    for (kind, items) in groups {
      var seen: [Int: Set<Int>] = [:]
      for item in items {
        guard let program = item.programId, seen[program, default: []].insert(item.reserveId).inserted else { continue }
        programs[program, default: []].append(.init(kind: kind, item: item))
      }
    }
    return programs.mapValues(NeoProgramReserveStatus.init(entries:))
  }
}

enum NeoProgramSearchMetadata {
  static let genreNames = ["ニュース・報道", "スポーツ", "情報・ワイドショー", "ドラマ", "音楽", "バラエティ", "映画", "アニメ・特撮",
    "ドキュメンタリー・教養", "劇場・公演", "趣味・教育", "福祉", "予備", "予備", "拡張", "その他"]
  static let searchableGenres = Array(0...11) + [15]
  static let subGenreNames: [[String]] = [
    ["定時・総合", "天気", "特集・ドキュメント", "政治・国会", "経済・市況", "海外・国際", "解説", "討論・会談", "報道特番", "ローカル・地域", "交通", "", "", "", "", "その他"],
    ["スポーツニュース", "野球", "サッカー", "ゴルフ", "その他の球技", "相撲・格闘技", "オリンピック・国際大会", "マラソン・陸上・水泳", "モータースポーツ", "マリン・ウィンタースポーツ", "競馬・公営競技", "", "", "", "", "その他"],
    ["芸能・ワイドショー", "ファッション", "暮らし・住まい", "健康・医療", "ショッピング・通販", "グルメ・料理", "イベント", "番組紹介・お知らせ", "", "", "", "", "", "", "", "その他"],
    ["国内ドラマ", "海外ドラマ", "時代劇", "", "", "", "", "", "", "", "", "", "", "", "", "その他"],
    ["国内ロック・ポップス", "海外ロック・ポップス", "クラシック・オペラ", "ジャズ・フュージョン", "歌謡曲・演歌", "ライブ・コンサート", "ランキング・リクエスト", "カラオケ・のど自慢", "民謡・邦楽", "童謡・キッズ", "民族音楽・ワールドミュージック", "", "", "", "", "その他"],
    ["クイズ", "ゲーム", "トークバラエティ", "お笑い・コメディ", "音楽バラエティ", "旅バラエティ", "料理バラエティ", "", "", "", "", "", "", "", "", "その他"],
    ["洋画", "邦画", "アニメ", "", "", "", "", "", "", "", "", "", "", "", "", "その他"],
    ["国内アニメ", "海外アニメ", "特撮", "", "", "", "", "", "", "", "", "", "", "", "", "その他"],
    ["社会・時事", "歴史・紀行", "自然・動物・環境", "宇宙・科学・医学", "カルチャー・伝統文化", "文学・文芸", "スポーツ", "ドキュメンタリー全般", "インタビュー・討論", "", "", "", "", "", "", "その他"],
    ["現代劇・新劇", "ミュージカル", "ダンス・バレエ", "落語・演芸", "歌舞伎・古典", "", "", "", "", "", "", "", "", "", "", "その他"],
    ["旅・釣り・アウトドア", "園芸・ペット・手芸", "音楽・美術・工芸", "囲碁・将棋", "麻雀・パチンコ", "車・オートバイ", "コンピュータ・ＴＶゲーム", "会話・語学", "幼児・小学生", "中学生・高校生", "大学生・受験", "生涯教育・資格", "教育問題", "", "", "その他"],
    ["高齢者", "障害者", "社会福祉", "ボランティア", "手話", "文字（字幕）", "音声解説", "", "", "", "", "", "", "", "", "その他"],
    [], [],
    ["BS／地上デジタル放送用番組付属情報", "広帯域CSデジタル放送用拡張", "", "サーバー型番組付属情報", "IP放送用番組付属情報"],
    ["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "その他"],
  ]
  static let weekItems = [("月", 0x02), ("火", 0x04), ("水", 0x08), ("木", 0x10), ("金", 0x20), ("土", 0x40), ("日", 0x01)] as [(label: String, bit: Int)]
  static func channelTypeLabel(_ type: String) -> String { type.hasPrefix("GR-ALT") ? String(type.dropFirst(3)) : type }
  static func genreLabel(_ genre: Int, sub: Int?) -> String {
    guard genreNames.indices.contains(genre) else { return "ジャンル \(genre)" }
    let name = genreNames[genre]
    guard let sub, subGenreNames[genre].indices.contains(sub), !subGenreNames[genre][sub].isEmpty else { return name }
    return name + " / " + subGenreNames[genre][sub]
  }
  static func relatedKeyword(_ title: String) -> String {
    var keyword = title
    for pattern in [#"\[.+?\]"#, "【.+?】", #"\(.\)"#, " +"] {
      keyword = keyword.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    if let boundary = keyword.range(of: " #") ?? keyword.range(of: "「") { keyword = String(keyword[..<boundary.lowerBound]) }
    return keyword.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : keyword
  }
}
