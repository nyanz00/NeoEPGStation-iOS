import Foundation

@MainActor @objc(NeoLiveCoordinator)
final class NeoLiveCoordinator: NSObject {
  private let source: URL, base: URL, headers: [String:String], channelID: Int
  private let apiSession: URLSession, socketSession: URLSession, relay: NeoLiveRelay
  private var watch: URLSessionWebSocketTask?, comments: URLSessionWebSocketTask?
  private var infoTask: Task<Void,Never>?, metadataTask: Task<Void,Never>?, receiveWatch: Task<Void,Never>?, receiveComments: Task<Void,Never>?
  private var keepSeat: Timer?, metadataTimer: Timer?, retry: Timer?, flush: Timer?
  private var generation = 0, closed = false, backlogComplete = false, received = 0
  private var pending: [[String:Any]] = [], recent: [String] = [], seen = Set<String>()
  @objc var timeProvider: (() -> Double)?
  @objc var runningProvider: (() -> Bool)?
  @objc var onComments: (([[String:Any]]) -> Void)?
  @objc var onCommentStatus: ((String) -> Void)?
  @objc var onMetadata: (([String:Any]) -> Void)?
  @objc var onFailure: ((Bool) -> Void)?
  @objc var onSourceData: ((Data,Int64) -> Void)?
  @objc private(set) var commentCount = 0
  @objc(initWithSource:base:headers:channelID:)
  init(source: URL, base: URL, headers: [String:String], channelID: Int) {
    self.source = source; self.base = base; self.headers = headers; self.channelID = channelID
    let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = .shared
    config.urlCache = nil; config.timeoutIntervalForRequest = 10
    apiSession = URLSession(configuration:config)
    let publicConfig = URLSessionConfiguration.ephemeral
    publicConfig.httpCookieStorage = nil; publicConfig.urlCredentialStorage = nil
    socketSession = URLSession(configuration:publicConfig)
    relay = NeoLiveRelay(source:source,headers:headers)
    super.init()
    relay.onFailure = { [weak self] retryable in Task { @MainActor in self?.onFailure?(retryable) } }
    relay.onData = { [weak self] data,offset in
      // The caption clock has its own serial parser. Keep transport callbacks
      // off UIKit while preserving byte order for the ARIB timing parser.
      Task { @MainActor in self?.onSourceData?(data,offset) }
    }
  }
  @objc(openWithCompletion:)
  func open(_ completion: @escaping (URL?) -> Void) {
    guard !closed else { completion(nil); return }
    clearSockets(); generation += 1; pending.removeAll(); recent.removeAll(); seen.removeAll()
    commentCount = 0; received = 0
    relay.open(completion)
    startComments(); refreshMetadata()
    if metadataTimer == nil {
      metadataTimer = Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshMetadata() }
      }
    }
    if flush == nil {
      flush = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
        MainActor.assumeIsolated { self?.flushComments() }
      }
    }
  }
  private func request(_ path: String) -> URLRequest {
    var request = URLRequest(url:URL(string:base.absoluteString+"/api"+path)!)
    headers.forEach { request.setValue($0.value,forHTTPHeaderField:$0.key) }
    request.setValue("application/json",forHTTPHeaderField:"Accept"); return request
  }
  private func refreshMetadata() {
    guard !closed, metadataTask == nil else { return }; let token = generation
    metadataTask = Task { [weak self] in
      guard let self else { return }; defer { self.metadataTask = nil }
      do {
        let (data,response) = try await self.apiSession.data(for:self.request("/schedules/broadcasting?isHalfWidth=true"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, !self.closed, self.generation == token else { return }
        let schedules = try JSONDecoder().decode([NeoLiveSchedule].self,from:data)
        guard let current = schedules.first(where: { $0.channel.id == self.channelID }) else { return }
        var context = current.context(base:self.base)
        context["liveChannels"] = schedules.filter { $0.channel.defaultVisible }.map { $0.context(base:self.base) }
        self.onMetadata?(context)
      } catch { /* Program metadata failure never interrupts a healthy stream. */ }
    }
  }
  private func startComments() {
    guard !closed else { return }; let token = generation
    onCommentStatus?("実況コメントに接続中…")
    infoTask = Task { [weak self] in
      guard let self else { return }
      do {
        let (data,response) = try await self.apiSession.data(for:self.request("/channels/\(self.channelID)/jikkyo"))
        guard !Task.isCancelled, !self.closed, self.generation == token, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let info = try JSONDecoder().decode(NeoLiveJikkyoInfo.self,from:data)
        guard let watchURL = self.socketURL(info.watchSessionUrl), let commentURL = self.socketURL(info.commentSessionUrl) else {
          self.onCommentStatus?("実況コメントがありません"); return
        }
        let socket = self.socketSession.webSocketTask(with:watchURL); self.watch = socket; socket.resume()
        self.send(["type":"startWatching","data":["reconnect":false]],to:socket)
        self.receiveWatch = Task { [weak self, socket] in
          while !Task.isCancelled {
            do {
              let message = try await socket.receive()
              guard let self, !self.closed, self.generation == token, self.watch === socket else { return }
              if let object = self.object(message) { self.watchMessage(object,commentURL:commentURL,token:token) }
            } catch { self?.reconnectComments(token); return }
          }
        }
      } catch { if !Task.isCancelled { self.reconnectComments(token) } }
    }
  }
  private func socketURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string:raw), ["ws","wss"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil else { return nil }; return url
  }
  private func object(_ message: URLSessionWebSocketTask.Message) -> [String:Any]? {
    let data: Data
    switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: return nil }
    guard data.count <= 256*1024 else { return nil }
    return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
  }
  private func send(_ value: Any, to socket: URLSessionWebSocketTask) {
    guard let data = try? JSONSerialization.data(withJSONObject:value), let text = String(data:data,encoding:.utf8) else { return }
    socket.send(.string(text)) { _ in }
  }
  private func watchMessage(_ message: [String:Any], commentURL: URL, token: Int) {
    let type = message["type"] as? String, data = message["data"] as? [String:Any] ?? [:]
    if type == "ping", let watch { send(["type":"pong"],to:watch) }
    else if type == "seat", keepSeat == nil {
      let interval = min(300,max(1,(data["keepIntervalSec"] as? Double) ?? 30))
      keepSeat = Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { [weak self] _ in
        MainActor.assumeIsolated { if let self, let watch = self.watch { self.send(["type":"keepSeat"],to:watch) } }
      }
    } else if type == "room" || type == "messageServer" {
      let server = data["messageServer"] as? [String:Any]
      connectComments(url:socketURL(server?["uri"] as? String) ?? commentURL,
        thread:data["threadId"] as? String ?? "",key:data["yourPostKey"] as? String,token:token)
    } else if ["disconnect","reconnect","error"].contains(type ?? "") { reconnectComments(token) }
  }
  private func connectComments(url: URL, thread: String, key: String?, token: Int) {
    guard comments == nil, !closed else { return }; backlogComplete = false
    let socket = socketSession.webSocketTask(with:url); comments = socket; socket.resume()
    send([["ping":["content":"rs:0"]],["ping":["content":"ps:0"]],
      ["thread":["version":"20061206","thread":thread,"threadkey":key as Any? ?? NSNull(),"user_id":"","res_from":-100]],
      ["ping":["content":"pf:0"]],["ping":["content":"rf:0"]]],to:socket)
    receiveComments = Task { [weak self, socket] in
      while !Task.isCancelled {
        do {
          let message = try await socket.receive()
          guard let self, !self.closed, self.generation == token, self.comments === socket else { return }
          if let object = self.object(message) { self.commentMessage(object) }
        } catch { self?.reconnectComments(token); return }
      }
    }
  }
  private func commentMessage(_ message: [String:Any]) {
    if (message["ping"] as? [String:Any])?["content"] as? String == "rf:0" {
      backlogComplete = true; onCommentStatus?("実況コメント"); return
    }
    guard backlogComplete, runningProvider?() == true, let chat = message["chat"] as? [String:Any] else { return }
    let identity = "\(chat["no"] ?? ""):\(chat["date"] ?? ""):\(chat["user_id"] ?? ""):\(chat["content"] ?? "")"
    guard !seen.contains(identity) else { return }
    seen.insert(identity); recent.append(identity)
    if recent.count > 2000 { seen.remove(recent.removeFirst()) }
    let time = max(0,timeProvider?() ?? 0)
    if let row = NeoLiveCommentCommand.row(chat,at:time+relay.delay(at:time)) {
      pending.append(row); received += 1; commentCount += 1
      if pending.count > 200 { pending.removeFirst(pending.count-200) }
    }
  }
  private func flushComments() {
    guard !pending.isEmpty, !closed else { return }
    let rows = pending; pending.removeAll(); onComments?(rows)
  }
  private func reconnectComments(_ token: Int) {
    guard !closed, generation == token, retry == nil else { return }
    clearSockets(); onCommentStatus?("実況コメントを再接続中…")
    retry = Timer.scheduledTimer(withTimeInterval:3,repeats:false) { [weak self] _ in
      MainActor.assumeIsolated { guard let self, !self.closed else { return }; self.retry = nil; self.startComments() }
    }
  }
  private func clearSockets() {
    infoTask?.cancel(); receiveWatch?.cancel(); receiveComments?.cancel()
    keepSeat?.invalidate(); keepSeat = nil; retry?.invalidate(); retry = nil
    let oldWatch = watch, oldComments = comments; watch = nil; comments = nil; backlogComplete = false
    oldWatch?.cancel(with:.goingAway,reason:nil); oldComments?.cancel(with:.goingAway,reason:nil)
  }
  @objc func suspend() { generation += 1; clearSockets(); pending.removeAll(); relay.suspend() }
  @objc func close() {
    guard !closed else { return }; closed = true; generation += 1; clearSockets()
    metadataTask?.cancel(); metadataTimer?.invalidate(); metadataTimer = nil; flush?.invalidate(); flush = nil
    relay.close(); apiSession.invalidateAndCancel(); socketSession.invalidateAndCancel()
    pending.removeAll(); onComments = nil; onMetadata = nil; onFailure = nil; onSourceData = nil
  }
}
