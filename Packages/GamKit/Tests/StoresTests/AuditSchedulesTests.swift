import Darwin
import Foundation
import GamEngine
@testable import Stores
import Synchronization
import TestSupport
import Testing
import Vault

/// Schedules (plan F7a) held to GamGUI's own (invariant 11): `Tests/Fixtures/schedules.json` is GamGUI's `core/schedules.py` run by
/// the generator, so the port is held to what GamGUI does rather than to a reading of it: the next due day over month ends, a
/// leap day and the year's end; the due words in two time zones, a change to summer time and a clock set back included; what
/// changed since a kept run, over every way an earlier run can't be compared; and the keep, a run at a time, with its words,
/// which kept runs stay (by their sequence, never the clock) and how many a lowered count, unscheduling, Delete and Setup's
/// Remove take.
@Suite("Schedules, held to GamGUI")
struct AuditSchedulesParityTests {
    let fixture = JSONValue.parse(try! String(contentsOf: Fixtures.schedulesJSON, encoding: .utf8))!

    static func day(_ iso: String) -> AuditSchedules.Day {
        let parts = iso.split(separator: "-").map { Int($0)! }
        return .init(year: parts[0], month: parts[1], day: parts[2])
    }

    static func rows(_ value: JSONValue?) -> [[String]] { (value?.array ?? []).map { $0.array!.map { $0.string! } } }

    static func tables(_ value: JSONValue?) -> [AuditSchedules.Table] {
        value!.array!.map { item in
            .init(key: item["key"]!.string!, title: item["title"]!.string!, columns: item["columns"]!.array!.map { $0.string! },
                  rows: rows(item["rows"]), known: item["known"]!.bool!, partial: item["partial"]!.bool!)
        }
    }

    static func expect(_ found: [String: AuditSchedules.Change], _ want: JSONValue?, _ label: String) {
        let want = want!.object!
        #expect(Set(found.keys) == Set(want.keys), "\(label)")
        for (key, item) in want {
            let change = found[key]
            #expect(change?.since == item["since"]!.double!, "\(label) \(key)")
            #expect(change?.new == rows(item["new"]) && change?.gone == rows(item["gone"]), "\(label) \(key): \(String(describing: change))")
            #expect(change?.why.utf8.elementsEqual(item["why"]!.string!.utf8) == true, "\(label) \(key): \(change?.why ?? "")")
        }
    }

    @Test func theConstantsAreGamGUIs() {
        let constants = fixture["constants"]!
        #expect(AuditSchedules.Cadence.allCases.map(\.rawValue) == constants["CADENCES"]!.array!.map { $0.string! })
        for cadence in AuditSchedules.Cadence.allCases {
            #expect(cadence.word == constants["CADENCE_WORDS"]![cadence.rawValue]!.string!)
        }
        #expect(AuditSchedules.keepDefault == constants["KEEP_DEFAULT"]!.int! && AuditSchedules.keepCap == constants["KEEP_CAP"]!.int!)
        #expect(AuditSchedules.keepRowsCap == constants["KEEP_ROWS_CAP"]!.int! && AuditSchedules.fileVersion == constants["FILE_VERSION"]!.int!)
        #expect(AuditSchedules.notKnownNow == constants["NOT_KNOWN_NOW"]!.string! && AuditSchedules.partUnknownNow == constants["PART_UNKNOWN_NOW"]!.string!)
        #expect(AuditSchedules.nothingBefore == constants["NOTHING_BEFORE"]!.string! && AuditSchedules.keptRunUnread == constants["KEPT_RUN_UNREAD"]!.string!)
        #expect(AuditSchedules.notAnswered == constants["NOT_ANSWERED"]!.string! && AuditSchedules.keptUnread == constants["KEPT_UNREAD"]!.string!)
    }

    /// A day, a week or a calendar month on; the 31st into a shorter month is its last day.
    @Test func theNextDueDayIsGamGUIs() {
        let cases = fixture["next_day"]!.array!
        #expect(cases.count > 40)
        for item in cases {
            let cadence = AuditSchedules.Cadence(rawValue: item["cadence"]!.string!)!
            #expect(AuditSchedules.nextDay(Self.day(item["last"]!.string!), cadence).description == item["next"]!.string!, "\(item)")
        }
    }

    /// Due is a local day, in the Mac's time zone, never a count of hours; a last run dated after now says to check the clock.
    @Test func whenARunIsDueAndItsWordsAreGamGUIs() {
        let cases = fixture["due"]!.array!
        #expect(cases.count > 700)
        for item in cases {
            let clock = AuditSchedules.Clock(timeZone: TimeZone(identifier: item["zone"]!.string!)!)
            let schedule = AuditSchedules.Schedule(run: "license_usage", cadence: .init(rawValue: item["cadence"]!.string!)!, keep: 5,
                                                   since: 0, done: item["done"]!.double!)
            let now = item["now"]!.double!
            let due = clock.due("License usage", schedule, now: now)
            let label = "\(item["zone"]!.string!) \(schedule.cadence) done \(schedule.done) now \(now)"
            #expect(due.due == item["due"]!.bool! && due.headline == item["headline"]!.string!, "\(label): \(due.headline)")
            #expect(due.detail == item["detail"]!.string! && due.line == item["line"]!.string!, "\(label): \(due.detail)")
            #expect(clock.isDue(schedule, now: now) == item["is_due"]!.bool!, "\(label)")
            #expect(clock.dueDay(schedule)?.description == item["due_day"]!.string, "\(label)")
        }
        for item in fixture["when_words"]!.array! {
            let clock = AuditSchedules.Clock(timeZone: TimeZone(identifier: item["zone"]!.string!)!)
            let when = item["when"]!.double!
            #expect(clock.words(at: when) == item["words"]!.string!, "\(item)")
            #expect(AuditSchedules.Clock.words(clock.day(when)) == item["day"]!.string!, "\(item)")
        }
    }

    /// New and gone are whole rows, as a multiset; a table unknown or partial, now or then, is never compared; an earlier run
    /// with another window, or that didn't keep the table whole, is passed over; one that can't be read stops the walk.
    @Test func whatChangedSinceIsGamGUIs() {
        let utc = AuditSchedules.Clock(timeZone: .gmt)
        let cases = fixture["changes"]!.array!
        #expect(cases.count == 14)
        for item in cases {
            let name = item["name"]!.string!
            let earlier: [(head: AuditSchedules.KeptRun, rows: JSONValue)] = item["earlier"]!.array!.map { run in
                let tables = run["tables"]!.array!.map { t in
                    AuditSchedules.KeptTable(key: t["key"]!.string!, title: t["title"]!.string!, columns: t["columns"]!.array!.map { $0.string! },
                                             known: t["known"]!.bool!, partial: t["partial"]!.bool!, count: t["count"]!.int!, kept: t["kept"]!.bool!)
                }
                return (AuditSchedules.KeptRun(id: run["id"]!.string!, when: run["when"]!.double!, days: run["days"]!.int!, tables: tables,
                                               problem: run["problem"]!.string!), run["rows"]!)
            }
            var loads: [String: Int] = [:]
            let found = AuditSchedules.changesSince(Self.tables(item["findings"]), days: item["days"]!.int!, earlier: earlier.map(\.head),
                                                    clock: utc) { id in
                loads[id, default: 0] += 1
                let (head, rows) = earlier.first { $0.head.id == id }!
                if let problem = rows.string { return .init(id: id, problem: problem) }
                var whole = head
                for index in whole.tables.indices where whole.tables[index].kept {
                    if let kept = rows[whole.tables[index].key] { whole.tables[index].rows = Self.rows(kept) }
                }
                return whole
            }
            Self.expect(found, item["changes"], name)
            #expect(loads == (item["loads"]!.object!.reduce(into: [:]) { $0[$1.key] = $1.value.int! }), "\(name)")
        }
    }

    /// The keep, a run at a time on a fresh store: what each run says of its keep, which kept runs stay (newest first, by their
    /// sequence: a run kept with the clock set back still sorts as the newest), what a lowered count, unscheduling, Delete and
    /// Setup's Remove take, and when each last counted.
    @Test func theKeepIsGamGUIs() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-schedules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AuditScheduleStore(root: base.appending(path: "schedules"))
        let keep = fixture["keep"]!
        let domain = try #require(Domain(keep["domain"]!.string!)), run = keep["run"]!.string!
        let utc = AuditSchedules.Clock(timeZone: .gmt)
        let steps = keep["steps"]!.array!
        #expect(steps.count == 17)
        for step in steps {
            let op = step["op"]!.string!
            if step["answered"] != nil {
                let after = store.afterRun(domain, run: run, tables: Self.tables(step["findings"]), days: step["days"]!.int!,
                                           answered: step["answered"]!.bool!, when: step["when"]!.double!, clock: utc)
                #expect(after.note == step["note"]!.string! && after.problem == step["problem"]!.bool!, "\(op): \(after.note)")
                Self.expect(after.changes, step["changes"], op)
            } else if step["cadence"] != nil {
                let (saved, gone) = try store.setSchedule(domain, run: run, cadence: .init(rawValue: step["cadence"]!.string!),
                                                          keep: step["keep_asked"]!.int!, now: step["when"]!.double!)
                #expect((saved != nil) == step["saved"]!.bool! && gone == step["gone"]!.int, "\(op)")
            } else if let forgot = step["forgot"]?.array {
                let (schedules, kept) = try store.forget(domain)
                #expect([schedules, kept] == forgot.map { $0.int! }, "\(op)")
            } else {
                #expect(try store.deleteKept(domain, run: run) == step["gone"]!.int!, "\(op)")
            }
            let schedule = try store.schedules(domain)[run]
            if let want = step["schedule"]?.object {
                #expect(schedule?.cadence.rawValue == want["cadence"]!.string! && schedule?.keep == want["keep"]!.int!, "\(op)")
                #expect(schedule?.since == want["since"]!.double! && schedule?.done == want["done"]!.double!, "\(op)")
            } else {
                #expect(schedule == nil, "\(op)")
            }
            let kept = try store.runs(domain, run: run)
            #expect(kept.map { String($0.id.prefix(13)) } == step["kept"]!.array!.map { $0.string! }, "\(op)")
            #expect(kept.map(\.days) == step["kept_days"]!.array!.map { $0.int! } && kept.allSatisfy(\.problem.isEmpty), "\(op)")
        }
    }
}

/// The store's own rules (GamGUI's `tests/test_schedules.py`, its store half, and this app's descriptors): private folders and
/// files, per domain; a file that isn't a store set aside, one the disk couldn't read never saved over; a link anywhere, or a
/// FIFO, refused or said, never followed or waited on; a kept run that can't be read said, never read as none.
@Suite("Schedules on this Mac")
struct AuditScheduleStoreTests {
    let base: URL
    let root: URL
    let example = Domain("example.com")!, other = Domain("example.org")!
    let utc = AuditSchedules.Clock(timeZone: .gmt)
    static let t0 = 1_794_992_400.0, day = 86_400.0

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-schedules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui/schedules")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    static func table(_ key: String, _ rows: [[String]], known: Bool = true, partial: Bool = false) -> AuditSchedules.Table {
        .init(key: key, title: key.capitalized, columns: ["Email", "Name"], rows: rows, known: known, partial: partial)
    }

    /// Schedules `license_usage` weekly on `domain` and runs it once per table list, each a day apart.
    @discardableResult
    func keep(_ store: AuditScheduleStore, _ runs: [[AuditSchedules.Table]], on domain: Domain? = nil, run: String = "license_usage",
              keeping: Int = 5) throws -> [AuditSchedules.AfterRun] {
        let domain = domain ?? example
        if try store.schedules(domain)[run] == nil {
            _ = try store.setSchedule(domain, run: run, cadence: .weekly, keep: keeping, now: Self.t0)
        }
        return runs.enumerated().map { index, tables in
            store.afterRun(domain, run: run, tables: tables, days: 0, answered: true, when: Self.t0 + Double(index) * Self.day, clock: utc)
        }
    }

    func keptFiles() -> [URL] {
        let walker = FileManager.default.enumerator(at: root.appending(path: "kept"), includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" }
    }

    @Test func schedulesAreKeptPerDomainInAPrivateFile() throws {
        let store = AuditScheduleStore(root: root)
        let (saved, gone) = try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        #expect(saved == .init(run: "license_usage", cadence: .weekly, keep: 3, since: Self.t0) && gone == 0)
        #expect(try store.schedules(example) == ["license_usage": saved!] && store.schedules(other).isEmpty)
        #expect(mode(root) == 0o700 && mode(root.appending(path: AuditScheduleStore.fileName)) == 0o600)
        let file = try #require(JSONValue.parse(String(contentsOf: root.appending(path: AuditScheduleStore.fileName), encoding: .utf8)))
        #expect(file["domains"]?.object?.keys == ["example.com"])
    }

    @Test func aScheduleThatIsntOneIsRefusedAndNothingSaved() throws {
        let store = AuditScheduleStore(root: root)
        for (run, keep) in [("license_usage", 0), ("license_usage", AuditSchedules.keepCap + 1), ("../x", 3), ("", 3)] {
            #expect(throws: AuditSchedules.Problem.self) {
                try store.setSchedule(example, run: run, cadence: .weekly, keep: keep, now: Self.t0)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: AuditScheduleStore.fileName).path))
    }

    /// A schedules file the disk couldn't read is unknown, said, and never saved over: no run keeps or counts.
    @Test func aSchedulesFileTheDiskCouldntReadIsUnknownAndNeverSavedOver() throws {
        let store = AuditScheduleStore(root: root)
        try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        let file = root.appending(path: AuditScheduleStore.fileName)
        let before = try Data(contentsOf: file)
        chmod(file.path, 0)
        defer { chmod(file.path, 0o600) }
        #expect(throws: AuditSchedules.Problem.self) { try store.schedules(example) }
        #expect(throws: AuditSchedules.Problem.self) {
            try store.setSchedule(example, run: "classroom_courses", cadence: .daily, keep: 1, now: Self.t0)
        }
        let after = store.afterRun(example, run: "license_usage", tables: [Self.table("t", [["a", "A"]])], days: 0, answered: true,
                                   when: Self.t0, clock: utc)
        #expect(after.problem && after.note.contains("couldn't be read just now") && after.note.hasSuffix("isn't kept and isn't compared."))
        chmod(file.path, 0o600)
        #expect(try Data(contentsOf: file) == before && store.setAside == nil && keptFiles().isEmpty)
    }

    /// One that isn't a store (not JSON, not UTF-8, another shape or version, a cadence it doesn't know, a domain not lowercased,
    /// a time no date can be made of, too deep, too large) is moved aside before an empty one starts, kept as it was.
    @Test(arguments: [#"{not json"#, "\u{FFFD}", #"{"version": 1, "domains": []}"#, #"{"version": 2, "domains": {}}"#,
                      #"{"version": 1, "domains": {"example.com": {"license_usage": {"cadence": "hourly", "keep": 3, "since": 1, "done": 0}}}}"#,
                      #"{"version": 1, "domains": {"Example.com": {}}}"#,
                      #"{"version": 1, "domains": {"example.com": {"license_usage": {"cadence": "weekly", "keep": 3, "since": 1, "done": 1e300}}}}"#,
                      #"{"version": 1, "domains": {"example.com": {"license_usage": {"cadence": "weekly", "keep": 3, "since": NaN}}}}"#,
                      #"{"version": 1, "domains": {"example.com": {"license_usage": {"cadence": "weekly", "keep": 3.0, "since": 1}}}}"#,
                      #"{"version": 1, "domains": {"example.com": {"license_usage": {"cadence": "weekly", "keep": true, "since": 1}}}}"#,
                      String(repeating: "[", count: 100_000), String(repeating: " ", count: (1 << 20) + 1)])
    func aSchedulesFileThatIsntAStoreIsSetAside(content: String) throws {
        let bytes = content == "\u{FFFD}" ? Data([0xFF, 0xFE, 0x00]) : Data(content.utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: root.appending(path: AuditScheduleStore.fileName))
        let store = AuditScheduleStore(root: root)
        #expect(try store.schedules(example).isEmpty)
        let aside = try #require(store.setAside)
        #expect(try Data(contentsOf: aside) == bytes)
        try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        #expect(try Data(contentsOf: aside) == bytes && Set(store.schedules(example).keys) == ["license_usage"])
    }

    /// The store's folder as a link is refused, never followed: what it points at is left alone.
    @Test func aLinkedSchedulesFolderIsRefusedNeverFollowed() throws {
        let elsewhere = base.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: elsewhere)
        let store = AuditScheduleStore(root: root)
        #expect(throws: AuditSchedules.Problem.self) { try store.schedules(example) }
        #expect(throws: AuditSchedules.Problem.self) {
            try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    /// A FIFO where the schedules file or a kept run should be never hangs a read: the one is unknown, the other "isn't a file".
    @Test func aFIFOWhereAScheduleOrAKeptRunShouldBeNeverHangs() throws {
        let store = AuditScheduleStore(root: root)
        try keep(store, [[Self.table("t", [["a", "A"]])]])
        let folder = try #require(keptFiles().first).deletingLastPathComponent()
        #expect(mkfifo(folder.appending(path: "0000000000009-deadbeef.jsonl").path, 0o600) == 0)
        let listed = try store.runs(example, run: "license_usage")
        #expect(listed.map(\.problem) == ["It isn't a file.", ""])
        let file = root.appending(path: AuditScheduleStore.fileName)
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(throws: AuditSchedules.Problem.self) { try store.schedules(example) }
    }

    @Test func aKeptRunIsWholePrivateAndListedNewestFirst() throws {
        let store = AuditScheduleStore(root: root)
        try keep(store, [[Self.table("seats", [["a@x.com", "A"]])],
                         [Self.table("seats", [["a@x.com", "A"], ["b@x.com", "B"]]), Self.table("gone", [], known: false)]])
        let listed = try store.runs(example, run: "license_usage")
        #expect(listed.map { $0.id.prefix(13) } == ["0000000000002", "0000000000001"])
        let head = listed[0]
        #expect(head.when == Self.t0 + Self.day && head.table("seats")?.count == 2 && head.table("seats")?.rows == nil)
        #expect(head.table("gone")?.known == false && head.table("gone")?.kept == false)
        #expect(try store.load(example, run: "license_usage", id: head.id).table("seats")?.rows == [["a@x.com", "A"], ["b@x.com", "B"]])
        #expect(try store.runs(other, run: "license_usage").isEmpty && store.runs(example, run: "classroom_courses").isEmpty)
        let files = keptFiles()
        #expect(files.count == 2 && files.allSatisfy { mode($0) == 0o600 } && !files[0].path.contains("example.com"))
        var folder = files[0].deletingLastPathComponent()
        while folder.path.count >= root.path.count {
            #expect(mode(folder) == 0o700, "\(folder.path)")
            folder.deleteLastPathComponent()
        }
    }

    /// A kept run that can't be read is listed with why, never dropped or read as none; it stops a comparison, said; only a
    /// listed id loads.
    @Test func aKeptRunThatCantBeReadIsSaidNeverPassedOver() throws {
        let store = AuditScheduleStore(root: root)
        try keep(store, [[Self.table("seats", [["a", "A"]])], [Self.table("seats", [["a", "A"], ["b", "B"]])]])
        let newest = try #require(keptFiles().max { $0.lastPathComponent < $1.lastPathComponent })
        let lines = try String(contentsOf: newest, encoding: .utf8).split(separator: "\n")
        try (lines[0] + "\n" + lines[1].prefix(20) + "\n").write(to: newest, atomically: false, encoding: .utf8)
        let id = newest.deletingPathExtension().lastPathComponent
        #expect(try store.runs(example, run: "license_usage").map(\.problem) == ["", ""], "the header still reads")
        #expect(try store.load(example, run: "license_usage", id: id).problem == "It isn't whole.")
        var after = store.afterRun(example, run: "license_usage", tables: [Self.table("seats", [["a", "A"]])], days: 0, answered: true,
                                   when: Self.t0 + 9 * Self.day, clock: utc)
        #expect(after.changes["seats"]?.why == "The run kept on \(utc.words(at: Self.t0 + Self.day)) couldn't be read whole, so this "
                + "table isn't compared.")
        try "garbage\n".write(to: newest, atomically: false, encoding: .utf8)
        #expect(try store.runs(example, run: "license_usage").map(\.problem) == ["", "It isn't whole.", ""])
        after = store.afterRun(example, run: "license_usage", tables: [Self.table("seats", [["a", "A"]])], days: 0, answered: true,
                               when: Self.t0 + 10 * Self.day, clock: utc)
        #expect(after.changes["seats"]?.compared == true, "the newest kept run reads, and is compared with")
        chmod(newest.path, 0)
        defer { chmod(newest.path, 0o600) }
        #expect(try store.runs(example, run: "license_usage").first { $0.id == id }?.problem == "It couldn't be read just now.")
        #expect(try store.load(example, run: "license_usage", id: "../../x").problem == "It is no longer kept.")
    }

    /// A link in a run's folder is never listed; a link anywhere from the store down to a run's folder is refused (said, never
    /// followed), and what it points at is left alone.
    @Test func aLinkAnywhereInTheKeptFoldersIsRefusedAndWhatItPointsAtLeftAlone() throws {
        let outside = base.appending(path: "outside/schedules")
        let real = AuditScheduleStore(root: outside)
        try keep(real, [[Self.table("t", [["a", "A"]])]])
        let victim = try #require(FileManager.default.enumerator(at: outside, includingPropertiesForKeys: nil)?.allObjects
            .compactMap { $0 as? URL }.first { $0.pathExtension == "jsonl" })
        let runFolder = victim.deletingLastPathComponent(), top = runFolder.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: runFolder.appending(path: "9999999999999-deadbeef.jsonl"), withDestinationURL: victim)
        #expect(try real.runs(example, run: "license_usage").count == 1, "a link in the folder isn't listed")
        try FileManager.default.removeItem(at: runFolder.appending(path: "9999999999999-deadbeef.jsonl"))
        for linked in ["kept", "domain", "run"] {
            let probeRoot = base.appending(path: "\(linked)/schedules")
            try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
            let kept = probeRoot.appending(path: "kept")
            switch linked {
            case "kept": try FileManager.default.createSymbolicLink(at: kept, withDestinationURL: outside.appending(path: "kept"))
            case "domain":
                try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: kept.appending(path: top.lastPathComponent), withDestinationURL: top)
            default:
                try FileManager.default.createDirectory(at: kept.appending(path: top.lastPathComponent), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: kept.appending(path: "\(top.lastPathComponent)/license_usage"),
                                                           withDestinationURL: runFolder)
            }
            let probe = AuditScheduleStore(root: probeRoot)
            try probe.setSchedule(example, run: "classroom_courses", cadence: .weekly, keep: 3, now: Self.t0)
            #expect(throws: AuditSchedules.Problem.self, "\(linked)") { try probe.runs(example, run: "license_usage") }
            #expect(throws: AuditSchedules.Problem.self, "\(linked)") { try probe.deleteKept(example, run: "license_usage") }
            try probe.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 1, now: Self.t0)
            let after = probe.afterRun(example, run: "license_usage", tables: [Self.table("t", [])], days: 0, answered: true,
                                       when: Self.t0, clock: utc)
            #expect(after.problem && after.note.contains("isn't a folder (it may be a link)"), "\(linked): \(after.note)")
            if linked == "run" {   // Remove lists the domain's run folders and passes a link over: nothing to follow
                #expect(try probe.forget(example).kept == 0)
            } else {
                #expect(throws: AuditSchedules.Problem.self, "\(linked)") { try probe.forget(example) }
            }
            #expect(FileManager.default.fileExists(atPath: victim.path), "\(linked)")
        }
        #expect(try real.runs(example, run: "license_usage").count == 1)
    }

    /// A kept run named at the last sequence (planted: this app never gets there) stops the keep, said, rather than write a file
    /// no listing would see and no prune would take.
    @Test func aSequenceAtItsEndStopsTheKeepNeverHidesAFile() throws {
        let store = AuditScheduleStore(root: root)
        try keep(store, [[Self.table("t", [["a", "A"]])]])
        let folder = try #require(keptFiles().first).deletingLastPathComponent()
        try FileManager.default.copyItem(at: try #require(keptFiles().first), to: folder.appending(path: "9999999999999-deadbeef.jsonl"))
        let after = store.afterRun(example, run: "license_usage", tables: [Self.table("t", [["a", "A"]])], days: 0, answered: true,
                                   when: Self.t0 + Self.day, clock: utc)
        #expect(after.problem && after.note.contains("names have run out"))
        #expect(keptFiles().count == 2)
    }

    /// A crash's half-written schedules file is swept once it's an hour old; a newer one is left to its save.
    @Test func aCrashsHalfWrittenSchedulesFileIsSwept() throws {
        let clock = Mutex(Self.t0)
        let store = AuditScheduleStore(root: root, now: { clock.withLock { $0 } })
        try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        let leftover = root.appending(path: ".schedules-left")
        try Data("{}".utf8).write(to: leftover)
        let made = try #require(FileManager.default.attributesOfItem(atPath: leftover.path)[.modificationDate] as? Date)
        clock.withLock { $0 = made.timeIntervalSince1970 + 60 }
        try store.setSchedule(example, run: "license_usage", cadence: .daily, keep: 3, now: Self.t0)
        #expect(FileManager.default.fileExists(atPath: leftover.path))
        clock.withLock { $0 = made.timeIntervalSince1970 + 3601 }
        try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    /// A table over the row cap isn't kept, says so, and is never compared with later.
    @Test func aTableOverTheRowCapIsntKeptAndSaysSo() throws {
        let store = AuditScheduleStore(root: root, rowsCap: 2)
        let results = try keep(store, [[Self.table("t", [["a", "A"], ["b", "B"], ["c", "C"]])],
                                       [Self.table("t", [["a", "A"], ["b", "B"], ["c", "C"]])]])
        let head = try #require(store.runs(example, run: "license_usage").last?.table("t"))
        #expect(head.count == 3 && !head.kept && results[1].changes["t"]?.why == AuditSchedules.nothingBefore)
    }

    /// A run that would be larger than the store keeps isn't kept, and says why; it still counts.
    @Test func aRunLargerThanTheStoreKeepsIsntKept() throws {
        let store = AuditScheduleStore(root: root, cap: 600)
        let rows = (0..<40).map { ["person\($0)@example.com", "Person \($0)"] }
        let after = try keep(store, [[Self.table("t", rows)]])[0]
        #expect(after.problem && after.note.hasPrefix("It couldn't be kept on this Mac: It holds more than this app keeps"))
        #expect(try store.runs(example, run: "license_usage").isEmpty && store.schedules(example)["license_usage"]?.done == Self.t0)
    }

    /// Prune keeps the newest; Delete and Setup's Remove leave nothing of that domain, and another domain's are untouched.
    @Test func pruneKeepsTheNewestAndDeleteAndForgetLeaveNothing() throws {
        let store = AuditScheduleStore(root: root)
        try keep(store, (0..<5).map { _ in [Self.table("seats", [["a", "A"]])] })
        try keep(store, [[Self.table("courses", [["c", "C"]])]], run: "classroom_courses")
        try keep(store, [[Self.table("seats", [["o", "O"]])]], on: other)
        let (_, pruned) = try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 2, now: Self.t0)
        #expect(try pruned == 3 && store.runs(example, run: "license_usage").map { $0.id.prefix(13) } == ["0000000000005", "0000000000004"])
        #expect(try store.deleteKept(example, run: "license_usage") == 2 && store.runs(example, run: "license_usage").isEmpty)
        #expect(try store.schedules(example)["license_usage"] != nil, "Delete keeps the schedule")
        let forgot = try store.forget(example)
        #expect(forgot.schedules == 2 && forgot.kept == 1)
        #expect(try store.schedules(example).isEmpty && store.runs(example, run: "classroom_courses").isEmpty)
        #expect(try store.runs(other, run: "license_usage").count == 1 && store.schedules(other).count == 1)
    }

    /// A run that finishes as it stops being scheduled, or as Setup removes its domain, keeps nothing and counts nothing.
    @Test(arguments: ["unscheduled", "removed"])
    func aRunThatFinishesAsItStopsBeingScheduledKeepsNothing(meanwhile: String) throws {
        final class Holder: @unchecked Sendable { var store: AuditScheduleStore? }
        let holder = Holder()
        let example = example
        let store = AuditScheduleStore(root: root, meanwhile: {
            guard let store = holder.store else { return }
            if meanwhile == "unscheduled" {
                _ = try? store.setSchedule(example, run: "license_usage", cadence: nil, keep: 5, now: Self.t0)
            } else {
                _ = try? store.forget(example)
            }
        })
        try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        holder.store = store
        let after = store.afterRun(example, run: "license_usage", tables: [Self.table("t", [["a", "A"]])], days: 0, answered: true,
                                   when: Self.t0, clock: utc)
        #expect(after.note == "Not kept: it stopped being scheduled while it ran." && !after.problem)
        #expect(try keptFiles().isEmpty && store.schedules(example).isEmpty)
    }

    /// A run with a step unanswered is never compared, kept or counted; one not scheduled keeps nothing and writes nothing.
    @Test func aRunWithAStepUnansweredIsNeverComparedKeptOrCounted() throws {
        let store = AuditScheduleStore(root: root)
        let unscheduled = store.afterRun(example, run: "license_usage", tables: [Self.table("t", [])], days: 0, answered: true,
                                         when: Self.t0, clock: utc)
        #expect(unscheduled.changes.isEmpty && unscheduled.note.isEmpty && !FileManager.default.fileExists(atPath: root.path))
        try store.setSchedule(example, run: "license_usage", cadence: .weekly, keep: 3, now: Self.t0)
        let after = store.afterRun(example, run: "license_usage", tables: [Self.table("t", [["a", "A"]])], days: 0, answered: false,
                                   when: Self.t0, clock: utc)
        #expect(after.problem && after.changes["t"]?.why == AuditSchedules.notAnswered && keptFiles().isEmpty)
        #expect(try store.schedules(example)["license_usage"]?.done == 0)
    }

    /// The store keeps nothing outside its own folder of the app's data folder.
    @Test func theKeptTablesLiveUnderTheStoresFolderAndNowhereElse() throws {
        let store = AuditScheduleStore(root: root)
        try keep(store, [[Self.table("t", [["a", "A"]])]])
        let everything = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        let files = everything.filter { !$0.hasDirectoryPath }
        #expect(files.count == 2 && files.allSatisfy { $0.path.contains("/SwiftGamGui/schedules/") }, "\(files)")
        #expect(AuditScheduleStore.defaultRoot.path.hasSuffix("/SwiftGamGui/schedules"))
    }
}
