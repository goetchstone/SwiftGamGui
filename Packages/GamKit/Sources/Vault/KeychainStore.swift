import Foundation
import LocalAuthentication
import Security
import Synchronization

/// Credentials in the data-protection Keychain: this device only, never synced, each item behind a
/// user-presence check (Touch ID or the login password). Needs a team-signed, provisioned build
/// (`Config/GamGUI-Team.entitlements`); an ad-hoc build gets `errSecMissingEntitlement` (-34018).
///
/// One `LAContext` is shared until `endSession()`, so a single authentication covers a burst of reads
/// instead of a prompt per item. Calls block while a prompt is up: never call this on the main thread.
public final class KeychainStore: SecretStore {
    public static let defaultService = "swiftgamgui"

    public let service: String
    private let context: Mutex<LAContext>

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
        context = Mutex(Self.newContext())
    }

    private static func newContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = "use your Google Workspace credentials"
        return context
    }

    private func query(_ credential: Credential, _ domain: Domain) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(domain.name)/\(credential.rawValue)",
            kSecUseDataProtectionKeychain: true,
        ]
    }

    package func read(_ credential: Credential, for domain: Domain) throws -> Data? {
        let service = service
        let account = "\(domain.name)/\(credential.rawValue)"
        // Inside the lock: the shared context is used by one Keychain call at a time (two reads can't
        // race to show two prompts), and it never leaves the lock — so the query is built here too.
        let (status, result) = context.withLock { context -> (OSStatus, Data?) in
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecUseDataProtectionKeychain: true,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecUseAuthenticationContext: context,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }
        switch status {
        case errSecSuccess: return result
        case errSecItemNotFound: return nil
        default: throw VaultError.keychain(status)
        }
    }

    package func write(_ data: Data, as credential: Credential, for domain: Domain) throws {
        try index(domain)
        if try update(data, as: credential, for: domain) { return }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
        ) else {
            throw VaultError.accessControlUnavailable
        }
        var item = query(credential, domain)
        item[kSecValueData] = data
        item[kSecAttrAccessControl] = access
        item[kSecAttrLabel] = "GamGUI: \(domain.name) \(credential.fileName)"
        // Under the context lock, as every call that changes an item: `replace(…, ifCurrent:)` reads,
        // compares and updates under it, so nothing may delete or add between those steps.
        let status = context.withLock { _ in SecItemAdd(item as CFDictionary, nil) }
        if status == errSecDuplicateItem, try update(data, as: credential, for: domain) { return }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    package func replace(_ data: Data, as credential: Credential, for domain: Domain, ifCurrent expected: Data) throws -> Bool {
        let service = service
        let account = "\(domain.name)/\(credential.rawValue)"
        // One lock around the read, the comparison and the update: every call that changes an item
        // (update, add, delete) takes the same lock, so nothing can change it in between.
        let status = context.withLock { context -> OSStatus in
            let item: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecUseDataProtectionKeychain: true,
                kSecUseAuthenticationContext: context,
            ]
            var read = item
            read[kSecReturnData] = true
            read[kSecMatchLimit] = kSecMatchLimitOne
            var current: CFTypeRef?
            let found = SecItemCopyMatching(read as CFDictionary, &current)
            guard found == errSecSuccess else { return found }
            guard current as? Data == expected else { return errSecItemNotFound }
            return SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw VaultError.keychain(status)
        }
    }

    /// Replaces the value of an item that exists; false when it doesn't. For `write`.
    private func update(_ data: Data, as credential: Credential, for domain: Domain) throws -> Bool {
        let service = service
        let account = "\(domain.name)/\(credential.rawValue)"
        let status = context.withLock { context -> OSStatus in
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecUseDataProtectionKeychain: true,
                kSecUseAuthenticationContext: context,
            ]
            return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw VaultError.keychain(status)
        }
    }

    package func delete(_ credential: Credential, for domain: Domain) throws {
        let query = query(credential, domain)
        let status = context.withLock { _ in SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status)
        }
    }

    /// The domains, from the index: one item per domain under `<service>.domains`, holding nothing but
    /// its name, with no user-presence control. Listing the credential items themselves asked for Touch
    /// ID every time Setup opened, even for their attributes. Items stored before the index existed are
    /// listed the old way once (one prompt at most) and indexed.
    package func domains() throws -> [Domain] {
        let indexed = try accounts(in: indexService)
        if !indexed.isEmpty { return Set(indexed.compactMap(Domain.init)).sorted() }
        let legacy = Set(try accounts(in: service).compactMap { $0.split(separator: "/").first.flatMap { Domain(String($0)) } })
        for domain in legacy { try index(domain) }
        return legacy.sorted()
    }

    package func forget(_ domain: Domain) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: indexService,
            kSecAttrAccount: domain.name,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = context.withLock { _ in SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }

    /// The domain index's service: names only, so no access control is needed to read it.
    private var indexService: String { "\(service).domains" }

    /// Adds `domain` to the index, before any of its credentials, so a stored credential is always listed
    /// (and can be removed). An entry already there is fine.
    private func index(_ domain: Domain) throws {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: indexService,
            kSecAttrAccount: domain.name,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel: "GamGUI: \(domain.name) (the domain's name only)",
            kSecValueData: Data(),
        ]
        let status = context.withLock { _ in SecItemAdd(item as CFDictionary, nil) }
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw VaultError.keychain(status) }
    }

    /// The account names of every item under `service`: attributes only.
    private func accounts(in service: String) throws -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess: return (items as? [[CFString: Any]] ?? []).compactMap { $0[kSecAttrAccount] as? String }
        case errSecItemNotFound: return []
        default: throw VaultError.keychain(status)
        }
    }

    package func endSession() {
        context.withLock { context in
            context.invalidate()
            context = Self.newContext()
        }
    }
}
