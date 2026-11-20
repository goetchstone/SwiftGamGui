import Foundation
import Security

/// What the running build's own signature says (plan 2026-11-18, S4): read once, from the entitlement itself, not
/// `#if DEBUG`, since the entitlement is the risk whichever configuration carries it. Home warns through
/// `BuildExposure.warns`.
enum BuildSafety {
    /// True when this process carries `com.apple.security.get-task-allow`. A signature that can't be read counts as
    /// debuggable: a warning that turns out needless is safer than a silence that turns out wrong.
    static let debuggable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return true }
        // A nil value means either "not there" or "couldn't look"; only the error tells them apart.
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.get-task-allow" as CFString, &error)
        if let error {
            _ = error.takeRetainedValue()
            return true
        }
        return (value as? Bool) == true
    }()

    /// The demo (Debug builds only) runs on placeholder credentials and the strict mock, never the Keychain.
    static var demo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SWIFTGAMGUI_DEMO"] == "1"
        #else
        false
        #endif
    }
}
