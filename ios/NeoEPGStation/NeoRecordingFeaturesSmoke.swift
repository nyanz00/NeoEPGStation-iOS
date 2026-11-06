#if targetEnvironment(simulator)
import UIKit

private final class NeoFeatureProtocol: URLProtocol {
  static let lock = NSLock()
  static var puts: [Int:Int] = [:], gets: [Int:Int] = [:], deletes = 0, forces = 0
  static var readSaves = 0, writeSaves = 0
  static var profileRequests = 0, historyRequests = 0
  static var detailRequests = 0, episodeGets = 0
  static var sessionCode = 200, listRequests = 0
  static var widths: [String:Bool] = [:]
  static var watched = Set<Int>(), failRefresh = false, reads = false, writes = true, authenticated = true, tokenSaved = false
  private var cancelled = false
  private let cancellation = NSLock()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() { cancellation.lock(); cancelled = true; cancellation.unlock() }
  override func startLoading() {
    let path = request.url!.path, method = request.httpMethod ?? "GET"
    let id = path.split(separator:"/").compactMap { Int($0) }.first ?? 0
    Self.lock.lock()
    let user = request.value(forHTTPHeaderField:"X-EPGStation-User-Id") ?? ""
    Self.authenticated = Self.authenticated && ["7","9"].contains(user)
    let historyPath = path.contains("/playbackHistory") || path.hasSuffix("/playback")
    let publicPath = path == "/api/recorded" || path == "/api/recorded/\(id)" || path == "/api/users" || path == "/api/viewer-profiles" || path.hasSuffix("/session")
    if historyPath {
      // Playback history deliberately uses only the active user, without a
      // locked-profile session (same public endpoint as the Web client).
      Self.historyRequests += 1
      Self.authenticated = Self.authenticated && request.value(forHTTPHeaderField:"X-Viewer-Session") == nil && request.value(forHTTPHeaderField:"X-Viewer-Profile-Id") == nil
    } else if !publicPath {
      Self.profileRequests += 1
      Self.authenticated = Self.authenticated && request.value(forHTTPHeaderField:"X-Viewer-Session") == "fixture-session" && request.value(forHTTPHeaderField:"X-Viewer-Profile-Id") == (user == "7" ? "21" : "22")
    }
    var code = 200, delay = 0.0, result: [String:Any] = [:]
    if path == "/api/users" { result = ["users":[["id":7,"name":"Fixture user"],["id":9,"name":"Other user"]]] }
    else if path == "/api/viewer-profiles" { result = ["profiles":[["id":21,"name":"Fixture profile","tvUserId":7,"lockRequired":true],["id":22,"name":"Other profile","tvUserId":9,"lockRequired":false]]] }
    else if path.hasSuffix("/session") { code = Self.sessionCode; result = code == 200 ? ["valid":true] : ["message":"fixture session check failure"] }
    else if path.hasSuffix("/annict/status") { result = ["configured":Self.reads,"writeConfigured":Self.writes,"viewerProfileId":21] }
    else if path.hasSuffix("/token") || path.hasSuffix("/write-token") {
      var body = request.httpBody ?? Data()
      if body.isEmpty, let input = request.httpBodyStream {
        input.open(); defer { input.close() }; var buffer = [UInt8](repeating:0,count:1024)
        while input.hasBytesAvailable { let count = input.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; body.append(contentsOf:buffer.prefix(count)) }
      }
      if method == "PUT" {
        Self.tokenSaved = Self.tokenSaved || String(data:body,encoding:.utf8)?.contains("fixture-token") == true
        if path.hasSuffix("/write-token") { Self.writeSaves += 1 } else { Self.readSaves += 1 }
      }
      if path.hasSuffix("/write-token") { Self.writes = method != "DELETE" } else { Self.reads = method != "DELETE" }
    } else if path.hasSuffix("/info") {
      if id == 2 && method == "GET" { delay = 0.3 }
      Self.gets[id,default:0] += 1
      if method == "POST" { Self.forces += 1 }
      if Self.failRefresh { code = 500; Self.failRefresh = false; result = ["message":"fixture refresh failure"] }
      else {
        result = Self.info
        if id == 2 && method == "GET" { result.removeValue(forKey:"keyframes") }
        else if method == "GET" && Self.gets[id] == 1 { var keys = result["keyframes"] as! [String:Any]; keys["status"] = "analyzing"; keys["stale"] = true; result["keyframes"] = keys }
      }
    } else if path.hasSuffix("/annictEpisode") {
      if method == "GET" { Self.episodeGets += 1 }
      let count = Self.puts[id,default:0]
      if method == "PUT" { Self.puts[id] = count+1; if id == 5 && count == 0 { code = 503 } else { Self.watched.insert(id) } }
      if method == "DELETE" { Self.deletes += 1; Self.watched.remove(id) }
      result = ["state":id == 8 && method == "GET" ? "pending" : "matched","annictId":123,"episodeNumber":4,"episodeNumberText":"第4話","episodeTitle":"Fixture episode","writeConfigured":id != 7 && Self.writes,"watched":Self.watched.contains(id),"canUnwatch":id != 9 && Self.watched.contains(id)]
      if id == 6 { delay = 0.2 }
    } else if path.hasSuffix("/playbackHistory") {
      Self.widths["history"] = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "isHalfWidth" })?.value == "true"
      result = ["items":(101..<105).map { id -> [String:Any] in
        var value = Self.recording(id:id); value.removeValue(forKey:"dropLogFile")
        return ["recorded":value,"playback":["position":0,"duration":100,"watchedSeconds":0]]
      }]
    } else if path.hasSuffix("/playbackHistory/settings") {
      result = ["enabled":true,"limit":100]
    } else if path == "/api/recorded" {
      Self.widths["list"] = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "isHalfWidth" })?.value == "true"
      Self.listRequests += 1; delay = 0.2
      result = ["records":(101..<105).map { Self.recording(id:$0) },"total":4]
    } else if path == "/api/recorded/\(id)" {
      Self.detailRequests += 1; delay = 0.15
      Self.widths["detail"] = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "isHalfWidth" })?.value == "true"
      result = Self.recording(id:id)
    } else if path.hasSuffix("/playback") { result = ["position":0,"duration":100,"watchedSeconds":0] }
    else { code = 404 }
    Self.lock.unlock()
    let data = try! JSONSerialization.data(withJSONObject:result)
    let response = HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
    DispatchQueue.global().asyncAfter(deadline:.now()+delay) { [self] in
      cancellation.lock(); let stopped = cancelled; cancellation.unlock(); guard !stopped else { return }
      client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
  }
  static var info: [String:Any] {
    ["fileName":"Feature fixture","formatName":"Matroska / WebM","size":1073741824,"duration":1440,"videoCodec":"av1","videoProfile":"Main","width":1440,"height":1080,"frameRate":23.976,"pixelFormat":"yuv420p10le","bitDepth":10,"hdr":NSNull(),"streams":[["index":1,"type":"audio","codec":"aac","language":"jpn","channels":2],["index":2,"type":"subtitle","codec":"ass","language":"jpn","title":"Comments"]],"ts":["networkId":1,"transportStreamId":2,"serviceId":3,"pmtPid":4,"pcrPid":5,"videoPid":6,"audioPid":7,"subtitlePid":8],"analyzedAt":1700000000000,"analysisError":NSNull(),"keyframes":["status":"ready","stale":false,"averageInterval":4,"minInterval":2,"maxInterval":6,"sampledDuration":60,"sampleWindows":[["start":0,"end":20,"keyframeCount":5]],"keyframeCount":15,"intervalCount":14,"analyzedAt":1700000005000,"error":NSNull()]]
  }
  static func recording(id:Int) -> [String:Any] {
    ["id":id,"name":"第４話　テスト！","startAt":1700000000000,"endAt":1700001800000,"isRecording":false,"description":"ＡＢＣ　テスト","extended":"＃４","videoFiles":[["id":1,"name":"AV1","type":"encoded","size":1000]],"dropLogFile":["id":4,"dropCnt":239,"errorCnt":0,"scramblingCnt":0]]
  }
  static func snapshot<T>(_ read: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return read() }
  static func failNextRefresh() { lock.lock(); failRefresh = true; lock.unlock() }
  static func setSessionCode(_ value: Int) { lock.lock(); sessionCode = value; lock.unlock() }
}

@MainActor enum NeoRecordingFeaturesSmoke {
  static func run(shell: NeoShell) async -> [String:Bool] {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NeoFeatureProtocol.self]
    let session = URLSession(configuration:config), base = URL(string:"https://recording-features.invalid")!
    let api = NeoAPI(base:base,session:session)
    api.activate(user:"7",headers:["X-Viewer-Profile-Id":"21","X-Viewer-Session":"fixture-session"]); shell.smokeUseAPI(api)
    let keys = ["annict.autoWatchMode","annict.threshold","annict.markFinal","annict.disableFinalRules","display.halfWidth."+base.absoluteString]
    let saved = keys.map { UserDefaults.standard.object(forKey:$0) }
    defer { for (key,value) in zip(keys,saved) { if let value { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }; session.invalidateAndCancel() }
    var checks = [String:Bool]()
    func progress(_ phase: String) { try? Data(phase.utf8).write(to:NeoPiPSmoke.directory.appendingPathComponent("ui-recording-features-progress.txt")) }
    api.isHalfWidthDisplayed = true
    let opening = await shell.smokeMeasureOpening()
    progress("opening measured")
    checks.merge(opening.checks) { _,value in value }
    if let data = try? JSONSerialization.data(withJSONObject:opening.timings,options:.prettyPrinted) {
      try? data.write(to:NeoPiPSmoke.directory.appendingPathComponent("recording-opening-times.json"))
    }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<100 { if condition() { return }; try? await Task.sleep(nanoseconds:50_000_000) }
    }
    func capture(_ name: String) {
      let surface = shell.view.window ?? shell.view!
      surface.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds:surface.bounds).image { _ in surface.drawHierarchy(in:surface.bounds,afterScreenUpdates:true) }
      try? image.pngData()?.write(to:NeoPiPSmoke.directory.appendingPathComponent(name+".png"))
    }
    let history = try? await api.history(user:api.viewer)
    checks["historyNormalizesTextBeforeRendering"] = history?.items.first?.recorded.name == "第4話 テスト!"
    let beforeDetails = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.detailRequests }
    api.prepareDetails([101,101])
    await wait { api.cachedRecording(101) != nil && api.cachedAnnictEpisode(101) != nil }
    checks["visiblePreparationDeduplicatesRequests"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.detailRequests == beforeDetails+1 }
    if let item = history?.items.first?.recorded {
      let prepared = NeoDetailPage(item:item,shell:shell); shell.smokeShowFeaturePage(prepared)
      checks["detailBodyDeferredUntilSlide"] = prepared.smokeRenderCount == 0 && !prepared.openingContentFinished
      await wait { prepared.openingContentFinished }
      checks["initialDetailUsesPreparedDropAndText"] = prepared.smokeDropText.contains("drop: 239") && prepared.smokeDropIsError && prepared.smokeTitleText == "第4話 テスト!"
      checks["initialDetailIncludesCachedAnnict"] = prepared.headerAccessory is NeoAnnictHeader
      let count = prepared.smokeRenderCount
      try? await Task.sleep(nanoseconds:200_000_000)
      checks["preparedDetailDoesNotRebuildAfterOpening"] = prepared.smokeRenderCount == count
      capture("recording-prepared-detail"); shell.smokePopFeaturePage()
    }
    api.isHalfWidthDisplayed = false
    checks["formatToggleIsolatesPreparedDetails"] = api.cachedRecording(101) == nil
    let fullRecord = try? await api.recording(101), fullHistory = try? await api.history(user:api.viewer)
    let fullList = try? await api.recordings(page:1)
    checks["halfWidthOffPreservesFullWidthAcrossEntrances"] = fullRecord?.name == "第４話　テスト！" && fullHistory?.items.first?.recorded.name == fullRecord?.name && fullList?.records.first?.name == fullRecord?.name
    checks["allRecordedQueriesHonorHalfWidthOff"] = NeoFeatureProtocol.snapshot { ["history","list","detail"].allSatisfy { NeoFeatureProtocol.widths[$0] == false } }
    api.isHalfWidthDisplayed = true
    checks["openAnimation150ms"] = shell.smokePushAnimationDuration == 0.15
    NeoAnnictPreferences.mode = "progress"; NeoAnnictPreferences.threshold = 90
    let settings = NeoSettingsCategoryPage(category:.annict,shell:shell); shell.smokeShowFeaturePage(settings)
    progress("metadata and text preferences checked")
    await wait { settings.openingContentFinished }
    checks["settingsInitialBuildOnce"] = settings.smokeRenderCount == 1
    settings.smokeConnectAnnict(write:false,token:"fixture-token")
    checks["tokenMutationDisablesControls"] = settings.smokeTokenControls.allSatisfy { !$0.connect.isEnabled && !$0.remove.isEnabled }
    await wait { settings.smokeRenderCount >= 2 }
    settings.smokeConnectAnnict(write:true,token:"fixture-token")
    await wait { settings.smokeRenderCount >= 3 }
    checks["tokensUseServerAPI"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.reads && NeoFeatureProtocol.tokenSaved && NeoFeatureProtocol.readSaves == 1 && NeoFeatureProtocol.writeSaves == 1 }
    checks["recordingSettingsPopulated"] = settings.smokeSettingCount >= 10
    await wait { settings.smokeTokenControls.allSatisfy { $0.connected } }
    settings.view.layoutIfNeeded()
    checks["connectedTokenButtonsMatchWeb"] = settings.smokeTokenControls.count == 2 && settings.smokeTokenControls.allSatisfy {
      !$0.connect.isEnabled && !$0.remove.isHidden && $0.remove.isEnabled && $0.field.frame.maxX < $0.connect.frame.minX && $0.remove.titleColor(for:.normal) == UIColor(red:244/255,green:67/255,blue:54/255,alpha:1)
    }
    for control in settings.smokeTokenControls {
      control.field.text = "   "; control.field.sendActions(for:.editingChanged)
      let emptyDisabled = !control.connect.isEnabled
      control.field.text = "replacement"; control.field.sendActions(for:.editingChanged)
      checks[control.field.accessibilityIdentifier!+"InputEnablesConnect"] = emptyDisabled && control.connect.isEnabled
      control.field.text = ""; control.field.sendActions(for:.editingChanged)
    }
    checks["annictControlsFitViewport"] = settings.smokeControlsWithinWidth
    settings.smokeSaveRowGeometry()
    capture("recording-annict-settings"); shell.smokePopFeaturePage()
    let detail = NeoDetailPage(item:NeoRecordedPage.fixtures.records[0],shell:shell); shell.smokeShowFeaturePage(detail)
    await wait { detail.openingContentFinished }
    checks["detailAvoidsDuplicateInitialBuild"] = detail.smokeRenderCount <= (shell.tablet ? 2 : 1)
    let header = detail.smokeAnnictControl()
    await wait { header?.smokeEpisode != nil }
    header?.smokeMark(); await wait { header?.smokeEpisode?.watched == true }
    checks["manualMarkFromDetail"] = header?.smokeEpisode?.watched == true
    capture("recording-annict-detail")
    header?.smokeUnmark(); await wait { header?.smokeEpisode?.watched == false }
    checks["manualUnmarkFromDetail"] = header?.smokeEpisode?.watched == false && NeoFeatureProtocol.snapshot { NeoFeatureProtocol.deletes == 1 }
    let ownedElsewhere = NeoAnnictHeader(api:api,recordingID:9,host:detail)
    _ = try? await api.annictEpisode(9,method:"PUT"); ownedElsewhere.load()
    await wait { ownedElsewhere.smokeEpisode != nil }; ownedElsewhere.smokeUnmark()
    checks["externalRecordCannotBeRemoved"] = ownedElsewhere.smokeEpisode?.canUnwatch == false && NeoFeatureProtocol.snapshot { NeoFeatureProtocol.deletes == 1 }
    let pending = NeoAnnictHeader(api:api,recordingID:8,host:detail); pending.load()
    await wait { pending.smokeEpisode?.state == "pending" }; pending.smokeRematch(); await wait { pending.smokeEpisode?.state == "matched" }
    checks["pendingEpisodeRematches"] = pending.smokeEpisode?.state == "matched"
    let original = NeoRecordedPage.fixtures.records[0]
    let item = NeoRecording(id:original.id,name:original.name,startAt:original.startAt,endAt:original.endAt,isRecording:false,description:nil,extended:nil,channelId:nil,channelName:nil,thumbnails:nil,
      videoFiles:[NeoVideoFile(id:1,name:"AV1",type:"encoded",size:0,filename:nil),NeoVideoFile(id:2,name:"TS",type:"ts",size:0,filename:nil),NeoVideoFile(id:11,name:String(repeating:"Long filename ",count:8),type:"encoded",size:0,filename:nil)])
    let info = NeoRecordedInfoDialog(item:item,api:api); detail.present(info,animated:false)
    await wait { info.smokeRows.count == 21 }
    checks["infoAllWebRows"] = info.smokeRows.count == 21
    await wait { info.smokeRows.last?.1 == "OK" }
    checks["analysisPollsUntilReady"] = info.smokeRows.last?.1 == "OK" && NeoFeatureProtocol.snapshot { (NeoFeatureProtocol.gets[1] ?? 0) >= 2 }
    info.view.layoutIfNeeded()
    let frames = info.smokeChoiceFrames
    checks["infoChoicesFlowHorizontallyAndWrap"] = frames.count == 3 && frames[0].minY == frames[1].minY && frames[1].minX > frames[0].maxX && frames[2].minY > frames[1].minY
    checks["infoCloseIsJapanese"] = info.smokeCloseTitle == "閉じる"
    capture("recording-info")
    let cardHeight = info.smokeCardHeight, bodyHeight = info.smokeBodyHeight
    info.smokeSelect(2); info.view.layoutIfNeeded()
    checks["uncachedInfoDoesNotCollapseOrShowPreviousFile"] = info.smokeRows.isEmpty && info.smokeBodyHeight >= bodyHeight-0.5 && abs(info.smokeCardHeight-cardHeight) < 0.5
    capture("recording-info-loading")
    await wait { info.smokeRows.count == 14 }
    checks["infoSwitchAndLegacyServer"] = info.smokeRows.count == 14 && info.smokeRows.last?.1.contains("unavailable") == true
    info.smokeReanalyze(); await wait { info.smokeRows.count == 21 }
    checks["infoReanalysisUsesPOST"] = info.smokeRows.count == 21 && NeoFeatureProtocol.snapshot { NeoFeatureProtocol.forces > 0 }
    NeoFeatureProtocol.failNextRefresh()
    info.smokeReanalyze(); await wait { !info.smokeMessage.isEmpty }
    checks["infoKeepsResultsWhenRefreshFails"] = info.smokeRows.count == 21 && info.smokeMessage.contains("Could not refresh")
    info.dismiss(animated:false); shell.smokePopFeaturePage()
    let cancelledDetail = NeoDetailPage(item:original,shell:shell)
    shell.smokeShowFeaturePage(cancelledDetail); shell.smokePopFeaturePage()
    try? await Task.sleep(nanoseconds:150_000_000)
    checks["returnCancelsUnstartedBodyConstruction"] = cancelledDetail.smokeRenderCount == 0 && !cancelledDetail.openingContentFinished

    let list = NeoRecordedPage(shell:shell); shell.smokeShowFeaturePage(list)
    progress("authentication failure checks")
    await wait { list.smokeLoadSettled }
    let secrets = NeoProfileSecrets(server:base), stored = String(repeating:"s",count:40)
    try? secrets.save(21,token:stored)
    NeoFeatureProtocol.setSessionCode(500)
    list.smokeReload(); shell.account?.restore()
    try? await Task.sleep(nanoseconds:50_000_000)
    checks["oldRequestDoesNotStopNewLoading"] = list.smokeLoading
    await wait { shell.account?.busy == false && shell.presentedViewController is UIAlertController }
    await wait { list.smokeLoadSettled }
    checks["sameUserVerificationFailureDoesNotHangList"] = list.smokeLoadSettled && api.viewer == "7" && !api.accountReady
    checks["temporaryFailureKeepsSavedSession"] = (try? secrets.read(21)) == stored
    let confirmation = shell.presentedViewController as? UIAlertController
    checks["temporaryFailureDoesNotOfferMasterFallback"] = confirmation != nil && confirmation?.actions.contains(where: { $0.title == "masterへ戻る" }) == false
    confirmation?.dismiss(animated:false)
    let historyPage = NeoHistoryPage(shell:shell); shell.smokeShowFeaturePage(historyPage)
    await wait { historyPage.smokeReady }
    checks["historyReadableDuringAuthenticationFailure"] = historyPage.smokeReady && !api.accountReady
    let privateBefore = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.episodeGets }
    _ = try? await api.annictEpisode(390)
    checks["protectedFeaturesStayBlockedWhileUnverified"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.episodeGets == privateBefore }
    shell.smokePopFeaturePage()
    NeoFeatureProtocol.setSessionCode(401)
    let expired = try? await api.validateProfile(21,token:stored)
    checks["explicitSessionRejectionIsInvalidAuthentication"] = expired == false
    NeoFeatureProtocol.setSessionCode(200)
    shell.account?.restore(); await wait { api.accountReady && shell.account?.busy == false }
    checks["verificationRetryRestoresSelectedUser"] = api.accountReady && api.viewer == "7"
    api.activate(user:"7",headers:["X-Viewer-Profile-Id":"21","X-Viewer-Session":"fixture-session"])
    secrets.remove(21); await wait { list.smokeLoadSettled }

    let baseline = NeoScrollFrameProbe(); baseline.start()
    progress("scroll checks")
    try? await Task.sleep(nanoseconds:300_000_000); let baselineTimes = baseline.finish()
    list.smokePrefetchAllowed = true
    let constructions = NeoDetailPage.smokeConstructions, detailGets = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.detailRequests }
    let scrolling = NeoScrollFrameProbe(); scrolling.start(); list.smokeScrollStart()
    try? await Task.sleep(nanoseconds:600_000_000)
    let scrollTimes = scrolling.finish()
    checks["animatedScrollingWasExercised"] = list.smokeScrollOffset > 100 && scrollTimes.count > 5
    checks["scrollingStartsNoDetailPrefetch"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.detailRequests == detailGets }
    checks["scrollingCreatesNoDetailScreens"] = NeoDetailPage.smokeConstructions == constructions
    list.smokeScrollEnd()
    await wait { NeoFeatureProtocol.snapshot { NeoFeatureProtocol.detailRequests > detailGets } }
    checks["settledListFetchesOnlyData"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.detailRequests > detailGets } && NeoDetailPage.smokeConstructions == constructions
    if let data = try? JSONSerialization.data(withJSONObject:["baselineFrameIntervalsMs":baselineTimes,"scrollFrameIntervalsMs":scrollTimes],options:.prettyPrinted) {
      try? data.write(to:NeoPiPSmoke.directory.appendingPathComponent("recording-scroll-times.json"))
    }
    list.smokePrefetchAllowed = false; api.pauseDetailPreparation(); shell.smokePopFeaturePage()
    progress("automatic Annict checks")
    NeoAnnictPreferences.mode = "start"
    let start = NeoAnnictPlayback(api:api,recordingID:3)
    start.sample(0,duration:100,running:false,seeking:false,rate:1)
    checks["pausedNeverAutoMarks"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[3] == nil }
    start.sample(0,duration:100,running:true,seeking:false,rate:1)
    await wait { NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[3] == 1 } }
    for _ in 0..<10 { start.sample(1,duration:100,running:true,seeking:false,rate:1) }
    checks["startMarksOnce"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[3] == 1 }; start.finish()
    NeoAnnictPreferences.mode = "progress"
    let progress = NeoAnnictPlayback(api:api,recordingID:4)
    progress.sample(95,duration:100,running:true,seeking:true,rate:1)
    progress.sample(95,duration:100,running:true,seeking:false,rate:1); progress.historyProgress(89,duration:100)
    checks["seekDoesNotMeetPercentage"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[4] == nil }
    progress.historyProgress(90,duration:100); await wait { NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[4] == 1 } }
    checks["serverCumulativePercentageMarks"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[4] == 1 }; progress.finish()
    NeoAnnictPreferences.mode = "start"
    let retry = NeoAnnictPlayback(api:api,recordingID:5,retryDelay:100_000_000)
    retry.sample(1,duration:100,running:true,seeking:false,rate:1)
    await wait { NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[5] == 2 } && retry.status.isEmpty }
    checks["failedAutomaticWriteRetries"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[5] == 2 } && retry.status.isEmpty; retry.finish()
    let closing = NeoAnnictPlayback(api:api,recordingID:10)
    closing.sample(1,duration:100,running:true,seeking:false,rate:1); closing.finish()
    await wait { NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[10] == 1 } }
    checks["eligibleWriteSurvivesPlayerClose"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[10] == 1 }
    let disabled = NeoAnnictPlayback(api:api,recordingID:7); disabled.sample(1,duration:100,running:true,seeking:false,rate:1)
    try? await Task.sleep(nanoseconds:200_000_000)
    checks["unconfiguredNeverWrites"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[7] == nil }; disabled.finish()
    let switched = NeoAnnictPlayback(api:api,recordingID:6); switched.sample(1,duration:100,running:true,seeking:false,rate:1)
    try? await Task.sleep(nanoseconds:50_000_000)
    api.activate(user:"9",headers:["X-Viewer-Profile-Id":"22","X-Viewer-Session":"fixture-session"])
    checks["profileSwitchIsolatesPreparedData"] = api.cachedRecording(101) == nil && api.cachedAnnictEpisode(101) == nil
    try? await Task.sleep(nanoseconds:300_000_000)
    checks["profileSwitchCancelsPendingRecord"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.puts[6] == nil }; switched.finish()
    checks["allRequestsUseActiveAuthentication"] = NeoFeatureProtocol.snapshot { NeoFeatureProtocol.authenticated && NeoFeatureProtocol.profileRequests > 0 && NeoFeatureProtocol.historyRequests > 0 }
    shell.showRoute("recorded")
    return checks
  }
}

@MainActor private final class NeoScrollFrameProbe: NSObject {
  private var link: CADisplayLink?, last: CFTimeInterval?, samples: [Double] = []
  func start() { link = CADisplayLink(target:self,selector:#selector(tick)); link?.add(to:.main,forMode:.common) }
  @objc private func tick() { let now = CACurrentMediaTime(); if let last { samples.append((now-last)*1000) }; last = now }
  func finish() -> [Double] { link?.invalidate(); link = nil; return samples }
}
#endif
