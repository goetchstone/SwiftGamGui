import AppKit
import GamEngine

/// The two credential-directory backstops that belong to the app's lifetime (invariant 4): a sweep at
/// launch for anything a crash or force-quit left behind, and a wipe at quit for anything still live.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let base = try? RuntimeDirectory.prepare() {
            EphemeralConfig.sweepStale(in: base)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EphemeralConfig.wipeAllLive()
    }
}
