import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Groups slice B: adding people to a group and removing a member from its page, previewed, confirmed and
/// run through ChangeCore, end to end against the strict mock with its argv log and state. Ports GamGUI's
/// board tests (`tests/test_groups_board.py`, the board's rows of `test_users_web.py` and
/// `test_write_routes_guarded.py`) and the incidents behind them: a write that ran on a bare POST, a confirm
/// that ran what the form said then rather than what the preview showed, and a preview held on one tenant
/// for what was read on another (GamGUI failure-log 2026-09-23, 2026-09-25).
@MainActor
@Suite("Group changes", .serialized)
final class GroupChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-group-changes-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let groups: GroupStore
    let members: GroupMembers
    let access: UserAccess
    let changes: GroupChanges
    let argvLog: URL
    let auditURL: URL
    let state: URL
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        groups = GroupStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        members = GroupMembers(setup: setup, runner: runner)
        members.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        changes = GroupChanges(executor: executor, setup: setup, members: members)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Imports `domain` with an `oauth2.txt` naming its admin, checks access (a pass connects it), and loads
    /// its directory and groups.
    private func connect(_ domain: String = "example.com") async throws {
        let folder = scratch.appending(path: "config-\(domain)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@\#(domain)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        await directory.load()
        await groups.load()
    }

    private func group(_ email: String) throws -> GamGroup {
        try #require(groups.group(at: email))
    }

    /// A group GAM no longer has (deleted since the list was read), or an address that isn't one.
    private func unlisted(_ email: String) -> GamGroup {
        GamGroup(record: ["email": .string(email)])
    }

    private func member(_ email: String, role: String = "MEMBER", type: String = "USER") -> GroupMember {
        GroupMember(record: ["email": .string(email), "role": .string(role), "type": .string(type)])
    }

    private func pending() throws -> GroupChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private func problem() throws -> GroupChanges.Problem {
        guard case .problem(let problem) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return problem
    }

    private func done() throws -> String {
        guard case .done(let message) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return message
    }

    /// Every call the mock logged, as the bytes it was handed (a count, then each element, NUL-separated).
    private func calls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    /// The group writes the mock ran.
    private func writes() -> [[String]] {
        calls().filter { $0.count > 1 && $0[0] == "update" && $0[1] == "group" }
    }

    private func bytes(_ calls: [[String]]) -> [[[UInt8]]] { calls.map { $0.map { Array($0.utf8) } } }

    /// GamGUI's `_audited`: each write's end record, oldest first.
    private func audited() -> [(action: String, target: String, ok: Bool)] {
        AuditLog.records(at: auditURL).reversed()
            .filter { $0["extra"]?.object?["phase"]?.string == "end" }
            .map { ($0["action"]?.string ?? "", $0["target"]?.string ?? "", $0["ok"] == .bool(true)) }
    }

    private func gamguiArgv(_ builder: String, _ kwargs: [String: String]) throws -> [String] {
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.argvJSON)) as? [String: Any])
        let cases = try #require(document["cases"] as? [[String: Any]])
        let found = cases.first { $0["builder"] as? String == builder && $0["kwargs"] as? [String: String] == kwargs }
        return try #require(found?["argv"] as? [String])
    }

    // MARK: adding

    /// `test_add_sends_the_role_through_the_builder`: GamGUI's builder, the address stripped, the role named,
    /// and the audit's record of it.
    @Test func anAddWithARoleRunsGamGUIsArgv() async throws {
        try await connect()
        await changes.previewAdd(" carol@example.com ", to: try group("sales@example.com"), role: .owner)
        let pending = try pending()
        #expect(pending.title == "Add carol@example.com to sales@example.com")
        #expect(pending.confirmLabel == "Add")
        #expect(pending.preview.steps.map(\.summary) == ["Add carol@example.com to sales@example.com as owner."])
        #expect(writes().isEmpty, "a preview writes nothing")
        await changes.confirm(pending, confirmed)
        #expect(try done() == "Added carol@example.com to sales@example.com as owner.")
        #expect(bytes(writes()) == bytes([["update", "group", "sales@example.com", "add", "owner", "carol@example.com"]]))
        #expect(audited().map(\.action) == ["addGroupMember"] && audited().map(\.target) == ["carol@example.com"]
                && audited().map(\.ok) == [true])
        let end = try #require(AuditLog.records(at: auditURL).first)
        #expect(end["extra"]?.object?["group"]?.string == "sales@example.com")
    }

    /// The role choices are GamGUI's `GROUP_ROLES`, and each is held to GamGUI's argv for it (argv.json).
    @Test func eachRoleIsHeldToGamGUIsArgv() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        for role in GamCommands.GroupRole.allCases {
            await changes.previewAdd("carol@example.com", to: sales, role: role)
            let held = try #require(try pending().preview.steps.first?.shownArgv)
            let gamgui = try gamguiArgv("add_group_member", ["group": "sales@example.com", "member": "carol@example.com",
                                                              "role": role.rawValue])
            #expect(bytes([held]) == bytes([gamgui]), "\(role)")
        }
        #expect(GamCommands.GroupRole.allCases.map(\.rawValue) == ["member", "manager", "owner"])
    }

    /// `test_a_bad_add_is_refused_in_words_before_gam`: free text meets GAM's `<UserTypeEntity>` (the admin, a
    /// name at the domain, or a list), so each address must be one address before anything is held.
    @Test func aBadAddIsRefusedInWordsBeforeGam() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        let refusals: [(text: String, group: GamGroup, why: String)] = [
            ("  ", sales, "Enter the email address of the person to add."),
            (" \n , ", sales, "Enter the email address of the person to add."),
            ("carol@example.com", unlisted(" "), "Pick a group first."),
            ("carol@example.com", unlisted("a@example.com,b@example.com"), "Pick a group first."),
            ("oauthuser", sales, "“oauthuser” isn't one email address. Pick someone from the suggestions, or type their full address."),
            ("Carol Clark", sales, "“Carol Clark” isn't one email address. Pick someone from the suggestions, or type their full address."),
            ("carol@example.com\nCarol Clark", sales, "“Carol Clark” isn't one email address. Pick someone from the suggestions, or type their full address."),
        ]
        for refusal in refusals {
            await changes.previewAdd(refusal.text, to: refusal.group, role: .member)
            #expect(try problem().summary == refusal.why, "\(refusal.text)")
        }
        #expect(writes().isEmpty)
        #expect(audited().isEmpty)
    }

    /// GamGUI's form takes one person; here several addresses (one per line, or separated by commas or
    /// semicolons) are one preview with one GamGUI step each, a repeat dropped.
    @Test func severalAddressesAreOnePreviewWithAStepEach() async throws {
        try await connect()
        #expect(GroupChanges.addresses(in: " carol@example.com\n dana@example.com , ;CAROL@example.com\r\nguest@outside.example.org;")
                == ["carol@example.com", "dana@example.com", "guest@outside.example.org"])
        await changes.previewAdd("carol@example.com\ndana@example.com, CAROL@example.com", to: try group("sales@example.com"), role: .member)
        let pending = try pending()
        #expect(pending.title == "Add 2 people to sales@example.com")
        #expect(pending.confirmLabel == "Add 2 People")
        #expect(pending.members == ["carol@example.com", "dana@example.com"])
        await changes.confirm(pending, confirmed)
        #expect(try done() == "Added 2 people to sales@example.com as member.")
        #expect(writes() == [["update", "group", "sales@example.com", "add", "member", "carol@example.com"],
                             ["update", "group", "sales@example.com", "add", "member", "dana@example.com"]])
    }

    // MARK: confirming

    /// Every group write is confirmed from its sheet: the guard wants the Confirm click (GamGUI's
    /// `confirm_step` for a removal), so a bare confirm writes nothing and spends the preview.
    @Test func theConfirmClickIsRequired() async throws {
        try await connect()
        await changes.previewAdd("carol@example.com", to: try group("sales@example.com"), role: .member)
        let add = try pending()
        #expect(add.preview.needsConfirmClick)
        await changes.confirm(add, OperatorConfirmation())
        #expect(try problem().summary == "This change needs confirmation — preview it, then confirm.")
        await changes.previewRemove(member("alice@example.com", role: "OWNER"), from: try group("sales@example.com"))
        let remove = try pending()
        #expect(remove.preview.needsConfirmClick)
        await changes.confirm(remove, OperatorConfirmation())
        #expect(try problem().summary == "This change needs confirmation — preview it, then confirm.")
        await changes.confirm(add, confirmed)
        #expect(writes().isEmpty, "a refused preview is spent")
    }

    /// GamGUI failure-log 2026-09-23 ("stale Apply"): a confirm runs the preview it was given exactly as
    /// held, and only while it's the one the screen shows. An edited address list, another group, a replay
    /// or a bare confirm writes nothing.
    @Test func confirmRunsWhatThePreviewHeld() async throws {
        try await connect()
        let sales = try group("sales@example.com"), staff = try group("staff@example.com")
        await changes.previewAdd("carol@example.com", to: sales, role: .member)
        let first = try pending()
        await changes.previewAdd("carol@example.com, dana@example.com", to: sales, role: .member)
        let edited = try pending()
        await changes.confirm(first, confirmed)
        #expect(writes().isEmpty, "the address list was edited after the first preview")
        await changes.previewAdd("dana@example.com", to: staff, role: .manager)
        let switched = try pending()
        await changes.confirm(edited, confirmed)
        #expect(writes().isEmpty, "the group changed after that preview")
        await changes.confirm(switched, confirmed)
        #expect(writes() == [["update", "group", "staff@example.com", "add", "manager", "dana@example.com"]])
        await changes.confirm(switched, confirmed)
        #expect(writes().count == 1, "a replayed confirm")
    }

    /// Above 25 people the count is typed, as the guard asks (`Guard.countConfirmAbove`); 25 needs only the click.
    @Test func moreThan25PeopleNeedTheirCountTyped() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        let guests = (1...26).map { String(format: "guest%02d@outside.example.org", $0) }
        await changes.previewAdd(guests.dropLast().joined(separator: "\n"), to: sales, role: .member)
        #expect(try pending().preview.decision.requiresTypedCount == false)
        await changes.previewAdd(guests.joined(separator: "\n"), to: sales, role: .member)
        let many = try pending()
        #expect(many.preview.decision.requiresTypedCount)
        await changes.confirm(many, confirmed)
        #expect(try problem().summary == "This changes 26 accounts: preview again, and type 26 to confirm.")
        await changes.previewAdd(guests.joined(separator: "\n"), to: sales, role: .member)
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true, typedCount: "25"))
        #expect(writes().isEmpty)
        await changes.previewAdd(guests.joined(separator: "\n"), to: sales, role: .member)
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true, typedCount: " 26 "))
        #expect(try done() == "Added 26 people to sales@example.com as member.")
        #expect(writes().count == 26)
    }

    // MARK: the tenant

    /// GamGUI failure-log 2026-09-25: a preview held on one tenant never runs on another.
    @Test func aTenantSwitchRefuses() async throws {
        try await connect()
        await changes.previewAdd("carol@example.com", to: try group("sales@example.com"), role: .member)
        let held = try pending()
        try await connect("example.org")
        #expect(setup.active == Domain("example.org"))
        await changes.confirm(held, confirmed)
        #expect(try problem().summary == "The active domain changed after the preview — preview again, so it runs on this one.")
        #expect(writes().isEmpty)
    }

    /// The group and its members are the screen's reads of the connected tenant; a switch landing while the
    /// preview is held (the executor's tenant already the next one) refuses it.
    @Test func aPreviewHeldAfterASwitchIsRefused() async throws {
        try await connect()
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault,
                                         runtimeDirectory: try RuntimeDirectory.prepare(scratch.appending(path: "run2")))
        let next = setup.generation + 1
        let switched = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { (Domain("example.org")!, next) },
                                extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_STATE": state.path])
        let changes = GroupChanges(executor: switched, setup: setup, members: members)
        await changes.previewRemove(member("alice@example.com", role: "OWNER"), from: try group("sales@example.com"))
        guard case .problem(let refused) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(refused.summary == Executor.PreviewRefusal.tenantChanged.message)
    }

    // MARK: removing

    /// `test_remove_runs_only_from_its_confirm_step`: the confirm step names who leaves which group and writes
    /// nothing; confirmed, GamGUI's argv runs.
    @Test func removeRunsOnlyFromItsConfirmStep() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        await changes.previewRemove(member("alice@example.com", role: "MEMBER"), from: sales)
        let pending = try pending()
        #expect(pending.title == "Remove alice@example.com from sales@example.com?")
        #expect(pending.confirmLabel == "Remove")
        #expect(writes().isEmpty)
        await changes.confirm(pending, OperatorConfirmation())
        #expect(writes().isEmpty)
        await changes.previewRemove(member("alice@example.com"), from: sales)
        await changes.confirm(try self.pending(), confirmed)
        #expect(try done() == "Removed alice@example.com from sales@example.com.")
        #expect(writes() == [["update", "group", "sales@example.com", "remove", "alice@example.com"]])
        #expect(audited().map(\.action) == ["removeGroupMember"] && audited().map(\.ok) == [true])
    }

    /// `test_the_confirm_step_warns_before_removing_an_owner` (`_group_remove_confirm.html`): an owner's and a
    /// manager's role is said, and what leaving means is said for everyone.
    @Test func theConfirmStepSaysWhatRemovingMeans() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        let leaving = "They stop getting the group's mail and lose what is shared with it. You can add them back."
        await changes.previewRemove(member("bob@example.com", role: "OWNER"), from: sales)
        #expect(try pending().notes == ["They are an owner — make sure the group keeps one.", leaving])
        await changes.previewRemove(member("bob@example.com", role: "MANAGER"), from: sales)
        #expect(try pending().notes == ["They are a manager.", leaving])
        await changes.previewRemove(member("bob@example.com", role: "MEMBER"), from: sales)
        #expect(try pending().notes == [leaving])
    }

    /// `test_remove_refuses_a_member_that_isnt_one_address` and `test_a_member_with_no_address_has_no_remove`:
    /// GAM would read anything else as something else, and everyone in the organization has no address.
    @Test func removeRefusesAMemberThatIsntOneAddress() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        for who in [member("oauthuser"), member("alice@example.com,bob@example.com"), member("", type: "CUSTOMER")] {
            await changes.previewRemove(who, from: sales)
            #expect(try problem().summary == "Pick a member to remove.", "\(who.email)")
        }
        await changes.previewRemove(member("alice@example.com"), from: unlisted("a@example.com,b@example.com"))
        #expect(try problem().summary == "Pick a member to remove.")
        #expect(writes().isEmpty && audited().isEmpty)
    }

    // MARK: failures and the list

    /// `test_a_failed_add_says_why` and `test_a_failed_write_says_why_with_gams_error_expandable`: the
    /// headline says what didn't happen and why in words; GAM's own error is the detail, never the headline.
    @Test func aFailedWriteSaysWhyWithGamsError() async throws {
        try await connect()
        await changes.previewAdd("carol@example.com", to: unlisted("missing@example.com"), role: .member)
        await changes.confirm(try pending(), confirmed)
        let gone = try problem()
        #expect(gone.summary == "Couldn't add carol@example.com to missing@example.com. The requested user, group, or resource was not found.")
        #expect(gone.detail?.contains("Group: missing@example.com, Does not exist") == true)
        #expect(!gone.summary.contains("GAM failed"))
        #expect(audited().map(\.ok) == [false])

        await changes.previewAdd("alice@example.com", to: try group("sales@example.com"), role: .member)
        await changes.confirm(try pending(), confirmed)
        let already = try problem()
        #expect(already.summary == "Couldn't add alice@example.com to sales@example.com. alice@example.com is already in sales@example.com.")
        #expect(already.detail?.contains("Add Failed: Member already exists.") == true)

        await changes.previewAdd("nobody@example.com", to: try group("sales@example.com"), role: .member)
        await changes.confirm(try pending(), confirmed)
        #expect(try problem().summary == "Couldn't add nobody@example.com to sales@example.com. "
                + "Google has no user or group at nobody@example.com. Check the address.")

        await changes.previewRemove(member("dana@example.com"), from: try group("sales@example.com"))
        await changes.confirm(try pending(), confirmed)
        let left = try problem()
        #expect(left.summary == "Couldn't remove dana@example.com from sales@example.com. dana@example.com isn't in sales@example.com now.")
        #expect(left.detail?.contains("Remove Failed: Does not exist") == true)
    }

    /// Several people, some added: what was added, and why each of the rest wasn't, at most five said
    /// (invariant 9) and the rest counted.
    @Test func aMixedResultSaysWhatWasAddedAndWhyNotTheRest() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        await changes.previewAdd("carol@example.com, alice@example.com", to: sales, role: .member)
        await changes.confirm(try pending(), confirmed)
        let mixed = try problem()
        #expect(mixed.summary == "Added 1 of 2 people to sales@example.com as member. alice@example.com is already in sales@example.com.")
        #expect(writes().count == 2)

        let nobody = (1...7).map { "nobody\($0)@example.com" }
        await changes.previewAdd(nobody.joined(separator: ","), to: sales, role: .member)
        await changes.confirm(try pending(), confirmed)
        let none = try problem()
        #expect(none.summary.hasPrefix("Added none of the 7 people to sales@example.com. Google has no user or group at nobody1@example.com."))
        #expect(none.summary.hasSuffix("Google has no user or group at nobody5@example.com. Check the address. 2 more weren't added either."),
                "\(none.summary)")
        #expect(none.detail?.split(separator: "\n").count == 5)
    }

    /// GamGUI re-reads the list after every write (`_list_ctx`): the page shows what GAM holds now, with no
    /// read asked for by the screen, and a person's groups agree.
    @Test func theListIsReadAgainAfterAWrite() async throws {
        try await connect()
        let sales = try group("sales@example.com")
        await members.load("sales@example.com")
        #expect(members.members(of: "sales@example.com")?.map(\.email) == ["alice@example.com", "it@example.com"])
        await changes.previewAdd("carol@example.com", to: sales, role: .manager)
        await changes.confirm(try pending(), confirmed)
        #expect(members.members(of: "sales@example.com")?.map(\.email) == ["alice@example.com", "carol@example.com", "it@example.com"])
        #expect(members.members(of: "sales@example.com")?.first { $0.email == "carol@example.com" }?.role == "MANAGER")
        await access.load("carol@example.com")
        #expect(access.lists(for: "carol@example.com")?.groups == ["it@example.com", "sales@example.com"])

        await changes.previewRemove(member("alice@example.com", role: "OWNER"), from: sales)
        await changes.confirm(try pending(), confirmed)
        #expect(members.members(of: "sales@example.com")?.map(\.email) == ["carol@example.com", "it@example.com"])

        // A failed write reads it again too: someone may have changed it elsewhere.
        let reads = calls().filter { $0.starts(with: ["print", "group-members"]) }.count
        await changes.previewRemove(member("alice@example.com"), from: sales)
        await changes.confirm(try pending(), confirmed)
        #expect(calls().filter { $0.starts(with: ["print", "group-members"]) }.count == reads + 1)
    }

    /// The re-read belongs to the tenant the write ran on: after a switch mid-write, nothing of the next
    /// tenant is read for it.
    @Test func theListIsNotReadOnAnotherTenantAfterASwitch() async throws {
        try await connect()
        let started = scratch.appending(path: "write-started")
        let script = scratch.appending(path: "slow-mock.sh")
        try Data(("#!/bin/sh\ntrap 'exit 143' TERM\n"
                  + "case \"$1 $2\" in \"update group\") : > '\(started.path)'; sleep 2 ;; esac\n"
                  + "exec '\(Fixtures.mockGam.path)' \"$@\"\n").utf8).write(to: script)
        chmod(script.path, 0o755)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault,
                                         runtimeDirectory: try RuntimeDirectory.prepare(scratch.appending(path: "run3")))
        let setup = setup
        let slow = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_STATE": state.path])
        let changes = GroupChanges(executor: slow, setup: setup, members: members)
        await changes.previewAdd("carol@example.com", to: try group("sales@example.com"), role: .member)
        guard case .previewing(let pending) = changes.state else { Issue.record("\(changes.state)"); return }
        let confirming = Task { await changes.confirm(pending, confirmed) }
        while !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        try await connect("example.org")
        await confirming.value
        #expect(writes().count == 1, "the write ran on example.com")
        #expect(!calls().contains { $0.starts(with: ["print", "group-members"]) }, "example.org's sales@ was read")
        #expect(members.members(of: "sales@example.com") == nil)
    }

    /// A result shows on its own group's page only.
    @Test func aResultConcernsItsOwnGroup() async throws {
        try await connect()
        await changes.previewAdd("oauthuser", to: try group("sales@example.com"), role: .member)
        #expect(changes.concerns("SALES@example.com"))
        #expect(!changes.concerns("staff@example.com"))
    }

    // MARK: choosing people

    /// `test_the_people_type_ahead_is_capped_and_offers_options` (`_pick`): the directory's people whose
    /// address or name holds the words, at most 15, and whether there are more.
    @Test func peopleAreSuggestedFromTheDirectoryAsGamGUISuggestsThem() async throws {
        try await connect()
        let users = try #require(directory.users)
        let carol = GroupChanges.people(matching: " CAR ", in: users)
        #expect(carol.shown.map(\.primaryEmail) == ["carol@example.com"] && !carol.more)
        #expect(GroupChanges.people(matching: "", in: users).shown.isEmpty, "nothing until something is typed")
        let many = (0..<40).map { GamUser(record: ["primaryEmail": .string(String(format: "person%02d@example.com", $0))]) }
        let capped = GroupChanges.people(matching: "person", in: many)
        #expect(capped.shown.count == GroupChanges.pickLimit && capped.more)
        #expect(capped.shown.first?.primaryEmail == "person00@example.com")
    }
}
