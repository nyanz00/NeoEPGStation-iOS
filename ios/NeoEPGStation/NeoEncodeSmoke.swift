#if targetEnvironment(simulator)
import Foundation
import UIKit

private final class NeoEncodeUIProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var records: [[String:Any]] = []
  private static var running: [[String:Any]] = [], waiting: [[String:Any]] = [], scheduled: [[String:Any]] = [], recovery: [[String:Any]] = []
  private static var calls: [String:Int] = [:], bodies: [String:[[String:Any]]] = [:], mutations: [String] = []
  private static var failRecordedIDs = Set<Int>(), failCancelIDs = Set<Int>(), failOrder = false
  private static var postDelay: TimeInterval = 0
  private var cancelled = false
  private let cancellationLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "encode-ui.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() { cancellationLock.lock(); cancelled=true; cancellationLock.unlock() }
  private static func body(_ request: URLRequest) -> [String:Any] {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }; var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; collected.append(buffer, count: n) }; data = collected
    }
    return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String:Any] } ?? [:]
  }
  override func startLoading() {
    let requestBody = Self.body(request), path = request.url!.path, method = request.httpMethod ?? "GET", key = method + " " + path
    Self.lock.lock()
    Self.calls[key, default:0] += 1
    if method != "GET" { Self.mutations.append(key) }
    if !requestBody.isEmpty { Self.bodies[key,default:[]].append(requestBody) }
    var status = 200, value: Any = [:]
    if path == "/api/config" { value = ["encode":["h264","hevc"],"recorded":["D:\\Encode"]] }
    else if path == "/api/users" { value = ["users":[["id":7,"name":"Fixture user"],["id":8,"name":"Other user"]]] }
    else if path == "/api/recorded" { value = ["records":Self.records,"total":Self.records.count] }
    else if path == "/api/encode", method == "GET" { value = ["runningItems":Self.running,"waitItems":Self.waiting,"scheduledItems":Self.scheduled,"recoveryItems":Self.recovery] }
    else if path == "/api/encode", method == "POST" {
      if let id = requestBody["recordedId"] as? Int, Self.failRecordedIDs.contains(id) { Self.failRecordedIDs.remove(id); status = 503; value = ["message":"fixture queue failure"] }
      else { let id = 5000 + Self.calls[key,default:1]; Self.waiting.append(["id":id,"mode":requestBody["mode"] ?? "h264","recorded":Self.records.first { ($0["id"] as? Int) == (requestBody["recordedId"] as? Int) } ?? Self.records[0]]); value = ["encodeId":id] }
    } else if path == "/api/encode/order", method == "PUT" {
      if Self.failOrder { Self.failOrder = false; status = 409; value = ["message":"EncodeQueueChangedError"] }
      else if let ids = requestBody["encodeIds"] as? [Int] { Self.waiting = ids.compactMap { id in Self.waiting.first { ($0["id"] as? Int) == id } }; value = [:] }
    } else if path.hasPrefix("/api/encode/"), method == "DELETE" {
      let id = Int(path.split(separator:"/").last ?? "") ?? -1
      if Self.failCancelIDs.contains(id) { Self.failCancelIDs.remove(id); status = 503; value = ["message":"fixture cancel failure"] }
      else { Self.running.removeAll { ($0["id"] as? Int) == id }; Self.waiting.removeAll { ($0["id"] as? Int) == id }; Self.scheduled.removeAll { ($0["id"] as? Int) == id }; Self.recovery.removeAll { ($0["id"] as? Int) == id } }
    } else if path.hasSuffix("/retry"), method == "POST" { }
    else { status = 404; value = ["message":"unexpected request: \(key)"] }
    let delay = method == "POST" && path == "/api/encode" ? Self.postDelay : 0
    Self.lock.unlock()
    let data = (try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed])) ?? Data("{}".utf8)
    let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
    DispatchQueue.global().asyncAfter(deadline:.now()+delay) { [self] in
      cancellationLock.lock(); let stopped=cancelled; cancellationLock.unlock(); guard !stopped else { return }
      client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
  }
  static func reset(records: [[String:Any]], running: [[String:Any]], waiting: [[String:Any]], scheduled: [[String:Any]], recovery: [[String:Any]], failRecordedIDs: Set<Int> = [], failCancelIDs: Set<Int> = []) {
    lock.lock(); defer { lock.unlock() }; self.records=records; self.running=running; self.waiting=waiting; self.scheduled=scheduled; self.recovery=recovery
    calls=[:]; bodies=[:]; mutations=[]; self.failRecordedIDs=failRecordedIDs; self.failCancelIDs=failCancelIDs; failOrder=false; postDelay=0
  }
  static func count(_ key:String)->Int { lock.lock(); defer { lock.unlock() }; return calls[key,default:0] }
  static func body(_ key:String,index:Int = -1)->[String:Any]? { lock.lock(); defer { lock.unlock() }; guard let values=bodies[key] else { return nil }; let i=index < 0 ? values.count+index : index; return values.indices.contains(i) ? values[i] : nil }
  static func allBodies(_ key:String)->[[String:Any]] { lock.lock(); defer { lock.unlock() }; return bodies[key] ?? [] }
  static func orderedIDs()->[Int] { lock.lock(); defer { lock.unlock() }; return waiting.compactMap{$0["id"] as? Int} }
  static func resetQueue(running:[[String:Any]],waiting:[[String:Any]],scheduled:[[String:Any]],recovery:[[String:Any]]) { lock.lock(); self.running=running; self.waiting=waiting; self.scheduled=scheduled; self.recovery=recovery; lock.unlock() }
  static func mutationOrder()->[String] { lock.lock(); defer { lock.unlock() }; return mutations }
  static func makeNextOrderConflict() { lock.lock(); failOrder=true; lock.unlock() }
  static func delayNextPost(_ value:TimeInterval) { lock.lock(); postDelay=value; lock.unlock() }
}

@MainActor enum NeoEncodeSmoke {
  private static func record(_ id:Int) -> [String:Any] {
    ["id":id,"name":"Encode fixture \(id)","startAt":1791021600000,"endAt":1791023400000,"isRecording":false,"description":"Fixture","channelId":1,"channelName":"Smoke","thumbnails":[],"videoFiles":[["id":id*10,"name":"shared.ts","type":"ts","size":100,"filename":"shared.ts"],["id":id*10+1,"name":"alternate.ts","type":"ts","size":100,"filename":"alternate.ts"]],"userId":7]
  }
  private static func queueItem(_ id:Int,_ recorded:Int,_ mode:String = "h264",percent:Double? = nil) -> [String:Any] {
    var value:[String:Any] = ["id":id,"mode":mode,"recorded":record(recorded)]
    if let percent { value["percent"] = percent }; return value
  }
  private static func wait(_ condition:() -> Bool, attempts:Int = 100) async -> Bool {
    for _ in 0..<attempts { if condition() { return true }; try? await Task.sleep(nanoseconds:20_000_000) }; return condition()
  }
  private static func views(_ root:UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
  private static func encodeButton(_ root:UIView) -> UIButton? {
    views(root).compactMap{$0 as? UIButton}.first { $0.configuration?.title == "ENCODE" || $0.title(for:.normal) == "ENCODE" }
  }
  private static func screenshot(_ shell:NeoShell,_ name:String) {
    guard let data = shell.view.asImage().pngData() else { return }
    try? data.write(to:NeoPiPSmoke.directory.appendingPathComponent("encode-\(name).png"))
  }
  static func run(shell:NeoShell) async -> [String:Bool] {
    var checks:[String:Bool] = [:]
    let base = URL(string:"https://encode-ui.invalid")!
    let records = (7101...7104).map(record)
    NeoEncodeUIProtocol.reset(records:records,running:[queueItem(8101,7101,"h264",percent:0.4)],waiting:[queueItem(8102,7102),queueItem(8103,7103)],scheduled:[queueItem(8104,7104,"later")],recovery:[["id":8105,"status":"failed","mode":"h264","recorded":record(7101),"reason":"fixture retry","canRetry":true],["id":8106,"status":"failed","mode":"h264","recorded":record(7102),"reason":"not retryable","canRetry":false]],failRecordedIDs:[7102],failCancelIDs:[8102])
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses=[NeoEncodeUIProtocol.self]
    let api = NeoAPI(base:base,session:URLSession(configuration:config)); api.activate(user:"7",headers:["X-Viewer-Profile-Id":"21","X-Viewer-Session":"encode-ui-fixture"])
    let fixtureConfig = try? JSONDecoder().decode(NeoServerConfig.self,from:JSONSerialization.data(withJSONObject:["encode":["h264","hevc"],"recorded":["D:\\Encode"]]))
    shell.smokeUseAPI(api); shell.smokeUseServerConfig(config:fixtureConfig)
    NotificationCenter.default.post(name:.neoAccountChanged,object:api); NotificationCenter.default.post(name:.neoRecordingPreferencesChanged,object:api)
    shell.showRoute("recorded"); shell.view.layoutIfNeeded()
    let nav = shell.children.compactMap{$0 as? UINavigationController}.first
    let list = nav?.viewControllers.first as? NeoRecordedPage
    checks["fourRecordFixtureLoaded"] = await wait { list?.records.map(\.id) == [7101,7102,7103,7104] && list?.smokeLoadSettled == true }
    guard checks["fourRecordFixtureLoaded"] == true, let list, let firstRecord = list.records.first else { return checks }
    shell.openDetail(firstRecord)
    var detail: NeoDetailPage?
    _ = await wait { detail = nav?.topViewController as? NeoDetailPage; return detail?.viewIfLoaded?.window != nil && nav?.transitionCoordinator == nil && encodeButton(detail?.view ?? UIView()) != nil }
    detail?.view.layoutIfNeeded()
    let direct = encodeButton(detail?.view ?? UIView())
    direct?.sendActions(for:.touchUpInside)
    var dialog = nav?.topViewController?.presentedViewController as? NeoEncodeDialog
    var bulk: NeoEncodeDialog?
    if dialog == nil { dialog = (nav?.topViewController as? NeoDetailPage)?.presentedViewController as? NeoEncodeDialog }
    let directReady = await wait { dialog = detail?.presentedViewController as? NeoEncodeDialog; return dialog?.smokeConfigModeCount == 2 && dialog?.smokeSubmitEnabled == true && dialog?.isBeingPresented == false }
    checks["recordDetailEncodeOpensReadyForm"] = directReady && dialog?.records.map(\.id) == [7101] && dialog?.bulk == false
    dialog?.smokeSetSource(71010); dialog?.smokeSetMode("hevc"); dialog?.smokeSetOptions(sameDirectory:false,removeOriginal:true,updateThumbnail:false); dialog?.smokeSetRoot("D:\\Encode"); dialog?.smokeSetDirectory("  Drama  ")
    shell.view.layoutIfNeeded(); screenshot(shell,"add")
    let enabled = dialog?.smokeSubmitEnabled == true; dialog?.smokeTapSubmit(); dialog?.smokeTapSubmit()
    let posted = await wait { NeoEncodeUIProtocol.count("POST /api/encode") == 1 && detail?.presentedViewController == nil }
    let body = NeoEncodeUIProtocol.body("POST /api/encode")
    checks["singleEncodeSubmitsExactOptionsOnce"] = enabled && posted && body?["recordedId"] as? Int == 7101 && body?["sourceVideoFileId"] as? Int == 71010 && body?["mode"] as? String == "hevc" && body?["parentDir"] as? String == "D:\\Encode" && body?["directory"] as? String == "Drama" && body?["removeOriginal"] as? Bool == true && body?["updateThumbnail"] as? Bool == false
    let dismissed = await wait { nav?.topViewController === detail && detail?.presentedViewController == nil }
    checks["singleEncodeCompletionDismisses"] = dismissed

    // Exercise the same dialog entry through the recorded-list context menu API.
    // The list's real menu is a UIKit menu; selecting its encode action presents the same action owner.
    shell.goBack(); _ = await wait { nav?.topViewController === list && nav?.transitionCoordinator == nil }
    list.view.layoutIfNeeded(); list.smokeOpenFirstMenu()
    let contextMenu = views(shell.view).compactMap{$0 as? NeoAnchoredMenu}.first
    if let contextMenu, let index = contextMenu.titles.firstIndex(of:NeoRecordingCommand.encode.rawValue) { contextMenu.select(index) }
    bulk = list.presentedViewController as? NeoEncodeDialog
    let listMenuReady = await wait { bulk?.smokeConfigModeCount == 2 && bulk?.records.map(\.id) == [7101] }
    checks["recordedListEncodeMenuOpensSameForm"] = listMenuReady && bulk?.bulk == false
    bulk?.smokeTapCancel(); _ = await wait { list.presentedViewController == nil }
    list.smokeEnterEditing(); list.smokeToggleRecording(7101); list.smokeToggleRecording(7102)
    list.smokeOpenBulk(.encode)
    bulk = list.presentedViewController as? NeoEncodeDialog
    let bulkReady = await wait { bulk?.smokeConfigModeCount == 2 && bulk?.smokeSubmitEnabled == true }
    checks["bulkEntryOpensCommonSourceForm"] = bulkReady && bulk?.records.map(\.id) == [7101,7102] && bulk?.bulk == true
    bulk?.smokeSetSource(71010); bulk?.smokeSetOptions(sameDirectory:true,removeOriginal:false,updateThumbnail:true); bulk?.smokeSetRoot("stale-parent"); bulk?.smokeSetDirectory(" stale-child ")
    bulk?.smokeTapSubmit(); bulk?.smokeTapSubmit()
    let partial = await wait { bulk?.smokeLocked == true && NeoEncodeUIProtocol.count("POST /api/encode") == 3 }
    let bulkBody = NeoEncodeUIProtocol.body("POST /api/encode",index:1)
    checks["bulkPartialLocksAndSameDirectoryOmitsStalePaths"] = partial && bulkBody?["recordedId"] as? Int == 7101 && bulkBody?["sourceVideoFileId"] as? Int == 71010 && bulkBody?["parentDir"] == nil && bulkBody?["directory"] == nil
    bulk?.smokeTapSubmit()
    let retried = await wait { NeoEncodeUIProtocol.count("POST /api/encode") == 4 && bulk?.presentingViewController == nil }
    let postBodies = NeoEncodeUIProtocol.body("POST /api/encode")
    checks["bulkRetryPostsOnlyFailedJob"] = retried && postBodies?["recordedId"] as? Int == 7102
      && NeoEncodeUIProtocol.allBodies("POST /api/encode").compactMap{$0["recordedId"] as? Int} == [7101,7101,7102,7102]


    NeoEncodeUIProtocol.resetQueue(running:[queueItem(8101,7101,"h264",percent:0.4)],waiting:[queueItem(8102,7102),queueItem(8103,7103)],scheduled:[queueItem(8104,7104,"later")],recovery:[["id":8105,"status":"failed","mode":"h264","recorded":record(7101),"reason":"fixture retry","canRetry":true],["id":8106,"status":"failed","mode":"h264","recorded":record(7102),"reason":"not retryable","canRetry":false]])
    shell.showRoute("encode"); let page = shell.children.compactMap{$0 as? UINavigationController}.first(where:{$0.topViewController is NeoEncodePage})?.topViewController as? NeoEncodePage
    let queueLoaded = await wait { page?.smokeInfo.runningItems.map(\.id) == [8101] && page?.smokeInfo.waitItems.map(\.id) == [8102,8103] && page?.smokeInfo.scheduledItems.map(\.id) == [8104] && page?.smokeInfo.recoveryItems.map(\.id) == [8105,8106] }
    checks["queueDisplaysFourEncodeGroups"] = queueLoaded
    shell.view.layoutIfNeeded(); screenshot(shell,"queue")
    if let page { page.smokeBeginOrder(); page.smokeMove(8103,to:0); page.smokeSaveOrder() }
    checks["queueReorderUsesExpectedPermutation"] = await wait { NeoEncodeUIProtocol.count("PUT /api/encode/order") == 1 && NeoEncodeUIProtocol.orderedIDs() == [8103,8102] }
    _ = await wait { page?.smokeBusy == false && page?.smokeInfo.waitItems.map(\.id) == [8103,8102] }
    page?.smokeBeginOrder(); page?.smokeMove(8102,to:0); NeoEncodeUIProtocol.makeNextOrderConflict(); page?.smokeSaveOrder()
    checks["orderConflictReloadsAndExitsReorderWithoutRetry"] = await wait { NeoEncodeUIProtocol.count("PUT /api/encode/order") == 2 && NeoEncodeUIProtocol.count("GET /api/encode") >= 3 && page?.smokeBusy == false && page?.smokeOrder == [8103,8102] && page?.smokeConflict == false }
    if let page { page.smokeSelect(8101); page.smokeSelect(8102); page.smokeSelect(8104); page.smokeAskCancel([8104,8102,8101]) }
    let confirm = page?.smokeConfirm
    _ = await wait { confirm?.viewIfLoaded?.window != nil && confirm?.isBeingPresented == false }; confirm?.smokeSubmit()
    let canceled = await wait { NeoEncodeUIProtocol.count("DELETE /api/encode/8104") == 1 && NeoEncodeUIProtocol.count("DELETE /api/encode/8102") == 1 && NeoEncodeUIProtocol.count("DELETE /api/encode/8101") == 1 }
    let order = NeoEncodeUIProtocol.mutationOrder().filter{$0.hasPrefix("DELETE ")}
    checks["bulkCancelRequestsWaitingAndScheduledBeforeRunning"] = canceled && order == ["DELETE /api/encode/8104","DELETE /api/encode/8102","DELETE /api/encode/8101"]
    checks["cancelPartialFailureKeepsFailedSelection"] = await wait { page?.smokeSelected == [8102] && page?.smokeConfirm == nil && page?.smokeBusy == false }
    page?.smokeRetry(8105)
    page?.smokeRetry(8106)
    checks["recoveryRetryUsesEligibleTaskOnly"] = await wait { NeoEncodeUIProtocol.count("POST /api/encode/8105/retry") == 1 && NeoEncodeUIProtocol.count("POST /api/encode/8106/retry") == 0 }
    _ = await wait { page?.smokeBusy == false }
    page?.smokeAskRecoveryDelete(8106); let deleteConfirm = page?.smokeConfirm
    _ = await wait { deleteConfirm?.viewIfLoaded?.window != nil && deleteConfirm?.isBeingPresented == false }; deleteConfirm?.smokeSubmit()
    checks["recoveryDeleteRequiresConfirmation"] = await wait { NeoEncodeUIProtocol.count("DELETE /api/encode/8106") == 1 && page?.smokeBusy == false && page?.smokeConfirm == nil }

    // An account change while the first bulk POST is pending must suppress the next record.
    shell.showRoute("recorded"); let rootNav = shell.children.compactMap{$0 as? UINavigationController}.first(where:{$0.topViewController is NeoRecordedPage})
    let root = rootNav?.topViewController as? NeoRecordedPage
    _ = await wait { root?.smokeLoadSettled == true && root?.presentedViewController == nil }; root?.smokeEnterEditing(); root?.smokeToggleRecording(7101); root?.smokeToggleRecording(7102); root?.smokeOpenBulk(.encode)
    let pendingDialog = root?.presentedViewController as? NeoEncodeDialog
    _ = await wait { pendingDialog?.smokeSubmitEnabled == true }
    NeoEncodeUIProtocol.delayNextPost(0.35); pendingDialog?.smokeTapSubmit()
    _ = await wait { NeoEncodeUIProtocol.count("POST /api/encode") == 5 }
    api.activate(user:"8",headers:["X-Viewer-Profile-Id":"22","X-Viewer-Session":"encode-ui-other"])
    try? await Task.sleep(nanoseconds:500_000_000)
    checks["accountChangeCancelsPendingBulkIntake"] = await wait { root?.presentedViewController == nil && NeoEncodeUIProtocol.count("POST /api/encode") == 5 }
    api.activate(user:"7",headers:["X-Viewer-Profile-Id":"21","X-Viewer-Session":"encode-ui-fixture"])
    shell.smokeUseAPI(api); shell.smokeUseServerConfig(config:fixtureConfig); shell.showRoute("recorded"); root?.smokeEndEditing(); root?.smokeFixtureRefresh()
    checks["recordedRootRetainedFourFixtures"] = await wait { root?.viewIfLoaded?.window != nil && root?.records.map(\.id) == [7101,7102,7103,7104] && root?.smokeLoadSettled == true }
    return checks
  }
}

private extension UIView {
  func asImage() -> UIImage { let renderer = UIGraphicsImageRenderer(bounds:bounds); return renderer.image { context in layer.render(in:context.cgContext) } }
}
#endif
