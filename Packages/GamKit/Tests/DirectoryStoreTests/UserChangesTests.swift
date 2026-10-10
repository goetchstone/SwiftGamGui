import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The user page's first writes, end to end against the strict mock: preview, confirm, the exact argv
/// GamGUI sends, the audit, and the cached directory patched (GamGUI's `patch_user`).
struct NotPreviewing: Error { let state: String }

@MainActor
@Suite("User changes", .serialized)
final class UserChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-users-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: UserChanges
    let access: UserAccess
    let runner: AuthenticatedRunner
    let argvLog: URL
    let auditURL: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        self.runner = runner
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": scratch.appending(path: "mock-state").path])
        changes = UserChanges(executor: executor, directory: directory, today: { "2026-10-09" })
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": scratch.appending(path: "mock-state").path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "gamcfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@example.com"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    private func user(_ email: String) throws -> GamUser {
        try #require(directory.users?.first { $0.primaryEmail == email })
    }

    private func pending() throws -> UserChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    /// The writes the mock ran, as argv (it logs each as a count then its elements, NUL-separated).
    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.first == "update" || ($0.count > 3 && ["delegate", "delegates"].contains($0[3]))
            || ($0.count > 2 && ["vacation", "signout"].contains($0[2])) }
    }

    @Test func aTitleAndDepartmentChangeRunsGamGUIsArgvAndPatchesTheList() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewOrganization(of: alice, title: "  Head of IT ", department: alice.department, origin: .form)
        let pending = try pending()
        #expect(!pending.isDestructive)
        #expect(pending.preview.steps.first?.shownArgv
                == ["update", "user", "alice@example.com", "organization", "title", "Head of IT", "department", alice.department, "primary"])
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .done = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(writes() == [["update", "user", "alice@example.com", "organization", "title", "Head of IT",
                              "department", alice.department, "primary"]])
        #expect(try user("alice@example.com").title == "Head of IT", "the list shows the change without a reload")
        #expect(try user("alice@example.com").department == alice.department)
        #expect(AuditLog.records(at: auditURL).first?["action"]?.string == "updateOrganization")
    }

    /// Invariant 10: a title Siri drafted is only a preview. It runs on the operator's Confirm click, never
    /// on a bare confirm, and the audit says Siri drafted it.
    @Test func aTitleSiriDraftedRunsOnlyOnTheConfirmClick() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewOrganization(of: alice, title: "Warehouse Lead", department: alice.department, origin: .siri)
        let pending = try pending()
        #expect(pending.preview.origin == .siri)
        #expect(pending.preview.needsConfirmClick, "a Siri draft must need the operator's click")
        await changes.confirm(pending, OperatorConfirmation())
        #expect(writes().isEmpty, "a Siri draft ran without the operator's click")
        await changes.previewOrganization(of: alice, title: "Warehouse Lead", department: alice.department, origin: .siri)
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        guard case .done = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(writes().count == 1)
        #expect(AuditLog.records(at: auditURL).contains { $0["extra"]?.object?["origin"]?.string == "siri" },
                "the audit must say Siri drafted it")
    }

    @Test func anUnchangedTitleAndDepartmentIsNotAWrite() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewOrganization(of: alice, title: alice.title, department: " \(alice.department) ", origin: .form)
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message.hasPrefix("Nothing to change"))
    }

    @Test func suspendingNeedsTheConfirmClickAndUnsuspendingPatchesBack() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        #expect(!alice.suspended)
        await changes.previewSuspend(alice, suspend: true)
        let pending = try pending()
        #expect(pending.isDestructive)
        await changes.confirm(pending, OperatorConfirmation())
        #expect({ if case .problem("This change needs confirmation — preview it, then confirm.") = changes.state { true } else { false } }())
        #expect(writes().isEmpty)

        await changes.previewSuspend(alice, suspend: true)
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        #expect(writes() == [["update", "user", "alice@example.com", "suspended", "on"]])
        #expect(try user("alice@example.com").suspended)
        #expect(directory.reports?.first { $0.key == "suspended" }?.count == directory.users?.filter(\.suspended).count)

        await changes.previewSuspend(try user("alice@example.com"), suspend: false)
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        #expect(try !user("alice@example.com").suspended)
    }

    /// A write that fails leaves the list as it was and says why, with GAM's remediation.
    @Test func aFailedWriteSaysWhyAndPatchesNothing() async throws {
        try await connect()
        let ghost = GamUser(record: ["primaryEmail": .string("missing@example.com"), "suspended": .bool(false)])
        await changes.previewSuspend(ghost, suspend: true)
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message.contains("missing@example.com"))
        #expect(directory.users?.contains { $0.primaryEmail == "missing@example.com" } == false)
    }

    @Test func aResultShowsOnlyUnderItsOwnPerson() async throws {
        try await connect()
        await changes.previewSuspend(try user("alice@example.com"), suspend: true)
        #expect(changes.concerns("ALICE@example.com"))
        #expect(!changes.concerns("bob@example.com"))
    }

    @Test func clearingATitleSticksForACSVShapedRecordToo() {
        let csv = GamUser(record: ["primaryEmail": .string("a@example.com"), "Organization Title": .string("Sales Lead")])
        #expect(csv.title == "Sales Lead")
        #expect(csv.with(title: "", department: "").title == "")
    }

    @Test func aWriteForAnOldTenantNeverPatchesTheNewOne() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        let before = alice.title
        directory.patch("alice@example.com", on: Domain("example.com")!, generation: setup.generation + 1) {
            $0.with(title: "Wrong tenant")
        }
        #expect(try user("alice@example.com").title == before)
    }

    // MARK: groups and delegates

    @Test func aPersonsGroupsAndDelegatesAreReadForTheirTenant() async throws {
        try await connect()
        await access.load("alice@example.com")
        let lists = try #require(access.lists(for: "alice@example.com"))
        #expect(lists.groups == ["sales@example.com", "staff@example.com"])
        #expect(lists.delegates == ["assistant@example.com", "backup@example.com"])
        #expect(access.lists(for: "bob@example.com") == nil, "only the person read")
    }

    /// Two people read at once (two windows' pages): each keeps their own lists, and neither read is
    /// left showing as running.
    @Test func eachPersonKeepsTheirOwnLists() async throws {
        try await connect()
        let access = access
        let first = Task { await access.load("alice@example.com") }
        while !access.isReading("alice@example.com") { await Task.yield() }
        await access.load("bob@example.com")
        await first.value
        #expect(access.lists(for: "bob@example.com")?.groups == ["staff@example.com"])
        #expect(access.lists(for: "alice@example.com")?.groups == ["sales@example.com", "staff@example.com"],
                "reading Bob evicted Alice's lists, and her page would wait for a read that never comes")
        #expect(!access.isReading("alice@example.com") && !access.isReading("bob@example.com"))
    }

    /// Only the last few people are kept (invariant 9), the oldest going first.
    @Test func theOldestPersonIsForgottenPastTheBound() async throws {
        try await connect()
        let access = UserAccess(setup: setup, runner: runner, keep: 2)
        access.environment = self.access.environment
        for email in ["alice@example.com", "bob@example.com", "carol@example.com"] { await access.load(email) }
        #expect(access.lists(for: "alice@example.com") == nil)
        #expect(access.lists(for: "bob@example.com") != nil && access.lists(for: "carol@example.com") != nil)
    }

    /// A page left before its delay is up reads nothing, and says so: it isn't left reading.
    @Test func aDelayedReadLeftEarlyReadsNothing() async throws {
        try await connect()
        let access = access
        let read = Task { await access.load("alice@example.com", after: .seconds(30)) }
        while !access.isReading("alice@example.com") { await Task.yield() }
        read.cancel()
        await read.value
        #expect(!access.isReading("alice@example.com"))
        #expect(access.lists(for: "alice@example.com") == nil)
    }

    @Test func joiningAGroupRunsGamGUIsArgv() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewAddToGroup(alice, group: " it@example.com ")
        let pending = try pending()
        #expect(!pending.preview.needsConfirmClick)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(writes() == [["update", "group", "it@example.com", "add", "member", "alice@example.com"]])
        #expect(changes.finished == 1)
    }

    @Test func aGroupThatIsntAnAddressIsRefusedBeforeAPreview() async throws {
        try await connect()
        await changes.previewRemoveFromGroup(try user("alice@example.com"), group: "a,b@example.com")
        guard case .problem("Pick a group to remove.") = changes.state else { Issue.record("\(changes.state)"); return }
        await changes.previewAddToGroup(try user("alice@example.com"), group: "sales")
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message.hasPrefix("“sales” isn't a group address"))
    }

    /// GamGUI's `confirm_step`: leaving a group runs only from its confirm step.
    @Test func leavingAGroupNeedsTheConfirmStep() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewRemoveFromGroup(alice, group: "sales@example.com")
        let pending = try pending()
        #expect(pending.preview.needsConfirmClick)
        await changes.confirm(pending, OperatorConfirmation())
        #expect(writes().isEmpty)
        await changes.previewRemoveFromGroup(alice, group: "sales@example.com")
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        #expect(writes() == [["update", "group", "sales@example.com", "remove", "alice@example.com"]])
    }

    @Test func aDelegateIsCheckedAsGamGUIChecksIt() async throws {
        try await connect()
        let users = directory.users
        let check = { (delegate: String) in UserChanges.checkDelegate(delegate, for: "alice@example.com", directory: users) }
        #expect(check("").error == "Enter a delegate email.")
        #expect(check("bob").error?.hasPrefix("“bob” isn't an email address") == true)
        #expect(check("ALICE@example.com").error == "A mailbox can't be delegated to its own owner.")
        #expect(UserChanges.checkDelegate("a.anders@example.com", for: "carol@example.com", directory: users).error
                == "a.anders@example.com is an alias of alice@example.com — enter the primary address.")
        #expect(check("stranger@example.com").warning?.hasPrefix("stranger@example.com isn't in the directory") == true)
        #expect(check("bob@example.com").warning?.hasPrefix("bob@example.com is suspended") == true)
        #expect(UserChanges.checkDelegate("bob@example.com", for: "alice@example.com", directory: nil).warning != nil)
    }

    @Test func addingAndRemovingADelegateRunsGamGUIsArgvAndTheListFollows() async throws {
        try await connect()
        let carol = try user("carol@example.com")
        await changes.previewAddDelegate(carol, delegate: "alice@example.com", directory: directory.users)
        let pending = try pending()
        #expect(pending.warning == nil)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        await access.load("carol@example.com")
        #expect(access.lists(for: "carol@example.com")?.delegates == ["helpdesk@example.com", "alice@example.com"])
        await changes.previewRemoveDelegate(carol, delegate: "alice@example.com")
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        await access.load("carol@example.com")
        #expect(access.lists(for: "carol@example.com")?.delegates == ["helpdesk@example.com"])
        #expect(writes() == [["user", "carol@example.com", "add", "delegate", "alice@example.com"],
                             ["user", "carol@example.com", "delete", "delegate", "alice@example.com"]])
    }

    @Test func aDelegateWarningIsShownAndConfirmingIsAddAnyway() async throws {
        try await connect()
        await changes.previewAddDelegate(try user("carol@example.com"), delegate: "bob@example.com", directory: directory.users)
        let pending = try pending()
        #expect(pending.warning?.hasPrefix("bob@example.com is suspended") == true)
        #expect(pending.confirmLabel == "Add Anyway")
    }

    // MARK: auto-reply and sign-out

    @Test func anAutoReplyGoesOutAsGamGUIsHTMLAndIsReadBack() async throws {
        try await connect()
        let bob = try user("bob@example.com")
        await changes.previewAutoReply(bob, subject: "Out of office", text: "Back Monday.\nUrgent? Call <the desk> & ask.",
                                       contactsOnly: false, domainOnly: true, start: " 2026-10-12 ", end: "")
        let pending = try pending()
        #expect(!pending.preview.needsConfirmClick)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(writes() == [["user", "bob@example.com", "vacation", "on", "subject", "Out of office", "message",
                              "Back Monday.<br/>Urgent? Call &lt;the desk&gt; &amp; ask.", "html", "contactsonly", "false",
                              "domainonly", "true", "start", "2026-10-12", "end", "NotSpecified"]])
        await access.load("bob@example.com")
        let vacation = try #require(try access.lists(for: "bob@example.com")?.vacation.get())
        #expect(vacation.enabled)
        #expect(vacation.subject == "Out of office")
        #expect(HTMLText.autoreplyText(vacation.message) == "Back Monday.\nUrgent? Call <the desk> & ask.",
                "the form pre-fills the text, not its markup")
    }

    /// GamGUI loads each panel on its own: a failed auto-reply read doesn't hide the groups and delegates.
    @Test func aFailedAutoReplyReadLeavesTheOtherLists() async throws {
        try await connect()
        let state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
        try Data().write(to: state.appending(path: "nogmail/alice@example.com"))
        await access.load("alice@example.com")
        let lists = try #require(access.lists(for: "alice@example.com"))
        #expect(lists.groups == ["sales@example.com", "staff@example.com"])
        guard case .failure(let problem) = lists.vacation else { Issue.record("\(lists.vacation)"); return }
        #expect(problem.summary.contains("Gmail Service/App not enabled"))
    }

    /// Live, 2026-10-09: the operator blanked a reply's message on purpose. Allowed (as in GamGUI), and said.
    @Test func anAutoReplyWithNoMessageIsWarnedAboutNotRefused() async throws {
        try await connect()
        await changes.previewAutoReply(try user("bob@example.com"), subject: "Away", text: " \n ", contactsOnly: false,
                                       domainOnly: false, start: "", end: "")
        let pending = try pending()
        #expect(pending.warning?.hasPrefix("No message: senders get only the subject line.") == true)
        #expect(pending.confirmLabel == "Turn On Anyway")
    }

    @Test func anAutoReplyWhoseEndHasPassedIsWarnedAbout() async throws {
        try await connect()
        await changes.previewAutoReply(try user("bob@example.com"), subject: "Away", text: "Back soon.", contactsOnly: false,
                                       domainOnly: false, start: "2026-01-14", end: "2026-01-16")
        let pending = try pending()
        #expect(pending.warning?.hasPrefix("The end date (2026-01-16) has already passed") == true)
        #expect(pending.confirmLabel == "Turn On Anyway")
        await changes.previewAutoReply(try user("bob@example.com"), subject: "Away", text: "Back soon.", contactsOnly: false,
                                       domainOnly: false, start: "", end: "2026-10-09")
        #expect(try self.pending().warning == nil, "ending today hasn't passed")
    }

    @Test func anAutoReplyEndingBeforeItStartsIsRefused() async throws {
        try await connect()
        await changes.previewAutoReply(try user("bob@example.com"), subject: "Away", text: "Back soon.", contactsOnly: false,
                                       domainOnly: false, start: "2026-10-20", end: "2026-10-12")
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message == "The end date (2026-10-12) is before the start date (2026-10-20).")
    }

    @Test func anAutoReplyIsTurnedOff() async throws {
        try await connect()
        await changes.previewAutoReplyOff(try user("alice@example.com"))
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        #expect(writes() == [["user", "alice@example.com", "vacation", "off"]])
    }

    @Test func signingOutRunsGamGUIsArgvAndARefusalSaysWhy() async throws {
        try await connect()
        await changes.previewSignOut(try user("alice@example.com"))
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        #expect(writes() == [["user", "alice@example.com", "signout"]])
        let refused = GamUser(record: ["primaryEmail": .string("SIGNOUTFAIL@example.com")])
        await changes.previewSignOut(refused)
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message.contains("Sign Out Failed"))
    }
}