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

    /// What quitting now would cut short (an onboarding run, or its wait for Google), asked at quit.
    static var interruptible: (@MainActor () -> String?)?

    /// Quitting mid-onboarding asks first: the rest wouldn't be applied, and the steps still waiting for
    /// Google are lost (nothing is persisted to replay later).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let what = Self.interruptible?() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(what) Quit anyway?"
        alert.informativeText = "The rest won't be applied."
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        GamRunner.stopAll()          // no gam keeps running against the tenant after we're gone
        EphemeralConfig.wipeAllLive()
    }
}
