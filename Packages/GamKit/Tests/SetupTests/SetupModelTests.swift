import Foundation
import GamEngine
import Security
@testable import Setup
import TestSupport
import Testing
import Vault

@MainActor
@Suite("SetupModel", .serialized)
struct SetupModelTests {
    let store = MemoryStore()
    let base: URL
    let lastDomain = LastDomain.memory()

    init() throws {
        base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
    }

    private func model(gamgui: [String: String] = [:], withRunner: Bool = true) -> SetupModel {
        let vault = Vault(store: store)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        let keychain = GamGUIKeychain { service, account in gamgui["\(service)|\(account)"].map { Data($0.utf8) } }
        return SetupModel(vault: vault, runner: withRunner ? runner : nil, gamgui: keychain, lastDomain: lastDomain)
    }

    /// A GAM config folder whose oauth2.txt signs in as `admin`.
    private func gamFolder(admin: String = "admin@example.com") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gamcfg-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "123"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}, "refresh_token": "placeholder"}"#.utf8)
            .write(to: folder.appending(path: "oauth2.txt"))
        return folder
    }

    @Test func importingStoresTheDomainInItsOneSpellingAndSuggestsIt() async throws {
        let model = model()
        let folder = try gamFolder(admin: "Admin@Example.com")
        #expect(await model.suggestedDomain(for: folder) == "example.com")
        await model.importFolder(folder, as: "  Example.COM ")
        #expect(model.domains == [Domain("example.com")!])
        #expect(model.activity == .done("Imported example.com. Check access next."))
        #expect(model.active == nil, "importing doesn't connect: Check access does")
    }

    @Test func aBadDomainOrFolderIsSaidPlainly() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "not a domain")
        #expect(model.activity == .problem("“not a domain” isn't a domain name."))
        let empty = FileManager.default.temporaryDirectory.appending(path: "empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        await model.importFolder(empty, as: "example.com")
        #expect(model.activity == .problem(
            "The folder has no oauth2service.json or oauth2.txt. Choose your GAM config folder (often ~/.gam)."))
        #expect(model.domains.isEmpty)
    }

    @Test func aPassingCheckConnectsAndAReCheckKeepsTheGeneration() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "example.com")
        let example = Domain("example.com")!
        await model.checkAccess(example)
        #expect(model.active == example)
        #expect(model.generation == 1)
        #expect(model.activity == .done("Connected to example.com as admin@example.com."))
        await model.checkAccess(example)
        #expect(model.generation == 1, "the same domain re-checked keeps its previews and caches")
    }

    @Test func aFailedCheckOfAnotherDomainKeepsTheConnectedOne() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.importFolder(try gamFolder(admin: "partialdwd@example.org"), as: "example.org")
        await model.checkAccess(Domain("example.com")!)
        await model.checkAccess(Domain("example.org")!)
        #expect(model.active == Domain("example.com")!)
        #expect(model.generation == 1)
        #expect(model.activity == .problem(
            "Domain-wide delegation isn't authorized for 2 of 7 scopes yet. Use the link, then check again."))
        #expect(model.lastCheck?.result.authorizationURL?.host() == "admin.google.com")
    }

    /// The directory and the group list both stop old work on a switch: each observer is told every time,
    /// and a re-check of the same domain tells none.
    @Test func everyTenantObserverIsToldOfEachChange() async throws {
        let model = model()
        var told: [String] = []
        model.onTenantChange { told.append("first") }
        model.onTenantChange { told.append("second") }
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.checkAccess(Domain("example.com")!)
        #expect(told == ["first", "second"])
        await model.checkAccess(Domain("example.com")!)
        #expect(told.count == 2, "the same domain re-checked isn't a change")
        await model.remove(Domain("example.com")!)
        #expect(told == ["first", "second", "first", "second"])
    }

    @Test func switchingToAnotherDomainBumpsTheGeneration() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.importFolder(try gamFolder(admin: "admin@example.org"), as: "example.org")
        await model.checkAccess(Domain("example.com")!)
        await model.checkAccess(Domain("example.org")!)
        #expect(model.active == Domain("example.org")!)
        #expect(model.generation == 2)
    }

    @Test func aTokenWithoutAnAdminAsksForOne() async throws {
        let model = model()
        let folder = try gamFolder()
        try Data(#"{"refresh_token": "placeholder"}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await model.importFolder(folder, as: "example.com")
        await model.checkAccess(Domain("example.com")!)
        #expect(model.activity == .problem("This domain's oauth2.txt names no admin. Enter the admin address GAM signs in as."))
        await model.checkAccess(Domain("example.com")!, typedAdmin: " Admin@Example.com ")
        #expect(model.active == Domain("example.com")!)
    }

    @Test func aLockedMacIsSaidPlainlyDuringACheck() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "example.com")
        store.failNext(.read, with: errSecInteractionNotAllowed)
        await model.checkAccess(Domain("example.com")!)
        #expect(model.activity == .problem("Your Mac is locked. Unlock it and try again."))
        #expect(model.active == nil)
    }

    @Test func removingTheConnectedDomainDisconnectsAndARefusalKeepsItListed() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "example.com")
        let example = Domain("example.com")!
        await model.checkAccess(example)
        store.failNext(.delete, with: errSecInteractionNotAllowed)
        await model.remove(example)
        #expect(model.domains == [example])
        #expect(model.active == example)
        await model.remove(example)
        #expect(model.domains.isEmpty)
        #expect(model.active == nil)
        #expect(model.generation == 2)
        #expect(model.lastCheck == nil)
    }

    @Test func copyingFromGamGUIUsesItsSpellingAndRefusesAnIncompleteSet() async throws {
        let model = model(gamgui: [
            "gamgui|_domains": #"["Example.com", "partial.example.org"]"#,
            "gamgui:Example.com|oauth2service": #"{"client_email": "gam@p.iam.gserviceaccount.com"}"#,
            "gamgui:Example.com|oauth2": #"{"decoded_id_token": {"email": "admin@example.com"}}"#,
            "gamgui:partial.example.org|oauth2": #"{"t": 1}"#,
        ])
        await model.lookForGamGUI()
        let entries = try #require(model.gamguiEntries)
        #expect(entries.map(\.spelling) == ["Example.com", "partial.example.org"])
        await model.copy(entries[1])
        #expect(model.activity == .problem("GamGUI has no oauth2service.json for partial.example.org."))
        await model.copy(entries[0])
        #expect(model.domains == [Domain("example.com")!])
        await model.checkAccess(Domain("example.com")!)
        #expect(model.active == Domain("example.com")!)
    }

    // MARK: review of PR #3

    @Test func reImportingTheConnectedDomainDisconnectsItUntilChecked() async throws {
        let model = model()
        let example = Domain("example.com")!
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.checkAccess(example)
        #expect(model.active == example)
        await model.importFolder(try gamFolder(admin: "admin@other.org"), as: "example.com")
        #expect(model.active == nil, "new credentials haven't passed a check")
        #expect(model.lastCheck == nil, "the old check was of other credentials")
        #expect(model.generation == 2)
    }

    @Test func anImportRefusedPartWayLeavesNoMixOfOldAndNew() async throws {
        let model = model()
        let example = Domain("example.com")!
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.checkAccess(example)
        // The second write (the service key, after oauth2.txt) is refused.
        store.failNext(.write, with: errSecUserCanceled, skipping: 1)
        await model.importFolder(try gamFolder(admin: "admin@other.org"), as: "example.com")
        #expect(model.domains.isEmpty, "a set is whole or absent")
        #expect(try store.read(.oauth2, for: example) == nil)
        #expect(try store.read(.oauth2Service, for: example) == nil)
        #expect(model.active == nil)
        #expect(model.activity == .problem(VaultError.keychain(errSecUserCanceled).guidance))
    }

    @Test func aDomainTheFailureLeftBehindIsStillListedSoItCanBeRemoved() async throws {
        let model = model()
        // The service key's write is refused, then so is the cleanup's first delete (the first delete
        // overall is the absent client_secrets.json's), leaving oauth2.txt stored.
        store.failNext(.write, with: errSecUserCanceled, skipping: 1)
        store.failNext(.delete, with: errSecInteractionNotAllowed, skipping: 1)
        await model.importFolder(try gamFolder(), as: "example.com")
        #expect(model.activity == .problem(VaultError.keychain(errSecInteractionNotAllowed).guidance))
        #expect(model.domains == [Domain("example.com")!])
        await model.remove(Domain("example.com")!)
        #expect(model.domains.isEmpty)
    }

    @Test func anImportWithoutClientSecretsDropsTheOldOne() async throws {
        let model = model()
        let example = Domain("example.com")!
        let folder = try gamFolder()
        try Data(#"{"installed": {}}"#.utf8).write(to: folder.appending(path: "client_secrets.json"))
        await model.importFolder(folder, as: "example.com")
        #expect(try store.read(.clientSecrets, for: example) != nil)
        await model.importFolder(try gamFolder(), as: "example.com")
        #expect(try store.read(.clientSecrets, for: example) == nil)
    }

    @Test func nothingStartsWhileAnActionRuns() async throws {
        let model = model()
        let example = Domain("example.com")!
        await model.importFolder(try gamFolder(), as: "example.com")
        let check = Task { await model.checkAccess(example) }
        while !model.isBusy { await Task.yield() }
        await model.remove(example)
        await model.importFolder(try gamFolder(admin: "admin@other.org"), as: "example.com")
        await check.value
        #expect(model.domains == [example], "the removal didn't start")
        #expect(model.active == example)
        #expect(model.lastCheck?.admin == "admin@example.com", "nor did the import")
    }

    @Test func aFailedReCheckOfTheConnectedDomainIsShown() async throws {
        let model = model()
        let example = Domain("example.com")!
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.checkAccess(example)
        #expect(model.status(of: example) == .connected)
        #expect(model.status(of: Domain("example.org")!) == .notConnected)
        // Delegation is withdrawn for this admin (the mock fails some scopes for partialdwd@).
        try store.write(Data(#"{"decoded_id_token": {"email": "partialdwd@example.com"}}"#.utf8), as: .oauth2, for: example)
        await model.checkAccess(example)
        #expect(model.active == example, "a failed re-check doesn't switch tenants")
        #expect(model.status(of: example) == .connectedButLastCheckFailed)
    }

    @Test func aBuildWithoutGamSaysSo() async {
        let model = model(withRunner: false)
        await model.checkAccess(Domain("example.com")!)
        #expect(model.activity == .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh."))
    }

    // MARK: reconnecting at launch (operator, 2026-10-09)

    @Test func theConnectedAdminIsTheLastPassingChecks() async throws {
        let model = model()
        #expect(model.connectedAdmin == nil)
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.checkAccess(Domain("example.com")!)
        #expect(model.connectedAdmin == "admin@example.com")
    }

    @Test func theLastConnectedDomainIsCheckedAgainAtLaunch() async throws {
        let first = model()
        await first.importFolder(try gamFolder(), as: "example.com")
        await first.checkAccess(Domain("example.com")!)
        #expect(lastDomain.load() == "example.com", "a pass remembers the domain, by name only")
        let relaunched = model()
        #expect(relaunched.active == nil)
        await relaunched.reconnect()
        #expect(relaunched.active == Domain("example.com")!, "connected by a real check, not assumed")
    }

    @Test func aDomainThatFailsItsCheckDoesntConnectAtLaunch() async throws {
        let first = model()
        await first.importFolder(try gamFolder(admin: "partialdwd@example.org"), as: "example.org")
        lastDomain.save("example.org")
        await first.reconnect()
        #expect(first.active == nil)
        #expect(first.reconnecting == nil)
        let failure = try #require(first.reconnectFailure, "a failed reconnect must say why, not look disconnected")
        #expect(failure.domain == Domain("example.org")! && !failure.problem.isEmpty)

        await first.importFolder(try gamFolder(), as: "example.com")
        await first.checkAccess(Domain("example.com")!)
        #expect(first.reconnectFailure == nil, "a domain connected since: the failure no longer applies")
    }

    /// While the launch's reconnect runs, the model says which domain it is connecting, for every screen.
    @Test func reconnectingSaysWhichDomainUntilItEnds() async throws {
        let first = model()
        await first.importFolder(try gamFolder(), as: "example.com")
        await first.checkAccess(Domain("example.com")!)
        let relaunched = model()
        #expect(relaunched.reconnecting == nil)
        let reconnect = Task { await relaunched.reconnect() }
        for _ in 0..<10_000 where relaunched.reconnecting == nil && relaunched.active == nil { await Task.yield() }
        #expect(relaunched.reconnecting == Domain("example.com")!, "connecting, and the screens can't say so")
        await reconnect.value
        #expect(relaunched.reconnecting == nil)
        #expect(relaunched.active == Domain("example.com")!)
        #expect(relaunched.reconnectFailure == nil)
    }

    /// Try Again while another action runs: refused, and the reason stays.
    @Test func aReconnectWhileAnActionRunsKeepsTheFailure() async throws {
        let model = model()
        await model.importFolder(try gamFolder(admin: "partialdwd@example.org"), as: "example.org")
        lastDomain.save("example.org")
        await model.reconnect()
        let failure = try #require(model.reconnectFailure)
        await model.importFolder(try gamFolder(), as: "example.com")
        let check = Task { await model.checkAccess(Domain("example.com")!) }
        while !model.isBusy { await Task.yield() }
        await model.reconnect()
        #expect(model.reconnectFailure == failure, "the reason was cleared by a reconnect that checked nothing")
        #expect(model.reconnecting == nil)
        await check.value
    }

    /// A second reconnect while one runs (a new window at launch) changes nothing: the first still shows.
    @Test func aSecondReconnectWhileOneRunsChangesNothing() async throws {
        let first = model()
        await first.importFolder(try gamFolder(), as: "example.com")
        await first.checkAccess(Domain("example.com")!)
        let relaunched = model()
        let reconnect = Task { await relaunched.reconnect() }
        for _ in 0..<10_000 where relaunched.reconnecting == nil { await Task.yield() }
        await relaunched.reconnect()
        #expect(relaunched.reconnecting == Domain("example.com")!, "the second call ended the first's \"Connecting\"")
        await reconnect.value
        #expect(relaunched.active == Domain("example.com")!)
    }

    /// A reconnect cancelled mid-check has no outcome: no failure, and no "CancellationError()" shown.
    @Test func aCancelledReconnectRecordsNoFailure() async throws {
        let first = model()
        await first.importFolder(try gamFolder(), as: "example.com")
        await first.checkAccess(Domain("example.com")!)
        let relaunched = model()
        let reconnect = Task { await relaunched.reconnect() }
        while !relaunched.isBusy { await Task.yield() }
        reconnect.cancel()
        await reconnect.value
        #expect(relaunched.reconnectFailure == nil)
        if case .problem(let problem) = relaunched.activity { #expect(!problem.contains("Cancellation"), "\(problem)") }
    }

    @Test func theLaunchReconnectRunsOnce() async throws {
        let first = model()
        await first.importFolder(try gamFolder(), as: "example.com")
        await first.checkAccess(Domain("example.com")!)
        let relaunched = model()
        relaunched.reconnectAtLaunch()
        while relaunched.active == nil { await Task.yield() }
        await relaunched.remove(Domain("example.com")!)
        await relaunched.importFolder(try gamFolder(), as: "example.com")
        lastDomain.save("example.com")
        relaunched.reconnectAtLaunch()
        for _ in 0..<1_000 { await Task.yield() }
        #expect(relaunched.active == nil && relaunched.reconnecting == nil, "a second window reconnected again")
    }

    @Test func removingTheDomainThatFailedClearsTheFailure() async throws {
        let model = model()
        await model.importFolder(try gamFolder(admin: "partialdwd@example.org"), as: "example.org")
        lastDomain.save("example.org")
        await model.reconnect()
        #expect(model.reconnectFailure != nil)
        await model.remove(Domain("example.org")!)
        #expect(model.reconnectFailure == nil)
    }

    @Test func aRemovedDomainIsForgottenForTheNextLaunch() async throws {
        let model = model()
        await model.importFolder(try gamFolder(), as: "example.com")
        await model.checkAccess(Domain("example.com")!)
        await model.remove(Domain("example.com")!)
        #expect(lastDomain.load() == nil)
        await model.reconnect()
        #expect(model.active == nil)
    }
}