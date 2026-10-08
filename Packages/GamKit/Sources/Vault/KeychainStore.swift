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

    public func read(_ credential: Credential, for domain: Domain) throws -> Data? {
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

    public func write(_ data: Data, as credential: Credential, for domain: Domain) throws {
        if try replace(data, as: credential, for: domain) { return }
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
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, try replace(data, as: credential, for: domain) { return }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    public func replace(_ data: Data, as credential: Credential, for domain: Domain) throws -> Bool {
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

    public func delete(_ credential: Credential, for domain: Domain) throws {
        let status = SecItemDelete(query(credential, domain) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status)
        }
    }

    public func domains() throws -> [Domain] {
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
        case errSecSuccess:
            let accounts = (items as? [[CFString: Any]] ?? []).compactMap { $0[kSecAttrAccount] as? String }
            return Set(accounts.compactMap { $0.split(separator: "/").first.flatMap { Domain(String($0)) } })
                .sorted()
        case errSecItemNotFound:
            return []
        default:
            throw VaultError.keychain(status)
        }
    }

    public func endSession() {
        context.withLock { context in
            context.invalidate()
            context = Self.newContext()
        }
    }
}
