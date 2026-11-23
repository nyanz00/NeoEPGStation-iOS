import Foundation

struct NeoReservationSession: Equatable {
  let api: NeoAPI
  let viewer: String
  let revision: Int
  let headers: [String: String]

  init(_ api: NeoAPI) {
    self.api = api
    viewer = api.viewer; revision = api.identityRevision; headers = api.profileHeaders
  }

  var viewerID: Int? { Int(viewer).flatMap { $0 > 0 ? $0 : nil } }

  func hasSameIdentity(as candidate: NeoAPI?) -> Bool {
    candidate === api && api.viewer == viewer && api.identityRevision == revision
  }

  func isCurrent(_ candidate: NeoAPI?) -> Bool {
    candidate === api && api.accountReady && Self(api) == self
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.api === rhs.api && lhs.viewer == rhs.viewer && lhs.revision == rhs.revision && lhs.headers == rhs.headers
  }

  func list(_ kind: NeoProgramReserveKind, userID: Int?, offset: Int, limit: Int, halfWidth: Bool) async throws -> NeoReservationList {
    var url = URLComponents(url: api.url("/reserves"), resolvingAgainstBaseURL: false)!
    url.queryItems = [
      .init(name: "type", value: kind.queryType), .init(name: "isHalfWidth", value: String(halfWidth)),
      .init(name: "offset", value: String(offset)), .init(name: "limit", value: String(limit)),
    ]
    if let userID { url.queryItems?.append(.init(name: "userId", value: String(userID))) }
    let list: NeoReservationList = try await api.request(url.url!, user: viewer, headers: headers)
    guard list.total >= 0, Set(list.reserves.map(\.id)).count == list.reserves.count else {
      throw NeoError("予約一覧の応答形式が一致しません。")
    }
    return list
  }

  func program(_ id: Int, halfWidth: Bool) async throws -> NeoScheduledProgram {
    let item: NeoScheduledProgram = try await api.request(
      api.url("/schedules/detail/\(id)?isHalfWidth=\(halfWidth)"), user: viewer, headers: headers)
    guard item.id == id else { throw NeoError("指定した番組情報を取得できませんでした。") }
    return item
  }

  func reservation(_ id: Int, halfWidth: Bool) async throws -> NeoReservationItem {
    let item: NeoReservationItem = try await api.request(
      api.url("/reserves/\(id)?isHalfWidth=\(halfWidth)"), user: viewer, headers: headers)
    guard item.id == id else { throw NeoError("指定した予約情報を取得できませんでした。") }
    return item
  }

  func add(programID: Int, options: NeoReservationOptions, time: NeoReservationTime? = nil) async throws {
    struct Added: Decodable { let reserveId: Int }
    var body = try options.body()
    if let time { body["timeSpecifiedOption"] = try time.body() }
    else { body["programId"] = programID }
    let _: Added = try await api.request(api.url("/reserves"), method: "POST", body: body, user: viewer, headers: headers)
  }

  func edit(_ id: Int, options: NeoReservationOptions) async throws {
    try await api.requestAcknowledgement(api.url("/reserves/\(id)"), method: "PUT", body: options.body(), user: viewer, headers: headers)
  }

  func change(_ id: Int, action: NeoReservationAction) async throws {
    try await api.requestAcknowledgement(api.url("/reserves/\(id)\(action.suffix)"), method: "DELETE", user: viewer, headers: headers)
  }

  func rebuild() async throws {
    try await api.requestAcknowledgement(api.url("/reserves/update"), method: "POST", user: viewer, headers: headers)
  }
}

extension Notification.Name {
  static let neoReservationsChanged = Notification.Name("neoReservationsChanged")
  static let neoReservationPreferencesChanged = Notification.Name("neoReservationPreferencesChanged")
}

extension NeoAPI {
  var quickReservationSettings: NeoQuickReservationSettings {
    get {
      guard let data = UserDefaults.standard.data(forKey: "reserve.quick." + base.absoluteString),
        let value = try? JSONDecoder().decode(NeoQuickReservationSettings.self, from: data) else { return .init() }
      return value
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: "reserve.quick." + base.absoluteString)
      }
    }
  }

  var reservesLength: Int {
    get { min(1000, max(1, UserDefaults.standard.object(forKey: "reserves.length." + base.absoluteString) as? Int ?? 24)) }
    set {
      UserDefaults.standard.set(min(1000, max(1, newValue)), forKey: "reserves.length." + base.absoluteString)
      NotificationCenter.default.post(name: .neoReservationPreferencesChanged, object: self)
    }
  }
}
