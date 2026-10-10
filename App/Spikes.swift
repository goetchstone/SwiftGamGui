import AppKit
import Foundation
import FoundationModels
import GamEngine
import Setup
import LocalAuthentication
import Security
import Vault

/// Phase 1 spikes, debug builds only. Launch the built binary with `SWIFTGAMGUI_SPIKE` set to
/// `keychain`, `legacy-keychain`, `vault` or `model`; results print to stdout and the app quits. They only
/// ever touch throwaway items named `swiftgamgui-spike*` — never GamGUI's `gamgui:<domain>` items.
enum Spikes {
    /// A spike or a snapshot was asked for: the launch must not reconnect to the operator's real domain.
    static var isRequested: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["SWIFTGAMGUI_SPIKE"] != nil || environment["SWIFTGAMGUI_SNAPSHOT"] != nil
        #else
        return false
        #endif
    }

    @MainActor
    static func runIfRequested(services: AppServices) async {
        #if DEBUG
        let setup = services.setup
        // Environment variables, not launch arguments: AppKit reads `-key value` arguments as
        // defaults, and a bare path left over is taken as a document to open — which made SwiftUI skip
        // the window entirely.
        let environment = ProcessInfo.processInfo.environment
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: a killed spike still shows how far it got
        if let path = environment["SWIFTGAMGUI_SNAPSHOT"] {
            if environment["SWIFTGAMGUI_DEMO"] == "1" {
                // Fill the demo screen. Home and Users: connected, and the directory loaded. Setup: one
                // passing check (connected), then one failing (the result panel).
                await setup.refresh()
                await setup.checkAccess(Domain("example.com")!)
                if Screen.initial != .setup {
                    await services.directory.load()
                } else {
                    await setup.checkAccess(Domain("example.org")!)
                }
            }
            await snapshot(to: URL(filePath: path))
            return
        }
        guard let spike = environment["SWIFTGAMGUI_SPIKE"] else { return }
        print("signing: team=\(teamIdentifier() ?? "none (ad-hoc)")")
        switch spike {
        case "keychain": keychain()
        case "legacy-keychain": legacyKeychain()
        case "model": model()
        case "vault": await vault()
        default: print("unknown spike \(spike)")
        }
        fflush(stdout)
        NSApp.terminate(nil)
        #endif
    }

    #if DEBUG
    /// Renders the app's real window (AppKit-backed controls included) to a PNG and quits: how a
    /// screen is looked at from the command line. No screen-recording permission involved. Only the
    /// screen's own pane, below the toolbar: the sidebar's and toolbar's system materials don't draw
    /// this way (the selected row came out as a black bar).
    @MainActor
    static func snapshot(to file: URL) async {
        // A person's page reads their groups, delegates and auto-reply after the list loads.
        let selecting = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"] != nil
        try? await Task.sleep(for: .seconds(selecting ? 4 : 1.5))
        guard let content = NSApp.windows.first(where: \.isVisible)?.contentView else {
            print("snapshot: no window")
            NSApp.terminate(nil)
            return
        }
        let view = splitView(in: content)?.arrangedSubviews.last ?? content
        // The sidebar floats over the screen's pane, which starts beneath it: crop to the safe area.
        var rect = view.bounds
        let toolbar = min(view.safeAreaInsets.top, rect.height)
        let sidebar = min(view.safeAreaInsets.left, rect.width)
        rect.size.height -= toolbar
        rect.size.width -= sidebar
        rect.origin.x += sidebar
        if view.isFlipped { rect.origin.y += toolbar }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            print("snapshot: nothing to draw")
            NSApp.terminate(nil)
            return
        }
        view.cacheDisplay(in: rect, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: file)
            print("snapshot: \(file.path)")
        } catch {
            print("snapshot: \(error)")
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// The window's split view (sidebar | screen), searched depth first.
    @MainActor
    static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(splitView(in:)).first
    }

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
            _ = try await vault.spikeRead(for: domain)
            print("read #1 ok in \(clock.now - started) (expect one Touch ID prompt)")
            started = clock.now
            _ = try await vault.spikeRead(for: domain)
            print("read #2 ok in \(clock.now - started) (same session: expect no prompt)")
            if let binary = AppServices.mockGam() {
                let base = try RuntimeDirectory.prepare()
                let runner = AuthenticatedRunner(runner: GamRunner(binary: binary), vault: vault, runtimeDirectory: base)
                let mockEnv = ProcessInfo.processInfo.environment.filter { GamEnvironment.mockOnly.contains($0.key) }
                let result = try await runner.run(GamCommands.infoUser(email: "alice@example.com"), as: domain,
                                                  extraEnvironment: mockEnv)
                let left = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("gamcfg-") }
                print("authenticated run: exit \(result.exitCode); gamcfg dirs left: \(left.count)")
                if mockEnv["GAM_MOCK_REFRESH"] != nil {
                    // The write-back updates the stored item in place (SecItemUpdate).
                    started = clock.now
                    let updated = try await vault.spikeOAuth2(for: domain, equals: Data("refreshed-token-payload\n".utf8))
                    print("refreshed oauth2.txt written back in place: \(updated) (read in \(clock.now - started))")
                }
            } else {
                // Never the bundled gam: these are placeholder credentials.
                print("no mock: set SWIFTGAMGUI_GAM_BINARY to Tests/Fixtures/mock_gam.sh to run the authenticated step")
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
