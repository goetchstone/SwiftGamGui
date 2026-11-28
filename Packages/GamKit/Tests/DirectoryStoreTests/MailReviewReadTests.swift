import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Reports' mail review against the strict mock (GamGUI's `tests/test_mail_review.py`, "the connector"): the clean read, Gmail
/// off for one account, a silent skip, and nothing read never shown as "none".
@MainActor
@Suite("Mail review read", .serialized)
final class MailReviewReadTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mailreview-\(UUID().uuidString)")
    let setup: SetupModel
    let access: UserAccess
    let state: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let vault = Vault(store: MemoryStore())
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
    }

    private func marker(_ folder: String, _ user: String) throws {
        let dir = state.appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: user))
    }

    private func review() async throws -> MailReview {
        let model = MailReviewRead(setup: setup, access: access)
        await model.read()
        guard case .read(.success(let review), _)? = model.state else { throw NotPreviewing(state: "\(String(describing: model.state))") }
        return review
    }

    @Test func theCleanRead() async throws {
        try await connect()
        let review = try await review()
        #expect(review.forwarding == [MailReview.Forwarding(user: "carol@example.com", to: "carol.home@example.org", disposition: "leaveInInbox")])
        #expect(review.delegations.contains { $0.user == "alice@example.com" })
        #expect(review.forwardingAccounts.read == review.forwardingAccounts.listed && review.complete)
    }

    /// GamGUI #198: each read is given the active people from a fresh directory read, the suspended left out, and each one is
    /// accounted for from their own worker's lines.
    @Test func eachReadIsGivenExactlyTheActivePeople() async throws {
        try await connect()
        let users = try String(contentsOf: Fixtures.mockGamData.appending(path: "print_users.json"), encoding: .utf8)
        let active = users.split(separator: "\n").filter { $0.contains("primaryEmail") && !$0.contains(#""suspended": true"#) }.count
        try #require(active > 1)
        let review = try await review()
        #expect(review.forwardingAccounts.listed == active && review.delegationAccounts.listed == active)
        #expect(review.delegationAccounts.read == active)
    }

    @Test func gmailOffForOneAccountKeepsTheOthersAndNamesIt() async throws {
        try await connect()
        try marker("nogmail", "carol@example.com")
        let review = try await review()
        #expect(review.forwarding.isEmpty && !review.complete)
        #expect(review.forwardingAccounts.unread == [MailReview.Unread(user: "carol@example.com", why: MailReview.gmailOff)])
        #expect(review.forwardingAccounts.read == review.forwardingAccounts.listed - 1)
    }

    @Test func anAccountSkippedWithoutAWordIsNeverReadAsNotForwarding() async throws {
        try await connect()
        try marker("quiet", "carol@example.com")
        let review = try await review()
        #expect(review.forwarding.isEmpty && review.forwardingAccounts.skipped == 1 && !review.complete)
    }
}
