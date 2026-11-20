import Foundation

private final class NeoEncodeProtocol: URLProtocol {
  struct Captured { let method: String; let path: String; let query: [String:String]; let headers: [String:String]; let body: [String:Any]? }
  private struct Reply { let status: Int; let data: Data }
  private static let lock = NSLock(); private static var requests: [Captured] = []; private static var replies: [String:Reply] = [:]
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "encode-tests.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }; var value = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; value.append(buffer, count: n) }; data = value
    }
    let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String:Any] }
    let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String:String]()) { $0[$1.key.lowercased()] = $1.value }
    var query: [String:String] = [:]; URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.forEach { query[$0.name] = $0.value }
    let captured = Captured(method: request.httpMethod ?? "GET", path: request.url!.path, query: query, headers: headers, body: body)
    Self.lock.lock(); Self.requests.append(captured); let reply = Self.replies["\(captured.method):\(captured.path)"] ?? Reply(status: 200, data: Data("{}".utf8)); Self.lock.unlock()
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
  static func reset() { lock.lock(); requests = []; replies = [:]; lock.unlock() }
  static func respond(_ path: String, method: String = "GET", status: Int = 200, _ json: String) { lock.lock(); replies["\(method):\(path)"] = Reply(status: status, data: Data(json.utf8)); lock.unlock() }
  static func captured() -> [Captured] { lock.lock(); defer { lock.unlock() }; return requests }
}

/// Engine.IO polling fixture whose later poll remains open until cancellation.
private final class NeoEncodeSocketFixture: URLProtocol {
  private static let lock = NSLock()
  private static var requests: [(String,String?,[String:String])] = []
  private static var socketPolls = 0
  private var held = false
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "socket-tests.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var bodyData = request.httpBody
    if bodyData == nil, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating:0,count:1024)
      while true { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; data.append(buffer,count:n) }
      bodyData = data
    }
    let body = bodyData.flatMap { String(data:$0,encoding:.utf8) }
    let sid = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "sid"})?.value
    let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into:[String:String]()) { $0[$1.key.lowercased()] = $1.value }
    Self.lock.lock(); Self.requests.append((request.httpMethod ?? "GET",body,headers)); if sid != nil && body == nil { Self.socketPolls += 1 }; let poll = Self.socketPolls; Self.lock.unlock()
    if body == nil {
      if sid == nil { respond(#"0{"sid":"fixture-sid","pingInterval":10000,"pingTimeout":10000}"#) }
      else if poll == 1 { respond("2fixture-ping\u{1e}42[\"updateEncode\"]\u{1e}42[\"updateStatus\"]") }
      else { held = true; Self.lock.lock(); Self.requests.append(("HOLD",nil,[:])); Self.lock.unlock() }
    } else { respond("ok") }
  }
  private func respond(_ text:String) {
    let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/plain"])!
    client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { if held { Self.lock.lock(); Self.requests.append(("CANCEL",nil,[:])); Self.lock.unlock() } }
  static func reset() { lock.lock(); requests = []; socketPolls = 0; lock.unlock() }
  static func captured() -> [(String,String?,[String:String])] { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor private enum NeoEncodeTests {
  static func check(_ name: String, _ condition: @autoclosure () -> Bool, count: inout Int) { count += 1; guard condition() else { fatalError("FAIL: \(name)") }; print("PASS: \(name)") }
  static func file(_ id: Int, _ name: String) -> NeoVideoFile { NeoVideoFile(id:id,name:name,type:"ts",size:1,filename:nil) }
  static func recording(_ id: Int, _ files: [NeoVideoFile], recording: Bool = false) -> NeoRecording {
    NeoRecording(id:id,name:"record-\(id)",startAt:Double(id),endAt:Double(id+1),isRecording:recording,description:nil,extended:nil,channelId:1,channelName:"Fixture",thumbnails:[],videoFiles:files)
  }
  static func api() -> NeoAPI {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NeoEncodeProtocol.self]
    let api = NeoAPI(base: URL(string:"https://encode-tests.invalid")!, session: URLSession(configuration:config))
    api.activate(user:"17",headers:["X-Viewer-Profile-Id":"8","X-Viewer-Session":"encode-fixture"]); return api
  }
  static func run() async throws {
    var count = 0
    check("single encode message matches Web without a count", NeoEncodePlan.successMessage(bulk:false,count:1) == "エンコードキューに追加しました。",count:&count)
    check("bulk encode message includes the total successful count", NeoEncodePlan.successMessage(bulk:true,count:3) == "3 件をエンコードキューに追加しました。",count:&count)
    var settings = NeoAddEncodeSettings(mode:"h264",parentDir:"D:\\encoded",sameDirectory:false,removeOriginal:true,updateThumbnail:false)
    let records = [recording(1,[file(10,"shared.ts"),file(11,"shared.ts"),file(12,"other.ts")]),recording(2,[file(20,"other.ts"),file(21,"shared.ts")])]
    let jobs = try NeoEncodePlan.jobs([records[0],records[0],records[1]],sourceName:"shared.ts",settings:settings,directory:"  Drama  ")
    check("duplicate recording IDs create one job and match exact common source labels per recording", jobs.map(\.recordedID) == [1,2] && jobs.map{$0.option["sourceVideoFileId"] as? Int} == [10,21], count:&count)
    check("normal output carries trimmed subdirectory and selected paths", jobs[0].option["directory"] as? String == "Drama" && jobs[0].option["parentDir"] as? String == "D:\\encoded" && jobs[0].option["removeOriginal"] as? Bool == true && jobs[0].option["updateThumbnail"] as? Bool == false, count:&count)
    do { _ = try NeoEncodePlan.jobs(records,sourceID:10,settings:settings,directory:""); check("source IDs are resolved per record", false,count:&count) } catch { check("source IDs are exact per record, not a common filename", true,count:&count) }
    do { _ = try NeoEncodePlan.jobs([recording(5,[file(50,"a.ts")]),recording(6,[file(60,"b.ts")])],sourceName:"a.ts",settings:settings,directory:""); check("no common source rejects", false,count:&count) } catch { check("no common source rejects", true,count:&count) }
    do { _ = try NeoEncodePlan.jobs([recording(3,[file(30,"a" )],recording:true)],sourceName:"a",settings:settings,directory:""); check("recording item rejects",false,count:&count) } catch { check("recording item rejects",true,count:&count) }
    settings.sameDirectory = true
    let same = try NeoEncodePlan.jobs([recording(4,[file(40,"x")])],sourceName:"x",settings:settings,directory:"stale")
    check("same-directory omits both output path fields", same[0].option["isSaveSameDirectory"] as? Bool == true && same[0].option["parentDir"] == nil && same[0].option["directory"] == nil,count:&count)
    let suite = "encode-tests-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName:suite)!; defer { defaults.removePersistentDomain(forName:suite) }
    check("settings load defaults when suite is empty", NeoAddEncodeSettings.load(defaults) == NeoAddEncodeSettings(),count:&count)
    settings.save(defaults); check("settings save and load round trip", NeoAddEncodeSettings.load(defaults) == settings,count:&count)

    let socketBase = URL(string:"https://example.invalid:8443/epgstation/")!
    let socketEndpoints = NeoEncodeSocketProtocol.endpoints(base:socketBase,port:9000)
    check("socket endpoints preserve subpath and include configured-port fallback", socketEndpoints.map(\.absoluteString) == ["https://example.invalid:9000/epgstation/socket.io/","https://example.invalid:8443/epgstation/socket.io/"],count:&count)
    let socketQuery = URLComponents(url:NeoEncodeSocketProtocol.url(socketEndpoints[0],sid:"a b"),resolvingAgainstBaseURL:false)?.queryItems ?? []
    check("Engine.IO URL carries v4 polling transport and session ID", socketQuery.first(where:{$0.name == "EIO"})?.value == "4" && socketQuery.first(where:{$0.name == "transport"})?.value == "polling" && socketQuery.first(where:{$0.name == "sid"})?.value == "a b",count:&count)
    check("Socket.IO parser recognizes only encode update events and separates packets", NeoEncodeSocketProtocol.isUpdate(#"42["updateEncode",{}]"#) && NeoEncodeSocketProtocol.isUpdate(#"42["updateStatus"]"#) && !NeoEncodeSocketProtocol.isUpdate(#"42["other"]"#) && !NeoEncodeSocketProtocol.isUpdate("42broken") && NeoEncodeSocketProtocol.packets("2ping\u{1e}42event") == ["2ping","42event"],count:&count)

    let auth = api(), originalRevision = auth.identityRevision, originalHeaders = auth.profileHeaders
    auth.suspendAuthentication(preservingIdentity:true)
    check("preserving suspension gates requests and keeps identity credentials", !auth.accountReady && auth.accountRevalidating && auth.identityRevision == originalRevision && auth.viewer == "17" && auth.profileHeaders == originalHeaders,count:&count)
    auth.activate(user:"17",headers:originalHeaders)
    check("same identity revalidation restores readiness without revision change", auth.accountReady && !auth.accountRevalidating && auth.identityRevision == originalRevision && auth.profileHeaders == originalHeaders,count:&count)
    auth.suspendAuthentication(preservingIdentity:true); auth.activate(user:"18",headers:originalHeaders)
    check("account change during revalidation advances identity revision", auth.identityRevision == originalRevision + 1 && auth.viewer == "18",count:&count)
    let accountRevision = auth.identityRevision
    auth.suspendAuthentication(preservingIdentity:true); auth.activate(user:"18",headers:["X-Viewer-Session":"rotated"])
    check("credential change during revalidation advances identity revision", auth.identityRevision == accountRevision + 1,count:&count)

    NeoEncodeSocketFixture.reset()
    let socketConfig = URLSessionConfiguration.ephemeral; socketConfig.protocolClasses = [NeoEncodeSocketFixture.self]
    let socketAPI = NeoAPI(base:URL(string:"https://socket-tests.invalid/epgstation")!,session:URLSession(configuration:socketConfig))
    socketAPI.activate(user:"private-user",headers:["Authorization":"private-token"])
    let updates = NeoServerStatusUpdates(); var updateCount = 0
    updates.start(api:socketAPI,port:nil) { updateCount += 1 }
    let deadline = Date().addingTimeInterval(2)
    while updateCount == 0 && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
    while !NeoEncodeSocketFixture.captured().contains(where:{$0.0 == "HOLD"}) && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
    updates.stop(); try await Task.sleep(nanoseconds:100_000_000)
    let socketRequests = NeoEncodeSocketFixture.captured()
    check("polling fixture completes handshake, namespace, ping pong and update callback", updateCount == 1 && socketRequests.contains(where:{$0.1 == "40"}) && socketRequests.contains(where:{$0.1 == "3fixture-ping"}),count:&count)
    check("polling requests do not copy user or authorization headers", socketRequests.allSatisfy({$0.2["authorization"] == nil && $0.2["x-epgstation-user-id"] == nil}),count:&count)
    check("stop cancels the deliberately held polling request", socketRequests.contains(where:{$0.0 == "CANCEL"}),count:&count)

    var submitted:[Int]=[], progress:[Int]=[]
    let result = try await NeoEncodePlan.submit(jobs,isCurrent:{true},enqueue:{ job in submitted.append(job.recordedID); if job.recordedID == 1 { throw NeoError("temporary") } },progress:{progress.append($0)})
    let retry = try await NeoEncodePlan.submit(result.failed.map(\.job),isCurrent:{true},enqueue:{ submitted.append($0.recordedID) },progress:{_ in})
    check("sequential partial failure continues and retries only failed original job", submitted == [1,2,1] && result.failed.map{$0.job.recordedID} == [1] && result.succeeded.map(\.recordedID) == [2] && retry.succeeded.map(\.recordedID) == [1],count:&count)
    var active = true; var stopped:[Int]=[]
    do { _ = try await NeoEncodePlan.submit(jobs,isCurrent:{active},enqueue:{ stopped.append($0.recordedID); active = false },progress:{_ in}); check("identity cancellation stops later submissions",false,count:&count) }
    catch is CancellationError { check("identity cancellation stops later submissions",stopped == [1],count:&count) }

    func item(_ id:Int)->NeoEncodeItem { NeoEncodeItem(id:id,mode:"h264",recorded:recording(id,[]),percent:nil,log:nil,scheduledAt:nil,scheduledAtLabel:nil) }
    let info = NeoEncodeInfo(runningItems:[item(4)],waitItems:[item(1),item(2)],scheduledItems:[item(3)])
    check("cancel order puts waiting and scheduled jobs before running and removes duplicate or unknown IDs", info.cancellationOrder([4,3,1,9,3]) == [3,1,4],count:&count)
    check("queue reorder accepts only a changed exact permutation", info.canSaveOrder([2,1],expected:[1,2]) && !info.canSaveOrder([1,2],expected:[1,2]) && !info.canSaveOrder([1,1],expected:[1,2]) && !info.canSaveOrder([2,3],expected:[1,2]),count:&count)

    NeoEncodeProtocol.reset(); NeoEncodeProtocol.respond("/api/encode", #"{"runningItems":[{"id":41,"mode":"x","recorded":{"id":1,"name":"r","startAt":0,"endAt":1,"isRecording":false,"videoFiles":[]}}],"waitItems":[],"scheduledItems":[{"id":42,"mode":"x","recorded":{"id":2,"name":"s","startAt":0,"endAt":1,"isRecording":false,"videoFiles":[]},"scheduledAt":10,"scheduledAtLabel":"later"}],"recoveryItems":[{"id":43,"status":"failed","reason":"lost","canRetry":true}]}"#)
    NeoEncodeProtocol.respond("/api/encode", method:"POST", #"{"encodeId":101}"#)
    NeoEncodeProtocol.respond("/api/encode/41", method:"DELETE", "{}")
    NeoEncodeProtocol.respond("/api/encode/43/retry", method:"POST", "{}")
    NeoEncodeProtocol.respond("/api/encode/order", method:"PUT", "{}")
    let client = api(); client.isHalfWidthDisplayed = false
    let decoded = try await client.encodes(user:"17",headers:client.profileHeaders)
    let queued = try await client.addEncode(jobs[0],user:"17",headers:client.profileHeaders)
    try await client.cancelEncode(41,user:"17",headers:client.profileHeaders); try await client.retryEncode(43,user:"17",headers:client.profileHeaders)
    try await client.reorderEncodes([2,1],expected:[1,2],user:"17",headers:client.profileHeaders)
    let req = NeoEncodeProtocol.captured()
    check("encode queue decodes all four groups and optional scheduled and recovery details", decoded.runningItems.map(\.id) == [41] && decoded.scheduledItems.first?.scheduledAt == 10 && decoded.recoveryItems.first?.canRetry == true && decoded.allItems.map(\.id) == [41,42],count:&count)
    check("GET encode request carries half width query and viewer identity headers", req[0].method == "GET" && req[0].query["isHalfWidth"] == "false" && req[0].headers["x-epgstation-user-id"] == "17" && req[0].headers["x-viewer-session"] == "encode-fixture",count:&count)
    check("add POST returns ID and sends exact encode option", queued == 101 && req[1].method == "POST" && req[1].path == "/api/encode" && req[1].body?["recordedId"] as? Int == 1 && req[1].body?["sourceVideoFileId"] as? Int == 10 && req[1].body?["mode"] as? String == "h264",count:&count)
    check("cancel, retry and reorder use exact methods, paths and permutation body", req[2].method == "DELETE" && req[2].path == "/api/encode/41" && req[3].method == "POST" && req[3].path == "/api/encode/43/retry" && req[4].method == "PUT" && req[4].body?["encodeIds"] as? [Int] == [2,1] && req[4].body?["expectedEncodeIds"] as? [Int] == [1,2],count:&count)
    NeoEncodeProtocol.reset(); NeoEncodeProtocol.respond("/api/encode", #"{"runningItems":[],"waitItems":[]}"#)
    let oldServer = try await client.encodes(user:"17",headers:client.profileHeaders)
    check("older servers may omit scheduled and recovery arrays", oldServer.scheduledItems.isEmpty && oldServer.recoveryItems.isEmpty,count:&count)

    NeoEncodeProtocol.reset()
    do { try await client.reorderEncodes([1,1],expected:[1,2],user:"17",headers:client.profileHeaders); check("invalid reorder rejected before request",false,count:&count) }
    catch { check("invalid reorder rejected before request",NeoEncodeProtocol.captured().isEmpty,count:&count) }
    NeoEncodeProtocol.respond("/api/encode/9/retry",method:"POST",status:503,#"{"message":"busy"}"#)
    do { try await client.retryEncode(9,user:"17",headers:client.profileHeaders); check("server error surfaces without retry",false,count:&count) }
    catch { let e = error as? NeoError; check("server error surfaces without automatic mutation retry",e?.statusCode == 503 && NeoEncodeProtocol.captured().count == 1,count:&count) }
    print("Encode: \(count) checks passed")
  }
}

@main private struct NeoEncodeMain { @MainActor static func main() async { do { try await NeoEncodeTests.run() } catch { fatalError("Unexpected encode test failure: \(error)") } } }
