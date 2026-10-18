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
  private var downloaded: [Int64: ClosedRange<Double>] = [:]
  private var rangeUpdatePending = false
  private var mediaTime = 0.0, highWater = 0.0, lastUse = ProcessInfo.processInfo.systemUptime
  private var seconds = NeoPlaybackCache.savedSeconds
  private var listener: NWListener?, session: URLSession!
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var requests: [ObjectIdentifier: URLSessionDataTask] = [:]
  private var retries: [ObjectIdentifier: DispatchWorkItem] = [:]
  private var retryActions: [ObjectIdentifier: () -> Void] = [:]
  private var fetchEpoch = 0
  private let flowLock = NSLock()
  private var pendingReads: Set<ObjectIdentifier> = []
  private var availableDelivery: Int64 = 0
  @objc var flowState: [String: NSNumber] {
    // Never wait behind cache disk I/O on the main/rendering thread.
    flowLock.lock(); defer { flowLock.unlock() }
    return ["waiting": NSNumber(value: !pendingReads.isEmpty), "delivery": NSNumber(value: availableDelivery)]
  }
  private func markRead(_ connection: NWConnection?, pending: Bool) {
    guard let connection else { return }
    flowLock.lock(); defer { flowLock.unlock() }
    let key = ObjectIdentifier(connection)
    if pending { pendingReads.insert(key) } else { pendingReads.remove(key) }
  }
  private var length: Int64 = 0, closed = false
  private var validator: String?, validatorHeader: String?
  private var byteClock = NeoMediaByteClock()
  private var matroskaIndex: NeoMatroskaSeekIndex?
  private var metadataFragments: [Int64: Data] = [:]
  @objc var hasMatroskaSeekIndex: Bool { queue.sync { matroskaIndex != nil } }
  @objc func matroskaSeekOffset(_ time: Double) -> Int64 { queue.sync { matroskaIndex?.nearest(time)?.offset ?? -1 } }
  private var startup: ((URL?, String?) -> Void)?
  @objc private(set) var status = ""
  private var warnings: [String: String] = [:]
  @objc private(set) var downloadedRanges: [[NSNumber]] = []
  @objc var onChange: (() -> Void)?
  @objc var onTransportFailure: (() -> Void)?
  @objc var onSourceData: ((Data, Int64) -> Void)?
  private var suspended = false
  private(set) var networkBytes: Int64 = 0, hitBytes: Int64 = 0
  private var requestSequence = 0
  private struct Delivery {
    let id: Int, seek: Int, began: Double, start: Int64, end: Int64
    var diskBytes: Int64 = 0, sentBytes: Int64 = 0, networkBytes: Int64 = 0, indexBytes: Int64 = 0
    var firstSent = false
  }
  private var deliverySequence = 0
  private var seekRangeStarts: [Int64] = [], seekNetworkBaseline: Int64 = 0
  private var seekTargetOffset: Int64 = -1
  @objc var seekMetrics: [String: NSNumber] { queue.sync {
    let expected = matroskaIndex?.nearest(mediaTime)?.offset ?? -1
    let target = expected > 0 ? seekRangeStarts.first { abs($0-expected) <= 65536 } ?? -1 : -1
    return ["largestRangeStart": NSNumber(value: seekRangeStarts.max() ?? -1), "indexedRangeStart": NSNumber(value: target),
     "networkBytes": NSNumber(value: networkBytes-seekNetworkBaseline), "fileBytes": NSNumber(value: length)]
  } }
  private var deliveries: [ObjectIdentifier: Delivery] = [:]
  private func recordConnectionEnd(_ connection: NWConnection, state: Int, error: NWError? = nil) {
    var domain = 0, code = 0
    if let error {
      switch error {
      case .posix(let value): domain = 1; code = Int(value.rawValue)
      case .dns(let value): domain = 2; code = Int(value)
      case .tls(let value): domain = 3; code = Int(value)
      @unknown default: domain = 4
      }
    }
    NeoPlaybackDiagnostics.record("range.connectionEnd", fields: ["delivery": deliveries[ObjectIdentifier(connection)]?.id ?? 0,
      "state": state, "errorDomain": domain, "errorCode": code, "closing": closed, "suspended": suspended])
  }
  private func finishDelivery(_ connection: NWConnection, reason: Int) {
    guard let entry = deliveries.removeValue(forKey: ObjectIdentifier(connection)) else { return }
    NeoPlaybackDiagnostics.record("range.deliveryEnd", fields: ["delivery": entry.id, "originSeek": entry.seek,
      "start": entry.start, "end": entry.end, "diskReadBytes": entry.diskBytes,
      "processedBytes": entry.sentBytes, "networkBytes": entry.networkBytes, "indexReadBytes": entry.indexBytes, "reason": reason,
      "durationMs": (ProcessInfo.processInfo.systemUptime-entry.began)*1000])
  }

  @objc(initWithSource:username:password:)
  init(source: URL, username: String, password: String) {
    self.source = source; directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    super.init()
    Self.cleanAbandoned()
    Self.activeLock.lock(); Self.activeDirectories.insert(directory); Self.activeLock.unlock()
    session = makeSession()
  }
  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = .shared; config.urlCredentialStorage = .shared
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
#if targetEnvironment(simulator)
    if source.host == "retry.example.test" { config.protocolClasses = [NeoCacheFaultProtocol.self] }
#endif
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  private func renewUpstreamSession() {
    let old = session; session = makeSession(); old?.finishTasksAndInvalidate()
  }
  // Recreate only the upstream HTTP pool; the local listener and VLC input stay.
  @objc func resumeFetching() {
    queue.async { [self] in
      guard !closed, !suspended else { return }
      renewUpstreamSession()
      let actions = Array(retryActions.values); retryActions.removeAll()
      retries.values.forEach { $0.cancel() }; retries.removeAll()
      actions.forEach { $0() }
      NeoPlaybackDiagnostics.record("range.foregroundResume", fields: ["pendingRetries": actions.count])
    }
  }
  @objc func start(_ completion: @escaping (URL?, String?) -> Void) {
    queue.async { [self] in
      startup = completion
      fetch(offset: 0, count: 1) { [self] result in
        switch result {
        case .failure: finishStart(nil, "巻き戻し用キャッシュを開始できません。サーバーのRange応答と認証を確認してください。")
        case .success(let data):
          if data.first == 0x1a {
            self.loadMatroskaIndex { [self] in self.listen() }
          } else { self.loadIndex(offset: 0, attempt: 0) { [self] in self.listen() } }
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
  @objc func checkAvailability(_ completion: @escaping (Bool) -> Void) {
    queue.async { [self] in
      guard !closed else { return }
      var request = URLRequest(url: source, timeoutInterval: 5)
      request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
      if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
      session.dataTask(with: request) { data, response, error in
        let available = error == nil && (response as? HTTPURLResponse)?.statusCode == 206 && data?.count == 1
        DispatchQueue.main.async { completion(available) }
      }.resume()
    }
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
                if !starting { self.report("動画の読み取り接続が切れました。復旧しています…", kind: "transport"); DispatchQueue.main.async { [weak self] in self?.onTransportFailure?() } }
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
  private func readEBML(_ offset: Int64, _ completion: @escaping (NeoMatroskaSeekIndex.Element?, Int64) -> Void) {
    guard offset >= 0, offset < length else { completion(nil, offset); return }
    fetch(offset: offset, count: Int(min(16, length-offset))) { [self] result in
      guard case .success(let data) = result, let element = NeoMatroskaSeekIndex.header(data) else { completion(nil, offset); return }
      metadataFragments[offset] = data
      completion(element, offset+Int64(element.body))
    }
  }
  private func loadMatroskaIndex(completion: @escaping () -> Void) {
    readEBML(0) { [self] header, body in
      guard let header, header.id == 0x1a45dfa3, let size = header.size, size <= 4096 else { completion(); return }
      fetch(offset: body, count: size) { [self] result in
        guard case .success(let data) = result,
          let fields = NeoMatroskaSeekIndex.children(data),
          fields.contains(where: { $0.0 == 0x4282 && String(data: $0.1, encoding: .utf8) == "matroska" }) else { completion(); return }
        readEBML(body+Int64(size)) { [self] segment, start in
          guard segment?.id == 0x18538067 else { completion(); return }
          scanMatroskaMetadata(start, segment: start, count: 0, positions: [:], completion: completion)
        }
      }
    }
  }
  private func scanMatroskaMetadata(_ offset: Int64, segment: Int64, count: Int,
                                    positions: [UInt64: Int64], completion: @escaping () -> Void) {
    guard count < 64 else { finishMatroskaIndex(segment: segment, positions: positions, completion: completion); return }
    readEBML(offset) { [self] element, body in
      guard let element, let size = element.size, Int64(size) <= length-body else {
        finishMatroskaIndex(segment: segment, positions: positions, completion: completion); return
      }
      var found = positions
      if [UInt64(0x1549a966), 0x1654ae6b, 0x1c53bb6b].contains(element.id) { found[element.id] = offset }
      if element.id == 0x1f43b675 {
        // Stop at the first media cluster. SeekHead locates tail Cues without
        // downloading or decoding the preceding recording.
        finishMatroskaIndex(segment: segment, positions: found, completion: completion); return
      }
      if element.id == 0x114d9b74 && size <= 1024*1024 {
        fetch(offset: body, count: size) { [self] result in
          if case .success(let data) = result {
            found.merge(NeoMatroskaSeekIndex.seeks(data, segment: segment, length: length)) { _, new in new }
          }
          scanMatroskaMetadata(body+Int64(size), segment: segment, count: count+1, positions: found, completion: completion)
        }
      } else { scanMatroskaMetadata(body+Int64(size), segment: segment, count: count+1, positions: found, completion: completion) }
    }
  }
  private func finishMatroskaIndex(segment: Int64, positions: [UInt64: Int64], completion: @escaping () -> Void) {
    let ids: [UInt64] = [0x1549a966, 0x1654ae6b, 0x1c53bb6b]
    var metadata: [UInt64: Data] = [:]
    func load(_ index: Int) {
      if index == ids.count {
        guard let info = metadata[ids[0]], let tracks = metadata[ids[1]], let cues = metadata[ids[2]],
          let parsed = NeoMatroskaSeekIndex(cues: cues, info: info, tracks: tracks, segment: segment, length: length) else { completion(); return }
        // Check actual Cluster IDs as well as metadata bounds before opting
        // into VLC's cue-trusting path. No raw content or URLs enter the log.
        readEBML(parsed.cues.first!.offset) { [self] first, _ in
          guard first?.id == 0x1f43b675 else { completion(); return }
          readEBML(parsed.cues.last!.offset) { [self] last, _ in
            if last?.id == 0x1f43b675 {
              matroskaIndex = parsed
              NeoPlaybackDiagnostics.record("mkv.indexReady", fields: ["cues": parsed.cues.count, "firstOffset": parsed.cues.first!.offset,
                "lastOffset": parsed.cues.last!.offset, "lastTime": parsed.cues.last!.time])
            }
            completion()
          }
        }
        return
      }
      let id = ids[index]
      guard let offset = positions[id] else { completion(); return }
      readEBML(offset) { [self] element, body in
        guard element?.id == id, let size = element?.size, size > 0, size <= 8*1024*1024, Int64(size) <= length-body else { completion(); return }
        fetch(offset: body, count: size) { result in
          guard case .success(let data) = result else { completion(); return }
          metadata[id] = data; self.metadataFragments[body] = data; load(index+1)
        }
      }
    }
    load(0)
  }
  private func finishStart(_ url: URL?, _ error: String?) {
    guard let callback = startup else { return }; startup = nil
    DispatchQueue.main.async { [weak self] in
      self?.setWarning(error, kind: "transport")
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
      if seconds == 0 {
        let expired = downloaded.filter { $0.value.upperBound < mediaTime }.map(\.key)
        for offset in expired { downloaded.removeValue(forKey: offset) }
        if !expired.isEmpty { publishDownloadedRanges() }
      }
      if running { lastUse = ProcessInfo.processInfo.systemUptime; highWater = max(highWater, mediaTime); evict() }
    }
  }
  @objc func beginSeek(_ time: Double) {
    queue.async { [self] in
      seekRangeStarts.removeAll(); seekNetworkBaseline = networkBytes
      seekTargetOffset = matroskaIndex?.nearest(time)?.offset ?? -1
      mediaTime = max(0, time); highWater = mediaTime; lastUse = ProcessInfo.processInfo.systemUptime
      NeoPlaybackDiagnostics.record("cache.seek", fields: ["target": time, "retainedBytes": bytes, "blocks": blocks.count, "seconds": seconds])
    }
  }
#if targetEnvironment(simulator)
  @objc func clearMediaCacheForSmoke() { queue.async { [self] in clearBlocks() } }
#endif
  @objc func close() {
    queue.async { [self] in
      guard !closed else { return }; closed = true
      metadataFragments.removeAll(); matroskaIndex = nil
      finishStart(nil, "再生を終了しました。")
      stopTransport()
      session.invalidateAndCancel(); clearBlocks()
      Self.activeLock.lock(); Self.activeDirectories.remove(directory); Self.activeLock.unlock()
    }
  }
  // Suspending transport does not destroy retained video blocks or metadata.
  private func stopTransport() {
    flowLock.lock(); pendingReads.removeAll(); flowLock.unlock()
    fetchEpoch += 1
    retries.values.forEach { $0.cancel() }; retries.removeAll(); retryActions.removeAll()
    let old = listener; listener = nil; old?.cancel()
    requests.values.forEach { $0.cancel() }; requests.removeAll()
    let oldConnections = Array(connections.values); connections.removeAll()
    oldConnections.forEach { finishDelivery($0, reason: 2); $0.cancel() }
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
  private func clearBlocks() {
    blocks.removeAll(); downloaded.removeAll(); bytes = 0
    try? FileManager.default.removeItem(at: directory); publishDownloadedRanges()
  }
  private func file(_ offset: Int64) -> URL { directory.appendingPathComponent(String(offset)) }
  private func evict() {
    // Demux reads lead the presentation clock by network caching/keyframes.
    // Keep a 15s safety margin rather than evicting data still being decoded.
    let cutoff = highWater - Double(seconds) - 15
    for (offset, block) in blocks where seconds == 0 || (block.endTime.map { $0 < cutoff } ?? false) {
      NeoPlaybackDiagnostics.record("cache.evict", fields: ["offset": offset, "bytes": block.count, "cutoff": cutoff, "endTime": block.endTime ?? -1])
      bytes -= block.count; blocks.removeValue(forKey: offset); downloaded.removeValue(forKey: offset)
      try? FileManager.default.removeItem(at: file(offset)); publishDownloadedRanges()
    }
    while bytes > limit, let oldest = blocks.min(by: { $0.value.used < $1.value.used }) {
      NeoPlaybackDiagnostics.record("cache.capacityEvict", fields: ["offset": oldest.key, "bytes": oldest.value.count])
      bytes -= oldest.value.count; blocks.removeValue(forKey: oldest.key); downloaded.removeValue(forKey: oldest.key)
      try? FileManager.default.removeItem(at: file(oldest.key)); publishDownloadedRanges()
      report("巻き戻し用キャッシュが容量上限に達しました。保持範囲が設定時間より短くなっています。", kind: "storage")
    }
  }
  // Transport recovery must not erase a separate disk-space warning.
  private func setWarning(_ text: String?, kind: String) {
    if let text { warnings[kind] = text } else { warnings.removeValue(forKey: kind) }
    let next = warnings["transport"] ?? warnings["fetch"] ?? warnings["storage"] ?? ""
    guard next != status else { return }; status = next; onChange?()
  }
  private func report(_ text: String?, kind: String) {
    DispatchQueue.main.async { [weak self] in self?.setWarning(text, kind: kind) }
  }
  private func publishDownloadedRanges() {
    guard !rangeUpdatePending else { return }; rangeUpdatePending = true
    queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }; self.rangeUpdatePending = false
      let ranges = NeoMediaByteClock.mergedDownloadedRanges(Array(self.downloaded.values))
        .map { [NSNumber(value: $0.lowerBound), NSNumber(value: $0.upperBound)] }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.downloadedRanges != ranges else { return }
        self.downloadedRanges = ranges; self.onChange?()
      }
    }
  }
  private func accept(_ connection: NWConnection) {
    guard !closed else { connection.cancel(); return }
    let id = ObjectIdentifier(connection); connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      let terminal: Bool
      switch state { case .cancelled, .failed: terminal = true; default: terminal = false }
      if terminal, let connection {
        self?.markRead(connection, pending: false)
        if case .failed(let error) = state { self?.recordConnectionEnd(connection, state: 2, error: error) }
        else { self?.recordConnectionEnd(connection, state: 1) }
        self?.finishDelivery(connection, reason: 1)
        let id = ObjectIdentifier(connection); self?.connections.removeValue(forKey: id)
        self?.requests.removeValue(forKey: id)?.cancel()
        self?.retries.removeValue(forKey: id)?.cancel(); self?.retryActions.removeValue(forKey: id)
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
    deliverySequence += 1
    seekRangeStarts.append(start)
    if seekRangeStarts.count > 64 { seekRangeStarts.removeFirst() }
    let entry = Delivery(id: deliverySequence, seek: NeoPlaybackDiagnostics.seekID,
      began: ProcessInfo.processInfo.systemUptime, start: start, end: end)
    deliveries[ObjectIdentifier(connection)] = entry
    let mapped = byteClock.timeRange(offset: start, count: 1)
    NeoPlaybackDiagnostics.record("range.request", fields: ["delivery": entry.id, "originSeek": entry.seek,
      "start": start, "end": end, "head": first[0] == "HEAD", "mappedTime": mapped?.lowerBound ?? -1,
      "retainedBytes": bytes, "retainedBlocks": blocks.count, "mp4Index": byteClock.isMP4])
    let header = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nContent-Length: \(end-start+1)\r\n" +
      (ranged ? "Content-Range: bytes \(start)-\(end)/\(length)\r\n" : "") + "Connection: close\r\n\r\n"
    send(connection, header) { [weak self] in
      if first[0] == "HEAD" { connection.cancel() } else { self?.pump(connection, offset: start, end: end) }
    }
  }
  private func send(_ connection: NWConnection, _ header: String, then: @escaping () -> Void) {
    connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
      if let error { self?.recordConnectionEnd(connection, state: 3, error: error); connection.cancel() }
      else { then() }
    })
  }
  private func pump(_ connection: NWConnection, offset: Int64, end: Int64) {
    guard !closed, !suspended, connections[ObjectIdentifier(connection)] != nil, offset <= end, case .ready = connection.state else {
      finishDelivery(connection, reason: offset > end ? 0 : 2); connection.cancel(); return
    }
    lastUse = ProcessInfo.processInfo.systemUptime
    let aligned = offset / blockSize * blockSize, count = Int(min(blockSize, length - aligned))
    func deliver(_ data: Data, base: Int64? = nil) {
      let begin = Int(offset - (base ?? aligned)), amount = min(data.count - begin, Int(end - offset + 1))
      guard amount > 0 else { connection.cancel(); return }
      connection.send(content: data.subdata(in: begin..<begin+amount), completion: .contentProcessed { [weak self] error in
        guard let self else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        if error == nil {
          if var entry = self.deliveries[key] {
            entry.sentBytes += Int64(amount)
            if !entry.firstSent {
              entry.firstSent = true
              NeoPlaybackDiagnostics.record("range.firstProcessed", fields: ["delivery": entry.id, "originSeek": entry.seek,
                "offset": offset, "bytes": amount, "durationMs": (ProcessInfo.processInfo.systemUptime-entry.began)*1000])
            }
            self.deliveries[key] = entry
          }
          self.pump(connection, offset: offset + Int64(amount), end: end)
        } else { self.recordConnectionEnd(connection, state: 4, error: error); self.finishDelivery(connection, reason: 3); connection.cancel() }
      })
    }
    if let fragment = metadataFragments.first(where: { offset >= $0.key && offset-$0.key < Int64($0.value.count) }) {
      let amount = min(fragment.value.count-Int(offset-fragment.key), Int(end-offset+1))
      let key = ObjectIdentifier(connection)
      if var entry = deliveries[key] { entry.indexBytes += Int64(amount); deliveries[key] = entry }
      NeoPlaybackDiagnostics.record("cache.indexHit", fields: ["offset": offset, "bytes": amount])
      deliver(fragment.value, base: fragment.key); return
    }
    if var block = blocks[aligned], let data = try? Data(contentsOf: file(aligned)), data.count == block.count {
      report(nil, kind: "fetch")
      let key = ObjectIdentifier(connection)
      if var entry = deliveries[key] { entry.diskBytes += Int64(data.count); deliveries[key] = entry }
      NeoPlaybackDiagnostics.record("cache.hit", fields: ["delivery": deliveries[key]?.id ?? 0,
        "originSeek": deliveries[key]?.seek ?? NeoPlaybackDiagnostics.seekID,
        "offset": aligned, "bytes": data.count, "requestedOffset": offset, "blockEndTime": block.endTime ?? -1,
        "payloadBytes": min(data.count-Int(offset-aligned), Int(end-offset+1))])
      onSourceData?(data, aligned)
      block.used = lastUse; blocks[aligned] = block; hitBytes += Int64(data.count); deliver(data); return
    }
    // A replacement MKV input first reads container headers before jumping to
    // its Cue. Do not prefetch whole megabyte blocks on that obsolete prefix
    // connection. Once near the destination, normal disk caching resumes.
    if seekTargetOffset > blockSize && offset < seekTargetOffset-blockSize {
      let prefixCount = Int(min(64*1024, end-offset+1))
      fetch(offset: offset, count: prefixCount, connection: connection) { [weak self] result in
        guard let self, !self.closed, case .ready = connection.state else { return }
        switch result {
        case .success(let data):
          self.report(nil, kind: "fetch")
          let key = ObjectIdentifier(connection)
          if var entry = self.deliveries[key] { entry.networkBytes += Int64(data.count); self.deliveries[key] = entry }
          deliver(data, base: offset)
        case .failure:
          self.report("動画データを取得できません。再接続しています…", kind: "fetch")
          self.finishDelivery(connection, reason: 4); connection.cancel()
          DispatchQueue.main.async { [weak self] in self?.onTransportFailure?() }
        }
      }
      return
    }
    NeoPlaybackDiagnostics.record("cache.miss", fields: ["delivery": deliveries[ObjectIdentifier(connection)]?.id ?? 0,
      "offset": aligned, "bytes": count, "requestedOffset": offset])
    fetch(offset: aligned, count: count, connection: connection) { [weak self] result in
      guard let self, !self.closed, case .ready = connection.state else { return }
      switch result {
      case .success(let data):
        self.report(nil, kind: "fetch")
        self.flowLock.lock(); self.availableDelivery += 1; self.flowLock.unlock()
        self.onSourceData?(data, aligned)
        let key = ObjectIdentifier(connection)
        if var entry = self.deliveries[key] { entry.networkBytes += Int64(data.count); self.deliveries[key] = entry }
        let range = self.byteClock.timeRange(offset: aligned, count: data.count) ?? self.byteClock.observeTS(data, offset: aligned) ?? self.byteClock.observeMatroska(data, offset: aligned)
        if let range { self.downloaded[aligned] = range; self.publishDownloadedRanges() }
        if self.seconds > 0 {
          do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try data.write(to: self.file(aligned), options: .atomic)
            self.bytes -= self.blocks[aligned]?.count ?? 0
            // MP4 metadata has no media time. Keep its bounded chunks so VLC
            // can seek without fetching the same moov/index again. Unknown
            // containers fall back to observed presentation/read checkpoints.
            let endTime = range?.upperBound ?? (self.byteClock.isMP4 ? nil : self.mediaTime+Double(30))
            self.report(nil, kind: "storage")
            self.blocks[aligned] = Block(count: data.count, endTime: endTime, used: self.lastUse); self.bytes += data.count; self.evict()
          } catch {
            self.downloaded.removeValue(forKey: aligned); self.publishDownloadedRanges()
            self.report("巻き戻し用キャッシュを保存できません。空き容量を確認してください。", kind: "storage")
          }
        }
        deliver(data)
      case .failure:
        self.report("動画データを取得できません。再接続しています…", kind: "fetch")
        self.finishDelivery(connection, reason: 4); connection.cancel()
        DispatchQueue.main.async { [weak self] in self?.onTransportFailure?() }
      }
    }
  }
  private func fetch(offset: Int64, count: Int, connection: NWConnection? = nil,
                     attempt: Int = 0, transferBegan: Double? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
    guard !closed, !suspended else { return }
    if let connection, connections[ObjectIdentifier(connection)] == nil { return }
    markRead(connection, pending: true)
    requestSequence += 1
    let requestID = requestSequence, seek = NeoPlaybackDiagnostics.seekID
    let began = ProcessInfo.processInfo.systemUptime, original = transferBegan ?? began, epoch = fetchEpoch
    NeoPlaybackDiagnostics.record("range.fetchStart", fields: ["request": requestID, "originSeek": seek,
      "offset": offset, "bytes": count, "attempt": attempt])
    var request = URLRequest(url: source); request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
    if connection != nil { request.timeoutInterval = min(15, max(1, 24-(began-original))) }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    if let validator, let validatorHeader { request.setValue(validator, forHTTPHeaderField: validatorHeader) }
    let task = session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        guard !self.closed, !self.suspended, self.fetchEpoch == epoch else { return }
        if let connection {
          let key = ObjectIdentifier(connection)
          guard self.connections[key] != nil, case .ready = connection.state else { return }
          self.requests.removeValue(forKey: key)
        }
        let http = response as? HTTPURLResponse, code = (error as NSError?)?.code ?? 0
        NeoPlaybackDiagnostics.record("range.fetchEnd", fields: ["request": requestID, "originSeek": seek,
          "offset": offset, "bytes": data?.count ?? 0, "httpStatus": http?.statusCode ?? 0,
          "errorCode": code, "attempt": attempt, "durationMs": (ProcessInfo.processInfo.systemUptime-began)*1000])
        let range = http?.value(forHTTPHeaderField: "Content-Range")
        let total = range.flatMap { Int64($0.split(separator: "/").last ?? "") } ?? 0
        let expected = min(count, Int(max(0,total-offset)))
        let valid = error == nil && http?.statusCode == 206 && total > 0 && expected > 0 &&
          range == "bytes \(offset)-\(offset+Int64(expected)-1)/\(total)" && data?.count == expected &&
          (self.length == 0 || self.length == total)
        if valid, let data, !data.isEmpty {
          self.markRead(connection, pending: false)
          self.length = total; self.networkBytes += Int64(data.count)
          if self.validator == nil {
            if let etag = http?.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { self.validator = etag; self.validatorHeader = "If-Match" }
            else if let modified = http?.value(forHTTPHeaderField: "Last-Modified") { self.validator = modified; self.validatorHeader = "If-Unmodified-Since" }
          }
          if attempt > 0 {
            self.report(nil, kind: "fetch")
            NeoPlaybackDiagnostics.record("range.retrySucceeded", fields: ["offset": offset, "attempt": attempt,
              "durationMs": (ProcessInfo.processInfo.systemUptime-original)*1000])
          }
          completion(.success(data)); return
        }
        let networkTransient = [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020].contains(code)
        let httpTransient = [408,429,500,502,503,504].contains(http?.statusCode ?? 0)
        // Never retry a changed file, an invalid Range or authentication failure
        // into the existing stream. Already delivered bytes must remain valid.
        if attempt < 2 && ProcessInfo.processInfo.systemUptime-original < 24 && (networkTransient || httpTransient) {
          self.renewUpstreamSession()
          if connection != nil { self.report("動画データの取得を再試行しています…", kind: "fetch") }
          NeoPlaybackDiagnostics.record("range.retry", fields: ["offset": offset, "bytes": count,
            "attempt": attempt+1, "httpStatus": http?.statusCode ?? 0, "errorCode": code])
          let action = { [weak self] in
            guard let self, !self.closed, !self.suspended, self.fetchEpoch == epoch else { return }
            self.fetch(offset: offset, count: count, connection: connection, attempt: attempt+1,
              transferBegan: original, completion: completion)
          }
          if let connection {
            let key = ObjectIdentifier(connection)
            self.retryActions[key] = action
            let work = DispatchWorkItem { [weak self] in
              guard let self, let action = self.retryActions.removeValue(forKey: key) else { return }
              self.retries.removeValue(forKey: key); action()
            }
            self.retries[key] = work; self.queue.asyncAfter(deadline: .now()+(attempt == 0 ? 0.25 : 0.75), execute: work)
          } else { self.queue.asyncAfter(deadline: .now()+0.25, execute: action) }
          return
        }
        NeoPlaybackDiagnostics.record("range.retryFailed", fields: ["offset": offset, "attempt": attempt,
          "httpStatus": http?.statusCode ?? 0, "errorCode": code])
        self.markRead(connection, pending: false)
        completion(.failure(error ?? URLError(.badServerResponse)))
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
          try? await Task.sleep(nanoseconds: 300_000_000)
          checks["downloadedRangesPublishedWithoutExtraFetch"] = !cache.downloadedRanges.isEmpty && cache.queue.sync { cache.networkBytes == bytes }
          cache.setWarning("動画データを取得できません。再読み込みで再試行できます。", kind: "fetch")
          _ = try await read()
          checks["successfulReadClearsFetchWarning"] = cache.status.isEmpty
          cache.setWarning("巻き戻し用キャッシュを保存できません。", kind: "storage")
          cache.setWarning("動画データを取得できません。", kind: "fetch")
          _ = try await read()
          checks["readRecoveryPreservesStorageWarning"] = cache.status == "巻き戻し用キャッシュを保存できません。"
          cache.setWarning(nil, kind: "storage")
          cache.setSeconds(0); _ = try await read()
          checks["offDoesNotRetain"] = cache.queue.sync { cache.blocks.isEmpty && cache.networkBytes > bytes }
          cache.setSeconds(30); _ = try await read()
          cache.observeTime(1000, running: true)
          checks["expiredMediaEvicted"] = cache.queue.sync { cache.blocks.isEmpty }
          try? await Task.sleep(nanoseconds: 300_000_000)
          checks["evictedRangesDisappear"] = cache.downloadedRanges.isEmpty
          cache.beginSeek(0)
          _ = try await read()
          checks["cacheRecreatedAfterEviction"] = cache.queue.sync { !cache.blocks.isEmpty }
          cache.queue.sync { cache.lastUse = ProcessInfo.processInfo.systemUptime-901 }
          cache.observeTime(1000, running: false)
          checks["idleRetainsCache"] = cache.queue.sync { !cache.blocks.isEmpty }
          let priorBytes = cache.queue.sync { cache.networkBytes }
          cache.setWarning("動画の読み取り接続が切れました。", kind: "transport")
          cache.suspendTransport()
          let reopened: URL = try await withCheckedThrowingContinuation { continuation in
            cache.reopen { url, error in
              if let url { continuation.resume(returning: url) }
              else { continuation.resume(throwing: NeoError(error ?? "Reopen")) }
            }
          }
          checks["endpointRecoveryClearsTransportWarning"] = cache.status.isEmpty
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
          checks.merge(try await retrySmoke()) { _, new in new }
          NeoPiPSmoke.save("rewind-cache-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
        } catch { NeoPiPSmoke.save("rewind-cache-smoke", ["success": false, "error": error.localizedDescription]) }
      }
    }
  }
  @MainActor private static func retrySmoke() async throws -> [String: Bool] {
    let source = URL(string: "https://retry.example.test/fixture")!
    let fixture = Data(repeating: 37, count: 2*1024*1024)
    var checks: [String: Bool] = [:]
    func endpoint(_ cache: NeoPlaybackCache) async throws -> URL {
      try await withCheckedThrowingContinuation { continuation in
        cache.start { url, error in
          if let url { continuation.resume(returning: url) }
          else { continuation.resume(throwing: NeoError(error ?? "Fixture startup")) }
        }
      }
    }
    func read(_ url: URL) async throws -> (Data, URLResponse) {
      var request = URLRequest(url: url); request.timeoutInterval = 4
      request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
      return try await URLSession.shared.data(for: request)
    }
    NeoCacheFaultProtocol.configure(fixture, failures: 2)
    let cache = NeoPlaybackCache(source: source, username: "", password: "")
    defer { cache.close() }
    var failures = 0, warningShown = false
    cache.onTransportFailure = { failures += 1 }
    cache.onChange = { if cache.status.contains("再試行") { warningShown = true } }
    let url = try await endpoint(cache)
    let (data, response) = try await read(url)
    checks["upstreamRetryKeepsDownstreamRangeConnection"] = data == fixture.prefix(1024) && (response as? HTTPURLResponse)?.statusCode == 206 && failures == 0
    checks["retryUsesSameByteRange"] = NeoCacheFaultProtocol.offsets == [0,0,0]
    checks["transientRetryWarningClearsOnSuccess"] = warningShown && cache.status.isEmpty
    cache.close()

    NeoCacheFaultProtocol.configure(fixture, failures: 1, status: 503)
    let unavailable = NeoPlaybackCache(source: source, username: "", password: "")
    defer { unavailable.close() }
    let unavailableURL = try await endpoint(unavailable)
    let (availableData, _) = try await read(unavailableURL)
    checks["temporaryServerFailureRetriesSameRange"] = availableData == fixture.prefix(1024) && NeoCacheFaultProtocol.offsets == [0,0]
    unavailable.close()

    NeoCacheFaultProtocol.configure(fixture, failures: 1)
    let resumed = NeoPlaybackCache(source: source, username: "", password: "")
    defer { resumed.close() }
    var resumedWarnings = 0
    resumed.onChange = {
      if resumed.status.contains("再試行") { resumedWarnings += 1; resumed.resumeFetching() }
    }
    let resumedURL = try await endpoint(resumed)
    let (resumedData, _) = try await read(resumedURL)
    try? await Task.sleep(nanoseconds: 350_000_000)
    checks["foregroundRetryRunsOnceWithoutReplacingEndpoint"] = resumedData == fixture.prefix(1024) && resumedWarnings > 0 && NeoCacheFaultProtocol.offsets == [0,0]
    resumed.close()

    NeoCacheFaultProtocol.configure(fixture, failures: 3, status: 412)
    let changed = NeoPlaybackCache(source: source, username: "", password: "")
    defer { changed.close() }
    var changedFailures = 0
    changed.onTransportFailure = { changedFailures += 1 }
    let changedURL = try await endpoint(changed)
    _ = try? await read(changedURL)
    try? await Task.sleep(nanoseconds: 150_000_000)
    checks["changedFileIsNotRetriedIntoExistingStream"] = NeoCacheFaultProtocol.offsets == [0] && changedFailures == 1
    changed.close()

    NeoCacheFaultProtocol.configure(fixture, failures: 3)
    let closing = NeoPlaybackCache(source: source, username: "", password: "")
    defer { closing.close() }
    closing.onChange = { if closing.status.contains("再試行") { closing.close() } }
    let closingURL = try await endpoint(closing)
    _ = try? await read(closingURL)
    try? await Task.sleep(nanoseconds: 400_000_000)
    checks["closeCancelsPendingUpstreamRetry"] = NeoCacheFaultProtocol.offsets == [0] && closing.queue.sync { closing.closed && closing.retryActions.isEmpty && closing.retries.isEmpty }
    return checks
  }
#endif
}

#if targetEnvironment(simulator)
// Fault injection is limited to the reserved fixture host in simulator builds.
// It exercises real URLSession -> loopback listener -> Range delivery/retry.
private final class NeoCacheFaultProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var fixture = Data(), remaining = 0, failureStatus = 0, requests: [Int64] = []
  static var offsets: [Int64] { lock.lock(); defer { lock.unlock() }; return requests }
  static func configure(_ data: Data, failures: Int, status: Int = 0) {
    lock.lock(); defer { lock.unlock() }
    fixture = data; remaining = failures; failureStatus = status; requests = []
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "retry.example.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let value = request.value(forHTTPHeaderField: "Range"), value.hasPrefix("bytes=") else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
    }
    let parts = value.dropFirst(6).split(separator: "-")
    guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
    }
    Self.lock.lock()
    let data = Self.fixture, status = Self.failureStatus
    // Tiny metadata reads succeed; fail only actual media-block transfers.
    let media = end-start+1 > 1024
    if media { Self.requests.append(Int64(start)) }
    let fail = media && Self.remaining > 0
    if fail { Self.remaining -= 1 }
    Self.lock.unlock()
    if fail && status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
    let finish = min(end, data.count-1)
    guard start >= 0, start <= finish else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
    let response = HTTPURLResponse(url: request.url!, statusCode: fail ? status : 206, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Range": "bytes \(start)-\(finish)/\(data.count)", "ETag": "\"fixture-v1\"", "Content-Length": "\(finish-start+1)"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data.subdata(in: start..<finish+1))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
#endif
