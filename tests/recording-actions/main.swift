import Foundation

Task { @MainActor in
  var count = 0
  func check(_ name: String, _ value: Bool) { count += 1; if !value { fatalError(name) }; print("PASS: \(name)") }
  let base = URL(string:CommandLine.arguments[1])!, api = NeoAPI(base:URL(string:CommandLine.arguments[1]+"/prefix")!)
  api.activate(user:"7",headers:["X-Viewer-Profile-Id":"21","X-Viewer-Session":"fixture"])
  let user = api.viewer, headers = api.profileHeaders
  func video(_ id:Int) -> NeoVideoFile { NeoVideoFile(id:id,name:"fixture",type:"encoded",size:2097152,filename:"test.mkv") }
  do {
    check("filename traversal stripped",NeoRecordingExport.safeFilename("../../folder\\test.mkv") == "test.mkv")
    check("filename control characters stripped",NeoRecordingExport.safeFilename("a\u{0000}b.mkv") == "ab.mkv")
    check("empty filename fallback",NeoRecordingExport.safeFilename("..",fallback:"video.mkv") == "video.mkv")
    check("filename bounded bytes",NeoRecordingExport.safeFilename(String(repeating:"あ",count:300)).utf8.count <= 220)
    let file = try await api.downloadRecording(video(1),playlist:false,user:user,headers:headers)
    check("video downloaded to disk",(try Data(contentsOf:file.file)) == Data(repeating:0x5a,count:2097152))
    check("response attachment name",file.file.lastPathComponent == "fixture.mkv")
    file.remove(); check("download temporary files released",!FileManager.default.fileExists(atPath:file.directory.path))
    let playlist = try await api.downloadRecording(video(1),playlist:true,user:user,headers:headers)
    check("playlist downloaded",try String(contentsOf:playlist.file,encoding:.utf8) == "#EXTM3U\nfixture\n")
    check("playlist extension",playlist.file.pathExtension == "m3u8"); playlist.remove()
    for id in [2,3,4] {
      do { let result = try await api.downloadRecording(video(id),playlist:false,user:user,headers:headers); result.remove(); check("reject invalid download \(id)",false) }
      catch { check("reject invalid download \(id)",true) }
    }
    let beforeCancel = try FileManager.default.contentsOfDirectory(atPath:FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("recorded-download-") }.sorted()
    let cancelled = Task { try await api.downloadRecording(video(5),playlist:false,user:user,headers:headers) }
    try await Task.sleep(nanoseconds:100_000_000); cancelled.cancel()
    do { let value = try await cancelled.value; value.remove(); check("download cancellation",false) }
    catch { check("download cancellation",true) }
    let afterCancel = try FileManager.default.contentsOfDirectory(atPath:FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("recorded-download-") }.sorted()
    check("cancelled export leaves no application temporary directory",beforeCancel == afterCancel)
    try await api.protectRecording(10,protected:true,user:user,headers:headers)
    try await api.protectRecording(10,protected:false,user:user,headers:headers)
    try await api.assignRecordingUser(10,userID:9,user:user,headers:headers)
    try await api.replaceRecordingThumbnail(101,user:user,headers:headers)
    try await api.deleteRecordingVideo(101,user:user,headers:headers)
    try await api.deleteRecording(10,user:user,headers:headers)
    check("204 mutation responses accepted",true)
    do { try await api.assignRecordingUser(10,userID:0,user:user,headers:headers); check("master assignment rejected",false) }
    catch { check("master assignment rejected",true) }
    let first = try await api.recording(20)
    check("record ownership decoded",first.userId == 9)
    api.recordingChanged(20)
    let second = try await api.recording(20)
    check("mutations invalidate detail cache",second.name != first.name)
    let stale = Task { try await api.recording(21) }
    try await Task.sleep(nanoseconds:50_000_000); api.recordingChanged(21)
    do { _ = try await stale.value; check("late old detail rejected",false) }
    catch { check("late old detail rejected",api.cachedRecording(21) == nil) }
    let (data,_) = try await URLSession.shared.data(from:base.appendingPathComponent("checks"))
    let result = try JSONSerialization.jsonObject(with:data) as! [String:Bool]
    for (name,value) in result.sorted(by:{$0.key<$1.key}) { check(name,value) }
    check("active account unchanged by recording assignment",api.viewer == "7")
    print("Recording actions/download: \(count) checks passed")
    exit(0)
  } catch { fatalError("Unexpected failure: \(error)") }
}
dispatchMain()
