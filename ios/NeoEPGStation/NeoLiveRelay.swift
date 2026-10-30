import Foundation
import Network

// One live HTTP consumer. Cancellation releases the server's shared stream
// lease; no recorded-file byte cache, Range requests or accumulated TS file.
final class NeoLiveRelay: NSObject, URLSessionDataDelegate {
  private let source: URL, headers: [String:String]
  private let queue = DispatchQueue(label:"neo.live.relay")
  private var session: URLSession!, task: URLSessionDataTask?, listener: NWListener?
  private var connection: NWConnection?, chunks: [Data] = [], pendingBytes = 0
  private var pendingClients: [ObjectIdentifier:NWConnection] = [:]
  private var busy = false, suspended = false, accepted = false, closed = false, generation = 0
  private let clockLock = NSLock(), pcr = NeoLivePCRClock()
  private var bytes: Int64 = 0
  var onData: ((Data,Int64) -> Void)?
  var onFailure: ((Bool) -> Void)?
  init(source: URL, headers: [String:String]) {
    self.source = source; self.headers = headers; super.init()
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = .shared; config.urlCredentialStorage = .shared
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 7*86400
    session = URLSession(configuration:config,delegate:self,delegateQueue:nil)
  }
  func delay(at playback: Double) -> Double { clockLock.lock(); defer { clockLock.unlock() }; return pcr.delay(playback:playback) }
  func open(_ completion: @escaping (URL?) -> Void) {
    queue.async { [self] in
      guard !closed else { return }
      retire(); generation += 1; let token = generation
      clockLock.lock(); pcr.reset(); clockLock.unlock(); bytes = 0
      do {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let next = try NWListener(using:params); listener = next
        let route = "/"+UUID().uuidString+"/live.ts"
        var reported = false
        next.stateUpdateHandler = { [weak self, weak next] state in
          guard let self, let next, self.listener === next, self.generation == token, !self.closed else { return }
          switch state {
          case .ready:
            guard !reported, let port = next.port else { return }; reported = true
            let url = URL(string:"http://127.0.0.1:\(port.rawValue)\(route)")!
            DispatchQueue.main.async { completion(url) }
          case .failed:
            if !reported { reported = true; DispatchQueue.main.async { completion(nil) } }
            else { self.fail(retryable:true) }
          default: break
          }
        }
        next.newConnectionHandler = { [weak self, weak next] client in
          guard let self, let next, self.listener === next, self.generation == token, !self.closed else { client.cancel(); return }
          guard self.pendingClients.count < 16 else { client.cancel(); return }
          self.pendingClients[ObjectIdentifier(client)] = client
          client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state { case .failed, .cancelled: self.pendingClients.removeValue(forKey:ObjectIdentifier(client)); default: break }
          }
          client.start(queue:self.queue); self.readHeader(client,route:route,token:token,data:Data())
        }
        next.start(queue:queue)
      } catch { DispatchQueue.main.async { completion(nil) } }
    }
  }
  private func readHeader(_ client: NWConnection, route: String, token: Int, data: Data) {
    client.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] more,_,ended,error in
      guard let self, !self.closed, self.generation == token else { client.cancel(); return }
      var data = data; data.append(more ?? Data())
      guard error == nil, data.count <= 16384 else { client.cancel(); return }
      guard let text = String(data:data,encoding:.utf8), text.contains("\r\n\r\n") else {
        if ended { client.cancel() } else { self.readHeader(client,route:route,token:token,data:data) }; return
      }
      let first = text.components(separatedBy:"\r\n")[0].split(separator:" ")
      guard first.count == 3, first[1] == Substring(route), ["GET","HEAD"].contains(String(first[0])) else { client.cancel(); return }
      if first[0] == "HEAD" {
        client.send(content:Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n".utf8),completion:.contentProcessed { _ in client.cancel() }); return
      }
      guard self.connection == nil else { client.cancel(); return }
      self.pendingClients.removeValue(forKey:ObjectIdentifier(client))
      self.connection = client
      client.stateUpdateHandler = { [weak self, weak client] state in
        guard let self, let client, self.connection === client else { return }
        if case .failed = state { self.fail(retryable:true) }
        if case .cancelled = state { self.task?.cancel(); self.task = nil; self.connection = nil }
      }
      var request = URLRequest(url:self.source)
      self.headers.forEach { request.setValue($0.value,forHTTPHeaderField:$0.key) }
      request.setValue("video/mp2t",forHTTPHeaderField:"Accept")
      self.accepted = false; self.task = self.session.dataTask(with:request); self.task?.resume()
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    queue.async { [self] in
      guard task === dataTask, !closed, let client = connection, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
      guard http.statusCode == 200 else {
        let retry = [408,429].contains(http.statusCode) || http.statusCode >= 500
        NeoPlaybackDiagnostics.record("live.httpFailure",fields:["status":http.statusCode])
        completionHandler(.cancel); fail(retryable:retry); return
      }
      accepted = true
      client.send(content:Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8),completion:.contentProcessed { _ in })
      completionHandler(.allow)
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async { [self] in
      guard task === dataTask, accepted, !closed else { return }
      clockLock.lock(); pcr.observe(data); clockLock.unlock()
      onData?(data,bytes); bytes += Int64(data.count)
      chunks.append(data); pendingBytes += data.count
      if pendingBytes > 4*1024*1024 { fail(retryable:true); return }
      if pendingBytes >= 2*1024*1024, !suspended { suspended = true; dataTask.suspend() }
      pump()
    }
  }
  private func pump() {
    guard !busy, let client = connection, !chunks.isEmpty, accepted else { return }
    let body = chunks.removeFirst(); busy = true
    var data = Data("\(String(body.count,radix:16))\r\n".utf8); data.append(body); data.append(Data("\r\n".utf8))
    let token = generation
    client.send(content:data,completion:.contentProcessed { [weak self] error in
      guard let self, self.generation == token, self.connection === client else { return }
      self.busy = false; self.pendingBytes -= body.count
      if error != nil { self.fail(retryable:true); return }
      if self.suspended, self.pendingBytes < 512*1024 { self.suspended = false; self.task?.resume() }
      self.pump()
    })
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async { [self] in
      guard self.task === task, !closed else { return }
      fail(retryable:true)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, url.scheme == source.scheme, url.host == source.host, url.port == source.port,
      url.user == nil, url.password == nil else { completionHandler(nil); return }
    completionHandler(request)
  }
  private func fail(retryable: Bool) {
    guard task != nil || connection != nil else { return }; retire()
    DispatchQueue.main.async { [weak self] in self?.onFailure?(retryable) }
  }
  private func retire() {
    let previous = task; task = nil; previous?.cancel()
    let client = connection; connection = nil; client?.cancel()
    let old = listener; listener = nil; old?.cancel()
    let pending = Array(pendingClients.values); pendingClients.removeAll(); pending.forEach { $0.cancel() }
    chunks.removeAll(); pendingBytes = 0; busy = false; suspended = false; accepted = false
  }
  func suspend() { queue.async { [self] in generation += 1; retire() } }
  func close() { queue.async { [self] in closed = true; generation += 1; retire(); session.invalidateAndCancel(); onData = nil; onFailure = nil } }
}
