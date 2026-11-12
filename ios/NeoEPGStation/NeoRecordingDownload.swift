import Foundation

struct NeoRecordingExport {
  let directory: URL, file: URL
  func remove() { try? FileManager.default.removeItem(at:directory) }
  static func safeFilename(_ suggested: String, fallback: String = "download") -> String {
    var name = suggested.replacingOccurrences(of:"\\",with:"/").components(separatedBy:"/").last ?? ""
    name = name.components(separatedBy:.controlCharacters).joined().trimmingCharacters(in:.whitespacesAndNewlines)
    if name.isEmpty || name == "." || name == ".." { name = fallback }
    while name.utf8.count > 220 { name.removeLast() }
    return name
  }
}

extension NeoAPI {
  // URLSession writes directly to a temporary file. Never materialize a
  // recording as Data, and keep the same redirect/cookie policy as API calls.
  func downloadRecording(_ video: NeoVideoFile, playlist: Bool, user: String, headers: [String:String]) async throws -> NeoRecordingExport {
    let path = playlist ? "/videos/\(video.id)/playlist" : "/videos/\(video.id)?isDownload=true"
    var request = URLRequest(url:url(path),cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:60)
    request.setValue("*/*",forHTTPHeaderField:"Accept")
    request.setValue(user,forHTTPHeaderField:"X-EPGStation-User-Id")
    for (key,value) in headers { request.setValue(value,forHTTPHeaderField:key) }
    let (temporary,response) = try await session.download(for:request)
    defer { try? FileManager.default.removeItem(at:temporary) }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw NeoError("サーバーの応答を確認できませんでした。") }
    guard (200..<300).contains(http.statusCode) else {
      var message: String?
      if let handle = try? FileHandle(forReadingFrom:temporary) {
        defer { try? handle.close() }
        if let bytes = try? handle.read(upToCount:65536), let json = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] {
          message = json["errors"] as? String ?? json["message"] as? String
        }
      }
      throw NeoError(message ?? "ダウンロードできませんでした（HTTP \(http.statusCode)）。",statusCode:http.statusCode)
    }
    let mime = http.mimeType?.lowercased() ?? ""
    guard !mime.contains("html"), !mime.contains("json") else { throw NeoError("動画ファイルの代わりに別のページが返されました。接続設定を確認してください。") }
    let original = NeoRecordingExport.safeFilename(video.filename ?? video.name)
    let fallback = playlist ? (original as NSString).deletingPathExtension+".m3u8" : original
    let suggested = http.value(forHTTPHeaderField:"Content-Disposition") == nil ? fallback : http.suggestedFilename ?? fallback
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-download-"+UUID().uuidString,isDirectory:true)
    let destination = directory.appendingPathComponent(NeoRecordingExport.safeFilename(suggested,fallback:fallback))
    do {
      try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      try FileManager.default.moveItem(at:temporary,to:destination)
      try Task.checkCancellation()
      return NeoRecordingExport(directory:directory,file:destination)
    } catch { try? FileManager.default.removeItem(at:directory); throw error }
  }
}
