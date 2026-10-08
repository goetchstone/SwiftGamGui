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
        let runner = mockGam().flatMap { binary -> AuthenticatedRunner? in
            (try? RuntimeDirectory.prepare(FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-run")))
                .map { AuthenticatedRunner(runner: GamRunner(binary: binary), vault: vault, runtimeDirectory: $0) }
        }
        return SetupModel(vault: vault, runner: runner,
                          gamgui: GamGUIKeychain { _, _ in nil })
    }

    /// `SWIFTGAMGUI_GAM_BINARY` when it is the mock: named `mock_gam.sh`, a regular file rather than a
    /// link, and a script rather than a Mach-O. A name alone would let a link to the real gam take
    /// placeholder or spike credentials to Google.
    nonisolated static func mockGam(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment[GamBinary.overrideVariable], !path.isEmpty else { return nil }
        let url = URL(filePath: path)
        var info = stat()
        guard url.lastPathComponent == "mock_gam.sh", lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let handle = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("#!".utf8) ? url : nil
    }
    #endif
}
