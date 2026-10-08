import AppKit
import Foundation
import FoundationModels
import GamEngine
import LocalAuthentication
import Security
import Vault

/// Phase 1 spikes, debug builds only. Launch the built binary with `--spike keychain`,
/// `--spike legacy-keychain`, `--spike vault` or `--spike model`; results print to stdout and the app quits. They only
/// ever touch throwaway items named `swiftgamgui-spike*` — never GamGUI's `gamgui:<domain>` items.
enum Spikes {
    @MainActor
    static func runIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--spike"), index + 1 < args.count else { return }
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: a killed spike still shows how far it got
        print("signing: team=\(teamIdentifier() ?? "none (ad-hoc)")")
        switch args[index + 1] {
        case "keychain": keychain()
        case "legacy-keychain": legacyKeychain()
        case "model": model()
        case "vault": await vault()
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

    /// The slice 2 path end to end on throwaway items (service `swiftgamgui-spike`, domain
    /// `spike.example.com`): Vault over the real Keychain, one Touch ID for a burst of reads, then an
    /// authenticated run of the mock (`SWIFTGAMGUI_GAM_BINARY`, `GAM_MOCK_FIXTURES`) and the wipe.
    static func vault() async {
        let vault = Vault(store: KeychainStore(service: "swiftgamgui-spike"))
        let domain = Domain("spike.example.com")!
        do {
            for credential in Credential.allCases {
                try await vault.store(Secret(Data("{\"placeholder\": true}".utf8)), as: credential, for: domain)
                print("stored \(credential.rawValue)")
            }
            print("domains: \(try await vault.domains())")
            let clock = ContinuousClock()
            var started = clock.now
            _ = try await vault.credentials(for: domain)
            print("read #1 ok in \(clock.now - started) (expect one Touch ID prompt)")
            started = clock.now
            _ = try await vault.credentials(for: domain)
            print("read #2 ok in \(clock.now - started) (same session: expect no prompt)")
            if let binary = GamBinary.locate() {
                let base = try RuntimeDirectory.prepare()
                let runner = AuthenticatedRunner(runner: GamRunner(binary: binary), vault: vault, runtimeDirectory: base)
                let mockEnv = ProcessInfo.processInfo.environment.filter { GamEnvironment.mockOnly.contains($0.key) }
                let result = try await runner.run(["info", "user", "alice@example.com"], as: domain,
                                                  extraEnvironment: mockEnv)
                let left = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("gamcfg-") }
                print("authenticated run: exit \(result.exitCode); gamcfg dirs left: \(left.count)")
            } else {
                print("no gam binary: set SWIFTGAMGUI_GAM_BINARY (debug builds) to run the authenticated step")
            }
        } catch {
            print("vault spike error: \(error)")
        }
        do {
            try await vault.remove(domain)
            print("removed; domains now: \(try await vault.domains())")
        } catch {
            print("cleanup error: \(error)")
        }
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
