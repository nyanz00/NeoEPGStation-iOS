// Only the app shell is replaced here. Actual models and shared UI code are
// type checked with the simulator SDK before native dependencies are built.
import UIKit

@MainActor final class NeoShell {
  var api: NeoAPI?
  private(set) var channels: [Int:String] = [:]
}
