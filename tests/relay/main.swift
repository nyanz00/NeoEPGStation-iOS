import Foundation
import Network

final class NeoPlaybackDiagnostics {
  static func record(_ name: String, fields: [String:Any]) {}
}

// Actual TCP/HTTP sockets, real relay implementation and retained segment files.
// Media bytes need no decoder: this test isolates listener recovery from VLC.
final class Origin: @unchecked Sendable {
  let listener: NWListener
  let queue = DispatchQueue(label:"relay.test.origin")
  let payload = Data(repeating:0x47,count:188*64)
  private let lock = NSLock()
  private var fail = false
  func failPlaylist(_ value: Bool) { lock.lock(); fail = value; lock.unlock() }
  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
    listener = try NWListener(using:parameters)
    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
  }
  func start() async -> URL {
    await withCheckedContinuation { done in
      listener.stateUpdateHandler = { [self] state in
        if case .ready = state, let port = listener.port {
          listener.stateUpdateHandler = nil
          done.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/api/videos/1")!)
        }
      }
      listener.start(queue:queue)
    }
  }
  private func accept(_ connection: NWConnection) {
    connection.start(queue:queue)
    connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [self] data,_,_,_ in
      let request = String(data:data ?? Data(),encoding:.utf8) ?? ""
      lock.lock(); let failed = fail; lock.unlock()
      let playlist = request.contains("/playlist?")
      let code = playlist && failed ? 503 : 200
      let body: Data
      if playlist {
        body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegments/0.ts\n#EXTINF:4,\nsegments/1.ts\n#EXT-X-ENDLIST\n".utf8)
      } else if request.hasPrefix("GET ") { body = payload }
      else { body = Data() }
      var response = Data("HTTP/1.1 \(code) OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
      response.append(body)
      connection.send(content:response,completion:.contentProcessed { _ in connection.cancel() })
    }
  }
}

@main struct RelayTest {
  static func main() async throws {
    let origin = try Origin(), source = await origin.start()
    let relay = NeoStreamingSession(source:source,ts:true,mode:0,quality:"test",username:"",password:"")
    let first: URL = await withCheckedContinuation { done in
      relay.start(at:0) { url,error in precondition(error == nil); done.resume(returning:url!) }
    }
    let (playlist,_) = try await URLSession.shared.data(from:first)
    precondition(String(data:playlist,encoding:.utf8)!.contains("/segments/0.ts"))
    await withCheckedContinuation { done in relay.loseListenerForProbe { done.resume() } }
    // The remote lease/API is healthy while the old LOCAL endpoint is dead.
    var oldRequest = URLRequest(url:first); oldRequest.timeoutInterval = 1
    do { _ = try await URLSession.shared.data(for:oldRequest); preconditionFailure("Fault did not close listener") } catch {}
    origin.failPlaylist(true)
    let failed: Bool = await withCheckedContinuation { done in
      relay.reopen(at:4) { url,error in done.resume(returning:url == nil && error != nil) }
    }
    precondition(failed && relay.retryableFailure)
    origin.failPlaylist(false)
    let second: URL = await withCheckedContinuation { done in
      relay.reopen(at:4) { url,error in precondition(error == nil); done.resume(returning:url!) }
    }
    let (restored,_) = try await URLSession.shared.data(from:second)
    precondition(String(data:restored,encoding:.utf8)!.contains("TIME-OFFSET=4"))
    let segment = second.deletingLastPathComponent().appendingPathComponent("segments/1.ts")
    let (bytes,response) = try await URLSession.shared.data(from:segment)
    precondition((response as? HTTPURLResponse)?.statusCode == 200 && bytes == origin.payload)
    relay.close(); origin.listener.cancel()
    print("Relay: closed old socket, failed remote playlist, fresh endpoint and segment delivery PASS")
  }
}
