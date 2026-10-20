import Foundation
import Network

// Owns one server VOD session and an authenticated, private loopback HLS
// endpoint. Segment files are shared by VLC demand and bounded prefetch.
@objc(NeoStreamingSession)
final class NeoStreamingSession: NSObject, URLSessionTaskDelegate {
  private let source: URL, ts: Bool, username: String, password: String
  private let queue = DispatchQueue(label: "neo.streaming.segments")
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neo-hls-"+UUID().uuidString)
  private let route = "/"+UUID().uuidString
  private let sessionID = UUID().uuidString
  private var session: URLSession!, listener: NWListener?, heartbeat: DispatchSourceTimer?
  private var manifest: NeoHLSManifest?, playlistURL: URL?, localURL: URL?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var tasks: [Int: URLSessionDataTask] = [:]
  private var waiters: [Int: [(Data?) -> Void]] = [:]
  private var cache: [Int: Int] = [:], cacheBytes = 0
  private var epoch = 0, closed = false, position = 0.0, refreshingSession = false
  private var ahead: Int, rewind: Int, mode: Int, quality: String
  private let flowLock = NSLock()
  private var pending: Set<ObjectIdentifier> = [], delivered: Int64 = 0
  @objc private(set) var downloadedRanges: [[NSNumber]] = []
  @objc private(set) var status = ""
  @objc private(set) var retryableFailure = false
  @objc var onChange: (() -> Void)?
  @objc var onTransportFailure: (() -> Void)?
  @objc var flowState: [String: NSNumber] {
    flowLock.lock(); defer { flowLock.unlock() }
    return ["waiting": NSNumber(value: !pending.isEmpty), "delivery": NSNumber(value: delivered)]
  }
  @objc var duration: Double { manifest?.duration ?? 0 }
  @objc var networkCaching: Int { Int(Double(ahead)*NeoStreamBuffer.interval(ts: ts)*1000) }

  @objc(initWithSource:ts:mode:quality:username:password:)
  init(source: URL, ts: Bool, mode: Int, quality: String, username: String, password: String) {
    self.source = source; self.ts = ts; self.mode = mode; self.quality = quality
    self.username = username; self.password = password
    ahead = NeoStreamBuffer.count(ts: ts, rewind: false); rewind = NeoStreamBuffer.count(ts: ts, rewind: true)
    super.init()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = .shared; config.urlCredentialStorage = .shared
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 40
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  private var api: URL { source.deletingLastPathComponent().deletingLastPathComponent() }
  private var sessionURL: URL { api.appendingPathComponent("streams/recorded/vodhls/sessions/"+sessionID) }
  private func request(_ url: URL, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: url); request.httpMethod = method
    if !username.isEmpty { request.setValue("Basic "+Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
    return request
  }
  @objc(startAt:completion:)
  func start(at time: Double, completion: @escaping (URL?, String?) -> Void) {
    queue.async { [self] in
      guard !closed else { return }; position = max(0, time)
      loadPlaylist { [weak self] error in
        guard let self else { return }
        if let error { DispatchQueue.main.async { completion(nil, error) }; return }
        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
          let listener = try NWListener(using: parameters); self.listener = listener
          listener.newConnectionHandler = { [weak self] in self?.accept($0) }
          var reported = false
          listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener, !self.closed else { return }
            if case .ready = state, !reported, let port = listener.port {
              reported = true; self.localURL = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.route)/playlist.m3u8")
              self.keepAlive(); self.prefetch()
              DispatchQueue.main.async { completion(self.localURL, nil) }
            } else if case .failed = state {
              self.localURL = nil
              if !reported { reported = true; DispatchQueue.main.async { completion(nil, "STREAMINGを開始できません。") } }
              else { DispatchQueue.main.async { self.onTransportFailure?() } }
            }
          }
          listener.start(queue: queue)
        } catch { DispatchQueue.main.async { completion(nil, "STREAMINGを開始できません。") } }
      }
    }
  }
  private func loadPlaylist(_ completion: @escaping (String?) -> Void) {
    let id = source.lastPathComponent
    var url = URLComponents(url: api.appendingPathComponent("streams/recorded/\(id)/vodhls/playlist"), resolvingAgainstBaseURL: false)!
    url.queryItems = [URLQueryItem(name: "mode", value: String(mode)), URLQueryItem(name: "quality", value: quality),
      URLQueryItem(name: "ss", value: String(format: "%.3f", position)), URLQueryItem(name: "subtitleIndex", value: "-1"),
      URLQueryItem(name: "startupBufferSegments", value: "1"), URLQueryItem(name: "vodSessionId", value: sessionID),
      URLQueryItem(name: "client", value: "ios")]
    let endpoint = url.url!, generation = epoch
    session.dataTask(with: request(endpoint)) { [weak self] data, response, error in
      guard let self else { return }; self.queue.async {
        guard !self.closed, generation == self.epoch else { return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        self.retryableFailure = error != nil || code == 0 || code == 408 || code == 429 || (500..<600).contains(code)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
          data.count <= 16*1024*1024, let text = String(data: data, encoding: .utf8) else {
          completion("配信に接続できませんでした。再読み込みで再試行してください。"); return
        }
        do {
          let value = try NeoHLSManifest(text: text, source: endpoint)
          self.retryableFailure = false
          self.manifest = value; self.playlistURL = endpoint; self.publish(error: false)
          NeoPlaybackDiagnostics.record("hls.playlist", fields: ["segments": value.segments.count, "duration": value.duration,
            "target": self.position, "mode": self.mode, "ahead": self.ahead, "rewind": self.rewind])
          completion(nil)
        } catch { self.retryableFailure = false; completion(error.localizedDescription) }
      }
    }.resume()
  }
  private func keepAlive() {
    heartbeat?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue); heartbeat = timer
    timer.schedule(deadline: .now()+10, repeating: 10)
    timer.setEventHandler { [weak self] in
      guard let self, !self.closed else { return }
      self.renewLease()

    }; timer.resume()
  }
  private func renewLease() {
    guard !closed else { return }
    let generation = epoch
    session.dataTask(with: request(sessionURL, method: "PUT")) { [weak self] _, response, error in
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      NeoPlaybackDiagnostics.record("hls.keepAlive", fields: ["status": code, "failed": error != nil])
      guard let self, code == 404 else { return }
      self.queue.async {
        guard !self.closed, self.epoch == generation, !self.refreshingSession else { return }
        self.refreshingSession = true
        self.loadPlaylist { [weak self] error in
          guard let self else { return }; self.refreshingSession = false
          if error == nil { self.prefetch() }
        }
      }
    }.resume()
  }
  @objc(reopenAt:completion:)
  func reopen(at time: Double, completion: @escaping (URL?, String?) -> Void) {
    queue.async { [self] in
      guard !closed else { return }
      position = max(0, time); epoch += 1; refreshingSession = false
      tasks.values.forEach { $0.cancel() }; tasks.removeAll()
      let previous = waiters.values.flatMap { $0 }; waiters.removeAll(); previous.forEach { $0(nil) }
      if localURL == nil { listener?.cancel(); start(at: time, completion: completion); return }
      loadPlaylist { [weak self] error in
        guard let self else { return }; self.keepAlive()
        if error == nil { self.evict(); self.prefetch() }
        DispatchQueue.main.async { completion(error == nil ? self.localURL : nil, error) }
      }
    }
  }
  @objc(checkAvailability:)
  func checkAvailability(_ completion: @escaping (Bool) -> Void) {
    queue.async { [self] in
      guard !closed else { return }
      session.dataTask(with: request(sessionURL, method: "PUT")) { _, response, error in
        // An expired session is recreated by the next playlist request.
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        DispatchQueue.main.async { completion(error == nil && ((200..<300).contains(code) || code == 404)) }
      }.resume()
    }
  }
  @objc func resumeFetching() { queue.async { [weak self] in self?.renewLease(); self?.prefetch() } }
  @objc func beginSeek(_ time: Double) { observeTime(time, running: false) }
  @objc(observeTime:running:)
  func observeTime(_ time: Double, running: Bool) {
    queue.async { [self] in
      guard !closed, time.isFinite else { return }
      position = max(0, time); evict(); prefetch()
    }
  }
  @objc(setAhead:rewind:)
  func setBuffer(ahead: Int, rewind: Int) {
    NeoStreamBuffer.save(ahead, ts: ts, rewind: false); NeoStreamBuffer.save(rewind, ts: ts, rewind: true)
    queue.async { [self] in
      self.ahead = NeoStreamBuffer.count(ts: ts, rewind: false); self.rewind = NeoStreamBuffer.count(ts: ts, rewind: true)
      evict(); prefetch()
    }
  }
  private func prefetch() {
    guard !closed, let manifest, tasks.isEmpty, waiters.isEmpty else { return }
    let current = manifest.index(at: position)
    guard let next = (current...min(manifest.segments.count-1, current+ahead-1)).first(where: { cache[$0] == nil }) else { return }
    fetch(next) { [weak self] data in if data != nil { self?.prefetch() } }
  }
  private func file(_ index: Int) -> URL { directory.appendingPathComponent("\(index).ts") }
  private func fetch(_ index: Int, attempt: Int = 0, completion: @escaping (Data?) -> Void) {
    guard !closed, let manifest, manifest.segments.indices.contains(index) else { completion(nil); return }
    if cache[index] != nil, let data = try? Data(contentsOf: file(index)) { completion(data); return }
    if waiters[index] != nil { waiters[index]?.append(completion); return }
    waiters[index] = [completion]; download(index, attempt: attempt)
  }
  private func download(_ index: Int, attempt: Int) {
    guard let manifest, !closed else { return }
    let generation = epoch, began = ProcessInfo.processInfo.systemUptime
    let task = session.dataTask(with: request(manifest.segments[index].url)) { [weak self] data, response, error in
      guard let self else { return }; self.queue.async {
        guard !self.closed, generation == self.epoch else { return }
        self.tasks.removeValue(forKey: index)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, code == 200, let data, !data.isEmpty, data.count <= 128*1024*1024 {
          do {
            try data.write(to: self.file(index), options: .atomic)
            self.cacheBytes -= self.cache[index] ?? 0; self.cache[index] = data.count; self.cacheBytes += data.count
          } catch { /* Disk pressure may prevent retention; still deliver this segment. */ }
          NeoPlaybackDiagnostics.record("hls.segment", fields: ["index": index, "bytes": data.count, "ms": (ProcessInfo.processInfo.systemUptime-began)*1000])
          self.publish(error: false); let callbacks = self.waiters.removeValue(forKey: index) ?? []
          callbacks.forEach { $0(data) }; self.evict(); self.prefetch()
        } else if attempt < 2 {
          // Preserve pending local reads during a short outage. A terminal
          // failure returns 503; the player recovery state retains its clock.
          self.queue.asyncAfter(deadline: .now()+Double(attempt+1)) { [weak self] in
            guard let self, !self.closed, self.epoch == generation else { return }; self.download(index, attempt: attempt+1)
          }
        } else {
          NeoPlaybackDiagnostics.record("hls.segmentFailure", fields: ["index": index, "status": code, "attempt": attempt+1])
          let callbacks = self.waiters.removeValue(forKey: index) ?? []; callbacks.forEach { $0(nil) }; self.publish(error: true)
        }
      }
    }; tasks[index] = task; task.resume()
  }
  private func evict() {
    guard let manifest else { return }; let current = manifest.index(at: position)
    for index in cache.keys.sorted(by: { abs($0-current) > abs($1-current) }) {
      if index < current-rewind || index > current+ahead || cacheBytes > 256*1024*1024 {
        cacheBytes -= cache.removeValue(forKey: index) ?? 0; try? FileManager.default.removeItem(at: file(index))
      }
    }
    publish(error: nil)
  }
  private func publish(error: Bool?) {
    guard let manifest else { return }
    let ranges: [[NSNumber]] = cache.keys.sorted().map { [NSNumber(value: manifest.segments[$0].start), NSNumber(value: manifest.segments[$0].start+manifest.segments[$0].duration)] }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed else { return }
      // observeTime follows UI updates. Publish only actual changes; otherwise
      // onChange -> updateControls -> observeTime becomes an unbounded loop.
      let newStatus = error.map { failed in failed && self.flowState["waiting"]?.boolValue == true ? "配信に接続できません。再接続しています…" : "" } ?? self.status
      guard self.downloadedRanges != ranges || self.status != newStatus else { return }
      self.downloadedRanges = ranges; self.status = newStatus; self.onChange?()
    }
  }
  private func accept(_ connection: NWConnection) {
    guard !closed, connections.count < 16 else { connection.cancel(); return }
    let key = ObjectIdentifier(connection); connections[key] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .cancelled, .failed: self.connections.removeValue(forKey: key); self.mark(connection, waiting: false)
      default: break
      }
    }
    connection.start(queue: queue); receive(connection, header: Data())
  }
  private func receive(_ connection: NWConnection, header: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak connection] data, _, ended, error in
      guard let self, let connection else { return }
      var header = header; if let data { header.append(data) }
      guard header.count <= 16384, error == nil else { connection.cancel(); return }
      guard let text = String(data: header, encoding: .utf8), text.contains("\r\n\r\n") else {
        if ended { connection.cancel() } else { self.receive(connection, header: header) }; return
      }
      let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
      guard parts.count == 3, ["GET", "HEAD"].contains(String(parts[0])) else { self.respond(connection, code: 405); return }
      let head = parts[0] == "HEAD", path = String(parts[1])
      if path == self.route+"/playlist.m3u8", let manifest = self.manifest {
        self.respond(connection, data: manifest.localPlaylist(route: self.route), type: "application/vnd.apple.mpegurl", head: head); return
      }
      let prefix = self.route+"/segments/"
      guard path.hasPrefix(prefix), path.hasSuffix(".ts"), let index = Int(path.dropFirst(prefix.count).dropLast(3)),
        let manifest = self.manifest, manifest.segments.indices.contains(index) else { self.respond(connection, code: 404); return }
      self.mark(connection, waiting: true)
      self.fetch(index) { [weak self, weak connection] data in
        guard let self, let connection else { return }
        self.mark(connection, waiting: false)
        guard let data else { self.respond(connection, code: 503); return }
        self.flowLock.lock(); self.delivered += Int64(data.count); self.flowLock.unlock()
        self.respond(connection, data: data, type: "video/mp2t", head: head)
      }
    }
  }
  private func mark(_ connection: NWConnection, waiting: Bool) {
    flowLock.lock(); defer { flowLock.unlock() }
    if waiting { pending.insert(ObjectIdentifier(connection)) } else { pending.remove(ObjectIdentifier(connection)) }
  }
  private func respond(_ connection: NWConnection, code: Int = 200, data: Data = Data(), type: String = "text/plain", head: Bool = false) {
    var output = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
    if !head { output.append(data) }
    connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
  }
  @objc func close() {
    queue.async { [self] in
      guard !closed else { return }; closed = true; epoch += 1; heartbeat?.cancel(); heartbeat = nil
      listener?.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll()
      tasks.values.forEach { $0.cancel() }; tasks.removeAll(); waiters.removeAll()
      let session = self.session!
      session.dataTask(with: request(sessionURL, method: "DELETE")) { _, _, _ in session.finishTasksAndInvalidate() }.resume()
      try? FileManager.default.removeItem(at: directory)
      NeoPlaybackDiagnostics.record("hls.release", fields: [:])
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, url.scheme == source.scheme, url.host == source.host, url.port == source.port else { completionHandler(nil); return }
    completionHandler(request)
  }
}
