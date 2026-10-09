import ChangeCore
import Directory
import Foundation
import GamEngine
import Setup
import Vault

/// The app's long-lived services, built once at launch. Setup and the directory share one runner, so
/// every screen acts as the domain Setup connected.
@MainActor
struct AppServices {
    let setup: SetupModel
    let directory: DirectoryStore
    /// The bundled gam and the private run folder, when both are usable: `gam version` runs there.
    let gam: (runner: GamRunner, runtimeDirectory: URL)?
    /// The only path to a write (ChangeCore); none without gam.
    let executor: Executor?
    /// The user page's writes, through the executor.
    let userChanges: UserChanges
    /// This app's audit log: Home reads it (off the main actor) for writes that never ended.
    let auditURL: URL

    static func make() -> AppServices {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTGAMGUI_DEMO"] == "1" { return demo() }
        #endif
        // No gam when it isn't bundled or the private run folder isn't safe: Setup and Home say so.
        let gam = GamBinary.locate().flatMap { binary in
            (try? RuntimeDirectory.prepare()).map { (runner: GamRunner(binary: binary), runtimeDirectory: $0) }
        }
        return assemble(vault: Vault(store: KeychainStore()), gam: gam, gamgui: GamGUIKeychain(),
                        setupFolderURL: SetupFolder.defaultURL, auditURL: AuditLog.defaultURL)
    }

    private static func assemble(vault: Vault, gam: (runner: GamRunner, runtimeDirectory: URL)?,
                                 gamgui: GamGUIKeychain, setupFolderURL: URL?, auditURL: URL, lastDomain: LastDomain = .userDefaults,
                                 extraEnvironment: [String: String] = [:]) -> AppServices {
        let runner = gam.map { AuthenticatedRunner(runner: $0.runner, vault: vault, runtimeDirectory: $0.runtimeDirectory) }
        let setup = SetupModel(vault: vault, runner: runner, gamgui: gamgui, setupFolderURL: setupFolderURL, lastDomain: lastDomain)
        // The executor runs on the domain Setup connected, at its generation: a switch refuses old previews.
        let executor = runner.map { runner in
            Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor [weak setup] in
                setup?.active.map { ($0, setup!.generation) }
            }, extraEnvironment: extraEnvironment)
        }
        let directory = DirectoryStore(setup: setup, runner: runner)
        return AppServices(setup: setup, directory: directory, gam: gam, executor: executor,
                           userChanges: UserChanges(executor: executor, directory: directory), auditURL: auditURL)
    }

    #if DEBUG
    /// Debug builds only: two example domains in memory, run against the strict mock — never the real
    /// GAM, so placeholder credentials can't reach Google. Without `SWIFTGAMGUI_GAM_BINARY` pointing at
    /// the mock there is no runner at all. The mock's canned output is found beside it.
    private static func demo() -> AppServices {
        let store = MemoryStore()
        let tokens = ["example.com": "admin@example.com", "example.org": "partialdwd@example.org"]
        for (name, admin) in tokens {
            let domain = Domain(name)!
            try? store.write(Data(#"{"client_email": "gam@demo.iam.gserviceaccount.com"}"#.utf8), as: .oauth2Service, for: domain)
            try? store.write(Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8), as: .oauth2, for: domain)
        }
        let mock = mockGam()
        if let mock {
            setenv("GAM_MOCK_FIXTURES", mock.deletingLastPathComponent().appending(path: "mock_gam").path, 0)
        }
        let gam = mock.flatMap { binary in
            (try? RuntimeDirectory.prepare(FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-run")))
                .map { (runner: GamRunner(binary: binary), runtimeDirectory: $0) }
        }
        return assemble(vault: Vault(store: store), gam: gam, gamgui: GamGUIKeychain { _, _ in nil },
                        setupFolderURL: FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-setup"),
                        auditURL: FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-audit/audit.jsonl"),
                        lastDomain: .memory())
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
