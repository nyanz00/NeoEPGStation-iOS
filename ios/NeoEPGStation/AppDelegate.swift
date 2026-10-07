import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    var controller = (window ?? self.window)?.rootViewController
    while let current = controller {
      if let player = current as? NeoPlayerController { return player.supportedInterfaceOrientations }
      controller = current.presentedViewController
    }
    return .portrait
  }
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    NeoPlaybackCache.cleanAbandoned()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = NeoShell(); self.window = window; window.makeKeyAndVisible()
#if targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["NEO_EPG_STORAGE_SMOKE"] == "1" {
      NeoNative.runStorageSmokeTest()
      DispatchQueue.global(qos: .userInitiated).async {
        NeoNative.writeSmoke("danmaku-smoke", NeoDanmakuRenderer.smokeTest())
        NeoPiPSmoke.compositionTest()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        if let root = self?.window?.rootViewController { NeoPiPSmoke.playerTest(root: root) }
      }
    }
#endif
    return true
  }
}
