import Foundation

extension NeoAPI {
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
