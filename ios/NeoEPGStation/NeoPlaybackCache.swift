import Foundation
import Network

// Each player owns a private loopback Range endpoint. VLC remains the demuxer;
// neither TS nor MP4 is remuxed or downloaded in full. Only requested blocks
// are fetched, and only this player's temporary directory can be removed.
@objc(NeoPlaybackCache)
final class NeoPlaybackCache: NSObject, URLSessionTaskDelegate {
  static let presets = [0, 30, 60, 120, 180, 240, 300]
  static let preference = "player.rewind.seconds"
  @objc static var savedSeconds: Int {
    let value = UserDefaults.standard.object(forKey: preference) as? Int ?? 60
    return presets.contains(value) ? value : 60
  }
  private static var root: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("NeoPlaybackTemporary", isDirectory: true)
  }
  private static let activeLock = NSLock()
  private static var activeDirectories: Set<URL> = []
  @objc static func cleanAbandoned() {
    activeLock.lock(); defer { activeLock.unlock() }
    for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !activeDirectories.contains(url) {
      try? FileManager.default.removeItem(at: url)
    }
  }
  private struct Block { let count: Int; let endTime: Double?; var used: Double }
  private let source: URL, authorization: String?, directory: URL
  private let queue = DispatchQueue(label: "neo.playback.range")
  private let route = "/" + UUID().uuidString
  private let blockSize: Int64 = 1024 * 1024
  private let limit = 2 * 1024 * 1024 * 1024
  private var blocks: [Int64: Block] = [:], bytes = 0
  private var mediaTime = 0.0, highWater = 0.0, lastUse = ProcessInfo.processInfo.systemUptime
  private var seconds = NeoPlaybackCache.savedSeconds
  private var listener: NWListener?, session: URLSession!
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var requests: [ObjectIdentifier: URLSessionDataTask] = [:]
  private var length: Int64 = 0, closed = false
  private var validator: String?, validatorHeader: String?
  private var byteClock = NeoMediaByteClock()
  private var startup: ((URL?, String?) -> Void)?
  @objc private(set) var status = ""
  @objc var onChange: (() -> Void)?
  @objc var onTransportFailure: (() -> Void)?
  private var suspended = false
  private(set) var networkBytes: Int64 = 0, hitBytes: Int64 = 0

  @objc(initWithSource:username:password:)
  init(source: URL, username: String, password: String) {
    self.source = source; directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    super.init()
    Self.cleanAbandoned()
    Self.activeLock.lock(); Self.activeDirectories.insert(directory); Self.activeLock.unlock()
    let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = .shared; config.urlCredentialStorage = .shared
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  @objc func start(_ completion: @escaping (URL?, String?) -> Void) {
    queue.async { [self] in
      startup = completion
      fetch(offset: 0, count: 1) { [self] result in
        switch result {
        case .failure: finishStart(nil, "巻き戻し用キャッシュを開始できません。サーバーのRange応答と認証を確認してください。")
        case .success:
          self.loadIndex(offset: 0, attempt: 0) { [self] in self.listen() }
        }
      }
    }
  }
  @objc func fetchDuration(_ completion: @escaping (Double) -> Void) {
    // The Web player uses this same file-duration API. In particular, VLC's
    // HTTP TS input may remain seekable without ever reporting a duration.
    var request = URLRequest(url: source.appendingPathComponent("duration"))
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    session.dataTask(with: request) { data, response, _ in
      var duration = 0.0
      if let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let value = json["duration"] as? Double, value.isFinite, value > 0, value <= 24*60*60 { duration = value }
      DispatchQueue.main.async { completion(duration) }
    }.resume()
  }
  private func listen() {
    guard !closed, !suspended else { return }
          do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let server = try NWListener(using: parameters); listener = server
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            server.stateUpdateHandler = { [weak self, weak server] state in
              guard let self, let server, self.listener === server else { return }
              if case .ready = state, let port = server.port {
                self.finishStart(URL(string: "http://127.0.0.1:\(port.rawValue)\(self.route)"), nil)
              } else if case .failed = state {
                let starting = self.startup != nil
                self.finishStart(nil, "巻き戻し用キャッシュの読み取り口を開始できません。")
                if !starting { self.report("動画の読み取り接続が切れました。復旧しています…"); DispatchQueue.main.async { [weak self] in self?.onTransportFailure?() } }
              }
            }
            server.start(queue: queue)
          } catch { finishStart(nil, "巻き戻し用キャッシュを準備できません。") }
  }
  private func loadIndex(offset: Int64, attempt: Int, completion: @escaping () -> Void) {
    guard offset+8 <= length, attempt < 64 else { completion(); return }
    fetch(offset: offset, count: Int(min(16, length-offset))) { [self] result in
      guard case .success(let data) = result, let short = NeoMediaByteClock.number(data, 0),
        let kind = String(data: data.subdata(in: 4..<8), encoding: .ascii) else { completion(); return }
      let header = short == 1 ? 16 : 8
      let size = short == 1 ? NeoMediaByteClock.number(data, 8, bytes: 8) ?? 0 : short
      guard size >= header, size <= length-offset else { completion(); return }
      if kind == "moov", size <= 32*1024*1024 {
        fetch(offset: offset+Int64(header), count: Int(size)-header) { [self] result in
          if case .success(let body) = result { _ = byteClock.loadMP4Moov(body) }; completion()
        }
      } else if ["ftyp", "mdat", "free", "wide", "skip"].contains(kind) {
        loadIndex(offset: offset+Int64(size), attempt: attempt+1, completion: completion)
      } else { completion() }
    }
  }
  private func finishStart(_ url: URL?, _ error: String?) {
    guard let callback = startup else { return }; startup = nil
    DispatchQueue.main.async { [weak self] in
      if let error { self?.status = error; self?.onChange?() }
      callback(url, error)
    }
  }
  @objc func setSeconds(_ value: Int) {
    guard Self.presets.contains(value) else { return }
    UserDefaults.standard.set(value, forKey: Self.preference)
    queue.async { [self] in seconds = value; if value == 0 { clearBlocks() } else { evict() } }
  }
  @objc func observeTime(_ value: Double, running: Bool) {
    guard value.isFinite else { return }
    queue.async { [self] in
      mediaTime = max(0, value)
      if running { lastUse = ProcessInfo.processInfo.systemUptime; highWater = max(highWater, mediaTime); evict() }
    }
  }
  @objc func beginSeek(_ time: Double) {
    queue.async { [self] in mediaTime = max(0, time); highWater = mediaTime; lastUse = ProcessInfo.processInfo.systemUptime }
  }
  @objc func close() {
    queue.async { [self] in
      guard !closed else { return }; closed = true
      finishStart(nil, "再生を終了しました。")
      stopTransport()
      session.invalidateAndCancel(); clearBlocks()
      Self.activeLock.lock(); Self.activeDirectories.remove(directory); Self.activeLock.unlock()
    }
  }
  // Suspending transport does not destroy retained video blocks or metadata.
  private func stopTransport() {
    let old = listener; listener = nil; old?.cancel()
    requests.values.forEach { $0.cancel() }; requests.removeAll()
    let oldConnections = Array(connections.values); connections.removeAll()
    oldConnections.forEach { $0.cancel() }
  }
  @objc func suspendTransport() {
    queue.async { [self] in guard !closed else { return }; suspended = true; stopTransport() }
  }
  @objc func reopen(_ completion: @escaping (URL?, String?) -> Void) {
    queue.async { [self] in
      guard !closed else { DispatchQueue.main.async { completion(nil, "再生を終了しました。") }; return }
      finishStart(nil, "接続を作り直しています。")
      stopTransport(); suspended = false; startup = completion; listen()
    }
  }
  private func clearBlocks() { blocks.removeAll(); bytes = 0; try? FileManager.default.removeItem(at: directory) }
  private func file(_ offset: Int64) -> URL { directory.appendingPathComponent(String(offset)) }
  private func evict() {
    // Demux reads lead the presentation clock by network caching/keyframes.
    // Keep a 15s safety margin rather than evicting data still being decoded.
    let cutoff = highWater - Double(seconds) - 15
    for (offset, block) in blocks where seconds == 0 || (block.endTime.map { $0 < cutoff } ?? false) {
      bytes -= block.count; blocks.removeValue(forKey: offset); try? FileManager.default.removeItem(at: file(offset))
    }
    while bytes > limit, let oldest = blocks.min(by: { $0.value.used < $1.value.used }) {
      bytes -= oldest.value.count; blocks.removeValue(forKey: oldest.key); try? FileManager.default.removeItem(at: file(oldest.key))
      report("巻き戻し用キャッシュが容量上限に達しました。保持範囲が設定時間より短くなっています。")
    }
  }
  private func report(_ text: String) {
    DispatchQueue.main.async { [weak self] in guard let self else { return }; self.status = text; self.onChange?() }
  }
  private func accept(_ connection: NWConnection) {
    guard !closed else { connection.cancel(); return }
    let id = ObjectIdentifier(connection); connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      let terminal: Bool
      switch state { case .cancelled, .failed: terminal = true; default: terminal = false }
      if terminal, let connection {
        let id = ObjectIdentifier(connection); self?.connections.removeValue(forKey: id)
        self?.requests.removeValue(forKey: id)?.cancel()
        if case .failed = state { connection.cancel() }
      }
    }
    connection.start(queue: queue); readHeaders(connection, data: Data())
  }
  private func readHeaders(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] next, _, end, error in
      guard let self, !self.closed, error == nil else { connection.cancel(); return }
      var all = data; if let next { all.append(next) }
      guard all.count <= 16384 else { connection.cancel(); return }
      if let text = String(data: all, encoding: .utf8), text.contains("\r\n\r\n") { self.respond(connection, text: text) }
      else if !end { self.readHeaders(connection, data: all) } else { connection.cancel() }
    }
  }
  private func respond(_ connection: NWConnection, text: String) {
    let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
    guard first.count == 3, String(first[1]) == route, ["GET", "HEAD"].contains(String(first[0])) else { connection.cancel(); return }
    var start: Int64 = 0, end = length - 1, ranged = false
    if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
      let value = range.components(separatedBy: "=").last ?? "", parts = value.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 2, !value.contains(",") else { connection.cancel(); return }
      ranged = true
      if parts[0].isEmpty, let suffix = Int64(parts[1]), suffix > 0 { start = max(0, length - suffix) }
      else if let offset = Int64(parts[0]), offset >= 0 { start = offset; if !parts[1].isEmpty { end = min(end, Int64(parts[1]) ?? -1) } }
      else { connection.cancel(); return }
    }
    guard start < length, end >= start else {
      send(connection, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(length)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", then: { connection.cancel() }); return
    }
    let header = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nContent-Length: \(end-start+1)\r\n" +
      (ranged ? "Content-Range: bytes \(start)-\(end)/\(length)\r\n" : "") + "Connection: close\r\n\r\n"
    send(connection, header) { [weak self] in
      if first[0] == "HEAD" { connection.cancel() } else { self?.pump(connection, offset: start, end: end) }
    }
  }
  private func send(_ connection: NWConnection, _ header: String, then: @escaping () -> Void) {
    connection.send(content: Data(header.utf8), completion: .contentProcessed { error in if error == nil { then() } else { connection.cancel() } })
  }
  private func pump(_ connection: NWConnection, offset: Int64, end: Int64) {
    guard !closed, !suspended, connections[ObjectIdentifier(connection)] != nil, offset <= end, case .ready = connection.state else { connection.cancel(); return }
    lastUse = ProcessInfo.processInfo.systemUptime
    let aligned = offset / blockSize * blockSize, count = Int(min(blockSize, length - aligned))
    func deliver(_ data: Data) {
      let begin = Int(offset - aligned), amount = min(data.count - begin, Int(end - offset + 1))
      guard amount > 0 else { connection.cancel(); return }
      connection.send(content: data.subdata(in: begin..<begin+amount), completion: .contentProcessed { [weak self] error in
        if error == nil { self?.pump(connection, offset: offset + Int64(amount), end: end) } else { connection.cancel() }
      })
    }
    if var block = blocks[aligned], let data = try? Data(contentsOf: file(aligned)), data.count == block.count {
      block.used = lastUse; blocks[aligned] = block; hitBytes += Int64(data.count); deliver(data); return
    }
    fetch(offset: aligned, count: count, connection: connection) { [weak self] result in
      guard let self, !self.closed, case .ready = connection.state else { return }
      switch result {
      case .success(let data):
        if self.seconds > 0 {
          do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try data.write(to: self.file(aligned), options: .atomic)
            self.bytes -= self.blocks[aligned]?.count ?? 0
            let range = self.byteClock.timeRange(offset: aligned, count: data.count) ?? self.byteClock.observeTS(data, offset: aligned) ?? self.byteClock.observeMatroska(data, offset: aligned)
            // MP4 metadata has no media time. Keep its bounded chunks so VLC
            // can seek without fetching the same moov/index again. Unknown
            // containers fall back to observed presentation/read checkpoints.
            let endTime = range?.upperBound ?? (self.byteClock.isMP4 ? nil : self.mediaTime+Double(30))
            self.blocks[aligned] = Block(count: data.count, endTime: endTime, used: self.lastUse); self.bytes += data.count; self.evict()
          } catch { self.report("巻き戻し用キャッシュを保存できません。空き容量を確認してください。") }
        }
        deliver(data)
      case .failure: self.report("動画データを取得できません。再読み込みで再試行できます。"); connection.cancel()
      }
    }
  }
  private func fetch(offset: Int64, count: Int, connection: NWConnection? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
    var request = URLRequest(url: source); request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    if let validator, let validatorHeader { request.setValue(validator, forHTTPHeaderField: validatorHeader) }
    let task = session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        if let connection { self.requests.removeValue(forKey: ObjectIdentifier(connection)) }
        guard !self.closed else { return }
        guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 206,
          let range = http.value(forHTTPHeaderField: "Content-Range"),
          let total = Int64(range.split(separator: "/").last ?? ""), total > 0,
          range.hasPrefix("bytes \(offset)-"), let data, data.count == min(count, Int(total-offset)),
          self.length == 0 || self.length == total else { completion(.failure(error ?? URLError(.badServerResponse))); return }
        self.length = total; self.networkBytes += Int64(data.count)
        if self.validator == nil {
          if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { self.validator = etag; self.validatorHeader = "If-Match" }
          else if let modified = http.value(forHTTPHeaderField: "Last-Modified") { self.validator = modified; self.validatorHeader = "If-Unmodified-Since" }
        }
        completion(.success(data))
      }
    }
    if let connection { requests[ObjectIdentifier(connection)] = task }; task.resume()
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, url.scheme == source.scheme, url.host == source.host, url.port == source.port else { completionHandler(nil); return }
    completionHandler(request)
  }
#if targetEnvironment(simulator)
  static func runSmoke(_ source: URL) {
    let old = UserDefaults.standard.object(forKey: preference)
    let cache = NeoPlaybackCache(source: source, username: "", password: "")
    cache.setSeconds(60)
    cache.start { url, error in
      Task { @MainActor in
        defer {
          cache.close()
          if let old { UserDefaults.standard.set(old, forKey: preference) } else { UserDefaults.standard.removeObject(forKey: preference) }
        }
        do {
          guard let url else { throw NeoError(error ?? "Cache startup") }
          func read() async throws -> Data {
            var request = URLRequest(url: url); request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 206, data.count == 1024 else { throw NeoError("Range contract") }
            return data
          }
          let first = try await read(), bytes = cache.queue.sync { cache.networkBytes }
          let second = try await read()
          var checks = ["sameBytes": first == second, "rewindWithoutUpstreamRequest": cache.queue.sync { cache.networkBytes == bytes && cache.hitBytes > 0 }]
          cache.setSeconds(0); _ = try await read()
          checks["offDoesNotRetain"] = cache.queue.sync { cache.blocks.isEmpty && cache.networkBytes > bytes }
          cache.setSeconds(30); _ = try await read()
          cache.observeTime(1000, running: true)
          checks["expiredMediaEvicted"] = cache.queue.sync { cache.blocks.isEmpty }
          cache.beginSeek(0)
          _ = try await read()
          checks["cacheRecreatedAfterEviction"] = cache.queue.sync { !cache.blocks.isEmpty }
          cache.queue.sync { cache.lastUse = ProcessInfo.processInfo.systemUptime-901 }
          cache.observeTime(1000, running: false)
          checks["idleRetainsCache"] = cache.queue.sync { !cache.blocks.isEmpty }
          let priorBytes = cache.queue.sync { cache.networkBytes }
          cache.suspendTransport()
          let reopened: URL = try await withCheckedThrowingContinuation { continuation in
            cache.reopen { url, error in
              if let url { continuation.resume(returning: url) }
              else { continuation.resume(throwing: NeoError(error ?? "Reopen")) }
            }
          }
          var resumed = URLRequest(url: reopened); resumed.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
          let (resumedData, resumedResponse) = try await URLSession.shared.data(for: resumed)
          checks["resumeRecreatesEndpointAndRetainsBytes"] = resumedData == first && (resumedResponse as? HTTPURLResponse)?.statusCode == 206 && cache.queue.sync { cache.networkBytes == priorBytes }
          let abandoned = root.appendingPathComponent("abandoned-smoke", isDirectory: true)
          try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
          try Data([1]).write(to: abandoned.appendingPathComponent("block"))
          let another = NeoPlaybackCache(source: source, username: "", password: "")
          checks["newPlaybackClearsAbandonedButKeepsActive"] = !FileManager.default.fileExists(atPath: abandoned.path) && FileManager.default.fileExists(atPath: cache.directory.path)
          another.close()
          cache.close()
          checks["closeCleanup"] = cache.queue.sync { cache.closed && cache.blocks.isEmpty && !FileManager.default.fileExists(atPath: cache.directory.path) }
          NeoPiPSmoke.save("rewind-cache-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
        } catch { NeoPiPSmoke.save("rewind-cache-smoke", ["success": false, "error": error.localizedDescription]) }
      }
    }
  }
#endif
}
