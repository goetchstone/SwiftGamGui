import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// A person's Chrome profiles, read from their page when the operator asks (`ChromeProfiles`). Reads only. Each person's
/// last read is kept for the tenant it was read on, the last few people at most (invariant 9), as `MailboxSearches` keeps
/// searches.
@MainActor
@Observable
public final class ChromeProfileReads {
    public enum State: Sendable {
        case reading
        case read(Result<[ChromeProfiles.Profile], UserAccess.Problem>)
    }

    private struct Kept {
        let email: String
        let domain: Domain
        let generation: Int
        let serial: Int
        let state: State
    }

    private var kept: [Kept] = []
    private var serial = 0
    private let keep: Int
    private let setup: SetupModel
    private let access: UserAccess

    public init(setup: SetupModel, access: UserAccess, keep: Int = 8) {
        self.setup = setup
        self.access = access
        self.keep = keep
    }

    /// `email`'s last read, while it belongs to the connected tenant.
    public func state(for email: String) -> State? {
        kept.first { $0.email == email && $0.domain == setup.active && $0.generation == setup.generation }?.state
    }

    /// Reads `email`'s Chrome profiles; a newer read of the same person replaces an older one still reading.
    public func read(_ email: String) async {
        guard let domain = setup.active else { return }
        let generation = setup.generation
        serial += 1
        let mine = serial
        store(Kept(email: email, domain: domain, generation: generation, serial: mine, state: .reading))
        let result = await access.chromeProfiles(of: email, in: domain)
        guard let current = kept.first(where: { $0.email == email && $0.domain == domain && $0.generation == generation }),
              current.serial == mine else { return }
        store(Kept(email: email, domain: domain, generation: generation, serial: mine, state: .read(result)))
    }

    private func store(_ entry: Kept) {
        kept.removeAll { ($0.email == entry.email && $0.domain == entry.domain && $0.generation == entry.generation)
            || $0.domain != setup.active || $0.generation != setup.generation }
        kept.insert(entry, at: 0)
        if kept.count > keep { kept.removeLast(kept.count - keep) }
    }
}
