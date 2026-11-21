import Foundation
import Synchronization
import Testing
@testable import ChangeCore
@testable import GamEngine
import TestSupport
import Vault

/// Keeping each signature first (GamGUI's signature backups, #163 and #164), in the executor: a step that replaces a
/// signature runs only after ChangeCore has read the person's stored one exactly and kept it, in the write lock. Unread,
/// the step fails and the run goes on (unless the failure is account-wide); changed since a Put Back's run, it's skipped;
/// not kept, the run stops; nowhere to keep, nothing runs. Against a scripted `gam` that answers `print signature` as GAM
/// 7.52.04's printShowSignature writes it, and a keeper that logs beside it, so one list shows the order things happened.
@Suite("Executor: signatures kept first", .serialized)
final class SignatureKeepTests {
    let example = Domain("example.com")!
    let base: URL
    let log: URL
    let auditURL: URL
    let vault: Vault

    static let alice = "alice@example.com", bob = "bob@example.com"
    /// What GAM's CSV writer writes for each signature: quoted (it holds a comma, a quote and line breaks), the quote
    /// doubled, the backslash doubled (GAM's escapechar), and a trailing space kept inside the quotes.
    static let aliceOld = "<div>Best,\n\"Alice\" \\ Anders</div>\r\n "
    static let bobOld = "Bob <b>Brown</b>  "

    init() throws {
        let store = MemoryStore()
        try store.write(Data(#"{"client_email": "gam@p.iam.gserviceaccount.com"}"#.utf8), as: .oauth2Service, for: example)
        try store.write(Data(#"{"decoded_id_token": {"email": "admin@example.com"}}"#.utf8), as: .oauth2, for: example)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-keep-\(UUID().uuidString)")
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        log = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        vault = Vault(store: store)
    }

    deinit { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

    // MARK: the scripted gam

    /// GAM's `print signature` CSV for `email` (printShowSignature: its titles, then `signature`, the one the sendAs
    /// resource adds; none when Gmail left it out), written as GAM's writer does.
    static func csv(_ email: String, _ signature: String?) -> String {
        func cell(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            let quoted = value.unicodeScalars.contains { ",\"\r\n".unicodeScalars.contains($0) }
            return quoted ? "\"" + escaped.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : escaped
        }
        let titles = "User,displayName,sendAsEmail,replyToAddress,isPrimary,isDefault,treatAsAlias,verificationStatus"
        let row = "\(email),,\(email),,True,True,,"
        return signature.map { "\(titles),signature\n\(row),\(cell($0))\n" } ?? "\(titles)\n\(row)\n"
    }

    /// How the scripted gam answers one person's `print signature`.
    enum Answer {
        /// GAM's getting line and the person's row.
        case signature(String?)
        /// The titles alone, exit 0, no getting line: GAM skipped a refused token without a word.
        case quiet
        /// A failure, as GAM writes it.
        case fails(exit: Int, stderr: String)
    }

    /// A `gam` that logs each argv as the mock does, answers `print signature` per `answers`, and takes every write.
    func gam(_ answers: [String: Answer]) throws -> URL {
        var cases = ""
        for (email, answer) in answers {
            let out = base.deletingLastPathComponent().appending(path: "out-\(UUID().uuidString)")
            switch answer {
            case .signature(let body):
                try Data(Self.csv(email, body).utf8).write(to: out)
                cases += "  \(email)) printf 'Getting Signatures for %s\\n' \"$2\" >&2; cat '\(out.path)'; exit 0 ;;\n"
            case .quiet:
                try Data(Self.csv(email, nil).prefix(while: { $0 != "\n" }).utf8 + [10]).write(to: out)
                cases += "  \(email)) cat '\(out.path)'; exit 0 ;;\n"
            case .fails(let exit, let stderr):
                cases += "  \(email)) printf '%s\\n' '\(stderr)' >&2; exit \(exit) ;;\n"
            }
        }
        let url = base.deletingLastPathComponent().appending(path: "gam-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s\\0' \"$#\" \"$@\" >> \"$GAM_MOCK_ARGV_LOG\"\n"
            + "if [ \"$3\" = print ] && [ \"$4\" = signature ]; then\n case \"$2\" in\n\(cases) esac\n echo 'unscripted' >&2; exit 2\nfi\nexit 0\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func executor(_ gam: URL, keeper: (any SignatureKeeper)?) -> Executor {
        Executor(runner: AuthenticatedRunner(runner: GamRunner(binary: gam), vault: vault, runtimeDirectory: base),
                 audit: AuditLog(url: auditURL), actor: "admin@example.com", tenant: { [example] in (example, 1) },
                 extraEnvironment: ["GAM_MOCK_ARGV_LOG": log.path], signatureKeeper: keeper)
    }

    /// Everything in order: each argv the gam ran, and each keep (`["keep", email, previous, setting]`) between them.
    func happened() -> [[String]] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    func read(_ email: String) -> [String] { GamCommands.printSignature(email: email).argv }
    func set(_ email: String, _ body: String) -> [String] { GamCommands.setSignature(email: email, signature: body).argv }

    func step(_ email: String, _ body: String, expectedNow: String? = nil) -> WriteStep {
        WriteStep(GamCommands.setSignature(email: email, signature: body, html: true), target: email,
                  summary: "Replace \(email)'s Gmail signature.",
                  keepFirst: .signature(email: email, setting: body, expectedNow: expectedNow))
    }

    func run(_ executor: Executor, _ steps: [WriteStep]) async throws -> RunOutcome {
        let preview = try await executor.preview(steps, confirmStep: true).get()
        return await executor.run(preview, confirmation: OperatorConfirmation(confirmed: true))
    }

    var records: [JSONObject] { AuditLog.records(at: auditURL).reversed() }

    // MARK: the cases

    @Test func eachSignatureIsReadExactlyAndKeptBeforeItsWrite() async throws {
        let keeper = LoggingKeeper(log: log)
        let executor = executor(try gam([Self.alice: .signature(Self.aliceOld), Self.bob: .signature(Self.bobOld)]), keeper: keeper)
        let outcome = try await run(executor, [step(Self.alice, "<b>new</b>"), step(Self.bob, "<b>new</b>")])
        #expect(outcome.succeeded)
        #expect(happened() == [read(Self.alice), ["keep", Self.alice, Self.aliceOld, "<b>new</b>"], set(Self.alice, "<b>new</b>"),
                               read(Self.bob), ["keep", Self.bob, Self.bobOld, "<b>new</b>"], set(Self.bob, "<b>new</b>")])
        // Byte for byte: GAM's escaped backslash, its doubled quote, the CRLF and the trailing spaces all come back.
        #expect(keeper.kept.first?.previous.utf8.elementsEqual(Self.aliceOld.utf8) == true)
        let run = try #require(keeper.started.first)
        #expect(keeper.started.count == 1 && run.what == "Set signature for 2 addresses" && run.domain == example && run.closed)
        #expect(outcome.kept == run.id)
        // The audit names where each replaced signature is kept.
        let writes = records.filter { $0["action"]?.string == "setSignature" }
        let named = writes.compactMap { record -> String? in record["extra"]?.object?["kept"]?.string }
        #expect(writes.count == 4 && named == Array(repeating: run.id, count: 4))
    }

    /// The keeper hears which kept runs a Put Back sets again, so it never prunes them for this run (review of Phase A: the
    /// oldest of five was deleted as its own Put Back started).
    @Test func aPutBackNamesTheRunItRestores() async throws {
        let keeper = LoggingKeeper(log: log)
        let executor = executor(try gam([Self.alice: .signature("new"), Self.bob: .signature("new")]), keeper: keeper)
        func back(_ email: String, _ source: String?) -> WriteStep {
            WriteStep(GamCommands.setSignature(email: email, signature: "old", html: true), target: email, summary: "Put back",
                      keepFirst: .signature(email: email, setting: "old", expectedNow: "new", restoring: source))
        }
        #expect(try await run(executor, [back(Self.alice, "R1"), back(Self.bob, nil)]).succeeded)
        #expect(keeper.started.map(\.restoring) == [["R1"]])
        #expect(try await run(executor, [step(Self.alice, "x")]).succeeded)
        #expect(keeper.started.last?.restoring == [])
    }

    /// No signature column (Gmail leaves an empty one out) is no signature: kept as empty.
    @Test func noSignatureIsKeptAsEmpty() async throws {
        let keeper = LoggingKeeper(log: log)
        let outcome = try await run(executor(try gam([Self.alice: .signature(nil)]), keeper: keeper), [step(Self.alice, "new")])
        #expect(outcome.succeeded && keeper.kept.map(\.previous) == [""])
    }

    /// GamGUI's `test_someone_whose_signature_cant_be_read_isnt_overwritten`: GAM skipped a refused token without a word, so
    /// that person isn't written; the next one is.
    @Test func anUnreadSignatureIsntReplacedAndTheRunGoesOn() async throws {
        let keeper = LoggingKeeper(log: log)
        let executor = executor(try gam([Self.alice: .quiet, Self.bob: .signature(Self.bobOld)]), keeper: keeper)
        let outcome = try await run(executor, [step(Self.alice, "new"), step(Self.bob, "new")])
        guard case .failed(let message, let kind) = outcome.steps[0] else { Issue.record("\(outcome.steps)"); return }
        #expect(message.hasPrefix(Executor.notRead) && kind == nil)
        #expect(outcome.steps[1].isSucceeded)
        #expect(happened() == [read(Self.alice), read(Self.bob), ["keep", Self.bob, Self.bobOld, "new"], set(Self.bob, "new")])
        // Nothing was begun for alice: no write, so no audit record of one.
        let alices = records.filter { $0["target"]?.string == Self.alice }
        #expect(alices.isEmpty)
    }

    /// A read refused for a reason every later call shares (the sign-in expired) stops the run, as a write's would.
    @Test func anAccountWideReadFailureStopsTheRun() async throws {
        let keeper = LoggingKeeper(log: log)
        let executor = executor(try gam([Self.alice: .fails(exit: 50, stderr: "ERROR: invalid_grant: Token has been expired or revoked."),
                                         Self.bob: .signature(Self.bobOld)]), keeper: keeper)
        let outcome = try await run(executor, [step(Self.alice, "new"), step(Self.bob, "new")])
        guard case .failed(let message, _) = outcome.steps[0], case .skipped(let reason) = outcome.steps[1] else {
            Issue.record("\(outcome.steps)"); return
        }
        #expect(message.hasPrefix(Executor.notRead) && reason == "Stopped: \(GamError.Kind.authExpired.remediation)")
        #expect(happened() == [read(Self.alice)] && outcome.kept == nil && keeper.started.first?.closed == true)
    }

    /// A per-person failure (Gmail off for them) fails only them, in GAM's words.
    @Test func aPersonsReadFailureFailsOnlyThem() async throws {
        let executor = executor(try gam([Self.alice: .fails(exit: 1, stderr: "User: alice@example.com, Service not enabled"),
                                         Self.bob: .signature(Self.bobOld)]), keeper: LoggingKeeper(log: log))
        let outcome = try await run(executor, [step(Self.alice, "new"), step(Self.bob, "new")])
        guard case .failed(let message, nil) = outcome.steps[0] else { Issue.record("\(outcome.steps)"); return }
        #expect(message.hasPrefix(Executor.notRead) && outcome.steps[1].isSucceeded)
    }

    /// GamGUI's `test_someone_changed_since_that_run_is_left_as_they_are`: a Put Back's person whose signature isn't, byte for
    /// byte, what that run left there is left as they are, and neither kept nor written.
    @Test func aSignatureChangedSinceIsLeftAsItIs() async throws {
        let keeper = LoggingKeeper(log: log)
        let executor = executor(try gam([Self.alice: .signature("<i>changed later</i>"), Self.bob: .signature(Self.bobOld)]),
                                keeper: keeper)
        let outcome = try await run(executor, [step(Self.alice, "Best,<br>Alice", expectedNow: "<b>Alice Anders</b>"),
                                               step(Self.bob, "old", expectedNow: Self.bobOld)])
        #expect(outcome.steps[0] == .skipped(reason: Executor.changedSince) && outcome.steps[1].isSucceeded)
        #expect(happened() == [read(Self.alice), read(Self.bob), ["keep", Self.bob, Self.bobOld, "old"], set(Self.bob, "old")])
    }

    /// GamGUI's `test_a_copy_that_cant_be_kept_stops_the_run_before_its_write`: nothing is written, and nobody after is read.
    @Test func aCopyThatCantBeKeptStopsTheRunBeforeItsWrite() async throws {
        let keeper = LoggingKeeper(log: log, failKeep: true)
        let executor = executor(try gam([Self.alice: .signature(Self.aliceOld), Self.bob: .signature(Self.bobOld)]), keeper: keeper)
        let outcome = try await run(executor, [step(Self.alice, "new"), step(Self.bob, "new")])
        #expect(outcome.steps == [.skipped(reason: Executor.notKept), .skipped(reason: Executor.notKept)])
        #expect(happened() == [read(Self.alice)] && outcome.kept == nil)
    }

    /// GamGUI's `test_no_place_to_keep_copies_replaces_nothing`: no keeper, or one that can't start a run, and the run is
    /// refused before anything is read.
    @Test func withNowhereToKeepNothingIsReplaced() async throws {
        let answers: [String: Answer] = [Self.alice: .signature(Self.aliceOld)]
        for keeper in [nil, LoggingKeeper(log: log, failStart: true)] as [LoggingKeeper?] {
            let outcome = try await run(executor(try gam(answers), keeper: keeper), [step(Self.alice, "new")])
            #expect(outcome.refusal == Executor.noPlaceToKeep && outcome.steps.isEmpty)
        }
        #expect(happened().isEmpty)
    }

    /// A run whose every read failed kept nobody: it names no kept run, and the keeper's is closed.
    @Test func aRunThatKeptNobodyNamesNoKeptRun() async throws {
        let keeper = LoggingKeeper(log: log)
        let outcome = try await run(executor(try gam([Self.alice: .quiet]), keeper: keeper), [step(Self.alice, "new")])
        #expect(outcome.kept == nil && keeper.started.count == 1 && keeper.started[0].closed && keeper.kept.isEmpty)
    }

    /// A run with no step that keeps starts no kept run and reads nothing first.
    @Test func otherWritesKeepNothing() async throws {
        let keeper = LoggingKeeper(log: log)
        let executor = executor(try gam([:]), keeper: keeper)
        let add = GamCommands.addGroupMember(group: "sales@example.com", member: Self.alice)
        #expect(try await run(executor, [WriteStep(add, target: Self.alice, summary: "Add to Sales")]).succeeded)
        #expect(keeper.started.isEmpty && happened() == [add.argv])
    }

    /// Review of Phase A: the executor took any signature write without a `KeepFirst` (onboarding's retry replaced a signature
    /// set since, keeping nothing). Only one on an account the run itself makes may keep nothing.
    @Test func aSignatureWriteThatKeepsNothingIsRefused() async throws {
        let executor = executor(try gam([:]), keeper: LoggingKeeper(log: log))
        let bare = WriteStep(GamCommands.setSignature(email: Self.alice, signature: "x"), target: Self.alice, summary: "Set")
        await #expect(throws: Executor.PreviewRefusal.signatureNotKept(step: 1)) {
            try await executor.preview([WriteStep(GamCommands.vacationOff(email: Self.bob), target: Self.bob, summary: ""), bare]).get()
        }
        #expect(Executor.PreviewRefusal.signatureNotKept(step: 0).message
                == "Step 1 would replace a signature without keeping the one it replaces.")
        let create = WriteStep(GamCommands.createUser(email: "new@example.com", firstName: "N", lastName: "W", password: "x"),
                               target: "new@example.com", summary: "")
        let onTheNewAccount = WriteStep(GamCommands.setSignature(email: "new@example.com", signature: "x"), target: "new@example.com",
                                        summary: "", requires: [0], newAccountFrom: 0)
        #expect((try? await executor.preview([create, onTheNewAccount]).get()) != nil)
        #expect(happened().isEmpty)
    }

    /// What's kept is the signature of the account the step's own write replaces, beside what that write sets: a keep for
    /// anyone or anything else, or on an account the run makes, is refused at the preview.
    @Test func aKeepIsOnlyItsOwnWritesSignature() async throws {
        let executor = executor(try gam([:]), keeper: LoggingKeeper(log: log))
        let write = GamCommands.setSignature(email: Self.alice, signature: "new", html: true)
        let refused: [WriteStep] = [
            WriteStep(write, target: Self.alice, summary: "", keepFirst: .signature(email: Self.bob, setting: "new", expectedNow: nil)),
            WriteStep(write, target: Self.alice, summary: "", keepFirst: .signature(email: Self.alice, setting: "other", expectedNow: nil)),
            WriteStep(GamCommands.setSignature(email: Self.alice, signature: "new", html: false), target: Self.alice, summary: "",
                      keepFirst: .signature(email: Self.alice, setting: "new", expectedNow: nil)),
            WriteStep(GamCommands.setSuspended(email: Self.alice, suspended: true), target: Self.alice, summary: "",
                      keepFirst: .signature(email: Self.alice, setting: "new", expectedNow: nil)),
        ]
        for step in refused {
            await #expect(throws: Executor.PreviewRefusal.badKeep(step: 0)) { try await executor.preview([step]).get() }
        }
        let create = WriteStep(GamCommands.createUser(email: Self.alice, firstName: "A", lastName: "A", password: "x"),
                               target: Self.alice, summary: "")
        let waits = WriteStep(write, target: Self.alice, summary: "", requires: [0], newAccountFrom: 0,
                              keepFirst: .signature(email: Self.alice, setting: "new", expectedNow: nil))
        await #expect(throws: Executor.PreviewRefusal.badKeep(step: 1)) { try await executor.preview([create, waits]).get() }
        // The descriptor is not on the screen's side of the step: its signature is masked as the argv's is.
        #expect(!"\(step(Self.alice, "secret body"))".contains("secret body"))
    }
}

/// A keeper that logs each keep into the scripted gam's argv log, in its format, and can be made to fail.
final class LoggingKeeper: SignatureKeeper {
    struct Kept: Equatable { let email, previous, setting: String }
    final class Run: KeptSignatureRun {
        let id = "0000000000001-\(String(UInt32.random(in: .min ... .max), radix: 16))"
        let what: String, domain: Domain, restoring: Set<String>
        let keeper: LoggingKeeper
        let state = Mutex((count: 0, closed: false))
        init(what: String, domain: Domain, restoring: Set<String>, keeper: LoggingKeeper) {
            self.what = what
            self.domain = domain
            self.restoring = restoring
            self.keeper = keeper
        }
        var keptCount: Int { state.withLock { $0.count } }
        var closed: Bool { state.withLock { $0.closed } }
        func keep(email: String, previous: String, setting: String) throws {
            if keeper.failKeep { throw POSIXError(.ENOSPC) }
            keeper.append(["keep", email, previous, setting])
            keeper.state.withLock { $0.kept.append(Kept(email: email, previous: previous, setting: setting)) }
            state.withLock { $0.count += 1 }
        }
        func close() { state.withLock { $0.closed = true } }
    }

    let log: URL
    let failStart: Bool, failKeep: Bool
    let state = Mutex((started: [Run](), kept: [Kept]()))

    init(log: URL, failStart: Bool = false, failKeep: Bool = false) {
        self.log = log
        self.failStart = failStart
        self.failKeep = failKeep
    }

    var started: [Run] { state.withLock { $0.started } }
    var kept: [Kept] { state.withLock { $0.kept } }

    func start(what: String, domain: Domain, restoring: Set<String>) throws -> any KeptSignatureRun {
        if failStart { throw POSIXError(.EACCES) }
        let run = Run(what: what, domain: domain, restoring: restoring, keeper: self)
        state.withLock { $0.started.append(run) }
        return run
    }

    func append(_ fields: [String]) {
        var data = Data("\(fields.count)\0".utf8)
        for field in fields { data += Data((field + "\0").utf8) }
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
