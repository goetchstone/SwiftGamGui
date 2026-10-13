import ChangeCore
import Directory
import Foundation
import GamEngine
import Setup
import Stores
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
    /// A selected person's groups, delegates, auto-reply and signature, read live.
    let userAccess: UserAccess
    /// One person's Gmail signature, through the executor.
    let signatureChanges: SignatureChanges
    /// The saved signature templates.
    let signatureTemplates: SignatureTemplates
    /// The tenant's groups, read when Groups is first shown.
    let groups: GroupStore
    /// An open group's members, read live.
    let groupMembers: GroupMembers
    /// Adding people to a group and removing a member, through the executor.
    let groupChanges: GroupChanges
    /// One new hire, through the executor (slice O1).
    let onboardChanges: OnboardChanges
    /// The roles Onboard offers: GamGUI's, read only.
    let onboardRoles: OnboardRoles
    /// Rooms, a person's calendars and who has access, read when a screen needs them.
    let calendarReads: CalendarReads
    /// Sharing a calendar with one person, and taking access away, through the executor.
    let calendarChanges: CalendarChanges
    /// Offboarding's read-only plan (Off1): no executor, so it can't run anything.
    let offboardChanges: OffboardChanges
    /// The storage and mail usage report, read when Reports first shows it.
    let usage: UsageStore
    /// This app's audit log: Home reads it (off the main actor) for writes that never ended, and Audit shows it.
    let auditURL: URL
    /// Siri's requests, waiting for the screens to draft them.
    let siriDrafts = SiriDrafts()

    static func make() -> AppServices {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTGAMGUI_DEMO"] == "1" { return demo() }
        #endif
        // No gam when it isn't bundled or the private run folder isn't safe: Setup and Home say so.
        let gam = GamBinary.locate().flatMap { binary in
            (try? RuntimeDirectory.prepare()).map { (runner: GamRunner(binary: binary), runtimeDirectory: $0) }
        }
        return assemble(vault: Vault(store: KeychainStore()), gam: gam, gamgui: GamGUIKeychain(),
                        setupFolderURL: SetupFolder.defaultURL, auditURL: AuditLog.defaultURL,
                        templates: SignatureTemplates(root: SignatureStore.defaultRoot, gamGUIFile: SignatureStore.gamGUIFile),
                        // GamGUI's roles file, built here at run time only (GamGUI's `paths.py`, `onboarding.py:47`).
                        rolesFile: URL.applicationSupportDirectory.appending(path: "GamGUI/onboarding.json"))
    }

    private static func assemble(vault: Vault, gam: (runner: GamRunner, runtimeDirectory: URL)?,
                                 gamgui: GamGUIKeychain, setupFolderURL: URL?, auditURL: URL, templates: SignatureTemplates,
                                 rolesFile: URL, lastDomain: LastDomain = .userDefaults,
                                 extraEnvironment: [String: String] = [:]) -> AppServices {
        let runner = gam.map { AuthenticatedRunner(runner: $0.runner, vault: vault, runtimeDirectory: $0.runtimeDirectory) }
        let setup = SetupModel(vault: vault, runner: runner, gamgui: gamgui, setupFolderURL: setupFolderURL, lastDomain: lastDomain)
        // The executor runs on the domain Setup connected, at its generation: a switch refuses old previews.
        let executor = runner.map { runner in
            Executor(runner: runner, audit: AuditLog(url: auditURL),
                     currentActor: { @MainActor [weak setup] in setup?.connectedAdmin }, tenant: { @MainActor [weak setup] in
                setup?.active.map { ($0, setup!.generation) }
            }, extraEnvironment: extraEnvironment)
        }
        let directory = DirectoryStore(setup: setup, runner: runner)
        let groupMembers = GroupMembers(setup: setup, runner: runner)
        let groups = GroupStore(setup: setup, runner: runner)
        let calendarReads = CalendarReads(setup: setup, runner: runner)
        return AppServices(setup: setup, directory: directory, gam: gam, executor: executor,
                           userChanges: UserChanges(executor: executor, directory: directory),
                           userAccess: UserAccess(setup: setup, runner: runner),
                           signatureChanges: SignatureChanges(executor: executor, setup: setup, directory: directory),
                           signatureTemplates: templates,
                           groups: groups,
                           groupMembers: groupMembers,
                           groupChanges: GroupChanges(executor: executor, setup: setup, members: groupMembers),
                           onboardChanges: OnboardChanges(executor: executor, setup: setup, directory: directory),
                           onboardRoles: OnboardRoles(file: rolesFile),
                           calendarReads: calendarReads,
                           calendarChanges: CalendarChanges(executor: executor, setup: setup, directory: directory, groups: groups,
                                                            reads: calendarReads, runner: runner),
                           // Its own reader: the leaver's delegates are read live, never from a page's lists.
                           offboardChanges: OffboardChanges(setup: setup, directory: directory,
                                                            access: UserAccess(setup: setup, runner: runner)),
                           usage: UsageStore(setup: setup, runner: runner),
                           auditURL: auditURL)
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
        let auditURL = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-audit/audit.jsonl")
        // The Audit screen's picture: example records, written fresh in the temporary folder, never the real log.
        if Screen.initial == .audit { DemoAudit.write(to: auditURL) }
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
                        auditURL: auditURL,
                        // A fresh folder each launch, never the operator's templates, and no copy from GamGUI.
                        templates: SignatureTemplates(
                            root: FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-signatures-\(UUID().uuidString)"),
                            gamGUIFile: nil),
                        rolesFile: demoRoles(beside: mock), lastDomain: .memory())
    }

    /// The demo's roles: the mock's GamGUI-format `onboarding.json`, copied into a fresh temporary folder
    /// each launch, so Onboard never reads the operator's GamGUI roles. Without the mock, a file that isn't there.
    private static func demoRoles(beside mock: URL?) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-demo-roles-\(UUID().uuidString)")
        let file = folder.appending(path: "onboarding.json")
        if let source = mock?.deletingLastPathComponent().appending(path: "mock_gam/onboarding.json") {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: file)
        }
        return file
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
