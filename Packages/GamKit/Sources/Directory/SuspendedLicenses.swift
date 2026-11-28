import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Remove licenses from suspended accounts (GamGUI's Reports Suspended card, #177; roadmap 3.3 and 4.3): the seats and the
/// directory read again, each seat on a suspended account held, one removal each through ChangeCore.
///
/// - Each person's data transfers are read at preview: one unfinished, failed or unread keeps every seat of theirs, listed with
///   why (`Licenses.manyRefusal`). Just before the run they are read again for everyone held; if any now refuses, nothing runs
///   and the operator previews again (GamGUI reads them as the job reaches each person; here the preview holds exactly what runs).
/// - Destructive ("you might lose their data"): a confirm always, the word typed at ten, the count typed past 25; in the jobs
///   tray with Stop; Retry the N that failed.
@MainActor
@Observable
public final class SuspendedLicenses {
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
        /// The seats held, in the steps' order.
        public let seats: [(email: String, seat: Licenses.Seat)]
        /// Who keeps their seats, and why.
        public let kept: [(email: String, why: String)]
        public var id: UUID { preview.id }
        public var count: Int { seats.count }
        public var needsWord: Bool { preview.decision.requiresTypedConfirmation }
        public var needsCount: Bool { preview.decision.requiresTypedCount }
    }

    public nonisolated static let shown = 200
    nonisolated static let failuresSaid = 5

    public private(set) var state: State = .idle
    public private(set) var typedProblem: String?
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let access: UserAccess

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, access: UserAccess) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.access = access
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    public func preview() async {
        guard !isBusy, let executor else { return }
        serial += 1
        let serial = serial
        typedProblem = nil
        guard let tenant = access.tenant else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        state = .checking
        let before = directory.revision
        await directory.load()
        let seatRead = await access.licenses(in: tenant.domain)
        guard serial == self.serial else { return }
        guard directory.problem == nil, let users = directory.users, directory.revision != before else {
            state = .problem("Couldn't read the directory again, so nothing is offered. " + (directory.problem?.summary ?? "Try again."))
            return
        }
        guard case .success(let seats) = seatRead else {
            if case .failure(let problem) = seatRead { state = .problem("Couldn't read the licenses again, so nothing is offered. \(problem.summary)") }
            return
        }
        let found = Licenses.onSuspended(seats, users: users).filter(\.seat.nameable)
        guard !found.isEmpty else {
            state = .done("Read again just now: no suspended account holds a license this read found. \(Licenses.onlySeatsRead)")
            return
        }
        var refusals: [String: String] = [:]
        for email in Set(found.map(\.email)) {
            let transfers = try? await access.dataTransfers(of: email).get()
            if let why = Licenses.manyRefusal(email, transfers) { refusals[email] = why }
        }
        guard serial == self.serial else { return }
        let held = found.filter { refusals[$0.email] == nil }
        let kept = refusals.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }.map { (email: $0.key, why: $0.value) }
        guard !held.isEmpty else {
            state = .problem("Every suspended account with a license keeps it: " + kept.map(\.why).joined(separator: " "))
            return
        }
        var steps: [WriteStep] = []
        for (email, seat) in held {
            guard let write = try? GamCommands.removeLicense(email: email, productID: seat.productID, skuID: seat.skuID) else { continue }
            steps.append(WriteStep(write, target: email, summary: "Remove \(email)'s \(seat.sku) license", risk: .destructive,
                                   about: ["sku": seat.skuID]))
        }
        let people = Array(Set(held.map(\.email)))
        let access = access
        let precondition: @Sendable () async throws -> Bool = {
            for email in people {
                let now = try? await access.dataTransfers(of: email).get()
                if let why = Licenses.manyRefusal(email, now) { throw PreconditionFailure(why + " Preview again.") }
            }
            return true
        }
        let n = steps.count
        let result = await executor.preview(steps, confirmStep: true, typedCountAbove: Guard.countConfirmAbove, expecting: tenant,
                                            title: "Remove \(n) license\(n == 1 ? "" : "s") from suspended accounts", precondition: precondition)
        guard serial == self.serial else {
            if case .success(let preview) = result { await executor.discard(preview.id) }
            return
        }
        switch result {
        case .success(let preview): state = .previewing(Pending(preview: preview, seats: held, kept: kept))
        case .failure(let refusal): state = .problem(refusal.message)
        }
    }

    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        if pending.needsWord, !Guard.normalized(confirmation.typedWord).utf8.elementsEqual(Guard.typedWord.utf8) {
            typedProblem = "Type confirm to remove them."
            return
        }
        if !pending.preview.decision.typedCountMatches(confirmation.typedCount) {
            typedProblem = "Type \(pending.count), the number of licenses, to confirm."
            return
        }
        typedProblem = nil
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        var removed = 0, failed: [String] = [], notRun = 0
        for (index, held) in pending.seats.enumerated() {
            switch index < outcome.steps.count ? outcome.steps[index] : nil {
            case .succeeded?: removed += 1
            case .failed(let message, let kind)?: failed.append("\(held.email) — \(held.seat.sku): \(kind?.remediation ?? message)")
            default: notRun += 1
            }
        }
        var words = "Removed \(removed) of \(pending.count) license\(pending.count == 1 ? "" : "s")."
        if notRun > 0 { words = "Stopped — \(notRun) not attempted. " + words }
        if !failed.isEmpty {
            words += " Not removed: " + failed.prefix(Self.failuresSaid).joined(separator: "; ")
                + (failed.count > Self.failuresSaid ? "; and \(failed.count - Self.failuresSaid) more" : "") + "."
        }
        words += outcome.auditProblem.map { " \($0)" } ?? ""
        state = failed.isEmpty && notRun == 0 ? .done(words) : .problem(words)
    }

    public func typingChanged() { typedProblem = nil }

    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        state = .idle
    }
}
