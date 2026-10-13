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
        SignInCopy.clearLeftover()   // a sign-in card copied before a crash or a force-quit
    }

    /// What quitting now would cut short (an onboarding run, its wait for Google, or a sign-in card still
    /// showing), and what that costs, asked at quit.
    static var interruptible: (@MainActor () -> (what: String, consequence: String)?)?

    /// Quitting mid-onboarding asks first: the rest wouldn't be applied, the steps still waiting for Google
    /// are lost (nothing is persisted to replay later), and a card's temporary password is shown nowhere else.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let interrupted = Self.interruptible?() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(interrupted.what) Quit anyway?"
        alert.informativeText = interrupted.consequence
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.backstops()
    }

    /// What every way out of the app does last; a debug snapshot that can't quit through AppKit calls it too.
    static func backstops() {
        GamRunner.stopAll()          // no gam keeps running against the tenant after we're gone
        EphemeralConfig.wipeAllLive()
        SignInCopy.clearLeftover()   // a copied sign-in card, before its two minutes are up
    }
}
