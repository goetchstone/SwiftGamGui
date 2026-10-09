import Foundation
import GamEngine
import Security
@testable import Setup
import TestSupport
import Testing
import Vault

/// GamGUI's guided setup, held to `Tests/Fixtures/setup.json` (generated from frozen GamGUI): the
/// fresh-setup Terminal commands, the delegation step's client ID, link and sign-out-scope note; and
/// the import from the setup folder, which wipes GAM's plain-text copies only once the Vault has them.
@MainActor
@Suite("Guided setup", .serialized)
final class GuidedSetupTests {
    struct Document: Decodable {
        struct Fact: Decodable { let oauth2service: String; let domain: String; let client_id: String; let auth_url: String }
        struct Security: Decodable { let oauth2: String; let user_security: Bool? }
        struct Commands: Decodable { let admin: String; let cfgdir: String; let gam: String; let env: String; let commands: [String] }
        let dwd_scopes: [[String]]
        let user_security_scope: String
        let admin_console_dwd_url: String
        let facts: [Fact]
        let user_security: [Security]
        let setup_commands: [Commands]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.setupJSON))
    let store = MemoryStore()

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func theConstantsAreGamGUIs() {
        #expect(document.dwd_scopes.map { $0[0] } == DelegationScopes.scopes)
        #expect(document.user_security_scope == CredentialFacts.userSecurityScope)
        #expect(document.admin_console_dwd_url == DelegationScopes.adminConsoleURL)
    }

    @Test func theClientIDAndLinkAreGamGUIsByteForByte() {
        #expect(document.facts.count == 18)
        for fact in document.facts {
            let clientID = CredentialFacts.clientID(inServiceAccount: Data(fact.oauth2service.utf8))
            #expect(bytes(clientID) == bytes(fact.client_id), "\(fact.oauth2service)")
            let url = DelegationScopes.authorizationURL(clientID: clientID, domain: Domain(fact.domain))
            #expect(bytes(url?.absoluteString ?? "") == bytes(fact.auth_url), "\(fact.oauth2service) \(fact.domain)")
        }
    }

    @Test func theSignOutScopeNoteIsGamGUIs() {
        for item in document.user_security {
            #expect(CredentialFacts.grantsUserSecurity(inOAuth2: Data(item.oauth2.utf8)) == item.user_security, "\(item.oauth2)")
        }
    }

    @Test func theTerminalCommandsAreGamGUIsByteForByte() throws {
        #expect(document.setup_commands.count == 4)
        for item in document.setup_commands {
            let fresh = try #require(FreshSetup.commands(admin: item.admin,
                                                         folder: URL(filePath: item.cfgdir, directoryHint: .notDirectory),
                                                         gam: URL(filePath: item.gam, directoryHint: .notDirectory)))
            #expect(fresh.lines.map(bytes) == ([item.env] + item.commands).map(bytes))
        }
    }

    /// GamGUI pastes the admin and paths unchecked; anything a shell would split or expand is refused.
    @Test func aValueAShellWouldSplitOrExpandGetsNoCommands() {
        let folder = URL(filePath: "/tmp/setup"), gam = URL(filePath: "/opt/gam7/gam")
        for admin in ["admin @example.com", "a;rm -rf ~@example.com", "$(id)@example.com", "`id`@example.com",
                      "-x@example.com", "admin@example.com\nid", "admin", "a@b@c", "@example.com", "admin@"] {
            #expect(FreshSetup.commands(admin: admin, folder: folder, gam: gam) == nil, "\(admin)")
        }
        for path in ["/tmp/$HOME", "/tmp/a\"b", "/tmp/a`id`", "/tmp/a\\b", "/tmp/a!b", "/tmp/a\nb"] {
            #expect(FreshSetup.commands(admin: "admin@example.com", folder: URL(filePath: path), gam: gam) == nil, "\(path)")
            #expect(FreshSetup.commands(admin: "admin@example.com", folder: folder, gam: URL(filePath: path)) == nil, "\(path)")
        }
        #expect(FreshSetup.commands(admin: " admin@example.com ", folder: folder, gam: gam) != nil, "trimmed")
    }

    // MARK: the setup folder, through the model

    private var made: [URL] = []

    deinit {
        for url in made { try? FileManager.default.removeItem(at: url) }
    }

    private func setupFolder() throws -> SetupFolder {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-setup-\(UUID().uuidString)")
        made.append(url)
        return try SetupFolder.prepare(url)
    }

    /// What GAM's three commands leave: the credentials, and files that aren't ours to touch.
    private func writeGamOutput(into folder: URL) throws {
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1234567890"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@example.com"}, "scopes": ["https://www.googleapis.com/auth/admin.directory.user.security"]}"#.utf8)
            .write(to: folder.appending(path: "oauth2.txt"))
        try Data(#"{"installed": {"client_id": "x"}}"#.utf8).write(to: folder.appending(path: "client_secrets.json"))
        try Data("[gam]\n".utf8).write(to: folder.appending(path: "gam.cfg"))
    }

    private func model(_ folder: SetupFolder?, withRunner: Bool = true) throws -> SetupModel {
        let vault = Vault(store: store)
        let base = try RuntimeDirectory.prepare(FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        return SetupModel(vault: vault, runner: withRunner ? runner : nil, gamgui: GamGUIKeychain { _, _ in nil },
                          setupFolderURL: folder?.url, lastDomain: .memory())
    }

    private func names(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    @Test func importingFromTheSetupFolderStoresTheSetWipesGamsCopiesAndShowsTheDelegationStep() async throws {
        let folder = try setupFolder()
        try writeGamOutput(into: folder.url)
        let model = try model(folder)
        await model.importFromSetupFolder(as: "example.com")
        let example = Domain("example.com")!
        #expect(model.activity == .done("Imported example.com and wiped GAM's copies from the setup folder. Authorize delegation next."))
        #expect(Set(try store.domains()) == [example])
        #expect(try store.read(.clientSecrets, for: example) != nil)
        #expect(try names(in: folder.url) == ["gam.cfg"], "only the credentials read are wiped")
        #expect(model.delegation?.clientID == "1234567890")
        #expect(model.delegation?.grantsUserSecurity == true)
        #expect(model.delegation?.authorizationURL?.absoluteString.contains("clientIdToAdd=1234567890") == true)
        await model.remove(example)
        #expect(model.delegation == nil, "a removed domain's delegation step goes with it")
    }

    /// GamGUI's `_is_managed`: the setup folder picked with Choose Folder… (here through a link, another
    /// spelling of it) is still ours, and gets the wiping import.
    @Test func theSetupFolderPickedByHandIsWipedToo() async throws {
        let folder = try setupFolder()
        try writeGamOutput(into: folder.url)
        let link = FileManager.default.temporaryDirectory.appending(path: "setup-link-\(UUID().uuidString)")
        made.append(link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url)
        let model = try model(folder)
        await model.importFolder(link, as: "example.com")
        #expect(model.activity == .done("Imported example.com and wiped GAM's copies from the setup folder. Authorize delegation next."))
        #expect(try names(in: folder.url) == ["gam.cfg"])
    }

    @Test func aRefusedVaultWriteWipesNothing() async throws {
        let folder = try setupFolder()
        try writeGamOutput(into: folder.url)
        let model = try model(folder)
        store.failNext(.write, with: errSecUserCanceled)
        await model.importFromSetupFolder(as: "example.com")
        #expect(model.activity == .problem(VaultError.keychain(errSecUserCanceled).guidance))
        #expect(try names(in: folder.url) == ["oauth2service.json", "oauth2.txt", "client_secrets.json", "gam.cfg"])
        #expect(model.delegation == nil)
    }

    /// PR #16's review: an optional file the read refused stayed on disk while the screen said "wiped".
    @Test func aCredentialLeftInTheFolderIsNamed() async throws {
        let folder = try setupFolder()
        try writeGamOutput(into: folder.url)
        try Data("not json".utf8).write(to: folder.url.appending(path: "client_secrets.json"))
        let model = try model(folder)
        await model.importFromSetupFolder(as: "example.com")
        guard case .problem(let text) = model.activity else { Issue.record("\(model.activity)"); return }
        #expect(text.hasPrefix("Imported example.com, but client_secrets.json is still in the setup folder"))
    }

    @Test func anEmptySetupFolderSaysToRunTheCommandsFirst() async throws {
        let model = try model(try setupFolder())
        await model.importFromSetupFolder(as: "example.com")
        #expect(model.activity == .problem("The setup folder has no oauth2service.json or oauth2.txt yet. Run the commands above first, in order."))
    }

    /// PR #16's review: the folder was made once, at launch. One deleted and recreated loosely since
    /// (GAM makes a missing GAMCFGDIR with the umask) is made private again before the read.
    @Test func aFolderRecreatedSinceLaunchIsMadePrivateAgain() async throws {
        let folder = try setupFolder()
        let model = try model(folder)
        try FileManager.default.removeItem(at: folder.url)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try writeGamOutput(into: folder.url)
        await model.importFromSetupFolder(as: "example.com")
        #expect(model.activity == .done("Imported example.com and wiped GAM's copies from the setup folder. Authorize delegation next."))
        var info = stat()
        #expect(lstat(folder.url.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test func aPaddedAdminSuggestsItsDomain() {
        #expect(SetupModel.suggestedDomain(forAdmin: "  admin@example.com\u{A0}") == "example.com")
    }

    @Test func freshSetupNeedsGamAndTheFolder() throws {
        let folder = try setupFolder()
        #expect(try model(folder).freshSetup(admin: "admin@example.com")?.commands.count == 3)
        #expect(try model(folder).freshSetup(admin: "not an address") == nil)
        #expect(try model(folder, withRunner: false).freshSetup(admin: "admin@example.com") == nil)
        #expect(try model(nil).freshSetup(admin: "admin@example.com") == nil)
    }
}
