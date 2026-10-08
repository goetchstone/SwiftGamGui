import GamEngine

/// Which users a list shows: GamGUI's `_filter_users`, over the loaded directory with no GAM call per
/// keystroke. The search is a case-insensitive substring of the address, name, title, department or
/// organizational unit.
public struct UserFilter: Equatable, Sendable {
    public enum Scope: String, CaseIterable, Sendable, Identifiable {
        case all = "All", active = "Active", suspended = "Suspended"
        public var id: Self { self }
    }

    public var scope: Scope
    public var query: String

    public init(scope: Scope = .all, query: String = "") {
        self.scope = scope
        self.query = query
    }

    public func matches(_ user: GamUser) -> Bool {
        switch scope {
        case .all: break
        case .active: if user.suspended { return false }
        case .suspended: if !user.suspended { return false }
        }
        let needle = PythonText.strip(query).lowercased()
        guard !needle.isEmpty else { return true }
        return [user.primaryEmail, user.fullName, user.title, user.department, user.orgUnitPath]
            .contains { $0.lowercased().contains(needle) }
    }

    public func apply(_ users: [GamUser]) -> [GamUser] {
        users.filter(matches)
    }
}
