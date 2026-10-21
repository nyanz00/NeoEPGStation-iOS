import Foundation

// Headers are validated before any body bytes become visible to VLC. Partial
// bodies are never committed to a cache, and redirects stay on the API origin.
final class NeoHTTPByteStream: NSObject, URLSessionDataDelegate {
  private final class Read {
    let limit: Int, validate: (HTTPURLResponse) -> Bool, received: (Data) -> Void
    let completion: (Data?, HTTPURLResponse?, Error?) -> Void
    var data = Data(), response: HTTPURLResponse?, accepted = false
    init(limit: Int, validate: @escaping (HTTPURLResponse) -> Bool, received: @escaping (Data) -> Void,
         completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
      self.limit = limit; self.validate = validate; self.received = received; self.completion = completion
    }
  }
  private let origin: URL, queue: DispatchQueue
  private let configuration: URLSessionConfiguration
  private var reads: [ObjectIdentifier: Read] = [:]
  private var session: URLSession!
  init(origin: URL, configuration: URLSessionConfiguration, queue: DispatchQueue) {
    self.origin = origin; self.queue = queue; self.configuration = configuration; super.init()
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }
  // Called on the owner's serial queue, as are all callbacks.
  func read(_ request: URLRequest, limit: Int, validate: @escaping (HTTPURLResponse) -> Bool,
            received: @escaping (Data) -> Void,
            completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> URLSessionDataTask {
    let task = session.dataTask(with: request)
    reads[ObjectIdentifier(task)] = Read(limit: limit, validate: validate, received: received, completion: completion)
    return task
  }
  func close() { session.invalidateAndCancel(); reads.removeAll() }
  func renew() {
    let previous = session
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    previous?.finishTasksAndInvalidate()
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    queue.async {
      guard let read = self.reads[ObjectIdentifier(dataTask)], let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
      read.response = http
      read.accepted = (response.expectedContentLength < 0 || response.expectedContentLength <= Int64(read.limit)) && read.validate(http)
      completionHandler(read.accepted ? .allow : .cancel)
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async {
      guard let read = self.reads[ObjectIdentifier(dataTask)], read.accepted else { return }
      guard data.count <= read.limit-read.data.count else {
        read.accepted = false; dataTask.cancel(); return
      }
      read.data.append(data); read.received(data)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async {
      guard let read = self.reads.removeValue(forKey: ObjectIdentifier(task)) else { return }
      let expected = read.response?.expectedContentLength ?? -1
      let complete = read.accepted && error == nil && (expected < 0 || expected == Int64(read.data.count))
      read.completion(complete ? read.data : nil, read.response, complete ? nil : error ?? URLError(.badServerResponse))
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
      url.user == nil, url.password == nil else { completionHandler(nil); return }
    completionHandler(request)
  }
}

// One consumer, bounded by its HTTP read's limit. Only one socket write is in
// flight. A growing response can feed VLC before its final byte is downloaded.
final class NeoByteRelay {
  private var data = Data(), cursor = 0, busy = false, ended = false, failed = false
  private let skip: Int, count: Int
  private let send: (Data, @escaping (Bool) -> Void) -> Void
  private let completion: (Bool) -> Void
  private let waiting: (Bool) -> Void
  private var finished = false
  init(skip: Int = 0, count: Int = Int.max, waiting: @escaping (Bool) -> Void = { _ in }, send: @escaping (Data, @escaping (Bool) -> Void) -> Void,
       completion: @escaping (Bool) -> Void) {
    self.skip = skip; self.count = count; self.waiting = waiting; self.send = send; self.completion = completion
  }
  func append(_ bytes: Data) { guard !ended else { return }; data.append(bytes); pump() }
  func finish(_ success: Bool) { ended = true; failed = !success; pump() }
  private func pump() {
    guard !finished, !busy else { return }
    if failed { finished = true; waiting(false); completion(false); return }
    let start = min(data.count, skip)+cursor
    let available = min(max(0, data.count-start), count-cursor)
    if available > 0 {
      waiting(false)
      let amount = min(64*1024, available)
      busy = true
      send(data.subdata(in: start..<start+amount)) { success in
        self.busy = false
        if success { self.cursor += amount } else { self.failed = true }
        self.pump()
      }
    } else if ended {
      finished = true; waiting(false); completion(!failed)
    } else { waiting(true) }
  }
}
