import Foundation
import GamEngine
import Vault

/// The toolbar's domain menu (plan F6, GamGUI's #173 `_tenant.html` and `_switch_failed.html`): which domains it offers and
/// what it says after a switch, in GamGUI's words. The switch itself is Setup's own `checkAccess`, warning and all: there is
/// no second path.
public enum DomainMenu {
    /// What the menu says after a switch that didn't happen: in a line, then the check's own summary, and the Admin console's
    /// delegation link when the check gave one.
    public struct Answer: Equatable, Sendable {
        public let text: String
        public let detail: String?
        public let link: URL?
        /// The fix is on Setup (each scope the check read, or the admin to type): the menu offers to open it.
        public let toSetup: Bool
    }

    /// The domains the menu offers: every one the Keychain holds but the active one (`Domain` is one spelling, so two
    /// spellings of a domain count once). Empty with none active, or no other stored: then there is no menu.
    @MainActor public static func others(_ setup: SetupModel) -> [Domain] {
        guard let active = setup.active else { return [] }
        return setup.domains.filter { $0 != active }
    }

    /// What it says after asking `checkAccess` to switch to `domain` from `active`; nil when there's nothing to say here: a
    /// pass (the window shows the new domain), a warning (`SetupModel.switchWarning` says it), or a check nobody waits for.
    public static func answer(_ outcome: SetupModel.CheckOutcome, switchingTo domain: Domain, from active: Domain?) -> Answer? {
        let stays = active.map { ", so \($0) stays active." } ?? "."
        switch outcome {
        case .connected, .warned, .cancelled:
            return nil
        case .failed(let check):
            return Answer(text: "\(domain) didn't pass the access check\(stays)", detail: SetupModel.summary(of: check),
                          link: check.authorizationURL, toSetup: true)
        case .busy(let checking?):
            return Answer(text: "\(checking)'s access is being checked. Wait for its answer, then try again. Nothing changed.",
                          detail: nil, link: nil, toSetup: false)
        case .busy(nil):
            return Answer(text: "Setup is busy with another action. Wait for it to finish, then try again. Nothing changed.",
                          detail: nil, link: nil, toSetup: false)
        case .keychainRefused:
            return Answer(text: "The Keychain didn't hand over \(domain)'s credentials: it may be locked, or its password prompt "
                              + "was cancelled. Nothing changed. Try again.", detail: nil, link: nil, toSetup: false)
        case .noAdmin:
            return Answer(text: "\(domain)'s oauth2.txt names no admin, so switch to it on Setup, where you type its super-admin "
                              + "email.", detail: nil, link: nil, toSetup: true)
        case .notRun(let reason):
            return Answer(text: "\(domain)'s access check couldn't run, so nothing changed.", detail: reason, link: nil, toSetup: false)
        }
    }

    /// The button under a failed check's answer: Setup shows the check just made, each scope it read (GamGUI's line, "Switch
    /// to it on Setup to see each scope the check read.", sends the operator to check again there).
    public static let toSetupForScopes = "See Each Scope the Check Read on Setup"
}
