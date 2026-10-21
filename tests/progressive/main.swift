import Foundation

// Delayed chunks exercise real URLSession delegate delivery, including a read
// failing after a valid prefix. No network or real recording is required.
final class ChunkProtocol: URLProtocol {
  private let lock = NSLock()
  private var stopped = false
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chunks.example.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
  private func live() -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
  override func startLoading() {
    let bad = request.url!.path == "/bad", truncated = request.url!.path == "/truncated"
    let response = HTTPURLResponse(url: request.url!, statusCode: bad ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "16"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    DispatchQueue.global().asyncAfter(deadline: .now()+0.05) {
      guard self.live() else { return }
      self.client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 8))
      DispatchQueue.global().asyncAfter(deadline: .now()+0.15) {
        guard self.live() else { return }
        if truncated { self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else {
          self.client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 8))
          self.client?.urlProtocolDidFinishLoading(self)
        }
      }
    }
  }
}

let queue = DispatchQueue(label: "test.progressive")
let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChunkProtocol.self]
let origin = URL(string: "https://chunks.example.test")!
let stream = NeoHTTPByteStream(origin: origin, configuration: config, queue: queue)
for path in ["/ok", "/truncated", "/bad"] {
  let done = DispatchSemaphore(value: 0)
  var prefixes: [Data] = [], completed = false
  queue.async {
    let request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
    stream.read(request, limit: 16, validate: { $0.statusCode == 200 }, received: { bytes in
      precondition(!completed); prefixes.append(bytes)
    }, completion: { data, response, error in
      completed = true
      if path == "/ok" { precondition(data?.count == 16 && error == nil && prefixes.count >= 2) }
      if path == "/truncated" { precondition(data == nil && error != nil && prefixes.flatMap(Array.init).count == 8) }
      if path == "/bad" { precondition(data == nil && error != nil && prefixes.isEmpty && response?.statusCode == 503) }
      done.signal()
    }).resume()
  }
  precondition(done.wait(timeout: .now()+5) == .success, "HTTP test timed out")
}
queue.sync { stream.close() }

var sent = Data(), writes: [(Bool) -> Void] = [], completions: [Bool] = [], waiting: [Bool] = []
let relay = NeoByteRelay(skip: 2, count: 5, waiting: { waiting.append($0) }, send: { bytes, completion in
  sent.append(bytes); writes.append(completion)
}, completion: { completions.append($0) })
relay.append(Data([0,1,2,3])); precondition(sent == Data([2,3]) && completions.isEmpty)
relay.append(Data([4,5,6,7])); precondition(writes.count == 1, "Only one downstream write may be in flight")
writes.removeFirst()(true); precondition(sent == Data([2,3,4,5,6]))
relay.finish(true); precondition(completions.isEmpty, "EOF must wait for downstream delivery")
writes.removeFirst()(true); precondition(completions == [true])
var failed = false
let partial = NeoByteRelay(send: { _, completion in completion(true) }, completion: { failed = !$0 })
partial.append(Data([1,2])); partial.finish(false); precondition(failed, "Partial response cannot finish as valid cache data")
print("PASS: progressive body before EOF, rejected headers, truncated body, range slicing, backpressure and downstream completion")
