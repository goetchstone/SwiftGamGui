import ChangeCore
import Foundation
import GamEngine
import Observation
import Vault

/// The user page's writes (GamGUI's `/users/organization` and `/users/suspend/*`), through ChangeCore: a
/// change is previewed (held by the executor, exactly as it will run), confirmed by the operator, run
/// once, audited, and then patched into the cached directory, so the list shows it without a reload.
/// Nothing here runs `gam` itself; every write goes through `Executor`.
@MainActor
@Observable
public final class UserChanges {
    public enum State: Sendable {
        case idle
        /// The preview the screen shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(String)
    }

    /// A held preview with what the screen says about it, and how a success updates the cached user.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let title: String
        /// What the confirm button says ("Suspend", "Save").
        public let confirmLabel: String
        /// The address the change is for.
        public let email: String
        /// Something the operator should know before confirming (GamGUI's "Add anyway" warnings).
        public let warning: String?
        let patch: @Sendable (GamUser) -> GamUser

        public var id: UUID { preview.id }
        public var isDestructive: Bool { preview.decision.maxRisk == .destructive }
    }

    public private(set) var state: State = .idle
    /// Counts confirmed changes that succeeded: a screen showing a person's live lists reads them again.
    public private(set) var finished = 0
    /// The address the current state is about, so a panel shows a result only under its own person.
    public private(set) var subject: String?
    private let executor: Executor?
    private let directory: DirectoryStore

    public init(executor: Executor?, directory: DirectoryStore) {
        self.executor = executor
        self.directory = directory
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: previews

    /// GamGUI's organization editor: GAM's `organization … primary` sets the title and department together,
    /// so both are always sent (an unchanged one as it is now), trimmed.
    public func previewOrganization(of user: GamUser, title: String, department: String) async {
        let title = PythonText.strip(title), department = PythonText.strip(department)
        subject = user.primaryEmail
        guard title != user.title || department != user.department else {
            state = .problem("Nothing to change: that's already \(user.fullName)'s title and department.")
            return
        }
        let step = WriteStep(GamCommands.updateOrganization(email: user.primaryEmail, title: title, department: department),
                             target: user.primaryEmail, summary: "Set \(user.fullName)'s title to “\(title)” and department to “\(department)”")
        await hold(step, title: "Change title and department", confirmLabel: "Save", email: user.primaryEmail) {
            $0.with(title: title, department: department)
        }
    }

    /// GamGUI's `plan_suspend`: suspending is destructive (a Confirm click), unsuspending LOW.
    public func previewSuspend(_ user: GamUser, suspend: Bool) async {
        let verb = suspend ? "Suspend" : "Unsuspend"
        let step = WriteStep(GamCommands.setSuspended(email: user.primaryEmail, suspended: suspend),
                             target: user.primaryEmail,
                             summary: suspend ? "Suspend \(user.primaryEmail): they can't sign in until unsuspended."
                                              : "Unsuspend \(user.primaryEmail): they can sign in again.")
        await hold(step, title: "\(verb) \(user.fullName)", confirmLabel: verb, email: user.primaryEmail) {
            $0.with(suspended: suspend)
        }
    }

    // MARK: groups and delegates

    /// GamGUI's `/users/groups/add`: one person, one group, as a member. LOW.
    public func previewAddToGroup(_ user: GamUser, group: String) async {
        let group = PythonText.strip(group)
        guard Address.looksLikeEmail(group) else {
            subject = user.primaryEmail
            state = .problem("“\(group)” isn't a group address: enter the group's full address, like sales@example.com.")
            return
        }
        let step = WriteStep(GamCommands.addGroupMember(group: group, member: user.primaryEmail), target: user.primaryEmail,
                             summary: "Add \(user.primaryEmail) to \(group) as a member.", about: ["group": group])
        await hold(step, title: "Add to \(group)", confirmLabel: "Add", email: user.primaryEmail)
    }

    /// GamGUI's `/users/groups/remove`: LOW, but only from its confirm step (`confirm_step`).
    public func previewRemoveFromGroup(_ user: GamUser, group: String) async {
        // GamGUI's preview checks both addresses: GAM would read anything else as something else.
        guard Address.looksLikeEmail(group), Address.looksLikeEmail(user.primaryEmail) else {
            subject = user.primaryEmail
            state = .problem("Pick a group to remove.")
            return
        }
        let step = WriteStep(GamCommands.removeGroupMember(group: group, member: user.primaryEmail), target: user.primaryEmail,
                             summary: "Remove \(user.primaryEmail) from \(group).", about: ["group": group])
        await hold(step, title: "Remove from \(group)", confirmLabel: "Remove", email: user.primaryEmail, confirmStep: true)
    }

    /// GamGUI's `/users/delegate/add` with its `_check_delegate`: an error blocks the add; a warning is shown
    /// on the preview, and confirming it is the "Add anyway".
    public func previewAddDelegate(_ user: GamUser, delegate: String, directory: [GamUser]?) async {
        let delegate = PythonText.strip(delegate)
        subject = user.primaryEmail
        let check = Self.checkDelegate(delegate, for: user.primaryEmail, directory: directory)
        if let error = check.error {
            state = .problem(error)
            return
        }
        let step = WriteStep(GamCommands.addDelegate(email: user.primaryEmail, delegate: delegate), target: user.primaryEmail,
                             summary: "Let \(delegate) read and send as \(user.primaryEmail).", about: ["delegate": delegate])
        await hold(step, title: "Add a delegate", confirmLabel: check.warning == nil ? "Add" : "Add Anyway",
                   email: user.primaryEmail, warning: check.warning)
    }

    /// GamGUI's `/users/delegate/remove`. LOW.
    public func previewRemoveDelegate(_ user: GamUser, delegate: String) async {
        let step = WriteStep(GamCommands.removeDelegate(email: user.primaryEmail, delegate: delegate), target: user.primaryEmail,
                             summary: "Stop \(delegate) reading and sending as \(user.primaryEmail).", about: ["delegate": delegate])
        await hold(step, title: "Remove a delegate", confirmLabel: "Remove", email: user.primaryEmail)
    }

    // MARK: auto-reply and sign-out

    /// GamGUI's `/users/vacation/set`: the typed text goes out as HTML (`autoreply_html`), so senders read its
    /// line breaks; every setting is named (GAM keeps any it isn't given). An empty date is GAM's
    /// `Started` / `NotSpecified`. LOW.
    public func previewAutoReply(_ user: GamUser, subject: String, text: String, contactsOnly: Bool, domainOnly: Bool,
                                 start: String, end: String) async {
        let step = WriteStep(
            GamCommands.setVacation(email: user.primaryEmail, subject: subject, message: HTMLText.autoreplyHTML(text),
                                    html: true, start: PythonText.strip(start), end: PythonText.strip(end),
                                    contactsOnly: contactsOnly, domainOnly: domainOnly),
            target: user.primaryEmail, summary: "Turn on \(user.primaryEmail)'s auto-reply: “\(subject)”.")
        await hold(step, title: "Turn on the auto-reply", confirmLabel: "Turn On", email: user.primaryEmail)
    }

    /// GamGUI's `/users/vacation/off`. LOW.
    public func previewAutoReplyOff(_ user: GamUser) async {
        let step = WriteStep(GamCommands.vacationOff(email: user.primaryEmail), target: user.primaryEmail,
                             summary: "Turn off \(user.primaryEmail)'s auto-reply.")
        await hold(step, title: "Turn off the auto-reply", confirmLabel: "Turn Off", email: user.primaryEmail)
    }

    /// GamGUI's `/users/signout`: ends every session; the person signs in again. LOW, as GamGUI rates it.
    public func previewSignOut(_ user: GamUser) async {
        let step = WriteStep(GamCommands.signOutUser(email: user.primaryEmail), target: user.primaryEmail,
                             summary: "Sign \(user.primaryEmail) out of every session: they sign in again on each device.")
        await hold(step, title: "Sign \(user.fullName) out", confirmLabel: "Sign Out", email: user.primaryEmail)
    }

    /// GamGUI's `_check_delegate`, against the cached directory: (error, warning).
    static func checkDelegate(_ delegate: String, for email: String, directory: [GamUser]?) -> (error: String?, warning: String?) {
        if delegate.isEmpty { return ("Enter a delegate email.", nil) }
        guard Address.looksLikeEmail(delegate) else {
            return ("“\(delegate)” isn't an email address — enter the delegate's full address, like name@example.com.", nil)
        }
        let key = PythonText.lower(delegate)
        if key == PythonText.lower(PythonText.strip(email)) { return ("A mailbox can't be delegated to its own owner.", nil) }
        guard let directory else {
            return (nil, "Couldn't check \(delegate) against the directory: it isn't loaded. Load it on Home or Users first.")
        }
        guard let found = directory.first(where: { PythonText.lower($0.primaryEmail) == key }) else {
            if let owner = directory.first(where: { $0.aliases.contains { PythonText.lower($0) == key } }) {
                return ("\(delegate) is an alias of \(owner.primaryEmail) — enter the primary address.", nil)
            }
            return (nil, "\(delegate) isn't in the directory. Gmail only accepts a delegate from your own organization — check for a typo. "
                + "(An account created in the last few minutes shows after Users → Refresh.)")
        }
        if found.suspended {
            return (nil, "\(delegate) is suspended — Gmail may refuse the delegation, and the account can't sign in to use it.")
        }
        return (nil, nil)
    }

    private func hold(_ step: WriteStep, title: String, confirmLabel: String, email: String, confirmStep: Bool = false,
                      warning: String? = nil, patch: @escaping @Sendable (GamUser) -> GamUser = { $0 }) async {
        guard !isBusy else { return }
        subject = email
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        switch await executor.preview([step], confirmStep: confirmStep) {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, title: title, confirmLabel: confirmLabel, email: email,
                                        warning: warning, patch: patch))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    // MARK: confirming

    /// Runs the preview the screen showed, once. `confirmation` is what the operator gave at the confirm
    /// step; the executor decides whether it is enough.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor else { return }
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        switch outcome.steps.first {
        case .succeeded:
            directory.patch(pending.email, on: pending.preview.domain, generation: pending.preview.generation, pending.patch)
            finished += 1
            let note = outcome.auditProblem.map { " \($0)" } ?? ""
            state = .done("Done: \(pending.preview.steps.first?.summary ?? pending.title)\(note)")
        case .failed(let message, let kind):
            state = .problem([message, kind?.remediation].compactMap { $0 }.joined(separator: " "))
        case .skipped(let reason):
            state = .problem(reason)
        case nil:
            state = .problem("Nothing ran.")
        }
    }

    /// Whether the current state is about `email`.
    public func concerns(_ email: String) -> Bool {
        subject.map { Guard.normalized($0) == Guard.normalized(email) } ?? false
    }

    /// Back to the user page; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
