import Foundation

@MainActor final class AnalysisFixture {
  var time = 0.0, requests = 0, progress = 0
  func info(_ status: String = "ready", version: Int = 2, current: Int = 2, stale: Bool = false, maximum: Double = 25) -> NeoCheckpointVideoInfo {
    let data: [String: Any] = ["videoCodec": "av1", "width": 1440, "height": 1080,
      "keyframes": ["status": status, "version": version, "currentVersion": current, "stale": stale,
        "averageInterval": 4, "minInterval": 2, "maxInterval": maximum, "intervalCount": 8, "keyframeCount": 11]]
    return try! JSONDecoder().decode(NeoCheckpointVideoInfo.self, from: JSONSerialization.data(withJSONObject: data))
  }
}

@main struct AnalysisTests {
  @MainActor static func main() async throws {
    let fixture = AnalysisFixture()
    let result = try await NeoCheckpointAnalysis.resolve(fetch: {
      fixture.requests += 1
      switch fixture.requests {
      case 1: return fixture.info("pending", version: 1, stale: true)
      case 2: return fixture.info("analyzing", version: 1, stale: true)
      default: return fixture.info()
      }
    }, progress: { _ in fixture.progress += 1 }, now: { fixture.time }, wait: { fixture.time += 3 })
    precondition(result.decision.enabled && result.requests == 3 && result.waitMs == 6000 && fixture.progress == 2)
    precondition(result.decision.analysisVersion == 2 && result.decision.analysisCurrentVersion == 2 && !result.decision.analysisStale)

    for version in [1,2,7] {
      let ready = try await NeoCheckpointAnalysis.resolve(fetch: { fixture.info(version: version, current: version, maximum: 6) },
        wait: { fatalError("A valid current result must not wait") })
      precondition(ready.requests == 1 && !ready.decision.enabled && ready.decision.reason == "short-gop")
    }
    // Even a transient ready+stale response must never be used to choose a route.
    var calls = 0
    let stale = try await NeoCheckpointAnalysis.resolve(fetch: {
      calls += 1; return calls == 1 ? fixture.info(version: 1, stale: true) : fixture.info()
    }, now: { fixture.time }, wait: { fixture.time += 3 })
    precondition(stale.requests == 2 && stale.decision.enabled)
    calls = 0
    let oldGeneration = try await NeoCheckpointAnalysis.resolve(fetch: {
      calls += 1; return calls == 1 ? fixture.info(version: 1) : fixture.info()
    }, now: { fixture.time }, wait: { fixture.time += 3 })
    precondition(oldGeneration.requests == 2 && oldGeneration.decision.enabled)

    for status in ["error","unavailable"] {
      let failed = try await NeoCheckpointAnalysis.resolve(fetch: { fixture.info(status) },
        wait: { fatalError("Terminal failures must not be polled") })
      precondition(!failed.decision.enabled && failed.outcome == "analysis-\(status)")
    }
    let legacy = try await NeoCheckpointAnalysis.resolve(fetch: {
      try JSONDecoder().decode(NeoCheckpointVideoInfo.self, from: Data("{}".utf8))
    }, wait: { fatalError("An old server must not wait") })
    precondition(legacy.outcome == "analysis-unsupported-server" && legacy.requests == 1)

    fixture.time = 0
    let timeout = try await NeoCheckpointAnalysis.resolve(fetch: { fixture.info("pending") }, timeout: 9,
      now: { fixture.time }, wait: { fixture.time += 3 })
    precondition(timeout.outcome == "analysis-timeout" && timeout.requests == 3 && !timeout.decision.enabled)
    let invalid = try await NeoCheckpointAnalysis.resolve(fetch: { fixture.info(maximum: 0) },
      wait: { fatalError("Invalid metrics must not poll forever") })
    precondition(invalid.outcome == "analysis-invalid" && !invalid.decision.enabled)
    let requestFailure = try await NeoCheckpointAnalysis.resolve(fetch: { throw URLError(.cannotConnectToHost) })
    precondition(requestFailure.outcome == "analysis-request-failed" && !requestFailure.decision.enabled)
    do {
      _ = try await NeoCheckpointAnalysis.resolve(fetch: { fatalError("Leaving a page must prevent another GET") }, isCurrent: { false })
      fatalError("Expected cancellation")
    } catch is CancellationError {}
    var current = true
    do {
      _ = try await NeoCheckpointAnalysis.resolve(fetch: { current = false; return fixture.info() }, isCurrent: { current })
      fatalError("A late response from a previous page/identity must not start a player")
    } catch is CancellationError {}
    do {
      _ = try await NeoCheckpointAnalysis.resolve(fetch: { fixture.info("pending") }, wait: { throw CancellationError() })
      fatalError("Cancelled waiting must not start a player")
    } catch is CancellationError {}
    print("Checkpoint analysis: current versions, old/missing analysis polling, invalid/error/legacy/timeout fallback, cancellation passed")
  }
}
