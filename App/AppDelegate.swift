import AppKit
import GamEngine

/// The backstops that belong to the app's lifetime (invariant 4): a sweep at launch for anything a
/// crash or force-quit left behind; at quit, every running `gam` stopped, then every live folder wiped.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let base = try? RuntimeDirectory.prepare() {
            EphemeralConfig.sweepStale(in: base)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GamRunner.stopAll()          // no gam keeps running against the tenant after we're gone
        EphemeralConfig.wipeAllLive()
    }
}
