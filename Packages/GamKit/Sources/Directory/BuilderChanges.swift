import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Builder's curated writes (GamGUI's `/builder/preview` and `/builder/run`), through ChangeCore, one at a time: a command's
/// values built as GamGUI builds them (`CuratedCommand`), held by the executor exactly as it will run, confirmed from its sheet
/// (always a click, as GamGUI's Builder asks, `confirm_step=True`), run once and audited with the command it came from. Nothing
/// here runs `gam` itself; the Builder's reads run as its promoted ones do (`UserAccess.catalogRead`).
///
/// Checks GamGUI's Builder doesn't make, each where a run would lose something: the screens' own checks for the same write (a
/// delegate as Users checks one); the connected admin refused for a suspend or a random password (either signs the app out, with
/// no way back from here), as Users refuses its temporary password, by the account GAM itself resolves the address to (an alias
/// reads as its owner), read at the preview and again just before the run, and refused when it can't be read; and a title or
/// department left empty said before it's cleared (GAM sets both together).
@MainActor
@Observable
public final class BuilderChanges {
    public enum State: Sendable {
        case idle
        /// The preview the sheet shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(String)
    }

    /// A held preview with what the confirm sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        /// The command's id, so its page alone shows it.
        public let command: String
        public let title: String
        /// Something the operator should know before confirming.
        public let warning: String?

        public var id: UUID { preview.id }
        public var isDestructive: Bool { preview.decision.maxRisk == .destructive }
    }

    public private(set) var state: State = .idle
    /// The command the current state is about.
    public private(set) var subject: String?
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    /// Its own reader: whose account an address is, read live, never from a page's lists.
    private let access: UserAccess
    /// Counts previews asked for: one that comes back after a newer one was asked for is dropped, never shown on its page.
    private var asked = 0

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, access: UserAccess) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.access = access
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether the current state is about `command`.
    public func concerns(_ command: CuratedCommand) -> Bool { subject == command.id }

    /// The risk a command's write is held at: its own, which `WriteStep` never lets fall below the write's floor.
    nonisolated static func risk(_ command: CuratedCommand) -> Risk {
        switch command.risk {
        case .read: .readOnly
        case .change: .low
        case .destructive: .destructive
        }
    }

    // MARK: previews

    /// GamGUI's preview of a curated write: `values` built (refused in words when a field is missing or wrong), the checks above,
    /// then held for the domain connected now.
    public func preview(_ command: CuratedCommand, values: [String: String]) async {
        guard !isBusy else { return }
        // The tenant the screen's values were typed for, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        subject = command.id
        asked += 1
        let request = asked
        func refuse(_ text: String) {
            guard request == asked else { return }
            state = .problem(text)
        }
        let write: GamWrite
        do {
            guard case .write(let built) = try command.built(values) else {
                return refuse("\(command.name) only reads: run it instead.")
            }
            write = built
        } catch {
            guard case .argument(let why) = error else { return refuse("\(command.name) couldn't be built.") }
            return refuse(why + ".")
        }
        let target = command.target(values)
        func value(_ key: String) -> String { PythonText.strip(values[key] ?? "") }
        var warning: String?
        var precondition: (@Sendable () async throws -> Bool)?
        switch write.action {
        case .suspendUser, .resetPassword:
            guard let admin = setup.connectedAdmin, !admin.isEmpty else {
                return refuse("The admin this app signs in as isn't known. Check access on Setup, then preview again.")
            }
            guard let domain = tenant?.domain else { return refuse("Connect a domain on Setup first.") }
            do throws(PreconditionFailure) {
                if try await Self.isConnectedAdmin(target, admin: admin, in: domain, access: access) {
                    return refuse("\(target) is the admin this app is connected as: \(command.name.lowercased()) would sign the app out, "
                        + "with no way back from here. Do it in the Admin console, or from another admin's setup.")
                }
            } catch {
                return refuse(error.reason)
            }
            precondition = { [setup, access] in
                guard let admin = await setup.connectedAdmin, !admin.isEmpty else {
                    throw PreconditionFailure("The admin this app signs in as isn't known. Check access on Setup")
                }
                let isAdmin = try await Self.isConnectedAdmin(target, admin: admin, in: domain, access: access)
                return !isAdmin
            }
        case .addDelegate:
            let check = UserChanges.checkDelegate(value("delegate"), for: target, directory: directory.users)
            if let error = check.error { return refuse(error) }
            warning = check.warning
        case .updateOrganization:
            let empty = ["title", "department"].filter { value($0).isEmpty }
            guard !empty.isEmpty else { break }
            let them = empty.count == 1 ? "it" : "them", named = empty.joined(separator: " and ")
            if let user = directory.users?.first(where: { Guard.normalized($0.primaryEmail) == Guard.normalized(target) }) {
                let cleared = empty.filter { !($0 == "title" ? user.title : user.department).isEmpty }
                if !cleared.isEmpty {
                    let it = cleared.count == 1 ? "it" : "them"
                    warning = "GAM sets the title and department together: this clears \(target)'s \(cleared.joined(separator: " and ")). "
                        + "Fill \(it) in to keep \(it)."
                }
            } else {
                warning = "GAM sets the title and department together, and \(target) isn't in the directory as read: if they have a "
                    + "\(named), this clears \(them)."
            }
        default:
            break
        }
        guard let executor else {
            return refuse("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
        }
        let step = WriteStep(write, target: target, summary: "\(command.name): \(target)", risk: Self.risk(command),
                             about: ["command": command.id])
        let held = await executor.preview([step], confirmStep: true, expecting: tenant, title: "\(command.name) for \(target)",
                                          precondition: precondition)
        guard request == asked else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, command: command.id, title: command.name, warning: warning))
        case .failure(let refusal):
            refuse(refusal.message)
        }
    }

    /// `address` is `admin`'s account: the same address, or one GAM resolves to it (`info user`, read now on `domain`: an alias
    /// reads as the account that owns it). Throws when GAM can't say whose account it is: nothing is refused on a guess.
    nonisolated static func isConnectedAdmin(_ address: String, admin: String, in domain: Domain,
                                             access: UserAccess) async throws(PreconditionFailure) -> Bool {
        if Guard.normalized(address) == Guard.normalized(admin) { return true }
        let primary: String
        do {
            primary = try await access.account(address, in: domain, fields: ["primaryEmail"]).primaryEmail
        } catch let problem as UserAccess.Problem {
            throw PreconditionFailure("Couldn't check whose account \(address) is (\(problem.summary)), so it isn't changed.")
        } catch {
            throw PreconditionFailure("Couldn't check whose account \(address) is, so it isn't changed.")
        }
        guard !primary.isEmpty else { throw PreconditionFailure("GAM didn't say whose account \(address) is, so it isn't changed.") }
        return Guard.normalized(primary) == Guard.normalized(admin)
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows. `confirmation` is what the operator gave; the
    /// executor decides whether it's enough.
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
        case .succeeded:
            state = .done("Done: \(pending.preview.steps.first?.summary ?? pending.title).\(note)")
        case .failed(let message, let kind):
            state = .problem([message, kind?.remediation].compactMap { $0 }.joined(separator: " ") + note)
        case .skipped(let reason), .waiting(let reason):
            state = .problem(reason + note)
        case nil:
            state = .problem("Nothing ran.")
        }
    }

    /// Back to the command; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
