import Foundation

/// GAM's three credential files. The raw values are the Keychain names GamGUI uses.
public enum Credential: String, CaseIterable, Sendable, Comparable {
    case clientSecrets = "client_secrets"
    case oauth2 = "oauth2"
    /// The service-account key: it can impersonate any user in the domain.
    case oauth2Service = "oauth2service"

    /// The file name GAM reads from `GAMCFGDIR`.
    public var fileName: String {
        switch self {
        case .clientSecrets: "client_secrets.json"
        case .oauth2: "oauth2.txt"
        case .oauth2Service: "oauth2service.json"
        }
    }

    /// What GAM needs before it can act as the domain.
    public static let required: [Credential] = [.oauth2Service, .oauth2]

    /// Removal order: the most dangerous first, so a refusal partway never leaves the
    /// impersonate-anyone key behind with the lesser credentials gone (GamGUI failure-log 2026-10-01).
    public static let removalOrder: [Credential] = [.oauth2Service, .oauth2, .clientSecrets]

    public static func < (lhs: Credential, rhs: Credential) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A Google Workspace domain, in its one canonical spelling. A capitalized domain was once kept as a
/// second tenant (GamGUI failure-log 2026-10-02), so every key goes through here.
public struct Domain: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let name: String

    public init?(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard (3...253).contains(name.count), name.contains("."),
              name.allSatisfy(allowed.contains),
              !name.hasPrefix("."), !name.hasSuffix("."), !name.hasPrefix("-"), !name.hasSuffix("-"),
              !name.contains("..")
        else { return nil }
        self.name = name
    }

    public var description: String { name }
    public static func < (lhs: Domain, rhs: Domain) -> Bool { lhs.name < rhs.name }
}

/// Credential bytes that never print, log, encode or `dump` their contents (invariant 4). The bytes are
/// `package`: code outside GamKit can create a secret and hand it to the Vault, but never read one.
public struct Secret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    package let bytes: Data

    public init(_ bytes: Data) {
        self.bytes = bytes
    }

    public var description: String { "<secret: \(bytes.count) bytes>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
