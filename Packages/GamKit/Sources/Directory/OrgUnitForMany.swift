import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Move many people to an org unit (GamGUI's `/users/bulk-ou`, roadmap 4.2; the mechanism of a department for many, 2.1).
///
/// - **The unit** is read again at preview (`UserAccess.orgUnits`): one the tree doesn't hold is refused, as GAM would.
/// - **Who**: a group's USER members (read live; a nested group and the whole-organization member aren't expanded, and the
///   preview says so) or pasted addresses, matched to the cached directory, **suspended accounts included** (moving a leaver to
///   a holding unit is the common case). Addresses with no account are listed.
/// - One `update org <unit> move user <email>` a person through the executor: a confirm always, the count typed past 25; in the
///   jobs tray and here with Stop; an account-wide failure stops it; Retry the N that failed.
@MainActor
@Observable
public final class OrgUnitForMany {
    public enum State: Sendable {
        case idle
        case checking
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(String)
    }

    public enum Who: Sendable, Hashable {
        case group(String)
        case pasted(String)
    }

    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let orgUnit: String
        public let people: [GamUser]
        public let isRetry: Bool
        /// Addresses with no account here (the first `shownMissing`), and how many.
        public let missing: [String]
        public let missingCount: Int
        /// The group's nested groups, and whether it holds the whole organization: not expanded, said.
        public let nested: [String]
        public let everyone: Bool
        public var id: UUID { preview.id }
        public var count: Int { people.count }
        public var needsCount: Bool { preview.decision.requiresTypedCount }
    }

    public struct Done: Sendable {
        public let message: String
        public let failures: [String]
        public let failedCount: Int
        public let partial: Bool
        public let retry: Retry?
    }

    public struct Retry: Sendable {
        public let orgUnit: String
        public let failed: [String]
        let domain: Domain
        let generation: Int
    }

    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var applied = 0
        public var failed = 0
        public var stopping = false
        public var done: Int { applied + failed }
        public init(total: Int) { self.total = total }
    }

    public nonisolated static let shown = 200
    public nonisolated static let shownMissing = 50
    public nonisolated static let failuresKept = 200

    public private(set) var state: State = .idle
    public private(set) var progress: Progress?
    public private(set) var typedProblem: String?
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

    /// The directory's accounts among `wanted` (suspended ones too), in address order, and the addresses it has none for.
    nonisolated static func people(_ users: [GamUser], wanted: Set<String>) -> (people: [GamUser], missing: [String]) {
        var byEmail: [String: GamUser] = [:]
        for user in users { byEmail[PythonText.lower(user.primaryEmail)] = user }
        let sorted = wanted.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        return (sorted.compactMap { byEmail[$0] }, sorted.filter { byEmail[$0] == nil })
    }

    public func preview(orgUnit: String, who: Who) async {
        guard !isBusy else { return }
        serial += 1
        let serial = serial
        typedProblem = nil
        let orgUnit = PythonText.strip(orgUnit)
        guard !orgUnit.isEmpty else {
            state = .problem("Pick the org unit to move them to first.")
            return
        }
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard let tenant else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        guard let users = directory.users else {
            state = .problem("Load the directory on Users first.")
            return
        }
        state = .checking
        let failed = "Couldn't read the org units, the group or the directory, so nothing is offered. "
        let paths = await access.orgUnits(in: tenant.domain)
        guard serial == self.serial else { return }
        switch paths {
        case .failure(let problem):
            state = .problem(failed + problem.summary)
            return
        case .success(let units) where !units.contains(orgUnit):
            state = .problem("“\(orgUnit)” isn't an org unit here: pick one from the list.")
            return
        case .success: break
        }
        var wanted: Set<String>, nested: [String] = [], everyone = false
        switch who {
        case .pasted(let text):
            wanted = DepartmentForMany.pasted(text)
            guard !wanted.isEmpty else {
                state = .problem("Pick a group or paste the addresses to move first.")
                return
            }
        case .group(let group):
            let group = PythonText.strip(group)
            guard !group.isEmpty, let runner else {
                state = .problem("Pick a group or paste the addresses to move first.")
                return
            }
            let read = GamCommands.printGroupMembers(group: group)
            let members: [GroupMember]
            do {
                let result = try await runner.run(read, as: tenant.domain, extraEnvironment: environment)
                guard serial == self.serial else { return }
                guard result.exitCode == 0, !result.stdoutTruncated else {
                    let why = result.exitCode == 0 ? "\(group) has more members than one call can return."
                        : GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv).remediation
                    state = .problem(failed + why)
                    return
                }
                members = GamOutput.records(result.stdout).map(GroupMember.init(record:))
            } catch {
                state = .problem(failed + DirectoryStore.problem(for: error, argv: read.argv).summary)
                return
            }
            guard !members.isEmpty else {
                state = .problem("\(group) has no members, read just now: nobody to move.")
                return
            }
            wanted = Set(members.filter { $0.memberType == "USER" && !$0.email.isEmpty }.map { PythonText.lower($0.email) })
            nested = Set(members.filter { $0.memberType == "GROUP" && !$0.email.isEmpty }.map { PythonText.lower($0.email) }).sorted()
            everyone = members.contains { !["USER", "GROUP"].contains($0.memberType) || $0.email.isEmpty }
        }
        let (people, missing) = Self.people(users, wanted: wanted)
        await hold(people, orgUnit: orgUnit, isRetry: false, missing: missing, nested: nested, everyone: everyone,
                   expecting: tenant, serial: serial)
    }

    public func previewRetry(_ retry: Retry) async {
        guard !isBusy else { return }
        serial += 1
        guard let users = directory.users else {
            state = .problem("Load the directory on Users first.")
            return
        }
        let (people, missing) = Self.people(users, wanted: Set(retry.failed.map { PythonText.lower($0) }))
        await hold(people, orgUnit: retry.orgUnit, isRetry: true, missing: missing, nested: [], everyone: false,
                   expecting: (retry.domain, retry.generation), serial: serial)
    }

    private func hold(_ people: [GamUser], orgUnit: String, isRetry: Bool, missing: [String], nested: [String], everyone: Bool,
                      expecting: (domain: Domain, generation: Int), serial: Int) async {
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        guard !people.isEmpty else {
            state = .problem(missing.isEmpty ? "Nobody to move." : "None of them has an account here: nobody to move.")
            return
        }
        let steps = people.map {
            WriteStep(GamCommands.moveUserToOrgUnit(orgUnit: orgUnit, email: $0.primaryEmail), target: $0.primaryEmail,
                      summary: "Move \($0.primaryEmail) from \($0.orgUnitPath.isEmpty ? "?" : $0.orgUnitPath) to \(orgUnit)",
                      about: ["org_unit": orgUnit])
        }
        let n = people.count, whom = "\(n) \(n == 1 ? "person" : "people")"
        let held = await executor.preview(steps, confirmStep: true, typedCountAbove: Guard.countConfirmAbove, expecting: expecting,
                                          title: isRetry ? "Move \(whom) to \(orgUnit), retried" : "Move \(whom) to \(orgUnit)")
        guard serial == self.serial else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, orgUnit: orgUnit, people: people, isRetry: isRetry,
                                        missing: Array(missing.prefix(Self.shownMissing)), missingCount: missing.count,
                                        nested: nested, everyone: everyone))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        if !pending.preview.decision.typedCountMatches(confirmation.typedCount) {
            typedProblem = "Type \(pending.count), the number of people, to confirm."
            return
        }
        typedProblem = nil
        state = .running(pending)
        progress = Progress(total: pending.count)
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (_, result) in events {
                switch result {
                case .succeeded: self?.progress?.applied += 1
                case .failed, .waiting: self?.progress?.failed += 1
                case .skipped: break
                }
            }
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        progress = nil
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        let (domain, generation) = (pending.preview.domain, pending.preview.generation)
        // Once for the whole run, not once a person (GamGUI #196).
        let moved = zip(pending.people, outcome.steps).filter { $0.1.isSucceeded }.map { $0.0.primaryEmail }
        directory.patchMany(moved, on: domain, generation: generation) { $0.with(orgUnitPath: pending.orgUnit) }
        if outcome.steps.count < pending.count || !outcome.steps.allSatisfy(\.isSucceeded), setup.isConnected(to: pending.preview) {
            let directory = directory
            Task { await directory.load() }
        }
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        state = .done(Self.done(pending, outcome.steps, note: outcome.auditProblem.map { " \($0)" } ?? ""))
    }

    nonisolated static func done(_ pending: Pending, _ steps: [RunOutcome.Step], note: String) -> Done {
        var moved = 0, failures: [String] = [], failed: [String] = [], notRun = 0, stoppedBy: String?
        for (index, person) in pending.people.enumerated() {
            switch index < steps.count ? steps[index] : nil {
            case .succeeded?: moved += 1
            case .skipped(let reason)?:
                notRun += 1
                if stoppedBy == nil { stoppedBy = reason }
            case nil: notRun += 1
            case .failed(let message, let kind)?:
                failed.append(person.primaryEmail)
                if failures.count < failuresKept { failures.append("\(person.primaryEmail) \u{2014} \(kind?.remediation ?? message)") }
            case .waiting(let message)?:
                failed.append(person.primaryEmail)
                if failures.count < failuresKept { failures.append("\(person.primaryEmail) \u{2014} \(message)") }
            }
        }
        let total = pending.count
        var message = "Moved \(moved) of \(total) \(total == 1 ? "person" : "people") to \(pending.orgUnit)."
        if notRun > 0 {
            let why = stoppedBy == Executor.stopped || stoppedBy == nil ? "Stopped by you \u{2014} \(notRun) not attempted."
                : "\(stoppedBy!) The remaining \(notRun) \(notRun == 1 ? "was" : "were") not attempted."
            message = "\(why) " + message
        }
        let retry = failed.isEmpty ? nil : Retry(orgUnit: pending.orgUnit, failed: failed, domain: pending.preview.domain,
                                                 generation: pending.preview.generation)
        return Done(message: message + note, failures: failures, failedCount: failed.count, partial: notRun > 0 || !failed.isEmpty,
                    retry: retry)
    }

    public func stop() async {
        guard case .running(let pending) = state, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        progress?.stopping = true
    }

    public func typingChanged() { typedProblem = nil }

    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        state = .idle
    }
}
