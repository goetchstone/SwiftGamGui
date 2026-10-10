import GamEngine

/// Which users a list shows: GamGUI's `_filter_users`, over the loaded directory with no GAM call per
/// keystroke. The search is a case-insensitive substring of the address, name, title, department or
/// organizational unit, compared as Python compares: lowercased by `str.lower()` and matched scalar
/// by scalar. Swift's `contains` matches whole `Character`s, so "राम" wasn't found in "रामू", nor "i" in
/// "İpek" (PR #8's review).
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
        matches(user, needle: needle)
    }

    /// The query as it's compared: stripped and lowercased once, not once per user.
    private var needle: [Unicode.Scalar] {
        Array(PythonText.lower(PythonText.strip(query)).unicodeScalars)
    }

    private func matches(_ user: GamUser, needle: [Unicode.Scalar]) -> Bool {
        switch scope {
        case .all: break
        case .active: if user.suspended { return false }
        case .suspended: if !user.suspended { return false }
        }
        guard !needle.isEmpty else { return true }
        return [user.primaryEmail, user.fullName, user.title, user.department, user.orgUnitPath]
            .contains { Self.contains(Array(PythonText.lower($0).unicodeScalars), needle) }
    }

    static func contains(_ text: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard text.count >= needle.count else { return false }
        return (0...(text.count - needle.count)).contains { text[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    public func apply(_ users: [GamUser]) -> [GamUser] {
        let needle = needle
        return users.filter { matches($0, needle: needle) }
    }
}
