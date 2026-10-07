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
  @objc static func cleanAbandoned() {
    // Called once, before any player is created. Never persist URLs or credentials.
    try? FileManager.default.removeItem(at: root)
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
  private var listener: NWListener?, session: URLSession!, sweep: DispatchSourceTimer?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var requests: [ObjectIdentifier: URLSessionDataTask] = [:]
  private var length: Int64 = 0, closed = false
  private var validator: String?, validatorHeader: String?
  private var byteClock = NeoMediaByteClock()
  private var startup: ((URL?, String?) -> Void)?
  @objc private(set) var status = ""
  @objc var onChange: (() -> Void)?
  private(set) var networkBytes: Int64 = 0, hitBytes: Int64 = 0

  @objc(initWithSource:username:password:)
  init(source: URL, username: String, password: String) {
    self.source = source; directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    super.init()
    let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
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
  private func listen() {
    guard !closed else { return }
          do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let server = try NWListener(using: parameters); listener = server
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            server.stateUpdateHandler = { [weak self, weak server] state in
              guard let self else { return }
              if case .ready = state, let port = server?.port {
                self.finishStart(URL(string: "http://127.0.0.1:\(port.rawValue)\(self.route)"), nil)
              } else if case .failed = state { self.finishStart(nil, "巻き戻し用キャッシュの読み取り口を開始できません。") }
            }
            server.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in
              guard let self else { return }
              if ProcessInfo.processInfo.systemUptime - self.lastUse > 15 * 60 { self.clearBlocks() }
            }; sweep = timer; timer.resume()
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
    DispatchQueue.main.async { callback(url, error) }
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
      listener?.cancel(); listener = nil; sweep?.cancel(); sweep = nil
      requests.values.forEach { $0.cancel() }; requests.removeAll()
      connections.values.forEach { $0.cancel() }; connections.removeAll()
      session.invalidateAndCancel(); clearBlocks()
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
      if case .cancelled = state, let connection {
        let id = ObjectIdentifier(connection); self?.connections.removeValue(forKey: id)
        self?.requests.removeValue(forKey: id)?.cancel()
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
    guard !closed, offset <= end, case .ready = connection.state else { connection.cancel(); return }
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
            let range = self.byteClock.timeRange(offset: aligned, count: data.count) ?? self.byteClock.observeTS(data, offset: aligned)
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
}
