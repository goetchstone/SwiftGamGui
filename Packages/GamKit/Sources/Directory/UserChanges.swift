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
        let patch: @Sendable (GamUser) -> GamUser

        public var id: UUID { preview.id }
        public var isDestructive: Bool { preview.decision.maxRisk == .destructive }
    }

    public private(set) var state: State = .idle
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

    private func hold(_ step: WriteStep, title: String, confirmLabel: String, email: String,
                      patch: @escaping @Sendable (GamUser) -> GamUser) async {
        guard !isBusy else { return }
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        switch await executor.preview([step]) {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, title: title, confirmLabel: confirmLabel, email: email, patch: patch))
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

    /// Back to the user page; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
