import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Close Out (roadmap 4.5, plan D2; GamGUI's `/lifecycle/closeout`): a section of Offboard for after the transfer has
/// finished. Check reads what the leaver still has (`CloseOut.Found`); Preview reads it all again, matches the picks to it,
/// and holds the steps through ChangeCore; Run reads the transfer and the leaver again (the preview's `precondition`), then
/// runs exactly the held steps.
///
/// - The connected admin is refused by account ID, asked as the account's suspend would be (`Executor`'s cut-off check), so
///   an alias or a renamed admin reads as the account behind it.
/// - The delete isn't here: it is the person page's delete zone, with its own refusals.
/// - Each step is destructive and needs the leaver's address typed; none waits on another. An alias move reads the alias as
///   theirs again right before it (`KeepFirst.aliasOf`).
@MainActor
@Observable
public final class CloseOutChanges {
    public enum State: Sendable {
        case idle
        case checking
        /// What the check found; nothing is held.
        case checked(CloseOut.Found)
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(String)
    }

    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let user: String
        public let manager: String
        public let steps: [CloseOut.Step]
        public let failedTransfers: [String]
        public var id: UUID { preview.id }
    }

    public struct Done: Sendable {
        public let message: String
        public let failures: [String]
        public let partial: Bool
    }

    static let tryAgain = "Try again in a moment."

    public private(set) var state: State = .idle
    var environment: [String: String] = [:]
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let access: UserAccess
    private let runner: AuthenticatedRunner?

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, access: UserAccess, runner: AuthenticatedRunner?) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.access = access
        self.runner = runner
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    // MARK: reading

    /// The account `typed` is, read now with `CloseOut.recordFields`, or why not.
    private func account(_ typed: String, in domain: Domain) async -> Result<GamUser, Problem> {
        let typed = PythonText.strip(typed)
        guard !typed.isEmpty else { return .failure(Problem("Type the leaver's address first.")) }
        guard let runner else { return .failure(Problem("Connect a domain on Setup first.")) }
        let read = GamCommands.infoUser(email: typed, fields: CloseOut.recordFields)
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            guard result.exitCode == 0 else {
                let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
                if error.kind == .notFound { return .failure(Problem("\(typed) isn't an account here.")) }
                return .failure(Problem("Couldn't read \(typed)'s account. \(error.remediation)"))
            }
            let user = GamUser(record: GamOutput.one(result.stdout))
            guard !user.primaryEmail.isEmpty else { return .failure(Problem("Couldn't read \(typed)'s account. \(Self.tryAgain)")) }
            guard PythonText.lower(user.primaryEmail) == PythonText.lower(typed) else {
                return .failure(Problem("\(typed) is an alias of \(user.primaryEmail): close out \(user.primaryEmail)."))
            }
            return .success(user)
        } catch {
            return .failure(Problem("Couldn't read \(typed)'s account. \(DirectoryStore.problem(for: error, argv: read.argv).summary)"))
        }
    }

    struct Problem: Error {
        let words: String
        init(_ words: String) { self.words = words }
    }

    /// Why `user` can't be closed out because it may be the admin this app signs in as, or nil: by account ID (an alias or a
    /// renamed admin reads as the account behind it), and an admin this app can't confirm refuses too (GamGUI's
    /// `_own_account`). The held preview guards `user` the same way at the run (`guarding:`), whatever is picked.
    private func ownAccount(_ user: String, expecting: (domain: Domain, generation: Int)) async -> String? {
        guard let executor else { return "This build has no GAM." }
        return await executor.lockout(of: user, in: expecting.domain)
    }

    /// Everything Close Out offers for `user`'s account, each read on its own: one that fails is said and offers nothing.
    private func found(_ record: GamUser, in domain: Domain) async -> CloseOut.Found {
        var found = CloseOut.Found(user: record.primaryEmail)
        found.orgUnit = record.orgUnitPath
        found.suspended = record.suspended
        if case .bool(let archived)? = record.record["archived"] { found.archived = archived }
        found.aliases = record.aliases
        found.transfers = try? await access.dataTransfers(of: found.user).get()
        guard found.refusal == nil else { return found }
        let user = found.user
        async let groups = access.closeOutGroups(of: user, in: domain)
        async let roles = access.closeOutRoles(of: user, in: domain)
        async let units = access.orgUnits(in: domain)
        async let seats = access.licenses(in: domain)
        let (g, r, u, s) = await (groups, roles, units, seats)
        func unread(_ words: String, _ problem: UserAccess.Problem) -> String {
            "Couldn't read \(user)'s \(words), so none are offered. \(problem.summary)"
        }
        switch g { case .success(let value): found.groups = value; case .failure(let p): found.unread["groups"] = unread("groups", p) }
        switch r { case .success(let value): found.roles = value; case .failure(let p): found.unread["roles"] = unread("admin roles", p) }
        switch u { case .success(let value): found.units = value; case .failure(let p): found.unread["units"] = unread("org units", p) }
        switch s {
        case .success(let value): found.seats = Licenses.held(value, by: user)
        case .failure(let p): found.unread["seats"] = unread("licenses", p)
        }
        return found
    }

    /// The read for one check or preview: the account, the connected-admin refusal, then everything.
    private func read(_ typed: String) async -> Result<CloseOut.Found, Problem> {
        guard let tenant = setup.active.map({ (domain: $0, generation: setup.generation) }) else {
            return .failure(Problem("Connect a domain on Setup first."))
        }
        switch await account(typed, in: tenant.domain) {
        case .failure(let problem): return .failure(problem)
        case .success(let record):
            if let why = await ownAccount(record.primaryEmail, expecting: tenant) { return .failure(Problem(why)) }
            return .success(await found(record, in: tenant.domain))
        }
    }

    /// Check: what `typed`'s account still has. Writes nothing and holds nothing.
    public func check(_ typed: String) async {
        guard !isBusy else { return }
        serial += 1
        let serial = serial
        state = .checking
        let result = await read(typed)
        guard serial == self.serial else { return }
        switch result {
        case .success(let found): state = .checked(found)
        case .failure(let problem): state = .problem(problem.words)
        }
    }

    // MARK: previewing

    /// Why the aliases can't go to `manager`, or nil (GamGUI's `_manager`).
    private func managerProblem(_ manager: String, user: String, in domain: Domain) async -> String? {
        guard let runner else { return "Connect a domain on Setup first." }
        let read = GamCommands.infoUser(email: manager, fields: ["primaryEmail"])
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            guard result.exitCode == 0 else {
                let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
                if error.kind == .notFound { return "\(manager) isn't an account here, so the aliases have nowhere to go." }
                return "Couldn't read \(manager)'s account. \(error.remediation)"
            }
            let primary = GamUser(record: GamOutput.one(result.stdout)).primaryEmail
            guard !primary.isEmpty else { return "Couldn't read \(manager)'s account. \(Self.tryAgain)" }
            if PythonText.lower(primary) != PythonText.lower(manager) { return "\(manager) is an alias of \(primary): move the aliases to \(primary)." }
            if PythonText.lower(primary) == PythonText.lower(user) { return "The aliases are moved to someone else: name the manager." }
            return nil
        } catch {
            return "Couldn't read \(manager)'s account. \(DirectoryStore.problem(for: error, argv: read.argv).summary)"
        }
    }

    /// Preview: everything read again, the picks matched to it, and the steps held. Nothing runs.
    public func preview(_ typed: String, _ asked: CloseOut.Asked, manager: String) async {
        guard !isBusy, let executor else { return }
        serial += 1
        let serial = serial
        guard let tenant = setup.active.map({ (domain: $0, generation: setup.generation) }) else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        state = .checking
        let read = await read(typed)
        guard serial == self.serial else { return }
        let found: CloseOut.Found
        switch read {
        case .failure(let problem):
            state = .problem(problem.words)
            return
        case .success(let value): found = value
        }
        if let refusal = found.refusal {
            state = .problem(refusal)
            return
        }
        // A pick in a section whose read failed is unread, never "changed".
        let picked: [String: Bool] = ["groups": !asked.groups.isEmpty, "roles": !asked.roles.isEmpty,
                                      "units": !PythonText.strip(asked.orgUnit).isEmpty, "seats": !asked.seats.isEmpty]
        let unread = ["groups", "roles", "units", "seats"].compactMap { picked[$0] == true ? found.unread[$0] : nil }
        guard unread.isEmpty else {
            state = .problem(unread.joined(separator: " ") + " Nothing is held: check again.")
            return
        }
        let (picks, stale) = CloseOut.pick(found, asked)
        guard stale.isEmpty else {
            state = .problem("\(found.user) changed since the check (\(stale.joined(separator: ", ")) isn't as it was): check again.")
            return
        }
        let manager = PythonText.strip(manager)
        if !picks.aliases.isEmpty, let why = await managerProblem(manager, user: found.user, in: tenant.domain) {
            guard serial == self.serial else { return }
            state = .problem(why)
            return
        }
        let steps: [CloseOut.Step]
        do { steps = try CloseOut.steps(found.user, picks, manager: manager) } catch {
            state = .problem("Couldn't plan this: \(error.reason).")
            return
        }
        guard !steps.isEmpty else {
            state = .problem("Nothing is picked: there is nothing to run.")
            return
        }
        let writes = steps.map { step in
            WriteStep(step.write, target: found.user, summary: step.summary, risk: .destructive,
                      about: step.alias.map { ["alias": $0, "to": manager] } ?? [:],
                      keepFirst: step.alias.map { .aliasOf(email: found.user, alias: $0) })
        }
        let user = found.user, aliases = picks.aliases, access = access, domain = tenant.domain
        // GamGUI's `_still_the_same`, right before the first write: the transfer, and the aliases and the manager.
        let precondition: @Sendable () async throws -> Bool = { [weak self] in
            let transfers = try? await access.dataTransfers(of: user).get()
            if let refusal = CloseOut.transferRefusal(user, transfers) { throw PreconditionRefusal("\(refusal) Nothing ran.") }
            guard !aliases.isEmpty else { return true }
            guard let self else { return false }
            switch await self.account(user, in: domain) {
            case .failure(let problem): throw PreconditionFailure("Couldn't read \(user) again (\(problem.words)), so nothing ran.")
            case .success(let record):
                let mine = Set(record.aliases.map { PythonText.lower($0) })
                let gone = aliases.filter { !mine.contains(PythonText.lower($0)) }
                if !gone.isEmpty {
                    throw PreconditionRefusal("\(gone.joined(separator: ", ")) isn't \(user)'s alias any more, so nothing ran. Check again.")
                }
            }
            if let why = await self.managerProblem(manager, user: user, in: domain) { throw PreconditionRefusal("\(why) Nothing ran.") }
            return true
        }
        let held = await executor.preview(writes, confirmStep: true, expecting: tenant, typedAddress: user,
                                          title: "Closing out \(user)", precondition: precondition, guarding: [user])
        guard serial == self.serial else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, user: user, manager: manager, steps: steps, failedTransfers: found.failedTransfers))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    // MARK: running

    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        // Suspended, the org unit and the aliases changed: the list mustn't keep the old ones.
        if setup.isConnected(to: pending.preview) {
            let directory = directory
            Task { await directory.load() }
        }
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        state = .done(Self.done(pending, outcome.steps, began: outcome.began, note: outcome.auditProblem.map { " \($0)" } ?? ""))
    }

    /// Each step's result: done, or why not; a failed alias move GAM was launched for (`began`) says the alias may be on
    /// nobody, since the add may have failed after the delete. One refused before it began moved nothing.
    nonisolated static func done(_ pending: Pending, _ steps: [RunOutcome.Step], began: Set<Int>, note: String) -> Done {
        var done = 0, failures: [String] = []
        for (index, step) in pending.steps.enumerated() {
            switch index < steps.count ? steps[index] : nil {
            case .succeeded?: done += 1
            case .failed(let message, let kind)?:
                var why = kind.map { $0 == .unknown ? message : $0.remediation } ?? message
                // The check before the move refused it: nothing moved. Otherwise the move itself failed, maybe after the delete.
                if let alias = step.alias, began.contains(index) {
                    why = CloseOut.aliasMayBeOnNobody(alias, user: pending.user, manager: pending.manager) + " " + why
                }
                failures.append("\(step.label) \u{2014} \(why)")
            case .waiting(let message)?: failures.append("\(step.label) \u{2014} \(message)")
            case .skipped(let reason)?: failures.append("\(step.label) \u{2014} \(reason)")
            case nil: failures.append("\(step.label) \u{2014} Not run.")
            }
        }
        let total = pending.steps.count
        return Done(message: "Closed out \(pending.user): \(done) of \(total) step\(total == 1 ? "" : "s") done." + note,
                    failures: failures, partial: done < total)
    }

    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        state = .idle
    }
}
