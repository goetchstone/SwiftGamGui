import AppKit
import Foundation
import GamEngine
import Setup
import LocalAuthentication
import Security
import Vault
import WebKit

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
            await sizeWindow(environment["SWIFTGAMGUI_WINDOW"])
            if environment["SWIFTGAMGUI_DEMO"] == "1" {
                // Fill the demo screen. Home, Users and Groups: connected, and the directory loaded (Groups:
                // its groups too). Setup: one passing check (connected), then one failing (the result panel).
                await setup.refresh()
                await setup.checkAccess(Domain("example.com")!)
                if Screen.initial != .setup {
                    await services.directory.load()
                    if Screen.initial == .groups { await services.groups.load() }
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
        case "model": ModelSpike.run()
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
        // A person's page reads their groups, delegates, auto-reply and signature after the list loads, and
        // a signature preview compiles its rule list before it draws.
        let selecting = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"] != nil
        try? await Task.sleep(for: .seconds(selecting ? 4 : 1.5))
        guard let content = NSApp.windows.first(where: \.isVisible)?.contentView else {
            print("snapshot: no window")
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["SWIFTGAMGUI_WINDOW"] == "smallest" {
            widenSideColumns(in: content)
            try? await Task.sleep(for: .seconds(1))
        }
        let view = splitViews(in: content).first?.arrangedSubviews.last ?? content
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
        await drawWebViews(in: view, rect: rect, onto: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: file)
            print("snapshot: \(file.path)")
        } catch {
            print("snapshot: \(error)")
        }
        // After the image, so CI keeps a picture of the layout that failed.
        let smallest = ProcessInfo.processInfo.environment["SWIFTGAMGUI_WINDOW"] == "smallest"
        let tooNarrow = columnsTooNarrow(in: content, spare: smallest ? spareWidth : 0)
        if !tooNarrow.isEmpty {
            print("snapshot: a column is narrower than its content's minimum: \(tooNarrow.joined(separator: "; "))")
            fflush(stdout)
            exit(EXIT_FAILURE)
        }
        NSApp.terminate(nil)
    }

    /// `cacheDisplay` leaves a web view blank: WebKit draws it in another process. Each signature preview
    /// is drawn from its own snapshot (`takeSnapshot`) over its place in the image, only its visible part.
    @MainActor
    static func drawWebViews(in view: NSView, rect: NSRect, onto bitmap: NSBitmapImageRep) async {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let webViews = descendants(view).compactMap { $0 as? WKWebView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        for webView in webViews {
            let visible = webView.visibleRect
            guard !visible.isEmpty else { continue }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = visible
            guard let image = try? await webView.takeSnapshot(configuration: configuration) else {
                print("snapshot: a web view couldn't be drawn")
                continue
            }
            let frame = webView.convert(visible, to: view)
            let y = view.isFlipped ? rect.maxY - frame.maxY : frame.minY - rect.minY
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: frame.minX - rect.minX, y: y, width: frame.width, height: frame.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        if !webViews.isEmpty { print("snapshot: drew \(webViews.count) web view(s) from their own snapshots") }
    }

    /// What the screen's pane must have beyond what it needs in the smallest window, with the sidebar and
    /// the inspector at their widest. The operator's crash came with 84 pt to spare, for a reason no
    /// copy of the layout reproduced (failure-log 2026-10-10, "person-page layout loop").
    static let spareWidth = 100.0

    /// Every split view column whose content needs more width than it has, and the screen's pane (the
    /// outer split's last column) when it has less than `spare` beyond that. When a person's page opens,
    /// the inspector's width is added to the list's minimum but the window's minimum isn't raised: on a
    /// Mac, AppKit loops until it raises NSGenericException. CI's AppKit grows the window or clips
    /// instead, so the snapshot fails here.
    @MainActor
    static func columnsTooNarrow(in content: NSView, spare: Double) -> [String] {
        var problems: [String] = []
        for (s, split) in splitViews(in: content).enumerated() {
            for (c, column) in split.arrangedSubviews.enumerated() where !column.isHidden {
                let needs = column.fittingSize.width.rounded(.up), has = column.frame.width
                let wanted = s == 0 && c == split.arrangedSubviews.count - 1 ? spare : 0
                print("layout: split \(s) column \(c): \(Int(has)) pt wide, needs \(Int(needs))")
                if needs + wanted > has + 0.5 {
                    problems.append("split \(s) column \(c) needs \(Int(needs)) pt and \(Int(wanted)) to spare, has \(Int(has))")
                }
            }
        }
        return problems
    }

    /// Every split view in the window, outermost (sidebar | screen) first.
    @MainActor
    static func splitViews(in view: NSView) -> [NSSplitView] {
        (view is NSSplitView ? [view as! NSSplitView] : []) + view.subviews.flatMap(splitViews(in:))
    }

    /// `SWIFTGAMGUI_WINDOW`: the window's content size, `900x572`, set before the demo fills the screen so
    /// a person's page opens in a window that size; or `smallest`, the window's minimum, with the sidebar
    /// and the page then dragged to their widest: the tightest layout an operator can make. A narrow
    /// window once crashed AppKit's layout when a name was clicked (failure-log 2026-10-10,
    /// "person-page layout loop").
    @MainActor
    static func sizeWindow(_ spec: String?) async {
        guard let spec else { return }
        let parts = spec.split(separator: "x")
        let size = parts.count == 2 ? Double(parts[0]).flatMap { w in Double(parts[1]).map { NSSize(width: w, height: $0) } } : nil
        guard spec == "smallest" || size != nil else {
            print("snapshot: SWIFTGAMGUI_WINDOW is WIDTHxHEIGHT or smallest, not \(spec)")
            return
        }
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: \.isVisible) {
                window.setContentSize(size ?? window.contentMinSize)
                try? await Task.sleep(for: .milliseconds(300))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("snapshot: no window to size")
    }

    /// Drags the sidebar and the inspector as wide as they go, as an operator can. Not remembered: the
    /// positions aren't autosaved over the operator's own.
    @MainActor
    static func widenSideColumns(in content: NSView) {
        for split in splitViews(in: content) {
            guard let items = (split.delegate as? NSSplitViewController)?.splitViewItems else { continue }
            split.autosaveName = nil
            for (index, item) in items.enumerated() {
                switch item.behavior {
                case .sidebar where index < items.count - 1: split.setPosition(split.bounds.width, ofDividerAt: index)
                case .inspector where index > 0: split.setPosition(0, ofDividerAt: index - 1)
                default: break
                }
            }
        }
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
