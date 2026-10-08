import AppKit
import Foundation
import FoundationModels
import LocalAuthentication
import Security

/// Phase 1 spikes, debug builds only. Launch the built binary with `--spike keychain`,
/// `--spike legacy-keychain` or `--spike model`; results print to stdout and the app quits. They only
/// ever touch throwaway items named `swiftgamgui-spike*` — never GamGUI's `gamgui:<domain>` items.
enum Spikes {
    @MainActor
    static func runIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--spike"), index + 1 < args.count else { return }
        print("signing: team=\(teamIdentifier() ?? "none (ad-hoc)")")
        switch args[index + 1] {
        case "keychain": keychain()
        case "legacy-keychain": legacyKeychain()
        case "model": model()
        default: print("unknown spike \(args[index + 1])")
        }
        fflush(stdout)
        NSApp.terminate(nil)
        #endif
    }

    #if DEBUG
    static let service = "swiftgamgui-spike"
    static let legacyService = "swiftgamgui-spike-legacy"

    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "?"
        return "\(status) (\(message))"
    }

    /// A data-protection item, first without and then with a user-presence access control.
    static func keychain() {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(base as CFDictionary)

        var plain = base
        plain[kSecAttrAccount] = "plain"
        plain[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        plain[kSecValueData] = Data("not-a-secret".utf8)
        print("add (data-protection, no ACL): \(describe(SecItemAdd(plain as CFDictionary, nil)))")

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
        ) else {
            print("SecAccessControlCreateWithFlags failed: \(String(describing: error?.takeRetainedValue()))")
            return
        }
        var guarded = base
        guarded[kSecAttrAccount] = "user-presence"
        guarded[kSecAttrAccessControl] = access
        guarded[kSecValueData] = Data("not-a-secret".utf8)
        print("add (data-protection, user presence): \(describe(SecItemAdd(guarded as CFDictionary, nil)))")

        let context = LAContext()
        context.localizedReason = "read a throwaway SwiftGamGui test item"
        context.touchIDAuthenticationAllowableReuseDuration = 30
        var query = base
        query[kSecAttrAccount] = "user-presence"
        query[kSecReturnData] = true
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        print("read #1 (expect a Touch ID / password prompt): \(describe(SecItemCopyMatching(query as CFDictionary, &result)))")
        result = nil
        print("read #2 (same context, within reuse window): \(describe(SecItemCopyMatching(query as CFDictionary, &result)))")

        print("delete all spike items: \(describe(SecItemDelete(base as CFDictionary)))")
    }

    /// Reads a legacy (file-based) login-keychain item another program created: the GamGUI-copy path.
    static func legacyKeychain() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacyService,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let bytes = (result as? Data)?.count ?? 0
        print("read legacy item (expect an Allow prompt): \(describe(status)); \(bytes) bytes returned")
    }

    static func model() {
        let model = SystemLanguageModel.default
        print("SystemLanguageModel.default.availability: \(model.availability)")
        print("supported languages: \(model.supportedLanguages.count)")
    }

    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [CFString: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier] as? String
    }
    #endif
}
