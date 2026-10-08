import Foundation
import Testing
@testable import GamEngine
import TestSupport
import Vault

/// Setup's Check access against the strict mock, which answers `check serviceaccount` the way the
/// vendored build prints it: a tenant that authorized exactly the delegation scopes, a `*partialdwd*`
/// admin missing two, and a `*badkey*` admin whose key Google rejected. GamGUI's verify history
/// (failure-log 2026-09-25 ×3, 2026-10-01) is what these hold.
@Suite("AccessCheck", .serialized)
struct AccessCheckTests {
    let example = Domain("example.com")!
    let runner: AuthenticatedRunner

    init() throws {
        let store = MemoryStore()
        for credential in Credential.allCases {
            try store.write(Data("{\"placeholder\": true}".utf8), as: credential, for: example)
        }
        let base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: Vault(store: store),
                                     runtimeDirectory: base)
    }

    private func check(_ admin: String) async throws -> AccessCheck {
        // checkAccess passes no mock environment; the mock needs its fixtures only for other commands.
        try await runner.checkAccess(admin: admin, as: example)
    }

    @Test func aTenantThatAuthorizedExactlyOurScopesPasses() async throws {
        let result = try await check("admin@example.com")
        #expect(result.outcome == .authorized)
        #expect(result.rows.filter(\.isScope).count == DelegationScopes.scopes.count)
        #expect(result.authorizationURL == nil)
    }

    @Test func missingDelegationNamesTheCountAndCarriesTheDirectLink() async throws {
        let result = try await check("partialdwd@example.com")
        #expect(result.outcome == .delegationIncomplete(failed: 2, of: DelegationScopes.scopes.count))
        #expect(result.authorizationURL?.host() == "admin.google.com")
    }

    @Test func aRejectedKeyIsNamedNotBlamedOnDelegation() async throws {
        let result = try await check("badkey@example.com")
        #expect(result.outcome == .serviceAccountProblem(["Service Account Private Key Authentication"]))
        #expect(result.authorizationURL == nil)
    }

    @Test func aFailureWithoutACheckAnswerIsAPlainError() {
        let result = AccessCheck.interpret(GamResult(
            exitCode: 16, stdout: "",
            stderr: "\nERROR: Service Account OAuth2 File: /x/oauth2service.json, Does not exist\n",
            stdoutTruncated: false, stderrTruncated: false))
        #expect(result.outcome == .failed("ERROR: Service Account OAuth2 File: /x/oauth2service.json, Does not exist"))
    }

    @Test func rowsAreReadInBothOfGamsForms() {
        let rows = AccessCheck.rows(in: """
            System time status:                                  PASS
              https://www.googleapis.com/auth/tasks              FAIL (7/7)
            Domain-wide Delegation authentication:, User: a@example.com, Scopes: 7
            """)
        #expect(rows == [AccessCheck.Row(label: "System time status", passed: true),
                         AccessCheck.Row(label: "https://www.googleapis.com/auth/tasks", passed: false)])
    }

    @Test func theDirectAdminLinkWinsOverTheShortLink() {
        let url = AccessCheck.authorizationURL(in: """
            https://gam-shortn.appspot.com/abc
                https://admin.google.com/ac/owl/domainwidedelegation?clientIdToAdd=1.
            """)
        #expect(url?.absoluteString == "https://admin.google.com/ac/owl/domainwidedelegation?clientIdToAdd=1")
    }

    @Test func theScopesAreGamGUIsDelegationScopes() throws {
        // The mock tests' concrete check_svcacct call passes GamGUI's DWD_SCOPES.
        let document = try JSONDecoder().decode(GoldenArgvTests.Document.self, from: Data(contentsOf: Fixtures.argvJSON))
        let calls = document.cases.filter { $0.builder == "check_svcacct" && $0.kwargs["admin"] == .string("admin@example.com") }
        #expect(calls.contains { $0.kwargs["scopes"] == .strings(DelegationScopes.scopes) })
    }

    @Test func theExitCodesAreTheBuilds() throws {
        struct Codes: Decodable { let build_rc: [String: Int32] }
        let codes = try JSONDecoder().decode(Codes.self, from: Data(contentsOf: Fixtures.exitCodesJSON))
        #expect(codes.build_rc["SCOPES_NOT_AUTHORIZED_RC"] == GamExitCode.scopesNotAuthorized)
        #expect(codes.build_rc["OAUTH2SERVICE_JSON_REQUIRED_RC"] == GamExitCode.oauth2ServiceJSONRequired)
    }

    @Test func theDelegationLinkIsPrefilled() {
        let url = DelegationScopes.authorizationURL(clientID: "1234567890", domain: example)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(url?.host() == "admin.google.com")
        #expect(items.first { $0.name == "clientScopeToAdd" }?.value == DelegationScopes.scopes.joined(separator: ","))
        #expect(items.first { $0.name == "dn" }?.value == "example.com")
        #expect(DelegationScopes.authorizationURL(clientID: "") == nil)
    }
}
