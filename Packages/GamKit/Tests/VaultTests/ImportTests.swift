import Darwin
import Foundation
import Security
import Testing
@testable import Vault

@Suite("Credential import")
struct ImportTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "gamconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    private func put(_ name: String, _ text: String? = nil) throws {
        let fallback = name == "oauth2service.json"
            ? "{\"type\": \"service_account\", \"client_email\": \"gam@project.iam.gserviceaccount.com\"}"
            : "{\"placeholder\": true}"
        try Data((text ?? fallback).utf8).write(to: folder.appending(path: name))
    }

    @Test func theRequiredFilesAreReadAndClientSecretsIsOptional() throws {
        try put("oauth2service.json")
        try put("oauth2.txt")
        try put("gam.cfg", "not json, ignored")
        #expect(Set(try CredentialFolder.read(folder).keys) == [.oauth2Service, .oauth2])
        try put("client_secrets.json")
        #expect(try CredentialFolder.read(folder).count == 3)
    }

    @Test func aMissingRequiredFileIsNamed() throws {
        try put("oauth2.txt")
        #expect(throws: CredentialFolder.Failure.missing([.oauth2Service])) { try CredentialFolder.read(folder) }
    }

    @Test func aSymlinkedCredentialIsRefused() throws {
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "real-\(UUID().uuidString)")
        try Data("{}".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "oauth2service.json"), withDestinationURL: elsewhere)
        try put("oauth2.txt")
        #expect(throws: CredentialFolder.Failure.notARegularFile("oauth2service.json")) { try CredentialFolder.read(folder) }
    }

    @Test func aFIFONamedLikeACredentialIsRefusedWithoutBlocking() throws {
        #expect(mkfifo(folder.appending(path: "oauth2service.json").path, 0o600) == 0)
        try put("oauth2.txt")
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: CredentialFolder.Failure.notARegularFile("oauth2service.json")) { try CredentialFolder.read(folder) }
        #expect(clock.now - started < .seconds(2))
    }

    @Test func anOversizedOrNonJSONFileIsRefused() throws {
        try put("oauth2service.json", String(repeating: "x", count: CredentialFolder.sizeCap + 1))
        try put("oauth2.txt")
        #expect(throws: CredentialFolder.Failure.tooLarge("oauth2service.json")) { try CredentialFolder.read(folder) }
        try put("oauth2service.json", "not json")
        #expect(throws: CredentialFolder.Failure.notJSON("oauth2service.json")) { try CredentialFolder.read(folder) }
    }

    @Test func aServiceAccountFileMustNameItsAccount() throws {
        try put("oauth2service.json", "{}")
        try put("oauth2.txt")
        #expect(throws: CredentialFolder.Failure.notAServiceAccount) { try CredentialFolder.read(folder) }
    }

    @Test func aUTF16FileIsRefusedThoughFoundationCouldParseIt() throws {
        try put("oauth2service.json")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("{\"placeholder\": true}".data(using: .utf16LittleEndian)!)
        try utf16.write(to: folder.appending(path: "oauth2.txt"))
        #expect(throws: CredentialFolder.Failure.notJSON("oauth2.txt")) { try CredentialFolder.read(folder) }
    }

    @Test func aProblemWithTheOptionalFileOnlyLeavesItOut() throws {
        try put("oauth2service.json")
        try put("oauth2.txt")
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "cs-\(UUID().uuidString)")
        try Data("{}".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "client_secrets.json"), withDestinationURL: elsewhere)
        #expect(Set(try CredentialFolder.read(folder).keys) == [.oauth2Service, .oauth2])
    }

    @Test func importedCredentialsNeverPrint() throws {
        try put("oauth2service.json")
        try put("oauth2.txt", "{\"refresh_token\": \"hunter2-token\"}")
        var dumped = ""
        dump(try CredentialFolder.read(folder), to: &dumped)
        #expect(!dumped.contains("hunter2"))
    }

    @Test func aFileIsNotAFolder() throws {
        try put("oauth2.txt")
        #expect(throws: CredentialFolder.Failure.notAFolder) { try CredentialFolder.read(folder.appending(path: "oauth2.txt")) }
    }

    // MARK: GamGUI's Keychain items

    private func gamgui(_ items: [String: String], failing: OSStatus? = nil) -> GamGUIKeychain {
        GamGUIKeychain { service, account in
            if let failing { throw VaultError.keychain(failing) }
            return items["\(service)|\(account)"].map { Data($0.utf8) }
        }
    }

    @Test func gamguisDomainsAreReadWithTheirSpellingsAndCaseTwinsShareOneDomain() throws {
        let keychain = gamgui(["gamgui|_domains": "[\"Example.com\", \"example.com\", \"not a domain\"]"])
        let entries = try keychain.entries()
        #expect(entries.map(\.spelling) == ["Example.com", "example.com"])
        #expect(Set(entries.map(\.domain)) == [Domain("example.com")!])
    }

    @Test func gamguisCredentialsAreReadUnderTheExactSpelling() throws {
        let keychain = gamgui([
            "gamgui:Example.com|oauth2service": "{\"k\": 1}",
            "gamgui:Example.com|oauth2": "{\"t\": 1}",
            "gamgui:example.com|oauth2": "{\"other\": 1}",
        ])
        let entry = GamGUIKeychain.Entry(spelling: "Example.com", domain: Domain("example.com")!)
        let found = try keychain.credentials(for: entry)
        #expect(Set(found.keys) == [.oauth2Service, .oauth2])
        #expect(found[.oauth2] == Secret(Data("{\"t\": 1}".utf8)))
    }

    @Test func oneOddIndexEntryDoesNotHideTheRest() throws {
        let entries = try gamgui(["gamgui|_domains": "[\"example.com\", 42, null, \"example.org\"]"]).entries()
        #expect(entries.map(\.spelling) == ["example.com", "example.org"])
    }

    @Test func aGarbledIndexOrADeniedReadIsHandled() throws {
        #expect(try gamgui(["gamgui|_domains": "{not json"]).entries().isEmpty)
        #expect(throws: VaultError.keychain(errSecUserCanceled)) {
            try gamgui([:], failing: errSecUserCanceled).entries()
        }
    }

    // MARK: facts and guidance

    @Test func theAdminEmailIsReadFromEitherClaimAndNeverFromAJWT() {
        let decoded = Data(#"{"decoded_id_token": {"email": "Admin@Example.com"}, "token": "secret"}"#.utf8)
        let older = Data(#"{"id_token": "{\"email\": \"admin@example.com\"}"}"#.utf8)
        let jwt = Data(#"{"id_token": "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6ImFAYi5jIn0.sig"}"#.utf8)
        #expect(CredentialFacts.adminEmail(inOAuth2: decoded) == "admin@example.com")
        #expect(CredentialFacts.adminEmail(inOAuth2: older) == "admin@example.com")
        #expect(CredentialFacts.adminEmail(inOAuth2: jwt) == nil)
        #expect(CredentialFacts.adminEmail(inOAuth2: Data(#"{"decoded_id_token": {"email": "a b@c.com"}}"#.utf8)) == nil)
        for control in ["\\u0000", "\\u001f"] {
            let text = #"{"decoded_id_token": {"email": "admin@example.com"# + control + #""}}"#
            #expect(CredentialFacts.adminEmail(inOAuth2: Data(text.utf8)) == nil, "control \(control)")
        }
    }

    @Test func scopesAndClientIDAreRead() {
        #expect(CredentialFacts.grantedScopes(inOAuth2: Data(#"{"scopes": ["s1", "s2"]}"#.utf8)) == ["s1", "s2"])
        #expect(CredentialFacts.clientID(inServiceAccount: Data(#"{"client_id": "123"}"#.utf8)) == "123")
        #expect(CredentialFacts.clientID(inServiceAccount: Data("garbage".utf8)) == nil)
    }

    @Test func aLockedMacIsSaidPlainly() {
        #expect(VaultError.keychain(errSecInteractionNotAllowed).guidance == "Your Mac is locked. Unlock it and try again.")
        #expect(VaultError.keychain(errSecMissingEntitlement).guidance.contains("signed with a team"))
        #expect(VaultError.missing(Domain("example.com")!, [.oauth2Service]).guidance.contains("oauth2service.json"))
    }
}
