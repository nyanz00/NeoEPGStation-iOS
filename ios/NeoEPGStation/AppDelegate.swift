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
      controller = current.presentedViewController
    }
    return (window ?? self.window)?.traitCollection.userInterfaceIdiom == .pad ? .all : .portrait
  }
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = NeoShell(); self.window = window; window.makeKeyAndVisible()
#if targetEnvironment(simulator)
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
