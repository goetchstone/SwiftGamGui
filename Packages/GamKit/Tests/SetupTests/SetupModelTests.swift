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

    init() throws {
        base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
    }

    private func model(gamgui: [String: String] = [:], withRunner: Bool = true) -> SetupModel {
        let vault = Vault(store: store)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        let keychain = GamGUIKeychain { service, account in gamgui["\(service)|\(account)"].map { Data($0.utf8) } }
        return SetupModel(vault: vault, runner: withRunner ? runner : nil, gamgui: keychain)
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

    @Test func aBuildWithoutGamSaysSo() async {
        let model = model(withRunner: false)
        await model.checkAccess(Domain("example.com")!)
        #expect(model.activity == .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh."))
    }
}
