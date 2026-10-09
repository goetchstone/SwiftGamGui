import Foundation
import Security
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

@MainActor
@Suite("DirectoryStore", .serialized)
struct DirectoryStoreTests {
    let base: URL
    let memory = MemoryStore()
    let vault: Vault
    let runner: AuthenticatedRunner
    let setup: SetupModel
    let store: DirectoryStore
    let example = Domain("example.com")!

    init() throws {
        // The mock reads its canned output from here; the runner passes it through in debug builds.
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        vault = Vault(store: memory)
        base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil })
        store = DirectoryStore(setup: setup, runner: runner, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    /// A GAM config folder whose oauth2.txt signs in as `admin`.
    private func connect(_ domain: String, admin: String, in setup: SetupModel? = nil) async throws {
        let setup = setup ?? self.setup
        let folder = FileManager.default.temporaryDirectory.appending(path: "gamcfg-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
    }

    private var mockUsers: [GamUser] {
        let text = (try? String(contentsOf: Fixtures.mockGamData.appending(path: "print_users.json"), encoding: .utf8)) ?? ""
        return GamOutput.records(text).map(GamUser.init(record:))
    }

    @Test func nothingLoadsUntilADomainIsConnected() async {
        await store.load()
        #expect(store.users == nil)
        #expect(store.problem?.summary == "Connect a domain on Setup first.")
    }

    @Test func aLoadReadsTheConnectedTenantsUsers() async throws {
        try await connect("example.com", admin: "admin@example.com")
        await store.load()
        #expect(store.problem == nil, "\(String(describing: store.problem))")
        let users = try #require(store.users)
        #expect(users.map(\.primaryEmail) == mockUsers.map(\.primaryEmail))
        #expect(users.count > 2 && users.suspendedCount > 0 && users.adminCount > 0)
        #expect(store.loadedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(store.reports?.first { $0.key == "suspended" }?.count == users.suspendedCount)
    }

    @Test func anotherTenantNeverSeesTheList() async throws {
        try await connect("example.com", admin: "admin@example.com")
        await store.load()
        #expect(store.users != nil)
        try await connect("example.org", admin: "admin@example.org")
        #expect(setup.active == Domain("example.org")!)
        #expect(store.users == nil, "example.com's users, shown as example.org's")
        try await connect("example.com", admin: "admin@example.com")
        #expect(store.users == nil, "a later generation of the same domain loads again")
    }

    @Test func aLoadRunningWhenTheTenantChangesIsDropped() async throws {
        try await connect("example.com", admin: "admin@example.com")
        let load = Task { await store.load() }
        while !store.isLoading { await Task.yield() }
        await setup.remove(example)
        await load.value
        try await connect("example.com", admin: "admin@example.com")
        #expect(store.users == nil)
        #expect(store.problem == nil)
    }

    /// The mock, slowed: a load lasts long enough to switch tenants or ask again in the middle of it.
    /// Like real GAM (one process), it ends on SIGTERM at once: the delay runs in the background with
    /// its output detached, and the trap exits.
    private func slowRunner(log: URL? = nil) throws -> AuthenticatedRunner {
        let script = FileManager.default.temporaryDirectory.appending(path: "slow-mock-\(UUID().uuidString).sh")
        let logLine = log.map { "printf '%s\\n' \"$*\" >> '\($0.path)'\n" } ?? ""
        try Data(("#!/bin/sh\ntrap 'exit 143' TERM\n\(logLine)"
                  + "case \"$1 $2\" in \"print users\") sleep 2 >/dev/null 2>&1 & wait $! ;; esac\n"
                  + "exec '\(Fixtures.mockGam.path)' \"$@\"\n").utf8)
            .write(to: script)
        chmod(script.path, 0o755)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    @Test func aTenantChangeStopsTheOldLoadAndLetsTheNextOneLoad() async throws {
        let slow = try slowRunner()
        let setup = SetupModel(vault: vault, runner: slow, gamgui: GamGUIKeychain { _, _ in nil })
        let store = DirectoryStore(setup: setup, runner: slow)
        try await connect("example.com", admin: "admin@example.com", in: setup)
        let clock = ContinuousClock(), started = clock.now
        let old = Task { await store.load() }
        while !store.isLoading { await Task.yield() }
        try await connect("example.org", admin: "admin@example.org", in: setup)
        #expect(!store.isLoading, "example.com's load isn't example.org's")
        await old.value
        #expect(clock.now - started < .seconds(1.5), "the old load's gam was stopped, not waited for")
        await store.load()
        #expect(store.users?.isEmpty == false, "example.org loads")
    }

    @Test func aLoadForAnotherTenantNeverShowsAsLoading() async throws {
        // Even for a store Setup doesn't notify (its one observer is the store made last).
        let slow = try slowRunner()
        let setup = SetupModel(vault: vault, runner: slow, gamgui: GamGUIKeychain { _, _ in nil })
        let unwatched = DirectoryStore(setup: setup, runner: slow)
        _ = DirectoryStore(setup: setup, runner: slow)
        try await connect("example.com", admin: "admin@example.com", in: setup)
        let old = Task { await unwatched.load() }
        while !unwatched.isLoading { await Task.yield() }
        try await connect("example.org", admin: "admin@example.org", in: setup)
        #expect(!unwatched.isLoading)
        await old.value
        #expect(unwatched.users == nil)
    }

    @Test func askingAgainWhileALoadRunsStartsNoSecond() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "argv-\(UUID().uuidString).log")
        let slow = try slowRunner(log: log)
        let setup = SetupModel(vault: vault, runner: slow, gamgui: GamGUIKeychain { _, _ in nil })
        let store = DirectoryStore(setup: setup, runner: slow)
        try await connect("example.com", admin: "admin@example.com", in: setup)
        async let first: Void = store.load()
        while !store.isLoading { await Task.yield() }
        await store.load()
        await first
        let runs = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("print users") }
        #expect(runs.count == 1)
    }

    @Test func aSuccessfulLoadClearsTheLastProblem() async throws {
        try await connect("example.com", admin: "admin@example.com")
        memory.failNext(.read, with: errSecInteractionNotAllowed)
        await store.load()
        #expect(store.problem?.summary == "Your Mac is locked. Unlock it and try again.")
        await store.load()
        #expect(store.problem == nil)
        #expect(store.users != nil)
    }

    @Test func aFailedOrCutRunShowsNothingButWhy() throws {
        let argv = GamCommands.printUsers().argv
        let failed = GamResult(exitCode: 50, stdout: "", stderr: "ERROR: 403: Request had insufficient authentication scopes",
                               stdoutTruncated: false, stderrTruncated: false)
        #expect(throws: GamError.self) { try DirectoryStore.users(from: failed, argv: argv) }
        let problem = DirectoryStore.problem(for: GamError(exitCode: 50, stderr: failed.stderr, argv: argv), argv: argv)
        #expect(problem.summary.hasPrefix("A required API scope is not authorized."))
        #expect(problem.detail?.contains("scope_missing") == true)

        let cut = GamResult(exitCode: 0, stdout: #"{"primaryEmail": "a@example.com"}"#, stderr: "",
                            stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: DirectoryStore.Truncated.self) { try DirectoryStore.users(from: cut, argv: argv) }
        #expect(DirectoryStore.problem(for: GamRunnerError.timedOut(seconds: 3600), argv: argv).summary
                == GamError.Kind.timeout.remediation)
    }

    @Test func theVersionRunsOnlyInsideThePrivateRunFolder() async throws {
        // A gam that answers only when handed a config directory inside the run folder: never ~/.gam,
        // never none (the mock answers `version` either way, so it couldn't tell).
        let probe = FileManager.default.temporaryDirectory.appending(path: "version-probe-\(UUID().uuidString)")
        try Data(("#!/bin/sh\ncase \"$GAMCFGDIR\" in '\(base.path)'/*) [ -d \"$GAMCFGDIR\" ] && echo 'GAM 7.48.22 - probe' ;; esac\n").utf8)
            .write(to: probe)
        chmod(probe.path, 0o755)
        #expect(await GamVersion.running(GamRunner(binary: probe), runtimeDirectory: base) == "7.48.22")
    }

    @Test func theVersionIsReadInAPrivateEmptyConfig() async throws {
        #expect(await GamVersion.running(GamRunner(binary: Fixtures.mockGam), runtimeDirectory: base) == GamVersion.expected)
        #expect(GamVersion.parse("GAM 7.48.22 - https://github.com/GAM-team/GAM - pyinstaller\nGAM-team\n") == "7.48.22")
        #expect(GamVersion.parse("something else") == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("gamcfg-") }
        #expect(left.isEmpty, "the version's config directory is wiped")
    }
}
