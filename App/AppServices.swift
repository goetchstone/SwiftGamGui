import Foundation
import GamEngine
import Setup
import Vault

/// The app's long-lived services, built once at launch.
@MainActor
enum AppServices {
    static func makeSetup() -> SetupModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTGAMGUI_DEMO"] == "1" { return demoSetup() }
        #endif
        let vault = Vault(store: KeychainStore())
        // No runner when GAM isn't bundled or the private run folder isn't safe: Setup says so.
        let runner = GamBinary.locate().flatMap { binary in
            (try? RuntimeDirectory.prepare()).map {
                AuthenticatedRunner(runner: GamRunner(binary: binary), vault: vault, runtimeDirectory: $0)
            }
        }
        return SetupModel(vault: vault, runner: runner)
    }

    #if DEBUG
    /// Debug builds only: two example domains in memory, run against the strict mock — never the real
    /// GAM, so placeholder credentials can't reach Google. Without `SWIFTGAMGUI_GAM_BINARY` pointing at
    /// the mock there is no runner at all.
    private static func demoSetup() -> SetupModel {
        let store = MemoryStore()
        let tokens = ["example.com": "admin@example.com", "example.org": "partialdwd@example.org"]
        for (name, admin) in tokens {
            let domain = Domain(name)!
            try? store.write(Data(#"{"client_email": "gam@demo.iam.gserviceaccount.com"}"#.utf8), as: .oauth2Service, for: domain)
            try? store.write(Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8), as: .oauth2, for: domain)
        }
        let vault = Vault(store: store)
        let environment = ProcessInfo.processInfo.environment
        let mock = environment[GamBinary.overrideVariable].map { URL(filePath: $0) }
        let runner = mock.flatMap { binary -> AuthenticatedRunner? in
            guard binary.lastPathComponent == "mock_gam.sh" else { return nil }
            return (try? RuntimeDirectory.prepare(FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-run")))
                .map { AuthenticatedRunner(runner: GamRunner(binary: binary), vault: vault, runtimeDirectory: $0) }
        }
        return SetupModel(vault: vault, runner: runner,
                          gamgui: GamGUIKeychain { _, _ in nil })
    }
    #endif
}
