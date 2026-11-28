import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// A person's licenses from their page (GamGUI's `/users/licenses/*`, roadmap 4.3): the seats one read found, and an add, a
/// change or a removal offered only from that read. Each change is previewed from a fresh read and run once through ChangeCore.
///
/// - A **removal** is destructive (Google: "you might lose their data"), needs their address typed, and is refused while a data
///   transfer from them is unfinished or can't be checked, at the preview and again just before it runs. A transfer that failed
///   doesn't refuse: the preview names it.
/// - A **change** is within the same product; an **add** is a license someone in the domain holds, of a product they hold none of.
/// - Never `sync`, never `archive`.
@MainActor
@Observable
public final class LicenseChanges {
    public enum Kind: Sendable, Equatable {
        case add(Licenses.Seat)
        case change(from: Licenses.Seat, to: Licenses.Seat)
        case remove(Licenses.Seat)
    }

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
        public let email: String
        public let kind: Kind
        public let notes: [String]
        public var id: UUID { preview.id }
        public var typedAddress: String? { preview.typedAddress }
    }

    /// The last read of the seats, for the person it was read for.
    public private(set) var read: (email: String, result: Result<Licenses.Choices, UserAccess.Problem>)?
    public private(set) var isReading = false
    public private(set) var state: State = .idle
    /// The person the state is about.
    public private(set) var subject: String?
    private let executor: Executor?
    private let setup: SetupModel
    private let access: UserAccess
    private let now: @Sendable () -> Date
    /// The domain's seats, as the card last read them (GamGUI #196): a card opened person after person reads every seat in the
    /// domain once, not once a person. Kept `seatsKept`, for the tenant read; any licence write here drops them; a preview, and
    /// Read Again, always read fresh.
    private var seats: (domain: Domain, generation: Int, at: Date, seats: [Licenses.Seat])?
    public nonisolated static let seatsKept: TimeInterval = 5 * 60

    public init(executor: Executor?, setup: SetupModel, access: UserAccess, now: @escaping @Sendable () -> Date = Date.init) {
        self.executor = executor
        self.setup = setup
        self.access = access
        self.now = now
        setup.onTenantChange { [weak self] in
            guard let self, !self.isBusy else { return }
            self.seats = nil
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

    /// The seats for `email`'s card: the ones kept from the last read of the last `seatsKept`, unless `fresh` (Read Again).
    public func load(_ email: String, fresh: Bool = false) async {
        isReading = true
        defer { isReading = false }
        guard let tenant = access.tenant else {
            read = (email, .failure(UserAccess.Problem(summary: "Connect a domain on Setup first.")))
            return
        }
        if !fresh, let kept = seats, kept.domain == tenant.domain, kept.generation == tenant.generation,
           now().timeIntervalSince(kept.at) < Self.seatsKept {
            read = (email, .success(Licenses.choices(kept.seats, for: email)))
            return
        }
        let result = await access.licenses(in: tenant.domain)
        if case .success(let found) = result { seats = (tenant.domain, tenant.generation, now(), found) } else { seats = nil }
        read = (email, result.map { Licenses.choices($0, for: email) })
    }

    /// The card's choices for `email`, while they're the last read's.
    public func choices(for email: String) -> Result<Licenses.Choices, UserAccess.Problem>? {
        guard let read, Guard.normalized(read.email) == Guard.normalized(email) else { return nil }
        return read.result
    }

    public func preview(_ kind: Kind, for user: GamUser) async {
        guard !isBusy, let executor else { return }
        let email = user.primaryEmail
        subject = email
        guard let tenant = access.tenant else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        state = .checking
        // A fresh read: offered only what it finds, the seat still where the card saw it.
        let seats: [Licenses.Seat]
        switch await access.licenses(in: tenant.domain) {
        case .success(let read): seats = read
        case .failure(let problem):
            state = .problem("Couldn't read the licenses again, so nothing is offered. \(problem.summary)")
            return
        }
        let choices = Licenses.choices(seats, for: email)
        let heldKeys = Set(choices.held.map(\.seat.key))
        var notes: [String] = [Licenses.onlySeatsRead]
        let step: WriteStep, title: String, typed: String?
        var precondition: (@Sendable () async throws -> Bool)?
        do {
            switch kind {
            case .add(let seat):
                guard choices.adds.contains(where: { $0.key == seat.key }), seat.nameable else {
                    state = .problem("\(seat.sku) can't be added to \(email) now: read again.")
                    return
                }
                step = WriteStep(try GamCommands.addLicense(email: email, productID: seat.productID, skuID: seat.skuID), target: email,
                                 summary: "Give \(email) a \(seat.sku) license", about: ["sku": seat.skuID])
                title = "Add \(seat.sku) for \(email)"
                typed = nil
            case .change(let from, let to):
                guard heldKeys.contains(from.key), choices.held.first(where: { $0.seat.key == from.key })?.changes.contains(where: { $0.key == to.key }) == true,
                      from.nameable, to.nameable else {
                    state = .problem("That change isn't offered for \(email) now: read again.")
                    return
                }
                step = WriteStep(try GamCommands.swapLicense(email: email, productID: from.productID, oldSKUID: from.skuID, newSKUID: to.skuID),
                                 target: email, summary: "Change \(email)'s \(from.sku) license to \(to.sku)", about: ["sku": to.skuID])
                title = "Change \(email)'s license"
                typed = nil
            case .remove(let seat):
                guard heldKeys.contains(seat.key), seat.nameable else {
                    state = .problem("\(email) doesn't hold \(seat.sku) now: read again.")
                    return
                }
                let transfers = try? await access.dataTransfers(of: email).get()
                if let refusal = Licenses.transferRefusal(email, transfers) {
                    state = .problem(refusal)
                    return
                }
                let failed = Licenses.failedTransfers(transfers)
                if !failed.isEmpty {
                    notes.append("A data transfer from \(email) failed (\(failed.joined(separator: ", "))): what it was moving may still be "
                                 + "only on their account.")
                }
                notes += [Licenses.mightLoseData, Licenses.reassignWait]
                step = WriteStep(try GamCommands.removeLicense(email: email, productID: seat.productID, skuID: seat.skuID), target: email,
                                 summary: "Remove \(email)'s \(seat.sku) license", risk: .destructive, about: ["sku": seat.skuID])
                title = "Remove \(email)'s \(seat.sku) license"
                typed = email
                let access = access
                precondition = {
                    let now = try? await access.dataTransfers(of: email).get()
                    if let refusal = Licenses.transferRefusal(email, now) { throw PreconditionFailure(refusal) }
                    return true
                }
            }
        } catch {
            state = .problem("GAM can't be given that license's IDs, so it isn't offered.")
            return
        }
        let held = await executor.preview([step], confirmStep: true, expecting: tenant, typedAddress: typed, title: title,
                                          precondition: precondition)
        switch held {
        case .success(let preview): state = .previewing(Pending(preview: preview, email: email, kind: kind, notes: notes))
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
        seats = nil   // a seat may have moved: the next card reads them again
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        switch outcome.steps.first {
        case .succeeded?: state = .done("Done: \(pending.preview.steps.first?.summary ?? pending.preview.title).\(note)")
        case .failed(let message, let kind)?: state = .problem([kind?.remediation, message].compactMap { $0 }.joined(separator: " ") + note)
        case .skipped(let why)?, .waiting(let why)?: state = .problem(why + note)
        case nil: state = .problem("Nothing ran.")
        }
        if setup.isConnected(to: pending.preview) { await load(pending.email, fresh: true) }
    }

    /// The preview `email`'s page shows in its sheet: held or running.
    public func sheetPending(for email: String) -> Pending? {
        guard subject.map({ Guard.normalized($0) == Guard.normalized(email) }) == true else { return nil }
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
