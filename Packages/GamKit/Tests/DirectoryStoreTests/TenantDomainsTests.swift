import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The Builder's External Only lens reads the tenant's domains (GamGUI's `tenant_domains`, 2.10's sweep): the primary, then every
/// secondary and domain alias `print domains` names, kept for the tenant read.
@MainActor
@Suite("Tenant domains", .serialized)
final class TenantDomainsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-domains-\(UUID().uuidString)")
    let setup: SetupModel
    let access: UserAccess

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let vault = Vault(store: MemoryStore())
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        access = UserAccess(setup: setup, runner: runner)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test func thePrimaryThenEveryDomainGamNames() async throws {
        #expect(await access.tenantDomains().isEmpty, "no tenant, no domains")
        let folder = scratch.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        let domains = await access.tenantDomains()
        #expect(domains.first == "example.com")
        #expect(Set(domains) == ["example.com", "example.net", "alias.example.net"], "\(domains)")
        #expect(CatalogResult.isExternal("pat@partner.org", domains: domains) && !CatalogResult.isExternal("x@alias.example.net", domains: domains))
    }
}
