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

    print("Program search tests passed (\(assertionCount) assertions)")
  }
}
