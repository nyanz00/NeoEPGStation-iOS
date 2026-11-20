import Foundation

extension NeoAPI {
  func programRules(_ query: NeoRuleListQuery, user: String, headers: [String: String]) async throws -> NeoRuleList {
    var parts = URLComponents(url: url("/rules"), resolvingAgainstBaseURL: false)!
    parts.queryItems = query.queryItems
    let list: NeoRuleList = try await request(parts.url!, user: user, headers: headers)
    guard list.total >= 0, Set(list.rules.map(\.id)).count == list.rules.count, list.rules.allSatisfy({ $0.id > 0 }) else {
      throw NeoError("ルール一覧の応答形式が一致しません。")
    }
    return list
  }

  func setProgramRuleEnabled(_ id: Int, enabled: Bool, user: String, headers: [String: String]) async throws -> NeoRuleMutationResult {
    var parts = URLComponents(url: url("/rules/\(id)/\(enabled ? "enable" : "disable")"), resolvingAgainstBaseURL: false)!
    if !enabled { parts.queryItems = [.init(name: "syncAnnictStopWatching", value: String(NeoAnnictPreferences.stopWatchingOnRuleDisable))] }
    return try await request(parts.url!, method: "PUT", user: user, headers: headers)
  }

  func deleteProgramRule(_ id: Int, user: String, headers: [String: String]) async throws -> NeoRuleMutationResult {
    try await request(url("/rules/\(id)"), method: "DELETE", user: user, headers: headers)
  }

  func programRule(_ id: Int, user: String, headers: [String: String]) async throws -> NeoProgramRule {
    let rule: NeoProgramRule = try await request(url("/rules/\(id)"), user: user, headers: headers)
    guard rule.id == id else { throw NeoError("指定したルールの情報を取得できませんでした。") }
    return rule
  }

  func programRuleReservations(_ id: Int, halfWidth: Bool, user: String, headers: [String: String]) async throws -> NeoProgramRuleReservationList {
    var parts = URLComponents(url: url("/reserves"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [.init(name: "type", value: "all"), .init(name: "ruleId", value: String(id)),
      .init(name: "isHalfWidth", value: String(halfWidth))]
    return try await request(parts.url!, user: user, headers: headers)
  }

  func saveProgramRule(_ rule: NeoProgramRuleWrite, replacing id: Int?, user: String, headers: [String: String]) async throws -> [String] {
    struct Added: Decodable { let ruleId: Int }
    struct Updated: Decodable { let annictStatusError: String?; let annictLinkError: String? }
    guard let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any] else {
      throw NeoError("ルール設定を保存用の形式に変換できませんでした。")
    }
    if let id {
      var parts = URLComponents(url: url("/rules/\(id)"), resolvingAgainstBaseURL: false)!
      parts.queryItems = [.init(name: "syncAnnictStopWatching", value: String(NeoAnnictPreferences.stopWatchingOnRuleDisable))]
      let result: Updated = try await request(parts.url!, method: "PUT", body: body, user: user, headers: headers)
      return [result.annictStatusError, result.annictLinkError].compactMap { $0 }
    }
    let result: Added = try await request(url("/rules"), method: "POST", body: body, user: user, headers: headers)
    guard result.ruleId > 0 else { throw NeoError("追加されたルールのIDを確認できませんでした。") }
    return []
  }

  var programSearchLimit: Int {
    get { min(10_000, max(1, UserDefaults.standard.object(forKey: "search.limit." + base.absoluteString) as? Int ?? 300)) }
    set { UserDefaults.standard.set(min(10_000, max(1, newValue)), forKey: "search.limit." + base.absoluteString) }
  }
  var programRelatedIncludesChannel: Bool {
    get { UserDefaults.standard.object(forKey: "search.related.channel." + base.absoluteString) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "search.related.channel." + base.absoluteString) }
  }
  var programRelatedIncludesGenre: Bool {
    get { UserDefaults.standard.object(forKey: "search.related.genre." + base.absoluteString) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "search.related.genre." + base.absoluteString) }
  }
  var alwaysShowProgramBroadcastDetails: Bool {
    get { UserDefaults.standard.bool(forKey: "search.program.details." + base.absoluteString) }
    set { UserDefaults.standard.set(newValue, forKey: "search.program.details." + base.absoluteString) }
  }

  func programSearchChannels(user: String, headers: [String: String]) async throws -> [NeoLiveChannel] {
    try await request(url("/channels"), user: user, headers: headers)
  }

  func searchPrograms(_ option: NeoProgramSearchOption, halfWidth: Bool, limit: Int,
                      user: String, headers: [String: String]) async throws -> [NeoScheduledProgram] {
    let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(option))
    return try await request(url("/schedules/search"), method: "POST",
      body: ["option": body, "isHalfWidth": halfWidth, "limit": limit], user: user, headers: headers)
  }

  func programReservationLists(startAt: Double, endAt: Double, user: String,
                               headers: [String: String]) async throws -> NeoProgramReserveLists {
    guard let start = Int64(exactly: startAt), let end = Int64(exactly: endAt) else {
      throw NeoError("番組の放送日時を確認できませんでした。")
    }
    var parts = URLComponents(url: url("/reserves/lists"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [.init(name: "startAt", value: String(start)), .init(name: "endAt", value: String(end))]
    return try await request(parts.url!, user: user, headers: headers)
  }
}
