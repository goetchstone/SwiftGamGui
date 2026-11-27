import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Reports' Forwarding & mail delegates (roadmap 3.2, GamGUI's `/reports/mail-review`): every active account's forwarding that
/// is on and every mail delegate, read only when the operator asks (one Gmail call per account, twice) and kept for the tenant
/// it was read on; a switch during the read keeps nothing. Reads only.
@MainActor
@Observable
public final class MailReviewRead {
    public enum State: Sendable {
        case reading
        case read(Result<MailReview, UserAccess.Problem>, at: Date)
    }

    /// Rows of each list a screen draws; the count says how many more (GamGUI's `MAIL_ROWS_SHOWN`, invariant 9).
    public nonisolated static let shown = 100

    private var kept: (state: State, domain: Domain, generation: Int, serial: Int)?
    private var serial = 0
    private let setup: SetupModel
    private let access: UserAccess

    public init(setup: SetupModel, access: UserAccess) {
        self.setup = setup
        self.access = access
    }

    /// The last read, while it belongs to the connected tenant.
    public var state: State? {
        guard let kept, kept.domain == setup.active, kept.generation == setup.generation else { return nil }
        return kept.state
    }

    public var isReading: Bool {
        if case .reading? = state { return true }
        return false
    }

    /// Reads both lists; a second read isn't started while one runs (GamGUI's: no second domain-wide read).
    public func read(now: @escaping @Sendable () -> Date = Date.init) async {
        guard let domain = setup.active, !isReading else { return }
        let generation = setup.generation
        serial += 1
        let mine = serial
        kept = (.reading, domain, generation, mine)
        let result = await access.mailReview(in: domain)
        guard kept?.serial == mine, setup.active == domain, setup.generation == generation else { return }
        kept = (.read(result, at: now()), domain, generation, mine)
    }
}
