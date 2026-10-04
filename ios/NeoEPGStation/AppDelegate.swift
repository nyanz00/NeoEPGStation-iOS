import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
#if targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["NEO_EPG_STORAGE_SMOKE"] == "1" {
      NeoNative.runStorageSmokeTest()
      DispatchQueue.global(qos: .userInitiated).async {
        let result = NeoDanmakuRenderer.smokeTest()
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
          let data = try? JSONSerialization.data(withJSONObject: result) {
          try? data.write(to: directory.appendingPathComponent("danmaku-smoke.json"))
        }
        NeoPiPSmoke.compositionTest()
      }
    }
#endif
    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    window = UIWindow(frame: UIScreen.main.bounds)

    factory.startReactNative(
      withModuleName: "NeoEPGStation",
      in: window,
      launchOptions: launchOptions
    )

#if targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["NEO_EPG_STORAGE_SMOKE"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        if let root = self?.window?.rootViewController { NeoPiPSmoke.playerTest(root: root) }
      }
    }
#endif

    return true
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
