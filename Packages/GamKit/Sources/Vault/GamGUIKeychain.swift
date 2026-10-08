import Foundation
import Security

/// Reads the credentials the Python GamGUI already stored, so Setup can copy them once (the operator's
/// original files may be gone: GamGUI wipes files it staged itself). GamGUI's items live in the legacy
/// login keychain through `keyring`: the index at service `gamgui`, account `_domains` (a JSON list of
/// domain spellings), and each credential at service `gamgui:<domain>`, account `oauth2service` /
/// `oauth2` / `client_secrets`. macOS asks the operator to Allow each read; nothing here writes to,
/// or deletes, GamGUI's items.
public struct GamGUIKeychain: Sendable {
    public typealias Reader = @Sendable (_ service: String, _ account: String) throws -> Data?

    /// A domain as GamGUI spelled it (the key to its items) and its canonical form (our key).
    public struct Entry: Sendable, Equatable {
        public let spelling: String
        public let domain: Domain
    }

    private let read: Reader

    public init(read: @escaping Reader = GamGUIKeychain.legacyRead) {
        self.read = read
    }

    /// The domains GamGUI lists. Case twins (`Example.com` beside `example.com`, GamGUI failure-log
    /// 2026-10-02) both appear, each with its own spelling, and map to one canonical domain.
    public func entries() throws -> [Entry] {
        guard let data = try read("gamgui", "_domains"),
              let spellings = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return spellings.compactMap { spelling in Domain(spelling).map { Entry(spelling: spelling, domain: $0) } }
    }

    /// The credentials GamGUI stored under `entry`'s exact spelling.
    public func credentials(for entry: Entry) throws -> [Credential: Data] {
        var found: [Credential: Data] = [:]
        for credential in Credential.allCases {
            if let data = try read("gamgui:\(entry.spelling)", credential.rawValue), !data.isEmpty {
                found[credential] = data
            }
        }
        return found
    }

    /// A legacy-keychain read: nil only for "no such item", every other status throws.
    public static let legacyRead: Reader = { service, account in
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw VaultError.keychain(status)
        }
    }
}
