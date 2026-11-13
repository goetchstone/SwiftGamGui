import ChangeCore
import GamEngine

/// Who a signature is set for: GamGUI's `match_scope` (`core/signatures.py`), for the scopes the operator asked for (one
/// person, a group's members, everyone in an org unit, the whole company). Active accounts only: a suspended account is
/// never in scope, as in GamGUI. GamGUI's department and location scopes aren't built here (nobody asked for them).
public enum SignatureScope: Sendable, Hashable {
    /// One person, by address (GamGUI's "Specific user (test)").
    case person(String)
    /// A group's members, read live when the preview is made.
    case group(String)
    /// An org unit's path: that unit and every unit inside it.
    case orgUnit(String)
    case company

    /// The kinds, for the screen's choice and what it keeps per window.
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case person, group, orgUnit, company

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .person: "One person"
            case .group: "A group's members"
            case .orgUnit: "Everyone in an org unit"
            case .company: "The whole company"
            }
        }
    }

    public init(kind: Kind, value: String) {
        switch kind {
        case .person: self = .person(value)
        case .group: self = .group(value)
        case .orgUnit: self = .orgUnit(value)
        case .company: self = .company
        }
    }

    public var kind: Kind {
        switch self {
        case .person: .person
        case .group: .group
        case .orgUnit: .orgUnit
        case .company: .company
        }
    }

    /// Whom a run's title names (GamGUI's `who`): "the whole company", else the value as the operator chose it, stripped.
    public var who: String {
        switch self {
        case .person(let value), .group(let value), .orgUnit(let value): PythonText.strip(value)
        case .company: "the whole company"
        }
    }

    /// GamGUI's `match_scope`: the active users in scope, in the directory's order. Only `company` means everyone: a
    /// scope with no value matches nobody (an empty choice once resolved to the whole company there). A person matches
    /// by address, any case; an org unit is its path exactly or any path under it. A group isn't matched here: its
    /// members are read (`match(_:members:)`), and GamGUI's `match_scope` matches nobody for it too.
    public static func match(_ users: [GamUser], _ scope: SignatureScope) -> [GamUser] {
        let active = users.filter { !$0.suspended }
        switch scope {
        case .person(let value):
            let address = PythonText.strip(value)
            guard !address.isEmpty else { return [] }
            let key = PythonText.lower(address)
            return active.filter { PythonText.lower($0.primaryEmail).unicodeScalars.elementsEqual(key.unicodeScalars) }
        case .orgUnit(let value):
            let path = PythonText.strip(value)
            guard !path.isEmpty else { return [] }
            // Python's `value.rstrip("/") + "/"`: "/" itself is every path under the root.
            let prefix = PythonText.rstrip(path, of: [0x2F]) + "/"
            return active.filter {
                $0.orgUnitPath.unicodeScalars.elementsEqual(path.unicodeScalars)
                    || $0.orgUnitPath.unicodeScalars.starts(with: prefix.unicodeScalars)
            }
        case .company:
            return active
        case .group:
            return []
        }
    }

    /// A group's scope (GamGUI's `_matched`): the active users whose address is one of its members', in the directory's
    /// order. A group inside it, the customer, a suspended or outside account: none is an active user, so none is set.
    /// Addresses compare in any case (GamGUI compared them exactly; Google prints both lowercased).
    public static func match(_ users: [GamUser], members: [GroupMember]) -> [GamUser] {
        let addresses = Set(members.map { scalars(Guard.normalized($0.email)) }.filter { !$0.isEmpty })
        return users.filter { !$0.suspended && addresses.contains(scalars(Guard.normalized($0.primaryEmail))) }
    }

    /// The org units to choose from (GamGUI's `scope_options` "ous"): every unit a user is in, suspended ones included,
    /// once each, in code-point order.
    public static func orgUnits(_ users: [GamUser]) -> [String] {
        Set(users.map(\.orgUnitPath).filter { !$0.isEmpty })
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// Whom "Retry the N that failed" previews (GamGUI's `/signatures/retry`): the active users whose address, lowercased,
    /// is one that failed, in the directory's order, and how many of those that failed aren't one any more.
    public static func retry(_ failed: [String], in users: [GamUser]) -> (people: [GamUser], gone: Int) {
        let failed = Set(failed.map { scalars(PythonText.lower($0)) })
        let people = users.filter { !$0.suspended && failed.contains(scalars(PythonText.lower($0.primaryEmail))) }
        return (people, failed.count - people.count)
    }

    /// Text as Python compares it, scalar by scalar: a Swift `String` set takes a decomposed "é" for the composed one.
    private static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }
}
