@testable import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import Stores
import TestSupport
import Testing
import Vault

/// Hires from a CSV (roadmap 2.3), previewed as one held preview and run through ChangeCore against the strict mock. Ports
/// GamGUI's bulk onboarding tests (`tests/test_onboarding.py`: resolve, tally, notify vs the sheet, a failed create fatal for
/// its row only, Run executes the previewed rows).
@MainActor
@Suite("Hires from a CSV", .serialized)
final class HiresFromCSVTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-hirecsv-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let executor: Executor
    let argvLog: URL
    let state: URL
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let setup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit/audit.jsonl")), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func model() -> HiresFromCSV {
        HiresFromCSV(executor: executor, setup: setup, directory: directory, waits: Array(repeating: .zero, count: 5))
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "alice@example.com"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { argv in
            !(argv.first == "print" || argv.first == "info" || argv.contains("check") || argv.first == "version"
              || (argv.count > 2 && (argv[2] == "print" || argv[2] == "show")))
        }
    }

    private let roles = HiresFromCSV.Roles(
        role: { name in
            switch name {
            case "Sales": RoleTemplate(name: "Sales", steps: ["Set up POS", "Order a laptop"])
            case "Empty": RoleTemplate(name: "Empty", steps: [])
            default: nil
            }
        },
        signature: { _ in nil }, welcome: { _ in nil })

    private func pending(_ model: HiresFromCSV) throws -> HiresFromCSV.Pending {
        guard case .previewing(let pending) = model.state else { throw NotPreviewing(state: "\(model.state)") }
        return pending
    }

    private func done(_ model: HiresFromCSV) throws -> HiresFromCSV.Done {
        guard case .done(let done) = model.state else { throw NotPreviewing(state: "\(model.state)") }
        return done
    }

    private func preview(_ model: HiresFromCSV, _ csv: String) async throws -> HiresFromCSV.Pending {
        await model.preview(Array(csv.utf8), roles: roles)
        return try pending(model)
    }

    /// `test_resolve_hires_pairs_rows_with_roles_and_the_tally_is_separate` and `test_bulk_preview_summarizes_and_flags_bad_rows`.
    @Test func rowsResolveAgainstTheRolesAndTally() async throws {
        try await connect()
        let model = model()
        let pending = try await preview(model, """
            role,name,email,create_account,first,last,notify
            Sales,Ada Byte,ada@example.com,yes,Ada,Byte,ada.p@example.org
            Sales,Ben Cole,ben@example.com,yes,Ben,Cole,
            Sales,,dana@example.com,,,,
            Empty,,d@example.com,,,,
            Nope,,e@example.com,,,,

            """)
        #expect(pending.hires.map(\.plan.email) == ["ada@example.com", "ben@example.com", "dana@example.com"])
        #expect(pending.errors == ["d@example.com: unknown role 'Empty' (or it has no steps).",
                                   "e@example.com: unknown role 'Nope' (or it has no steps)."])
        #expect(pending.creates == 2 && pending.notifies == 1 && pending.sheets == 1)
        #expect(pending.perRole.map(\.role) == ["Sales"] && pending.perRole.map(\.count) == [3])
        #expect(pending.preview.title == "Bulk onboarding \u{2014} 3 hires")
        #expect(writes().isEmpty, "a preview writes nothing")
    }

    /// Each hire's steps follow the last's: a task names its own hire's list step, and its argv's placeholder moves with it.
    @Test func eachHiresStepsAreShiftedIntoOnePreview() async throws {
        try await connect()
        let model = model()
        let pending = try await preview(model, "role,email,assignee\nSales,dana@example.com,\nSales,carol@example.com,\n")
        let second = pending.hires[1].steps
        #expect(pending.hires[0].steps == 0..<3 && second == 3..<6)
        let task = pending.preview.steps[second.lowerBound + 1]
        #expect(task.requires == [second.lowerBound])
        #expect(task.write.argv.contains(WriteStep.listIDPlaceholder(second.lowerBound)))
    }

    /// `test_provision_hire_notify_vs_sheet` and `test_bulk_run_executes_the_previewed_rows_and_roles`: the create the preview
    /// held, notify's address handed to GAM; the other's password on the sheet only.
    @Test func aRunCreatesAndPutsOnlyUnemailedPasswordsOnTheSheet() async throws {
        try await connect()
        let model = model()
        let pending = try await preview(model, """
            role,name,email,create_account,first,last,notify
            Sales,Ada Byte,ada@example.com,yes,Ada,Byte,ada.p@example.org
            Sales,Ben Cole,ben@example.com,yes,Ben,Cole,

            """)
        await model.confirm(pending, confirmed)
        let creates = writes().filter { $0.first == "create" && $0.count > 1 && $0[1] == "user" }
        #expect(creates.map { $0[2] } == ["ada@example.com", "ben@example.com"])
        #expect(creates[0].contains("notify") && creates[0][creates[0].firstIndex(of: "notify")! + 1] == "ada.p@example.org")
        #expect(!creates[1].contains("notify"))
        #expect(model.credentials.map(\.email) == ["ben@example.com"])
        let ran = try done(model)
        #expect(ran.message.hasPrefix("Onboarded 2 of 2 hires; 2 accounts created (1 emailed by GAM)."), "\(ran.message)")
        await model.preview(Array("role,email,create_account,first,last\nSales,cy@example.com,yes,Cy,Dee\n".utf8), roles: roles)
        guard case .problem(let why, _) = model.state else { Issue.record("\(model.state)"); return }
        #expect(why.hasPrefix("Print or save the sign-in details"), "the sheet goes first")
        model.doneWithCredentials()
        #expect(model.credentials.isEmpty)
    }

    /// `test_provision_hire_account_failure_is_fatal_for_that_row`: a duplicate create skips that hire's other steps only.
    @Test func aFailedCreateSkipsOnlyItsOwnHire() async throws {
        try await connect()
        let model = model()
        let pending = try await preview(model, """
            role,name,email,create_account,first,last
            Sales,Carol Clark,carol@example.com,yes,Carol,Clark
            Sales,,dana@example.com,,,

            """)
        await model.confirm(pending, confirmed)
        let ran = try done(model)
        #expect(ran.hires.map(\.ok) == [false, true])
        #expect(ran.message.hasPrefix("Onboarded 1 of 2 hires."))
        #expect(!writes().contains { $0.contains("carol@example.com") && $0.first != "create" }, "nothing else ran for carol")
        #expect(model.credentials.isEmpty, "no account, no password")
    }

    @Test func aFileWithNothingToRunHoldsNothing() async throws {
        try await connect()
        let model = model()
        await model.preview(Array("role,email\nNope,a@example.com\n".utf8), roles: roles)
        guard case .problem(let why, let errors) = model.state else { Issue.record("\(model.state)"); return }
        #expect(why == "Nothing to run \u{2014} every row had an unknown role or was invalid.")
        #expect(errors == ["a@example.com: unknown role 'Nope' (or it has no steps)."])
        await model.preview(Array("role,email\n".utf8), roles: roles)
        guard case .problem(let none, _) = model.state else { Issue.record("\(model.state)"); return }
        #expect(none == "No hires found in the CSV.")
    }

    // MARK: the review of #206

    /// The cards go at fifteen minutes, as the one-hire card does: dropped from memory, not only hidden.
    @Test func theSignInCardsAreDroppedAfterFifteenMinutes() async throws {
        try await connect()
        let clock = HireTestClock()
        let model = HiresFromCSV(executor: executor, setup: setup, directory: directory, waits: [], now: { clock.now })
        let pending = try await preview(model, "role,name,email,create_account,first,last\nSales,Ben Cole,ben@example.com,yes,Ben,Cole\n")
        await model.confirm(pending, confirmed)
        #expect(model.credentials.count == 1)
        model.dropCredentialsIfExpired()
        #expect(model.credentials.count == 1, "not yet")
        clock.moved = .seconds(16 * 60)
        model.dropCredentialsIfExpired()
        clock.moved = .zero
        #expect(model.credentials.isEmpty, "gone, not hidden by the clock")
    }

    /// Stop during the wait for Google says so, never "Google still hadn't finished".
    @Test func stopDuringTheWaitSaysStopped() async throws {
        try await connect()
        let provisioning = state.appending(path: "provisioning")
        try FileManager.default.createDirectory(at: provisioning, withIntermediateDirectories: true)
        try Data("99".utf8).write(to: provisioning.appending(path: "ben@example.com"))
        let model = HiresFromCSV(executor: executor, setup: setup, directory: directory, waits: [.seconds(30)])
        let pending = try await preview(model, "role,name,email,create_account,first,last\nSales,Ben Cole,ben@example.com,yes,Ben,Cole\n")
        let run = Task { await model.confirm(pending, confirmed) }
        try await yieldWhile(every: .milliseconds(20)) { model.progress?.waitingUntil == nil }
        await model.stop()
        await run.value
        let ran = try done(model)
        #expect(ran.hires[0].outcome.contains(Onboarding.stoppedReason), "\(ran.hires[0].outcome)")
        #expect(!ran.hires[0].outcome.contains(Onboarding.notReadyReason))
    }

    /// After a failure every later step would share, nothing waits for Google, and the hires not reached are not attempted.
    @Test func anAccountWideStopEndsTheRunWithoutWaiting() async throws {
        try await connect()
        let base = scratch.appending(path: "run2")
        let script = scratch.appending(path: "failing.sh")
        try Data("#!/bin/sh\nif [ \"$1\" = update ]; then echo 'ERROR: 403: Request had insufficient authentication scopes' >&2; exit 50; fi\nexec '\(Fixtures.mockGam.path)' \"$@\"\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault,
                                         runtimeDirectory: try RuntimeDirectory.prepare(base))
        let setup = setup
        let failing = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit2.jsonl")), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_FIXTURES": Fixtures.mockGamData.path, "GAM_MOCK_STATE": state.path])
        let model = HiresFromCSV(executor: failing, setup: setup, directory: directory, waits: [.seconds(600)])
        let roles = HiresFromCSV.Roles(role: { _ in RoleTemplate(name: "Sales", steps: ["x"], groups: ["sales@example.com"]) },
                                       signature: { _ in nil }, welcome: { _ in nil })
        await model.preview(Array("role,email\nSales,dana@example.com\nSales,carol@example.com\n".utf8), roles: roles)
        await model.confirm(try pending(model), confirmed)
        let ran = try done(model)
        #expect(ran.message.hasPrefix("Stopped: ") && ran.message.contains("1 not attempted"), "\(ran.message)")
    }
}

/// A clock a test moves.
final class HireTestClock: @unchecked Sendable {
    let start = ContinuousClock.now
    var moved: Duration = .zero
    var now: ContinuousClock.Instant { start + moved }
}
