import Foundation

var assertionCount = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  assertionCount += 1
  if !condition() { fatalError("Program search test failed: \(message)") }
}

func expectThrows(_ body: () throws -> Void, _ message: String) {
  do {
    try body()
    fatalError("Program search test failed: expected error for \(message)")
  } catch let error as NeoProgramSearchForm.ValidationError {
    expect(error.message.count > 0, "validation error has a message for \(message)")
  } catch {
    fatalError("Program search test failed: wrong error for \(message): \(error)")
  }
}

@main
struct ProgramSearchTests {
  static func main() throws {
    // Date input keeps the Web's strict shape while accepting locale compatibility
    // characters; time input is normalized by editing before it is parsed.
    expect(NeoDateInput.parse("２０２６／０１／０１") == "2026-01-01", "full-width JST date parses")
    expect(NeoDateInput.parse("2026-02-29") == nil, "non-leap date is rejected")
    expect(NeoProgramSearchTime.parse("24:00") == nil, "24:00 is rejected")
    expect(NeoProgramSearchTime.parse("２３:３０") == nil, "raw full-width time is not silently accepted")
    expect(NeoProgramSearchTime.editing("２３３０", previous: "") == "23:30", "time editing normalizes locale digits")

    // 00:30 JST is the preceding UTC date. These values guard against using the
    // device's local timezone or losing the cross-midnight day boundary.
    var midnight = NeoProgramSearchForm()
    midnight.startDate = "２０２６／０１／０１"
    midnight.startTime = "00:30"
    midnight.endDate = "2026-01-01"
    midnight.endTime = "01:15"
    let midnightPrepared = try midnight.prepared()
    let midnightPeriod = midnightPrepared.option.searchPeriods?.first
    expect(midnightPeriod?.startAt == 1_767_195_000_000, "JST midnight start converts to the prior UTC date")
    expect(midnightPeriod?.endAt == 1_767_197_700_000, "JST midnight end keeps minute precision")

    var oneSided = NeoProgramSearchForm()
    oneSided.startDate = "2026-01-01"
    let oneSidedPeriod = try oneSided.prepared().option.searchPeriods?.first
    expect(oneSidedPeriod?.startAt == 1_767_193_200_000, "start-only period uses JST 00:00")
    expect(oneSidedPeriod?.endAt == 253_402_300_799_999, "start-only period uses Web open end")

    var endOnly = NeoProgramSearchForm()
    endOnly.endDate = "2026-01-02"
    let endOnlyPeriod = try endOnly.prepared().option.searchPeriods?.first
    expect(endOnlyPeriod?.startAt == 0, "end-only period uses Web open start")
    expect(endOnlyPeriod?.endAt == 1_767_365_940_000, "end-only period uses JST 23:59")

    var invalidDate = NeoProgramSearchForm()
    invalidDate.startDate = "2026-02-30"
    expectThrows({ _ = try invalidDate.prepared() }, "invalid calendar date")

    var reversed = NeoProgramSearchForm()
    reversed.startDate = "2026-01-02"
    reversed.endDate = "2026-01-01"
    expectThrows({ _ = try reversed.prepared() }, "reversed search period")

    var noTarget = NeoProgramSearchForm()
    noTarget.keyword = "  番組  "
    noTarget.keywordFields = .init(caseSensitive: false, regexp: false, name: false, description: false, extended: false)
    let noTargetPrepared = try noTarget.prepared()
    expect(noTargetPrepared.form.keywordFields.name && noTargetPrepared.form.keywordFields.description,
      "keyword with no targets restores name and description")
    expect(noTargetPrepared.option.keyword == "番組" && noTargetPrepared.option.name == true && noTargetPrepared.option.description == true && noTargetPrepared.option.extended == false,
      "normalized keyword target flags are sent on the wire")

    var selectedChannel = NeoProgramSearchForm()
    selectedChannel.channelIDs = [42]
    selectedChannel.channelTypes = ["GR", "BS4K"]
    let selectedChannelOption = try selectedChannel.prepared().option
    expect(selectedChannelOption.channelIds == [42] && selectedChannelOption.channelTypes == nil && selectedChannelOption.BS4K == nil,
      "selected channel IDs take precedence over enabled waves")

    var waves = NeoProgramSearchForm()
    waves.channelTypes = ["GR", "BS4K"]
    let waveOption = try waves.prepared().option
    expect(waveOption.channelIds == nil && waveOption.channelTypes == ["GR"] && waveOption.BS4K == true,
      "BS4K is split from ordinary channelTypes")

    var mixedGenres = NeoProgramSearchForm()
    mixedGenres.genres = [7, 1]
    mixedGenres.subGenres = ["7:3", "7:1", "1:2"]
    let mixedGenreOption = try mixedGenres.prepared().option
    let mixedGenreValues = mixedGenreOption.genres?.map { "\($0.genre):\($0.subGenre ?? -1)" }
    expect(mixedGenreValues == ["7:3", "7:1", "1:2"],
      "mixed genre and subgenre selections retain form order")

    var partialTime = NeoProgramSearchForm()
    partialTime.startHour = 23
    let partialTimeOption = try partialTime.prepared().option
    let partialTimeValue = partialTimeOption.times?.first
    expect(partialTimeValue?.week == 0x7f && partialTimeValue?.start == nil && partialTimeValue?.range == nil,
      "partial time selection does not send an incomplete hour range")

    let wireData = try JSONEncoder().encode(midnightPrepared.option)
    let wire = try JSONSerialization.jsonObject(with: wireData) as! [String: Any]
    expect(wire["keyword"] == nil && wire["channelIds"] == nil && wire["channelTypes"] == nil,
      "empty optional search fields are omitted from wire JSON")
    let wireTimes = (wire["times"] as? [[String: Any]])?.first
    expect(wireTimes?["week"] as? Int == 0x7f && wireTimes?["start"] == nil && wireTimes?["range"] == nil,
      "partial time wire JSON keeps omitted start and range keys")
    let wirePeriods = (wire["searchPeriods"] as? [[String: Any]])?.first
    let wireStart = (wirePeriods?["startAt"] as? NSNumber)?.int64Value
    let wireEnd = (wirePeriods?["endAt"] as? NSNumber)?.int64Value
    expect(wireStart == 1_767_195_000_000 && wireEnd == 1_767_197_700_000,
      "period epoch values survive JSON encoding")

    let reserveJSON = #"""
    {
      "normal":[
        {"reserveId":10,"programId":7,"userId":1},
        {"reserveId":10,"programId":7,"userId":1},
        {"reserveId":11,"programId":7}
      ],
      "conflicts":[
        {"reserveId":20,"programId":7},
        {"reserveId":20,"programId":7},
        {"reserveId":21,"programId":7}
      ],
      "overlaps":[{"reserveId":30,"programId":7}],
      "skips":[{"reserveId":40,"programId":7},{"reserveId":41}]
    }
    """#
    let reserveLists = try JSONDecoder().decode(NeoProgramReserveLists.self, from: Data(reserveJSON.utf8))
    let reserveIndex = reserveLists.index
    let reserveStatus = reserveIndex[7]
    expect(reserveIndex[41] == nil, "reserve entries without programId are excluded")
    expect(reserveStatus?.primary == .normal, "normal reservation has highest status priority")
    let reserveEntries = reserveStatus?.entries.map { "\($0.kind.label):\($0.item.reserveId)" }
    expect(reserveEntries == ["予約:10", "予約:11", "競合:20", "競合:21", "重複:30", "除外:40"],
      "reserve index deduplicates within kind and preserves priority/order")
    expect(reserveStatus?.label(inResult: true) == "予約済み＋競合あり・重複あり・除外あり", "result status label includes secondary states")
    expect(reserveStatus?.label(inResult: false) == "予約＋競合あり・重複あり・除外あり", "detail status label uses dialog wording")

    let programJSON = #"""
    {
      "id":99,"channelId":42,"startAt":1767193200000,"endAt":1767195000000,"isFree":true,
      "name":"[字] アニメ #12「初回」","genre1":7,"subGenre1":0,"genre2":1,"subGenre2":2
    }
    """#
    let program = try JSONDecoder().decode(NeoScheduledProgram.self, from: Data(programJSON.utf8))
    let related = NeoProgramSearchForm.related(to: program, includeChannel: true, includeGenre: true)
    expect(related.keyword == "アニメ" && related.channelIDs == [42] && related.genres == [7] && related.subGenres == ["7:0"],
      "related search includes cleaned keyword, channel and first genre")
    let relatedWithoutMetadata = NeoProgramSearchForm.related(to: program, includeChannel: false, includeGenre: false)
    expect(relatedWithoutMetadata.channelIDs.isEmpty && relatedWithoutMetadata.genres.isEmpty && relatedWithoutMetadata.subGenres.isEmpty,
      "related search settings can omit channel and genre")
    expect(NeoProgramSearchMetadata.relatedKeyword("番組(特別版) #02") == "番組(特別版)",
      "related keyword preserves multi-character parentheses and trims episode suffix")

    let ruleJSON = #"""
    {"id":44,"userId":7,"isTimeSpecification":true,
     "searchOption":{"keyword":"時刻番組","channelIds":[101],"GR":true,"BS":true,
       "times":[{"week":126,"start":84600,"range":2700}],
       "searchPeriods":[{"startAt":1767193200000,"endAt":1767195000000}],"isFree":true},
     "reserveOption":{"enable":false,"allowEndLack":false,"avoidDuplicate":true,
       "periodToAvoidDuplicate":2.5,"tags":[4,8]},
     "saveOption":{"parentDirectoryName":"録画","directory":"${name}","recordedFormat":"ts"},
     "encodeOption":{"mode1":"x264","channelId1":101,"mode2":"x265","channelIds2":[201,202],
       "mode3":"copy","channelId3":303,"encodeParentDirectoryName1":"enc",
       "directory1":"dir1","isDeleteOriginalAfterEncode":true,"updateThumbnail":true,"startDelayMinutes":5}}
    """#
    let rule = try JSONDecoder().decode(NeoProgramRule.self, from: Data(ruleJSON.utf8))
    let restoredRule = NeoProgramRuleDraft(rule: rule)
    expect(restoredRule.userID == 7 && restoredRule.timeName == "時刻番組" && restoredRule.timeChannelID == 101
      && restoredRule.startTime == "23:30" && restoredRule.endTime == "00:15" && restoredRule.week == 126,
      "rule draft restores user, time, channel and weekdays")
    expect(!restoredRule.enabled && !restoredRule.allowEndLack && restoredRule.avoidDuplicate
      && restoredRule.duplicateDays == "2.5" && restoredRule.parentDirectoryName == "録画"
      && restoredRule.directory == "${name}" && restoredRule.recordedFormat == "ts",
      "rule draft restores reserve and save fields")
    expect(restoredRule.encodes.count == 3 && restoredRule.encodes[0].channelIDs == [101]
      && restoredRule.encodes[1].channelIDs == [201, 202] && restoredRule.encodes[2].channelIDs == [303]
      && restoredRule.deleteOriginal && restoredRule.updateThumbnail && restoredRule.delayMinutes == "5",
      "rule draft restores legacy, multi-station and third encode slots")
    expect(rule.scheduleLabel == "月・火・水・木・金・土 23:30～00:15", "rule summary formats its time window")
    let crossMidnight = try NeoProgramRuleTime.window(start: "23:30", end: "00:15")
    expect(crossMidnight.start == 84600 && crossMidnight.range == 2700, "rule time window keeps cross-midnight seconds")
    var preserveLegacyEncode = restoredRule; preserveLegacyEncode.enabled = true
    let preservedRule = try preserveLegacyEncode.write(searchOption: rule.searchOption, existing: rule)
    expect(preservedRule.encodeOption?.channelId1 == 101 && preservedRule.encodeOption?.mode3 == "copy"
      && preservedRule.encodeOption?.channelId3 == 303, "unchanged rule save preserves legacy and third encode slots")

    var saved = restoredRule
    saved.enabled = true; saved.allowEndLack = true; saved.avoidDuplicate = false; saved.duplicateDays = ""
    saved.parentDirectoryName = "新録画"; saved.directory = "out"; saved.recordedFormat = "mp4"
    saved.encodes = [.init(mode: "hevc", channelIDs: [501, 502], parentDirectoryName: "enc", directory: "encoded")]
    saved.deleteOriginal = false; saved.updateThumbnail = false; saved.delayMinutes = "0"
    let writtenRule = try saved.write(searchOption: rule.searchOption, existing: rule)
    expect(writtenRule.reserveOption.enable && writtenRule.reserveOption.allowEndLack
      && !writtenRule.reserveOption.avoidDuplicate && writtenRule.reserveOption.periodToAvoidDuplicate == nil
      && writtenRule.reserveOption.tags == [4, 8], "rule save emits edited reserve fields and preserves tags")
    expect(writtenRule.saveOption?.parentDirectoryName == "新録画" && writtenRule.saveOption?.directory == "out"
      && writtenRule.saveOption?.recordedFormat == "mp4", "rule save emits all recording fields")
    expect(writtenRule.encodeOption?.channelIds1 == [501, 502] && writtenRule.encodeOption?.channelId1 == nil
      && writtenRule.encodeOption?.mode2 == nil && writtenRule.encodeOption?.mode3 == nil
      && writtenRule.encodeOption?.startDelayMinutes == 0, "rule save emits multi-station encoding and clears old slots")
    var cleared = restoredRule; cleared.encodes = []
    let withoutEncode = try cleared.write(searchOption: rule.searchOption, existing: rule)
    expect(withoutEncode.encodeOption == nil,
      "clearing all encode rows removes the encode option")

    var noUser = restoredRule; noUser.userID = nil
    expectThrows({ _ = try noUser.write(searchOption: rule.searchOption) }, "missing rule user")
    var noTime = restoredRule; noTime.timeName = ""
    expectThrows({ _ = try noTime.write(searchOption: rule.searchOption) }, "missing time name")
    var sameTime = restoredRule; sameTime.startTime = sameTime.endTime
    expectThrows({ _ = try sameTime.write(searchOption: rule.searchOption) }, "same rule start and end")
    var badDelay = restoredRule; badDelay.delayMinutes = "-1"
    expectThrows({ _ = try badDelay.write(searchOption: rule.searchOption) }, "negative encode delay")

    var legacy = NeoProgramSearchOption(); legacy.keyword = "old"; legacy.keyCS = true
    legacy.GR = true; legacy.BS = true; legacy.CS = false; legacy.SKY = true
    legacy.times = [.init(week: 127, start: 3600, range: 1800), .init(week: 1, start: 7200, range: 900)]
    legacy.searchPeriods = [.init(startAt: 1767193200000, endAt: 1767195000000), .init(startAt: 1767283200000, endAt: 1767286800000)]
    legacy.genres = [.init(genre: 7, subGenre: 3)]; legacy.durationMin = 600; legacy.isFree = true
    var editedSearch = NeoProgramSearchForm(restoring: legacy); editedSearch.keyword = "new"
    let retained = try editedSearch.ruleOption(preserving: legacy)
    expect(retained.keyword == "new" && retained.GR == true && retained.BS == true && retained.CS == false && retained.SKY == true
      && retained.times?.count == 2 && retained.searchPeriods?.count == 2 && retained.genres?.count == 1
      && retained.durationMin == 600 && retained.isFree == true,
      "editing one search field preserves legacy waves and additional ranges")

    let reservationJSON = #"{"reserves":[{"id":1,"channelId":2,"name":"A","startAt":0,"endAt":60000,"userId":7,"ruleId":44,"programId":8,"description":null,"extended":null,"isConflict":true,"isSkip":false,"isOverlap":false}],"total":1}"#
    let reservation = try JSONDecoder().decode(NeoProgramRuleReservationList.self, from: Data(reservationJSON.utf8)).reserves[0]
    expect(reservation.status.primary == .conflict && reservation.status.label(inResult: false) == "競合"
      && reservation.displayProgram.name == "A" && reservation.displayProgram.durationMinutes == 1,
      "rule reservation exposes conflict status and display program")

    let rulesQuery = NeoRuleListQuery(userID: 7, keyword: "作品", hasReserve: true, page: 3, limit: 24)
    let queryParams = Dictionary(uniqueKeysWithValues: rulesQuery.queryItems.map { ($0.name, $0.value) })
    expect(queryParams == ["type": "normal", "offset": "48", "limit": "24", "userId": "7", "keyword": "作品", "hasReserve": "true"],
      "rule list uses the Web reservation type, filters and offset")
    expect(NeoRuleListQuery().queryItems.map(\.name) == ["type", "offset", "limit"], "all users and unselected filters are omitted")
    expect(rulesQuery.pageCount(total: 49) == 3 && rulesQuery.pageCount(total: 0) == 1, "rule page count handles empty and partial last pages")

    let ruleListData = Data(#"{"rules":[{"id":1,"isTimeSpecification":false,"searchOption":{"keyword":"  作品 ","channelIds":[40,41],"genres":[{"genre":7,"subGenre":0},{"genre":7,"subGenre":0}]},"reserveOption":{"enable":true,"allowEndLack":false,"avoidDuplicate":false},"reservesCnt":2,"annictId":35,"encodeOption":{"mode1":"HEVC","mode2":"H264","startDelayMinutes":10}}],"total":1}"#.utf8)
    let ruleList = try JSONDecoder().decode(NeoRuleList.self, from: ruleListData)
    guard let listRule = ruleList.rules.first else { fatalError("Missing fixture rule") }
    expect(listRule.reservesCnt == 2 && listRule.annictId == 35 && listRule.listTitle == "作品", "rule card decodes count, link, and title")
    expect(listRule.listConditions(channelNames: [40: "放送局"]) == "放送局、41 / アニメ・特撮 / 国内アニメ", "rule card joins channels and deduplicates genre paths")
    expect(listRule.listEncodeSummary == "エンコード: HEVC、H264（録画完了後10分待機）", "rule card shows all modes and encode delay")

    print("Program search and rule tests passed (\(assertionCount) assertions)")
  }
}
