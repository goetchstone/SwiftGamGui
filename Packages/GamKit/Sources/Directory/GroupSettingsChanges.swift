import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// A group's settings from its page (GamGUI's Groups board, #182, roadmap 4.4): seven of Google's, read with `info group`. The
/// preview reads them again and holds only what changes; the run reads them once more just before it starts, refuses one changed
/// since, and writes only those. A setting the read left out offers nothing; Google's refusal is shown in its words.
@MainActor
@Observable
public final class GroupSettingsChanges {
    public enum State: Sendable {
        case idle
        case checking
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(String)
    }

    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let group: String
        public let changes: [GroupSettings.Change]
        public var id: UUID { preview.id }
    }

    /// The last read, for the group it was read for.
    public private(set) var read: (group: String, result: Result<[GroupSettings.Setting], UserAccess.Problem>)?
    public private(set) var isReading = false
    public private(set) var state: State = .idle
    public private(set) var subject: String?
    private let executor: Executor?
    private let setup: SetupModel
    private let access: UserAccess

    public init(executor: Executor?, setup: SetupModel, access: UserAccess) {
        self.executor = executor
        self.setup = setup
        self.access = access
        setup.onTenantChange { [weak self] in
            guard let self, !self.isBusy else { return }
            self.read = nil
            self.state = .idle
        }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    public func settings(of group: String) -> Result<[GroupSettings.Setting], UserAccess.Problem>? {
        guard let read, Guard.normalized(read.group) == Guard.normalized(group) else { return nil }
        return read.result
    }

    public func load(_ group: String) async {
        isReading = true
        defer { isReading = false }
        if GroupSettings.skipped(group) {
            read = (group, .failure(UserAccess.Problem(summary: "GAM doesn't read or change an abuse@ or postmaster@ group's settings.")))
            return
        }
        read = (group, await access.groupSettings(group))
    }

    /// Holds what `wanted` changes, from a fresh read.
    public func preview(_ group: String, wanted: [String: String]) async {
        guard !isBusy, let executor else { return }
        subject = group
        guard let tenant = access.tenant else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        state = .checking
        let now: [GroupSettings.Setting]
        switch await access.groupSettings(group, in: tenant.domain) {
        case .success(let read): now = read
        case .failure(let problem):
            state = .problem("Couldn't read \(group)'s settings again, so nothing is offered. \(problem.summary)")
            return
        }
        let changes: [GroupSettings.Change]
        do { changes = try GroupSettings.changes(now, wanted: wanted) } catch {
            state = .problem("That isn't a value offered here.")
            return
        }
        guard !changes.isEmpty else {
            state = .problem("Nothing to change: those are \(group)'s settings now.")
            return
        }
        let write: GamWrite
        do {
            write = try GamCommands.updateGroupSettings(group: group, changes: Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.new) }))
        } catch {
            state = .problem("GAM doesn't change \(group)'s settings.")
            return
        }
        let step = WriteStep(write, target: group, summary: changes.map { "\($0.label): \($0.before) → \($0.after)" }.joined(separator: "; "),
                             about: ["settings": changes.map { "\($0.key) \($0.new)" }.joined(separator: ", ")])
        let access = access
        let precondition: @Sendable () async throws -> Bool = {
            switch await access.groupSettings(group, in: tenant.domain) {
            case .failure(let problem): throw PreconditionFailure(problem.summary)
            case .success(let now):
                let moved = GroupSettings.moved(changes, now: now)
                if !moved.isEmpty {
                    throw PreconditionFailure("\(moved.joined(separator: ", ")) changed since the preview: preview again.")
                }
                return true
            }
        }
        let held = await executor.preview([step], confirmStep: true, expecting: tenant, title: "Change \(group)'s settings",
                                          precondition: precondition)
        switch held {
        case .success(let preview): state = .previewing(Pending(preview: preview, group: group, changes: changes))
        case .failure(let refusal): state = .problem(refusal.message)
        }
    }

    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        switch outcome.steps.first {
        case .succeeded?: state = .done("Changed \(pending.group)'s settings.\(note)")
        case .failed(let message, let kind)?:
            if let said = GroupSettings.googleSaid(message) {
                state = .problem("Google refused the change: \(said)\(note)")
            } else {
                state = .problem([kind?.remediation, message].compactMap { $0 }.joined(separator: " ") + note)
            }
        case .skipped(let why)?, .waiting(let why)?: state = .problem(why + note)
        case nil: state = .problem("Nothing ran.")
        }
        if setup.isConnected(to: pending.preview) { await load(pending.group) }
    }

    public func sheetPending(for group: String) -> Pending? {
        guard subject.map({ Guard.normalized($0) == Guard.normalized(group) }) == true else { return nil }
        switch state {
        case .previewing(let pending), .running(let pending): return pending
        default: return nil
        }
    }

    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
