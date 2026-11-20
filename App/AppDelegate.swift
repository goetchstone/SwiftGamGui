import AppKit
import GamEngine

/// The backstops that belong to the app's lifetime (invariant 4): a sweep at launch for anything a
/// crash or force-quit left behind; the Vault's session ended when the screen locks; at quit, every running `gam`
/// stopped, then every live folder wiped.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let base = try? RuntimeDirectory.prepare() {
            EphemeralConfig.sweepStale(in: base)
        }
        SignInCopy.clearLeftover()   // a sign-in card copied before a crash or a force-quit
        lockTheVaultWithTheScreen()
    }

    /// Ends the Vault's session; set by the app at launch.
    static var lockVault: (@Sendable () async -> Void)?

    /// The Vault's session ends when the screen locks, the display sleeps or another user's session takes the screen, not
    /// only after its 10 minutes: a Mac walked away from isn't left with the admin's credentials a click away (plan
    /// 2026-11-18, S2). A `gam` call under way keeps what it holds; the next read asks for Touch ID again.
    private func lockTheVaultWithTheScreen() {
        let lock: @Sendable (Notification) -> Void = { _ in Task { @MainActor in await AppDelegate.lockVault?() } }
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock)
        _ = workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock)
        _ = DistributedNotificationCenter.default().addObserver(forName: Self.screenLocked, object: nil, queue: .main, using: lock)
    }

    /// What macOS posts, distributed, when the screen locks.
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")

    /// What quitting now would cut short (an offboarding, onboarding or phishing trash run, onboarding's wait for
    /// Google, or a sign-in card still showing), and what that costs, asked at quit.
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
