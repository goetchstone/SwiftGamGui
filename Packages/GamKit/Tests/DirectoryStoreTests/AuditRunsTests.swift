import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import TestSupport
import Testing
import Vault

/// The audit runs' logic held to GamGUI's own (invariant 11): `Tests/Fixtures/audit_runs.json` is GamGUI's `core/audit_runs.py`
/// and `GAMConnector.audit_read` run by the generator over edge cases, so the Swift port is held to what GamGUI does rather
/// than to a reading of it: each run's steps and argv, the inactive table and its flags at every window, the license tables
/// with and without the directory, every way a step can end, the suspend preview's targets, and each step's read record.
@Suite("Audit runs, held to GamGUI")
struct AuditRunsTests {
    let fixture = JSONValue.parse(try! String(contentsOf: Fixtures.auditRunsJSON, encoding: .utf8))!
    var now: Date { Self.date(fixture["now"]!.string!) }
    var users: [GamUser] { fixture["directory"]!.array!.map { GamUser(record: $0.object!) } }

    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso.replacingOccurrences(of: "+00:00", with: "Z"))! }

    static func step(_ key: String) -> AuditRuns.Step {
        AuditRuns.all.flatMap(\.steps).first { $0.key == key }!
    }

    static func reads(_ value: JSONValue?) -> [AuditRuns.StepRead] {
        (value?.array ?? []).map { item in
            AuditRuns.StepRead(step: step(item["step"]!.string!), state: AuditRuns.State(rawValue: item["state"]!.string!)!,
                               why: item["why"]!.string!, unread: item["unread"]?.array?.map { $0.string! } ?? [])
        }
    }

    static func users(_ value: JSONValue?) -> [GamUser] { value!.array!.map { GamUser(record: $0.object!) } }
    static func records(_ value: JSONValue?) -> [GamOutput.Record] { value!.array!.map { $0.object! } }

    /// A finding as the fixture writes it, field for field, the text compared as bytes. GamGUI names itself in two notes; this
    /// app's name is GAM GUI (its only listed difference in a table's words).
    static func expect(_ found: AuditRuns.Finding, _ want: JSONValue, _ label: String) {
        func same(_ a: String, _ b: JSONValue?) -> Bool {
            a.utf8.elementsEqual((b?.string ?? "\u{0}").replacingOccurrences(of: "GamGUI", with: "GAM GUI").utf8)
        }
        #expect(same(found.key, want["key"]) && same(found.title, want["title"]), "\(label): \(found.title)")
        #expect(same(found.summary, want["summary"]), "\(label): \(found.summary)")
        #expect(same(found.why, want["why"]) && same(found.note, want["note"]), "\(label): \(found.why) | \(found.note)")
        #expect(found.columns == want["columns"]!.array!.map { $0.string! }, "\(label)")
        #expect(found.rows.map { $0.map { Array($0.utf8) } } == want["rows"]!.array!.map { $0.array!.map { Array($0.string!.utf8) } },
                "\(label): \(found.rows)")
        #expect(found.known == want["known"]!.bool! && found.links == want["links"]!.bool!, "\(label)")
        #expect(found.partial == (want["partial"]?.bool ?? false), "\(label)")
    }

    /// Each finding of a run over one case's reads and tables.
    func expectFindings(_ run: AuditRuns.Run, _ cases: JSONValue?, tables make: (Set<String>) -> AuditRuns.Tables) {
        let cases = cases!.array!
        #expect(!cases.isEmpty)
        for (n, item) in cases.enumerated() {
            let present = Set(item["tables"]!.array!.map { $0.string! })
            let found = AuditRuns.findings(for: run, reads: Self.reads(item["reads"]), tables: make(present), now: now,
                                           days: DirectoryReport.inactiveDays,
                                           leaving: Set(item["leaving"]?.array?.map { $0.string! } ?? []))
            let want = item["findings"]!.array!
            #expect(found.count == want.count, "\(run.key) \(n)")
            for (finding, expected) in zip(found, want) { Self.expect(finding, expected, "\(run.key) \(n)") }
        }
    }

    @Test func theRunsAndTheirStepsAreGamGUIs() {
        let runs = fixture["runs"]!.array!
        #expect(AuditRuns.all.map(\.key) == runs.map { $0["key"]!.string! })
        for (run, want) in zip(AuditRuns.all, runs) {
            #expect(run.title == want["title"]!.string! && run.what == want["what"]!.string!, "\(run.key)")
            let steps = want["steps"]!.array!
            #expect(run.steps.count == steps.count, "\(run.key)")
            for (step, item) in zip(run.steps, steps) {
                #expect(step.key == item["key"]!.string! && step.title == item["title"]!.string!, "\(run.key)")
                #expect(step.keyColumn == item["key_column"]!.string!, "\(run.key)/\(step.key)")
                #expect(step.okCodes.map(Int.init) == item["ok_rcs"]!.array!.map { $0.int! }, "\(run.key)/\(step.key)")
                #expect(step.partialCodes.map(Int.init) == item["partial_rcs"]!.array!.map { $0.int! }, "\(run.key)/\(step.key)")
                #expect(run.command(step) == item["command"]!.string!, "\(run.key)/\(step.key)")
                #expect(AuditRuns.read(step)?.argv == item["argv"]!.array?.map { $0.string! }, "\(run.key)/\(step.key)")
            }
        }
        let constants = fixture["constants"]!
        #expect(AuditRuns.rowsShown == constants["ROWS_SHOWN"]!.int!)
        #expect(AuditRuns.windows == constants["INACTIVE_WINDOWS"]!.array!.map { $0.int! })
        #expect(DirectoryReport.inactiveDays == constants["INACTIVE_DAYS"]!.int!)
        #expect([AuditRuns.State.read, .partial, .unknown, .notRun].map(\.rawValue) == constants["STATES"]!.array!.map { $0.string! })
        #expect(ReadAudit.Origin.auditRun.rawValue == constants["ORIGIN"]!.string!)
        #expect(AuditRuns.staleDays == constants["STALE_DAYS"]!.int!)
        #expect([AuditRuns.newAccount, AuditRuns.adminFlag, AuditRuns.external, AuditRuns.aiName, AuditRuns.broad, AuditRuns.suspendedAdmin]
                == constants["FLAGS"]!.array!.map { $0.string! })
        #expect(AuditRuns.all.flatMap(\.steps).allSatisfy { AuditRuns.read($0).map { AuditRuns.isAuditRead($0.argv) } ?? true })
    }

    @Test func whatIsUnknownAndWhyIsGamGUIs() {
        for item in fixture["implausibly_empty"]!.array! {
            #expect(AuditRuns.implausiblyEmpty(Self.step(item["step"]!.string!), rows: item["rows"]!.int!) == item["why"]!.string!)
        }
        for item in fixture["unknown_because"]!.array! {
            let needed = item["needed"]!.array!.map { Self.step($0.string!) }
            let reads = Self.reads(item["reads"])
            let why = needed.count == 1 ? AuditRuns.unknownBecause(reads, needed[0])
                : AuditRuns.unknownBecause(reads, needed[0], needed[1])
            #expect(Array(why.utf8) == Array(item["why"]!.string!.utf8), "\(why)")
        }
        for item in fixture["shown_time"]!.array! {
            let shown = AuditRuns.shownTime(item["value"]?.string)
            #expect(Array(shown.utf8) == Array(item["shown"]!.string!.utf8), "\(item)")
        }
    }

    /// The window's bucket, never-signed-in first; a new account (made inside the window, or when isn't known) and an admin
    /// flagged; an unknown directory never an empty list.
    @Test func theInactiveTableIsGamGUIsAtEveryWindow() {
        for item in fixture["inactive"]!.array! {
            let days = item["days"]!.int!
            let directory = item["directory"]?.array.map { $0.map { GamUser(record: $0.object!) } } ?? users
            Self.expect(AuditRuns.inactiveFinding(directory, days: days, now: now), item["finding"]!, "inactive \(days)")
        }
        for item in fixture["inactive_unknown"]!.array! {
            let found = AuditRuns.findings(for: AuditRuns.inactiveUsers, reads: Self.reads(item["reads"]), tables: .init(), now: now,
                                           days: item["days"]!.int!)
            #expect(found.count == 1)
            Self.expect(found[0], item["findings"]!.array![0], "inactive unknown")
        }
    }

    /// The people a suspend acts on: in address order, the connected admin left out by address or by account ID.
    @Test func theSuspendTargetsAreGamGUIs() {
        for item in fixture["suspend"]!.array! {
            let id = item["admin_id"]!.string!
            let (targets, leftOut) = AuditRuns.inactiveToSuspend(users, admin: item["admin"]!.string!, adminID: id.isEmpty ? nil : id,
                                                                 days: item["days"]!.int!, now: now)
            let want = item["targets"]!.array!
            #expect(targets.map(\.email) == want.map { $0["email"]!.string! }, "\(item["admin"]!) \(item["days"]!)")
            #expect(targets.map(\.name) == want.map { $0["name"]!.string! })
            #expect(targets.map(\.lastLogin) == want.map { $0["last_login"]!.string! })
            #expect(targets.map(\.new) == want.map { $0["new"]!.bool! })
            #expect(leftOut == item["left_out"]!.array!.map { $0.string! })
        }
    }

    /// Seats per license, on suspended accounts and on addresses the directory lacks, over every way the two steps can end.
    @Test func theLicenseTablesAreGamGUIs() {
        for (n, item) in fixture["licenses"]!.array!.enumerated() {
            var tables = AuditRuns.Tables()
            if let seats = item["seats"]?.array { tables.rows[AuditRuns.licenses.key] = seats.map { $0.object! } }
            if item["directory"]!.bool! { tables.users = users }
            let found = AuditRuns.findings(for: AuditRuns.licenseUsage, reads: Self.reads(item["reads"]), tables: tables, now: now,
                                           days: DirectoryReport.inactiveDays)
            let want = item["findings"]!.array!
            #expect(found.count == want.count)
            for (finding, expected) in zip(found, want) { Self.expect(finding, expected, "licenses \(n)") }
        }
    }

    /// Shared drive members (outside members first; an alias is inside), drives no active organizer looks after (suspended,
    /// gone from the directory or deleted, being offboarded here; a group organizer never flagged), and listed drives GAM
    /// didn't read the members of, over every way the four steps can end.
    @Test func theSharedDriveTablesAreGamGUIs() {
        let directory = Self.users(fixture["drive_directory"]), drives = Self.records(fixture["drive_list"])
        let acls = Self.records(fixture["acl_rows"]), domains = Self.records(fixture["domains"]!["records"])
        #expect(AuditRuns.domainsFrom(domains) == fixture["domains"]!["found"]!.array!.map { $0.string! })
        expectFindings(AuditRuns.sharedDrives, fixture["shared_drives"]) { present in
            AuditRuns.Tables(users: present.contains("directory") ? directory : nil,
                             rows: ["drives": present.contains("drives") ? drives : nil, "drive_acls": present.contains("drive_acls") ? acls : nil,
                                    "domains": present.contains("domains") ? domains : nil].compactMapValues { $0 })
        }
    }

    /// Every class with its owner by ID, classes owned by a suspended account or by one the directory doesn't list, and stale
    /// ones (active or provisioned, a year without change), with the directory read and without it.
    @Test func theClassroomTablesAreGamGUIs() {
        let directory = Self.users(fixture["course_directory"]), courses = Self.records(fixture["courses"])
        expectFindings(AuditRuns.classroom, fixture["classroom"]) { present in
            AuditRuns.Tables(users: present.contains("directory") ? directory : nil,
                             rows: present.contains("courses") ? ["courses": courses] : [:])
        }
    }

    /// Who holds an admin role (a holder GAM couldn't name joined by ID, else kept as unknown, never dropped), the token read
    /// for them, and their apps flagged, over every way the three steps can end, an admin GAM couldn't read included.
    @Test func theAdminTokenTablesAreGamGUIs() throws {
        let directory = Self.users(fixture["admin_directory"]), tokens = Self.records(fixture["token_rows"])
        let holders = fixture["holders"]!, rows = Self.records(holders["rows"])
        #expect(rows.map { AuditRuns.holder(of: $0, users: directory) } == holders["holders"]!.array!.map { $0.string! })
        #expect(rows.map { AuditRuns.holder(of: $0, users: nil) } == holders["holders_without_directory"]!.array!.map { $0.string! })
        #expect(AuditRuns.adminAddresses(rows, users: directory) == holders["addresses"]!.array!.map { $0.string! })
        #expect(AuditRuns.adminAddresses(rows) == holders["addresses_without_directory"]!.array!.map { $0.string! })
        #expect(AuditRuns.unnamedHolders(rows, users: directory) == holders["unnamed"]!.array!.map { $0.string! })
        #expect(AuditRuns.unnamedHolders(rows, users: nil) == holders["unnamed_without_directory"]!.array!.map { $0.string! })
        #expect(AuditRuns.read(AuditRuns.adminTokens, tables: .init(users: directory, rows: ["admins": rows]))?.argv
                == holders["token_argv"]!.array!.map { $0.string! })
        #expect(AuditRuns.read(AuditRuns.adminTokens) == nil && holders["token_argv_without_admins"] == .null)
        expectFindings(AuditRuns.adminTokenReview, fixture["admin_tokens"]) { present in
            AuditRuns.Tables(users: present.contains("directory") ? directory : nil,
                             rows: ["admins": present.contains("admins") ? rows : nil,
                                    "admin_tokens": present.contains("admin_tokens") ? tokens : nil].compactMapValues { $0 })
        }
        for item in fixture["complete"]!.array! {
            let reads = zip(AuditRuns.adminTokenReview.steps, item["states"]!.array!).map {
                AuditRuns.StepRead(step: $0.0, state: AuditRuns.State(rawValue: $0.1.string!)!)
            }
            let outcome = AuditRuns.Outcome(run: AuditRuns.adminTokenReview, reads: reads,
                                            findings: [AuditRuns.Finding("x", "x", "", [], partial: item["partial"]!.bool!)],
                                            tables: .init(), when: now, days: 0)
            #expect(outcome.complete == item["complete"]!.bool!, "\(item)")
        }
    }

    /// Each step's read record, as GamGUI's `audit_read` writes it over the same output: a `print` read without `todrive` or
    /// nothing runs; the rows, or GAM's words, or "the table wasn't written" when the step's key column isn't in GAM's titles;
    /// never the output. A cancelled read is said in this app's words, as F1's.
    @Test func eachStepsReadRecordIsGamGUIs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-audit-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let audit = ReadAudit(log: AuditLog(url: folder.appending(path: "reads.jsonl")))
        let domain = try #require(Domain("example.com"))
        for item in fixture["reads"]!.array! {
            let name = item["name"]!.string!, argv = item["argv"]!.array!.map { $0.string! }
            let records = item["records"]!.array!
            guard item["raised"]?.string != "ValueError" else {
                #expect(!AuditRuns.isAuditRead(argv) && records.isEmpty && item["ran"]!.array!.isEmpty, "\(name)")
                continue
            }
            #expect(AuditRuns.isAuditRead(argv), "\(name)")
            let outcome: ReadAudit.Outcome
            if let output = item["output"]?.string, let exit = item["exit"]?.int {
                let step = AuditRuns.Step(key: "x", title: "x", keyColumn: item["key_column"]!.string!,
                                          okCodes: item["ok_rcs"]!.array!.map { Int32($0.int!) },
                                          partialCodes: item["partial_rcs"]!.array!.map { Int32($0.int!) })
                let result = GamResult(exitCode: Int32(exit), stdout: output, stderr: item["stderr"]!.string!, stdoutTruncated: false,
                                       stderrTruncated: false)
                switch AuditRuns.answer(result, step: step, argv: argv) {
                case .success(let (rows, unread)):
                    #expect(rows.count == item["rows"]?.int && unread == item["unread"]!.array!.map { $0.string! }, "\(name)")
                    outcome = .read(rows: rows.count, partial: !unread.isEmpty)
                case .failure(.incomplete(let incomplete)):
                    #expect(item["raised"]?.string == "Incomplete", "\(name)")
                    outcome = .failed(incomplete.reason)
                case .failure(.gam(let error)):
                    // GamGUI's `str(GAMError)` is its message, held to this app's by gam_errors.json.
                    #expect(item["raised"]?.string == "GAMError", "\(name)")
                    outcome = .failed(error.message)
                }
            } else if let error = item["error"]?.string {
                outcome = .failed(error)
            } else {
                outcome = .interrupted
            }
            var written = try audit.record(command: "license_usage/licenses", target: "", argv: argv, domain: domain,
                                           origin: .auditRun, outcome: outcome)
            written["ts"] = nil
            var expected = try #require(records.first?.object, "\(name)")
            if outcome == .interrupted, var extra = expected["extra"]?.object {
                extra["error"] = .string(ReadAudit.interrupted)
                expected["extra"] = .object(extra)
            }
            #expect(written == expected, "\(name)")
        }
    }
}
