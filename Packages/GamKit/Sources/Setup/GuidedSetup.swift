import Foundation
import GamEngine
import Vault

/// GamGUI's `setup_commands`: what to run in Terminal for a fresh GAM authorization, pointed at the
/// guided setup's folder, in GAM7's order. They open a browser and ask questions, so the operator runs
/// them; Setup then imports from the folder. Held to `Tests/Fixtures/setup.json`.
public struct FreshSetup: Equatable, Sendable {
    /// `export GAMCFGDIR="<folder>"`: the commands write the credentials there.
    public let environment: String
    /// `create project <admin>`, `oauth create`, `create svcacct`.
    public let commands: [String]

    public var lines: [String] { [environment] + commands }

    /// Nil when a value wouldn't paste as the one word GamGUI meant: an admin that isn't a plain address,
    /// or a path holding a character a shell treats specially inside double quotes. GamGUI interpolates
    /// both unchecked; refusing them means what the operator pastes can only be these commands, which
    /// are GamGUI's byte for byte for every value accepted.
    public static func commands(admin: String, folder: URL, gam: URL) -> FreshSetup? {
        let admin = admin.trimmingCharacters(in: .whitespaces)
        let folderPath = folder.path(percentEncoded: false), gamPath = gam.path(percentEncoded: false)
        guard isPlainAddress(admin), isQuotable(folderPath), isQuotable(gamPath) else { return nil }
        let gam = "\"\(gamPath)\""
        return FreshSetup(environment: "export GAMCFGDIR=\"\(folderPath)\"",
                          commands: ["\(gam) create project \(admin)", "\(gam) oauth create", "\(gam) create svcacct"])
    }

    /// `local@domain` of ASCII letters, digits and `._%+-`: nothing a shell would split or expand.
    static func isPlainAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !text.hasPrefix("-") else { return false }
        let local = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-".utf8)
        let domain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-".utf8)
        return parts[0].utf8.allSatisfy(local.contains) && parts[1].utf8.allSatisfy(domain.contains)
    }

    /// Inside double quotes a shell still expands `$`, `` ` ``, `\`, `"` and (interactively) `!`; a
    /// control character or newline would end the line.
    static func isQuotable(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains { "$`\\\"!".unicodeScalars.contains($0) || $0.value < 0x20 || $0.value == 0x7F }
    }
}

/// The delegation step after an import (GamGUI's `dwd_details`): the service account's client ID, the
/// Admin-console link with it and the scopes filled in, and whether the admin token carries
/// offboarding's sign-out scope. Read from the credentials in hand, so no extra Keychain read.
public struct Delegation: Equatable, Sendable {
    public let domain: Domain
    public let clientID: String
    public let authorizationURL: URL?
    /// Nil when `oauth2.txt` doesn't record its scopes as a list.
    public let grantsUserSecurity: Bool?

    public static var scopesText: String { DelegationScopes.scopes.joined(separator: ",") }

    init(domain: Domain, credentials: [Credential: Secret]) {
        self.domain = domain
        clientID = credentials[.oauth2Service].map { CredentialFacts.clientID(inServiceAccount: $0.bytes) } ?? ""
        authorizationURL = DelegationScopes.authorizationURL(clientID: clientID, domain: domain)
        grantsUserSecurity = credentials[.oauth2].flatMap { CredentialFacts.grantsUserSecurity(inOAuth2: $0.bytes) }
    }
}
