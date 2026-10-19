import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Searches of one person's mailbox from their page (GamGUI's "Search a mailbox"; docs/plans/2026-10-19-compromised-account.md
/// slice 3). Reads only. Each person's last search is kept for the tenant it was read on, the last few people at most, so
/// a page in another window keeps its own (invariant 9).
@MainActor
@Observable
public final class MailboxSearches {
    public enum State: Sendable {
        case searching(String)
        case found(String, Result<[MailboxSearch.Message], UserAccess.Problem>)

        public var query: String {
            switch self {
            case .searching(let query), .found(let query, _): query
            }
        }
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

    /// `email`'s last search, while it belongs to the connected tenant.
    public func state(for email: String) -> State? {
        kept.first { $0.email == email && $0.domain == setup.active && $0.generation == setup.generation }?.state
    }

    /// Searches `email`'s mailbox for `query`; a newer search of the same person replaces an older one still reading.
    public func search(_ email: String, query: String) async {
        guard let domain = setup.active else { return }
        let generation = setup.generation
        serial += 1
        let mine = serial
        store(Kept(email: email, domain: domain, generation: generation, serial: mine, state: .searching(query)))
        let result = await access.searchMailbox(of: email, query: query, in: domain)
        guard let current = kept.first(where: { $0.email == email && $0.domain == domain && $0.generation == generation }),
              current.serial == mine else { return }
        store(Kept(email: email, domain: domain, generation: generation, serial: mine, state: .found(query, result)))
    }

    private func store(_ entry: Kept) {
        kept.removeAll { ($0.email == entry.email && $0.domain == entry.domain && $0.generation == entry.generation)
            || $0.domain != setup.active || $0.generation != setup.generation }
        kept.insert(entry, at: 0)
        if kept.count > keep { kept.removeLast(kept.count - keep) }
    }
}
