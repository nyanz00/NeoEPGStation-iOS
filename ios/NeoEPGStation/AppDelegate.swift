import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func applicationDidBecomeActive(_ application: UIApplication) {
    (window?.rootViewController as? NeoShell)?.revalidateAccount()
  }
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    var controller = (window ?? self.window)?.rootViewController
    while let current = controller {
      if let player = current as? NeoPlayerController { return player.supportedInterfaceOrientations }
      if let player = current as? NeoAetherPlayer { return player.supportedInterfaceOrientations }
      if let player = current as? NeoAVPlayerComparison { return player.supportedInterfaceOrientations }
      controller = current.presentedViewController
    }
    return (window ?? self.window)?.traitCollection.userInterfaceIdiom == .pad ? .all : .portrait
  }
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = NeoShell(); self.window = window; window.makeKeyAndVisible()
#if targetEnvironment(simulator)
    if let raw = ProcessInfo.processInfo.environment["NEO_EPG_LIVE_SMOKE"], let base = URL(string:raw), let shell = window.rootViewController as? NeoShell {
      let api = NeoAPI(base:base); api.activate(user:"master",headers:["X-Live-Test":"synthetic"]); shell.smokeUseAPI(api)
      DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
        shell.showRoute("onair")
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
          guard let page = shell.children.compactMap({ $0 as? UINavigationController }).first?.viewControllers.first as? NeoOnAirPage else {
            NeoPiPSmoke.save("live-smoke",["success":false,"error":"onair route missing"]); return
          }
          page.runLiveUIProbe { ui in
            Task { @MainActor in
              do {
                let config = try await api.configuration(), schedules = try await api.broadcasting()
                let options = NeoLiveOption.available(config), schedule = schedules.first!
                var context = schedule.context(base:base)
                context["liveHeaders"] = api.liveRequestHeaders; context["liveType"] = "m2ts"; context["liveMode"] = 0; context["liveQuality"] = options[0].quality
                context["liveOptions"] = options.map(\.dictionary); context["liveChannels"] = schedules.map { $0.context(base:base) }
                let controller = NeoPlayerController(url:options[0].url(api:api,channel:schedule.channel.id),title:schedule.channel.name,username:"",password:"",networkCaching:500)
                controller.recordingContext = context; controller.modalPresentationStyle = .fullScreen
                NeoSubtitlePreference.save(""); UserDefaults.standard.set(true,forKey:"player.comments.enabled")
                shell.present(controller,animated:false) {
                  controller.runLiveProbe { result in
                    var result = result; result["ui"] = ui; result["success"] = result["success"] as? Bool == true && ui.values.allSatisfy { $0 }
                    NeoPiPSmoke.save("live-smoke",result)
                    if let source = NeoPlaybackDiagnostics.exportURL(), let bytes = try? Data(contentsOf:source) { try? bytes.write(to:NeoPiPSmoke.directory.appendingPathComponent("live-diagnostics.json")) }
                  }
                }
              } catch { NeoPiPSmoke.save("live-smoke",["success":false,"error":"live fixture setup failed"]) }
            }
          }
        }
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_AETHER_CONNECTED"], let url = URL(string:base+"/api/videos/1") {
      NeoCommentOverlay.waitBeforePlayback = true
      UserDefaults.standard.set(true,forKey:"player.comments.enabled")
      NeoSubtitlePreference.save("")
      let streaming = ProcessInfo.processInfo.environment["NEO_EPG_CONNECTED_STREAM"] == "1"
      DispatchQueue.main.asyncAfter(deadline:.now()+1) {
        let controller = NeoPlayerController(url:url,title:"Synthetic connected player",username:"",password:"",networkCaching:5000)
        controller.initialPosition = 20
        controller.aetherOptions = ["checkpointEnabled":ProcessInfo.processInfo.environment["NEO_EPG_CONNECTED_CHECKPOINT"] == "1"]
        var context: [String:Any] = ["baseURL":base,"id":1,"user":"1","videoFileType":"encoded","disableHistory":false]
        if streaming { context["streaming"] = true; context["streamMode"] = 0; context["streamQualities"] = ["Synthetic A","Synthetic B"] }
        controller.recordingContext = context
        window.rootViewController?.present(controller,animated:false) {
          controller.runAetherConnectedProbe { result in
            NeoPiPSmoke.save("aether-connected-smoke",result)
            if let source = NeoPlaybackDiagnostics.exportURL(), let bytes = try? Data(contentsOf:source) {
              try? bytes.write(to:NeoPiPSmoke.directory.appendingPathComponent("aether-connected-diagnostics.json"))
            }
          }
        }
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_CHECKPOINT_ANALYSIS"], let url = URL(string: base) {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        (window.rootViewController as? NeoShell)?.runCheckpointAnalysisProbe(base: url,
          scenario: ProcessInfo.processInfo.environment["NEO_EPG_ANALYSIS_CASE"] ?? "stale")
      }
      return true
    }
    if let path = ProcessInfo.processInfo.environment["NEO_EPG_CHECKPOINT_TRIAL"], let url = URL(string: path) {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let controller = NeoDecodeTrialController(source: url, checkpoint: true)
        window.rootViewController?.present(controller, animated: false) { controller.run() }
      }
      return true
    }
    if let path = ProcessInfo.processInfo.environment["NEO_EPG_DECODE_TRIAL"], let url = URL(string: path) {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let controller = NeoDecodeTrialController(source: url)
        window.rootViewController?.present(controller, animated: false) { controller.run() }
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_AVPLAYER_COMPARE"], let url = URL(string: base+"/api/videos/1/web") {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let player = NeoAVPlayerComparison(url: url, title: "Synthetic direct comparison")
        window.rootViewController?.present(player, animated: false) { player.runComparisonProbe() }
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_AETHER_COMPARE"], let url = URL(string: base+"/api/videos/1") {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let mode = ProcessInfo.processInfo.environment["NEO_EPG_CHECKPOINT_COMPARE"]
        let player = NeoAetherPlayer(url: url, title: "Synthetic engine comparison", initialPosition: 0,
          checkpointMode: mode.map { $0 == "on" })
        window.rootViewController?.present(player, animated: false) { player.runComparisonProbe() }
      }
      return true
    }
#endif
#if targetEnvironment(simulator)
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_ENCODED_SEEK"], let url = URL(string: base+"/api/videos/1") {
      UserDefaults.standard.set(60, forKey: NeoPlaybackCache.preference)
      UserDefaults.standard.set(false, forKey: "player.comments.enabled")
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let player = NeoPlayerController(url: url, title: "Synthetic encoded seek", username: "", password: "", networkCaching: 5000)
        player.initialPosition = 30
        player.recordingContext = ["disableHistory": true, "videoFileType": "encoded"]
        player.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(player, animated: false) {
          player.runEncodedSeekProbe { result in
            NeoPiPSmoke.save("encoded-seek-smoke", result)
            if let source = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: source) {
              try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("encoded-seek-diagnostics.json"))
            }
          }
        }
      }
      return true
    }
    if ProcessInfo.processInfo.environment["NEO_EPG_REFLOW_ZOOM"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        var checks = NeoShell.reflowSmoke(in: window.rootViewController!.view)
        let chrome = NeoPlayerChrome(title: "Synthetic fullscreen zoom")
        window.rootViewController?.view.addSubview(chrome)
        for size in [CGSize(width: 844, height: 390), CGSize(width: 390, height: 844), CGSize(width: 1194, height: 834)] {
          chrome.frame = CGRect(origin: .zero, size: size); chrome.setNeedsLayout(); chrome.layoutIfNeeded()
          for (key, value) in chrome.runZoomPanChecks() { checks["\(Int(size.width))."+key] = value }
        }
        NeoPiPSmoke.save("reflow-zoom-smoke", ["success": checks.values.allSatisfy { $0 }, "checks": checks])
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_STREAMING"], let url = URL(string: base+"/api/videos/1") {
      NeoCommentOverlay.waitBeforePlayback = true
      UserDefaults.standard.set(true, forKey: "player.comments.enabled")
      let ts = ProcessInfo.processInfo.environment["NEO_EPG_STREAM_TYPE"] == "ts"
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let player = NeoPlayerController(url: url, title: "Synthetic HLS", username: "", password: "", networkCaching: 300)
        player.initialPosition = 49
        player.recordingContext = ["disableHistory": true, "videoFileType": ts ? "ts" : "encoded", "streaming": true,
          "streamMode": 0, "streamQualities": ["Synthetic A", "Synthetic B"]]
        player.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(player, animated: false) {
          player.runStreamingProbe { result in
            NeoPiPSmoke.save("streaming-smoke", result)
            if let source = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: source) {
              try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("streaming-diagnostics.json"))
            }
          }
        }
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_TS_RESUME"], let url = URL(string: base+"/api/videos/1") {
      NeoCommentOverlay.waitBeforePlayback = true
      UserDefaults.standard.set(true, forKey: "player.comments.enabled")
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let player = NeoPlayerController(url: url, title: "Synthetic TS resume", username: "", password: "", networkCaching: 300)
        player.initialPosition = 49
        player.recordingContext = ["disableHistory": true, "videoFileType": "ts"]
        player.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(player, animated: false) {
          player.runTSResumeProbe { result in
            NeoPiPSmoke.save("ts-resume-smoke", result)
            if let source = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: source) {
              try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("ts-resume-diagnostics.json"))
            }
          }
        }
      }
      return true
    }
    if ProcessInfo.processInfo.environment["NEO_EPG_ZOOM_FONT_SMOKE"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let chrome = NeoPlayerChrome(title: "Zoom feedback")
        window.rootViewController?.view.addSubview(chrome)
        chrome.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        chrome.setNeedsLayout(); chrome.layoutIfNeeded()
        var checks = chrome.runZoomChecks()
        chrome.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        chrome.setNeedsLayout(); chrome.layoutIfNeeded()
        for (key, value) in chrome.runZoomChecks() { checks["portrait."+key] = value }
        let zoomChecks = checks
        DispatchQueue.global(qos: .userInitiated).async {
          let fonts = NeoDanmakuRenderer.fontDiagnosticsSmoke()
          DispatchQueue.main.async {
            let result = zoomChecks.merging(fonts) { _, new in new }
            NeoPiPSmoke.save("player-zoom-font-smoke", ["success": result.values.allSatisfy { $0 }, "checks": result])
          }
        }
      }
      return true
    }
    if ProcessInfo.processInfo.environment["NEO_EPG_ARIB_PROBE"] == "1" {
      UserDefaults.standard.removeObject(forKey: "player.subtitle.name")
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let player = NeoPlayerController(url: NeoPiPSmoke.directory.appendingPathComponent("arib-timing.ts"), title: "Synthetic ARIB timing", username: "", password: "", networkCaching: 100)
        player.recordingContext = ["disableHistory": true, "videoFileType": "ts"]; player.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(player, animated: false) {
          player.runARIBProbe { result in NeoPiPSmoke.save("arib-timing-smoke", result) }
        }
      }
      return true
    }
    if let base = ProcessInfo.processInfo.environment["NEO_EPG_NETWORK_PROBE"], let url = URL(string: base+"/api/videos/4") {
      DispatchQueue.main.asyncAfter(deadline: .now()+1) {
        let player = NeoPlayerController(url: url, title: "Synthetic network recovery", username: "", password: "", networkCaching: 5000)
          if ProcessInfo.processInfo.environment["NEO_EPG_NETWORK_MODE"] == "tunnel" { player.initialPosition = 90 }
        player.recordingContext = ["disableHistory": true]; player.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(player, animated: false) {
          player.runNetworkProbe { result in
            NeoPiPSmoke.save("network-recovery-smoke", result)
            if let source = NeoPlaybackDiagnostics.exportURL(), let data = try? Data(contentsOf: source) {
              try? data.write(to: NeoPiPSmoke.directory.appendingPathComponent("network-diagnostics.json"))
            }
          }
        }
      }
      return true
    }
    if ProcessInfo.processInfo.environment["NEO_EPG_STORAGE_SMOKE"] == "1" {
      NeoNative.runStorageSmokeTest()
      NeoCommentOverlay.runPreparationSmoke()
      if let base = ProcessInfo.processInfo.environment["NEO_EPG_RANGE_SMOKE"] { NeoCommentOverlay.runJikkyoSmoke(base: base) }
      if let base = ProcessInfo.processInfo.environment["NEO_EPG_RANGE_SMOKE"], let url = URL(string: base+"/api/videos/1") { NeoPlaybackCache.runSmoke(url) }
      DispatchQueue.global(qos: .userInitiated).async {
        NeoNative.writeSmoke("danmaku-smoke", NeoDanmakuRenderer.smokeTest())
        NeoPiPSmoke.compositionTest()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        if let root = self?.window?.rootViewController as? NeoShell {
          Task { await NeoAccountSmoke.run(root); NeoPiPSmoke.playerTest(root: root) }
        }
      }
    }
#endif
    return true
  }
}
