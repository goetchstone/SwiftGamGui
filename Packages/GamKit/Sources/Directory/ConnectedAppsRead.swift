import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Every account's connected apps and AI agents (`ConnectedApps`), read when the operator asks, kept for the tenant it was
/// read on. Reads only: an attacked account's apps are revoked by the lock's sign-out, and an app everyone should lose is
/// blocked in the Admin console.
@MainActor
@Observable
public final class ConnectedAppsRead {
    public enum State: Sendable {
        case reading
        case read(Result<[ConnectedApps.App], UserAccess.Problem>, at: Date)
    }

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

    /// Reads every account's apps; a newer read replaces one still reading.
    public func read(now: @escaping @Sendable () -> Date = Date.init) async {
        guard let domain = setup.active else { return }
        let generation = setup.generation
        serial += 1
        let mine = serial
        kept = (.reading, domain, generation, mine)
        let result = await access.connectedApps(in: domain)
        guard kept?.serial == mine, setup.active == domain, setup.generation == generation else { return }
        kept = (.read(result, at: now()), domain, generation, mine)
    }
}
