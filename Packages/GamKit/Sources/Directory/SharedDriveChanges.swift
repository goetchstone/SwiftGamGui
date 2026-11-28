import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Shared drives screen (GamGUI's `/drives`, roadmap 4.7): find a drive, read its members fresh, and add a person or group
/// with a role, change a role, or remove one. Each change is previewed and runs only if the members read again just before it
/// still match (`SharedDrives.moved`). The last manager is never removed or demoted; a write GAM skips without a word reads as
/// failed (`GamWrite.notDone`). A members read that failed is unknown, never "no members".
@MainActor
@Observable
public final class SharedDriveChanges {
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
        public let change: SharedDrives.Change
        public var id: UUID { preview.id }
    }

    public private(set) var drives: Result<[SharedDrives.Drive], UserAccess.Problem>?
    public private(set) var members: (drive: String, result: Result<[SharedDrives.Member], UserAccess.Problem>)?
    public private(set) var isReading = false
    public private(set) var state: State = .idle
    private let executor: Executor?
    private let setup: SetupModel
    private let access: UserAccess

    public init(executor: Executor?, setup: SetupModel, access: UserAccess) {
        self.executor = executor
        self.setup = setup
        self.access = access
        setup.onTenantChange { [weak self] in
            guard let self, !self.isBusy else { return }
            self.drives = nil
            self.members = nil
            self.state = .idle
        }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    public func loadDrives() async {
        isReading = true
        defer { isReading = false }
        drives = await access.sharedDrives()
    }

    public func loadMembers(_ drive: SharedDrives.Drive) async {
        isReading = true
        defer { isReading = false }
        members = (drive.id, await access.driveMembers(drive.id))
    }

    public func members(of drive: SharedDrives.Drive) -> Result<[SharedDrives.Member], UserAccess.Problem>? {
        members?.drive == drive.id ? members?.result : nil
    }

    /// Plans a change from a fresh members read and holds it; the run reads the members once more.
    public func preview(_ drive: SharedDrives.Drive, action: SharedDrives.Action, email: String = "", kind: String = "",
                        role: String = "", memberID: String = "") async {
        guard !isBusy, let executor else { return }
        guard let tenant = access.tenant else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        state = .checking
        let now: [SharedDrives.Member]
        switch await access.driveMembers(drive.id, in: tenant.domain) {
        case .success(let read):
            now = read
            members = (drive.id, .success(read))
        case .failure(let problem):
            state = .problem("Couldn't read \(drive.name.isEmpty ? drive.id : drive.name)'s members again, so nothing is offered. \(problem.summary)")
            return
        }
        let change: SharedDrives.Change
        switch SharedDrives.plan(now, drive: drive, action: action, email: email, kind: kind, role: role, memberID: memberID) {
        case .success(let planned): change = planned
        case .failure(let why):
            state = .problem(why.reason)
            return
        }
        let write: GamWrite
        do { write = try change.write() } catch {
            state = .problem("That change can't be given to GAM.")
            return
        }
        let step = WriteStep(write, target: change.who, summary: change.question,
                             about: ["drive": "\(change.driveName) (\(change.driveID))", "role": change.newLabel])
        let access = access
        let precondition: @Sendable () async throws -> Bool = {
            switch await access.driveMembers(change.driveID, in: tenant.domain) {
            case .failure(let problem): throw PreconditionFailure(problem.summary)
            case .success(let again):
                if let why = SharedDrives.moved(change, members: again) { throw PreconditionFailure(why + " Preview again.") }
                return true
            }
        }
        let held = await executor.preview([step], confirmStep: true, expecting: tenant, title: change.question, precondition: precondition)
        switch held {
        case .success(let preview): state = .previewing(Pending(preview: preview, change: change))
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
        case .succeeded?: state = .done(pending.change.done + note)
        case .failed(let message, let kind)?: state = .problem([kind?.remediation, message].compactMap { $0 }.joined(separator: " ") + note)
        case .skipped(let why)?, .waiting(let why)?: state = .problem(why + note)
        case nil: state = .problem("Nothing ran.")
        }
        if setup.isConnected(to: pending.preview) {
            await loadMembers(SharedDrives.Drive(id: pending.change.driveID, name: pending.change.driveName))
        }
    }

    public var pending: Pending? {
        switch state {
        case .previewing(let pending), .running(let pending): pending
        default: nil
        }
    }

    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
