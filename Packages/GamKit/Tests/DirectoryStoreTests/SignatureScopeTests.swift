import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Signatures for many people (S2): a group's members, an org unit, the whole company, previewed, confirmed and run
/// through ChangeCore against the strict mock with its argv log. Ports GamGUI's `tests/test_signatures.py` (the scopes),
/// the signature cases of `test_users_web.py`, `test_retry_failures.py`, `test_jobs_tray.py` and
/// `test_write_routes_guarded.py`. The mock's directory: admin, alice and dana in /Staff, carol in /Students, bob
/// suspended in /Staff.
@MainActor
@Suite("Signature scopes", .serialized)
final class SignatureScopeTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-sigscope-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let runner: AuthenticatedRunner
    let base: URL
    let argvLog: URL
    let auditURL: URL
    let state: URL
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The screen's changes, writing through `writer` (the mock by default), reading groups with the mock.
    private func changes(writer: AuthenticatedRunner? = nil) -> SignatureChanges {
        let setup = setup
        let executor = Executor(runner: writer ?? runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        let changes = SignatureChanges(executor: executor, setup: setup, directory: directory, runner: runner)
        changes.environment = ["GAM_MOCK_STATE": state.path]
        return changes
    }

    private func connect(_ domain: String = "example.com", admin: String = "admin@example.com") async throws {
        let folder = scratch.appending(path: "config-\(domain)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        await directory.load()
    }

    private func pending(_ changes: SignatureChanges) throws -> SignatureChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private func problem(_ changes: SignatureChanges) throws -> SignatureChanges.Problem {
        guard case .problem(let problem) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return problem
    }

    private func done(_ changes: SignatureChanges) throws -> SignatureChanges.Done {
        guard case .done(let done) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return done
    }

    /// The signature writes the mock ran, as argv.
    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 2 && $0[2] == "signature" }
    }

    private func bytes(_ calls: [[String]]) -> [[[UInt8]]] { calls.map { $0.map { Array($0.utf8) } } }

    /// GamGUI's `_audited`: each write's end record, oldest first.
    private func audited() -> [(action: String, target: String, ok: Bool)] {
        AuditLog.records(at: auditURL).reversed()
            .filter { $0["extra"]?.object?["phase"]?.string == "end" }
            .map { ($0["action"]?.string ?? "", $0["target"]?.string ?? "", $0["ok"] == .bool(true)) }
    }

    private func marker(_ path: String) throws {
        let file = state.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
    }

    /// A mock in front of the strict one: `prefix` runs first (a delay, a failure).
    private func wrapped(_ prefix: String) throws -> AuthenticatedRunner {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let script = scratch.appending(path: "mock-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(prefix)exec '\(Fixtures.mockGam.path)' \"$@\"\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    private static func user(_ email: String, ou: String = "/", suspended: Bool = false) -> GamUser {
        GamUser(record: ["primaryEmail": .string(email), "orgUnitPath": .string(ou), "suspended": .bool(suspended)])
    }

    private static func member(_ email: String, type: String = "USER") -> GroupMember {
        GroupMember(record: ["email": .string(email), "type": .string(type), "role": .string("MEMBER")])
    }

    // MARK: who is in scope (`test_signatures.py`)

    /// `test_match_scope_ou_includes_children_excludes_suspended`: a unit is itself and every unit under it, never a
    /// sibling whose name starts the same; suspended accounts are never in scope; the company is every active account.
    @Test func anOrgUnitIncludesItsChildrenAndNoSuspendedAccount() {
        let users = [Self.user("a@e.com", ou: "/Sales"), Self.user("b@e.com", ou: "/Sales/East"), Self.user("c@e.com", ou: "/IT"),
                     Self.user("d@e.com", ou: "/Sales", suspended: true), Self.user("e@e.com", ou: "/SalesOps")]
        #expect(SignatureScope.match(users, .orgUnit("/Sales")).map(\.primaryEmail) == ["a@e.com", "b@e.com"])
        #expect(SignatureScope.match(users, .orgUnit(" /Sales/ ")).map(\.primaryEmail) == ["b@e.com"],
                "stripped, then the path itself or under it: Python's rstrip leaves the unit's own path unmatched")
        #expect(SignatureScope.match(users, .orgUnit("/")).count == 4, "the root is everyone active")
        #expect(SignatureScope.match(users, .company).count == 4)
        #expect(SignatureScope.orgUnits(users) == ["/IT", "/Sales", "/Sales/East", "/SalesOps"], "suspended accounts' units too")
    }

    /// `test_match_scope_with_no_value_matches_nobody`: only the company means everyone. An empty choice once resolved to
    /// the whole company.
    @Test func aScopeWithNoValueMatchesNobody() {
        let users = [Self.user("a@e.com"), Self.user("b@e.com")]
        for scope: SignatureScope in [.person(""), .person("  "), .orgUnit(""), .group(""), .group("staff@e.com")] {
            #expect(SignatureScope.match(users, scope).isEmpty, "\(scope)")
        }
        #expect(SignatureScope.match(users, .company).count == 2)
    }

    /// `test_match_scope_user_selects_single_active`: one person, any case; never a suspended one.
    @Test func onePersonIsMatchedInAnyCaseAndOnlyWhenActive() {
        let users = [Self.user("a@e.com"), Self.user("b@e.com"), Self.user("c@e.com", suspended: true)]
        #expect(SignatureScope.match(users, .person("a@e.com")).map(\.primaryEmail) == ["a@e.com"])
        #expect(SignatureScope.match(users, .person("A@E.COM")).map(\.primaryEmail) == ["a@e.com"])
        #expect(SignatureScope.match(users, .person("c@e.com")).isEmpty)
    }

    /// GamGUI's `_matched` for a group: its members that are active users, in the directory's order; a group inside it,
    /// the customer and a suspended account aren't.
    @Test func aGroupIsItsActiveUsersInTheDirectorysOrder() {
        let users = [Self.user("a@e.com"), Self.user("b@e.com", suspended: true), Self.user("c@e.com"), Self.user("d@e.com")]
        let members = [Self.member("D@e.com"), Self.member("a@e.com"), Self.member("b@e.com"), Self.member("it@e.com", type: "GROUP"),
                       Self.member("", type: "CUSTOMER")]
        #expect(SignatureScope.match(users, members: members).map(\.primaryEmail) == ["a@e.com", "d@e.com"])
    }

    /// GamGUI's `/signatures/retry`: the failed addresses still active, once each, and how many are gone.
    @Test func aRetryIsTheFailedStillActive() {
        let users = [Self.user("a@e.com"), Self.user("b@e.com", suspended: true), Self.user("c@e.com")]
        let (people, gone) = SignatureScope.retry(["C@e.com", "b@e.com", "x@e.com", "c@e.com"], in: users)
        #expect(people.map(\.primaryEmail) == ["c@e.com"])
        #expect(gone == 2, "b@ is suspended and x@ isn't in the directory; c@ counts once")
    }

    // MARK: the preview

    /// `test_signatures_preview`: the count, and the render for a real (active) person, nothing written.
    @Test func theCompanyPreviewHoldsEachPersonsRender() async throws {
        try await connect()
        let changes = changes()
        await changes.previewScope(.company, template: "{name} | {email}")
        let pending = try pending(changes)
        #expect(pending.isScoped && !pending.isRetry && pending.previous == nil)
        #expect(pending.people.map(\.primaryEmail) == ["admin@example.com", "alice@example.com", "carol@example.com", "dana@example.com"])
        #expect(pending.person.primaryEmail == "admin@example.com" && pending.body == "IT Admin | admin@example.com")
        #expect(pending.preview.steps.map(\.signatureBody) == pending.people.map { Signature.render("{name} | {email}", for: $0) })
        #expect(pending.preview.title == "Signature for the whole company \u{2014} 4 users")
        #expect(pending.title == "Set the signature for 4 people in the whole company" && pending.confirmLabel == "Replace 4 Signatures")
        #expect(pending.preview.needsConfirmClick && !pending.preview.decision.requiresTypedCount)
        #expect(writes().isEmpty)
    }

    /// The org unit and group scopes against the mock: /Staff without bob (suspended); the root everyone; staff@'s one
    /// active member, sales@'s (it@ is a group inside it).
    @Test func orgUnitsAndGroupsMatchTheirActivePeople() async throws {
        try await connect()
        let changes = changes()
        for (scope, people) in [(SignatureScope.orgUnit("/Staff"), ["admin@example.com", "alice@example.com", "dana@example.com"]),
                                (.orgUnit("/"), ["admin@example.com", "alice@example.com", "carol@example.com", "dana@example.com"]),
                                (.group("staff@example.com"), ["alice@example.com"]),
                                (.group("SALES@example.com"), ["alice@example.com"])] {
            await changes.previewScope(scope, template: "{name}")
            #expect(try pending(changes).people.map(\.primaryEmail) == people, "\(scope)")
        }
        #expect(try pending(changes).preview.title == "Signature for SALES@example.com \u{2014} 1 user")
        #expect(writes().isEmpty)
    }

    /// `test_signatures_apply_empty_scope_is_friendly`: a scope nobody matches holds nothing to confirm.
    @Test func aScopeNobodyMatchesHoldsNothing() async throws {
        try await connect()
        let changes = changes()
        for scope: SignatureScope in [.orgUnit(""), .orgUnit("/Nowhere"), .group("empty-group@example.com"), .group("team@example.com")] {
            await changes.previewScope(scope, template: "{name}")
            #expect(try problem(changes).summary == "No active users match this scope.", "\(scope)")
        }
        #expect(writes().isEmpty)
    }

    /// A group read that fails is said, never taken for an empty group (GamGUI's `_matched` swallowed it).
    @Test func aGroupThatCantBeReadIsSaid() async throws {
        try await connect()
        let changes = changes()
        await changes.previewScope(.group("nosuch@example.com"), template: "{name}")
        let refused = try problem(changes)
        #expect(refused.summary == "Couldn't read nosuch@example.com's members, so nothing was previewed. nosuch@example.com isn't a group here.")
        #expect(refused.detail?.contains("Does not exist") == true)
        #expect(writes().isEmpty)
    }

    /// GamGUI's `smart_quote_warning` on the preview, and this app's: an empty render clears signatures; a render GAM
    /// would read as a file is left out and said, never sent.
    @Test func thePreviewWarnsAndLeavesOutAKeywordRender() async throws {
        try await connect()
        let changes = changes()
        await changes.previewScope(.company, template: "<a href=\u{201C}x\u{201D}>[[{title}]]</a>")
        var pending = try pending(changes)
        #expect(pending.warnings.first == Signature.smartQuoteWarning("<a href=\u{201C}x\u{201D}>"))
        await changes.previewScope(.company, template: "[[{title}]]")
        pending = try self.pending(changes)
        #expect(pending.warnings == ["This renders empty for 2 of them: confirming clears their Gmail signatures."])
        await changes.previewScope(.company, template: "[[{title}]]file")
        pending = try self.pending(changes)
        #expect(pending.people.map(\.primaryEmail) == ["alice@example.com", "dana@example.com"])
        #expect(pending.notes == ["Left out 2: GAM would take their signature as a file or document to load, not as the "
            + "signature (admin@example.com, carol@example.com)."])
        await changes.previewScope(.orgUnit("/Students"), template: "[[{title}]]file")
        #expect(try problem(changes).summary.hasPrefix("Left out 1: GAM would take"))
    }

    // MARK: the run

    /// `test_signatures_apply`: every active person in scope gets their own render, each one audited write; the result
    /// says how many.
    @Test func theRunSetsEachPersonsOwnSignatureOnceEach() async throws {
        try await connect()
        let changes = changes()
        await changes.previewScope(.orgUnit("/Staff"), template: "{name}")
        await changes.confirm(try pending(changes), confirmed)
        let dana = try #require(directory.users?.first { $0.primaryEmail == "dana@example.com" })
        #expect(bytes(writes()) == bytes([["user", "admin@example.com", "signature", "IT Admin", "html"],
                                          ["user", "alice@example.com", "signature", "Alice Anders", "html"],
                                          ["user", "dana@example.com", "signature", dana.fullName, "html"]]))
        #expect(audited().map(\.target) == ["admin@example.com", "alice@example.com", "dana@example.com"])
        #expect(audited().allSatisfy { $0.action == "setSignature" && $0.ok })
        let done = try done(changes)
        #expect(done.message == "Applied to 3 of 3 users." && !done.partial && done.retry == nil && done.previous == nil)
        #expect(changes.finished == 1 && changes.progress == nil)
    }

    /// `test_signatures_apply_over_the_threshold_needs_the_count_typed` (the threshold lowered, as GamGUI's test does):
    /// the click alone, or another count, runs nothing. It is said on the sheet, which stays with its preview unspent (the
    /// executor spends one it refuses), each wrong try counted so it is said again; typing clears it; the right count then
    /// runs that same preview.
    @Test func overTheThresholdTheCountIsTyped() async throws {
        try await connect()
        let changes = changes()
        changes.typedCountAbove = 1
        await changes.previewScope(.company, template: "{name}")
        let pending = try pending(changes)
        #expect(pending.preview.decision.requiresTypedCount)
        for typed in ["", "3", "all", "04"] {
            await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: typed))
            #expect(changes.typedProblem == "Type 4, the number of people, to confirm.", "\(typed)")
            #expect(try self.pending(changes).id == pending.id, "the sheet stays")
        }
        #expect(changes.typedRefusals == 4)
        #expect(writes().isEmpty)
        changes.typingChanged()
        #expect(changes.typedProblem == nil)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: " 4 "))
        #expect(writes().map { $0[1] } == ["admin@example.com", "alice@example.com", "carol@example.com", "dana@example.com"])
    }

    /// The executor still refuses another count itself (the screen's check is not the only one).
    @Test func theExecutorRefusesAnotherCount() async throws {
        try await connect()
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        let changes = SignatureChanges(executor: executor, setup: setup, directory: directory, runner: runner)
        changes.typedCountAbove = 1
        await changes.previewScope(.company, template: "{name}")
        let outcome = await executor.run(try pending(changes).preview, confirmation: OperatorConfirmation(confirmed: true, typedCount: "3"))
        #expect(outcome.refusal == "This changes 4 accounts: preview again, and type 4 to confirm.")
        #expect(writes().isEmpty)
    }

    /// `test_write_routes_guarded.py`'s signature case: a scope or template edited after the preview, a bare confirm or a
    /// replay runs nothing; the confirm runs the people and the template the preview held.
    @Test func theConfirmRunsOnlyThePreviewShown() async throws {
        try await connect()
        let changes = changes()
        await changes.previewScope(.group("staff@example.com"), template: "{name}")
        let first = try pending(changes)
        changes.edited()
        await changes.confirm(first, confirmed)
        #expect(writes().isEmpty, "the scope was edited after the preview")
        await changes.previewScope(.group("staff@example.com"), template: "{name}")
        let held = try pending(changes)
        await changes.previewScope(.company, template: "{name} EDITED")
        let widened = try pending(changes)
        await changes.confirm(held, confirmed)
        #expect(writes().isEmpty, "a later preview replaced it")
        await changes.confirm(widened, OperatorConfirmation())
        #expect(writes().isEmpty, "a bare confirm")
        await changes.previewScope(.group("staff@example.com"), template: "{name}")
        let again = try pending(changes)
        await changes.confirm(again, confirmed)
        await changes.confirm(again, confirmed)
        #expect(bytes(writes()) == bytes([["user", "alice@example.com", "signature", "Alice Anders", "html"]]), "once, as held")
    }

    /// `test_a_signature_retry_is_the_preview_and_confirm_step_for_exactly_the_failed`: a failure is named with why, and
    /// its retry is a new preview of exactly those people with the run's template, written only from its confirm.
    @Test func aRetryPreviewsExactlyTheFailedWithTheSameTemplate() async throws {
        try await connect()
        try marker("nogmail/carol@example.com")
        let changes = changes()
        await changes.previewScope(.company, template: "Hi {first}")
        await changes.confirm(try pending(changes), confirmed)
        let ran = try done(changes)
        #expect(ran.message == "Applied to 3 of 4 users." && ran.partial && ran.failedCount == 1)
        #expect(ran.failures == ["carol@example.com \u{2014} \(GamError.Kind.serviceNotEnabled.remediation)"])
        let retry = try #require(ran.retry)
        #expect(retry.failed == ["carol@example.com"] && retry.template == "Hi {first}")
        #expect(writes().count == 4)

        await changes.previewRetry(retry)
        let pending = try pending(changes)
        #expect(pending.isRetry && pending.people.map(\.primaryEmail) == ["carol@example.com"] && pending.body == "Hi Carol")
        #expect(pending.preview.title == "Signature retry \u{2014} 1 user")
        #expect(writes().count == 4, "a retry is a preview")
        await changes.confirm(pending, confirmed)
        #expect(bytes(Array(writes().dropFirst(4))) == bytes([["user", "carol@example.com", "signature", "Hi Carol", "html"]]))
        #expect(try done(changes).retry?.failed == ["carol@example.com"], "GAM still refuses: it can be retried again")
        await changes.confirm(pending, confirmed)
        #expect(writes().count == 5, "a replayed confirm")
    }

    /// A retry after a switch is refused: its people were the old tenant's (GamGUI binds the retry's preview to its tenant).
    @Test func aRetryOnAnotherTenantIsRefused() async throws {
        try await connect()
        try marker("nogmail/carol@example.com")
        let changes = changes()
        await changes.previewScope(.orgUnit("/Students"), template: "{name}")
        await changes.confirm(try pending(changes), confirmed)
        let retry = try #require(try done(changes).retry)
        try await connect("example.org", admin: "admin@example.org")
        await changes.previewRetry(retry)
        #expect(try problem(changes).summary == Executor.PreviewRefusal.tenantChanged.message)
        #expect(writes().count == 1)
    }

    /// `test_stop_ends_the_signature_apply_after_the_write_in_flight`: Stop ends the run after the write in flight; the
    /// rest never run, and the result says how many weren't attempted.
    @Test func stopEndsTheRunAfterTheWriteInFlight() async throws {
        try await connect()
        let changes = changes(writer: try wrapped("[ \"$3\" = signature ] && sleep 0.3\n"))
        await changes.previewScope(.company, template: "{name}")
        let pending = try pending(changes)
        let run = Task { await changes.confirm(pending, confirmed) }
        while (changes.progress?.done ?? 0) < 1 { try await Task.sleep(for: .milliseconds(20)) }
        await changes.stop()
        #expect(changes.progress?.stopping == true)
        await run.value
        let stopped = try done(changes)
        let set = writes().count
        #expect(set >= 1 && set < 4, "\(set) ran")
        #expect(stopped.message == "Stopped by you \u{2014} \(4 - set) not attempted. Applied to \(set) of 4 before stopping.")
        #expect(stopped.partial && stopped.retry == nil, "nothing failed: the ones not attempted aren't a retry's")
    }

    /// GamGUI's `stop_reason`: a failure every later person would share (a scope not granted) stops the run there.
    @Test func anAccountWideFailureStopsTheRun() async throws {
        try await connect()
        let failing = try wrapped("""
            if [ "$3" = signature ] && [ "$2" = alice@example.com ]; then echo 'ERROR: 403: Request had insufficient authentication scopes' >&2; exit 50; fi

            """)
        let changes = changes(writer: failing)
        await changes.previewScope(.company, template: "{name}")
        await changes.confirm(try pending(changes), confirmed)
        let stopped = try done(changes)
        #expect(stopped.message == "Stopped: \(GamError.Kind.scopeMissing.remediation) The remaining 2 were not attempted. "
            + "Applied to 1 of 4 before stopping.")
        #expect(stopped.failedCount == 1 && stopped.retry?.failed == ["alice@example.com"])
    }

    /// `test_signatures_apply_final_summary_caps_failed_list` (`test_users_web.py:506-519`): every failure counted, only the
    /// first `failuresKept` named (invariant 9); the retry still holds all of them, from the run's own outcome.
    @Test func aScopesFailuresAreCapped() async throws {
        try await connect()
        let changes = changes()
        await changes.previewScope(.company, template: "{name}")
        let held = try pending(changes)
        let count = SignatureChanges.failuresKept + 100
        let people = (0..<count).map { Self.user("u\($0)@example.com") }
        let pending = SignatureChanges.Pending(preview: held.preview, person: people[0], title: held.title, confirmLabel: held.confirmLabel,
                                               previous: nil, warnings: [], isPutBack: false, scope: .company, people: people,
                                               template: "{name}", isRetry: false, notes: [])
        let done = SignatureChanges.scopeDone(pending, Array(repeating: .failed(message: "x", kind: .notFound), count: count), note: "")
        #expect(done.failedCount == count && done.failures.count == SignatureChanges.failuresKept)
        #expect(done.retry?.failed.count == count)
        #expect(done.message == "Applied to 0 of \(count) users." && done.partial)
    }

    /// A preview whose group read ends after the scope or template changed holds nothing the screen shows: the confirm
    /// can't open for a scope or template the screen no longer names (GamGUI refuses an Apply whose form differs).
    @Test func aScopePreviewOutdatedWhileReadingIsDropped() async throws {
        try await connect()
        let reading = scratch.appending(path: "reading")
        let slow = try wrapped("[ \"$1 $2\" = \"print group-members\" ] && : > '\(reading.path)' && sleep 0.3\n")
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_STATE": state.path])
        let changes = SignatureChanges(executor: executor, setup: setup, directory: directory, runner: slow)
        let preview = Task { await changes.previewScope(.group("sales@example.com"), template: "{name}") }
        while !FileManager.default.fileExists(atPath: reading.path) { try await Task.sleep(for: .milliseconds(10)) }
        changes.edited()
        await preview.value
        guard case .idle = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        // A newer preview begun meanwhile is the one shown.
        try FileManager.default.removeItem(at: reading)
        let older = Task { await changes.previewScope(.group("sales@example.com"), template: "{name}") }
        while !FileManager.default.fileExists(atPath: reading.path) { try await Task.sleep(for: .milliseconds(10)) }
        await changes.previewScope(.orgUnit("/Students"), template: "{email}")
        let newer = try pending(changes)
        await older.value
        #expect(try pending(changes).id == newer.id && newer.scope == .orgUnit("/Students"))
        #expect(writes().isEmpty)
    }
}
