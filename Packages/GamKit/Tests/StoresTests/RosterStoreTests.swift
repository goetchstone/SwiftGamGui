import Foundation
import GamEngine
@testable import Stores
import Testing
import TestSupport

/// The kept roster (GamGUI's `tests/test_roster.py`, the store) and Plan an Import's pieces below the screen (the
/// non-route parts of `tests/test_roster_web.py`): student data kept owner-only, for its days, deleted on Purge, read
/// for the screen without the people.
@Suite("Roster store and import")
struct RosterStoreTests {
    final class Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-roster-\(UUID().uuidString)")
        var store: URL { url.appending(path: "roster") }

        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }

        func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).sorted() }
    }

    /// A clock a test moves.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_794_355_200)      // 2026-11-11T00:00:00Z
    }

    static func snapshot(_ name: String = "a OneRoster ZIP reads into one snapshot") throws -> RosterSnapshot {
        let item = try #require(RosterParityTests.cases.first { $0.name == name })
        return try Roster.read(item.uploads, caps: item.caps)
    }

    static func mode(_ url: URL) -> Int {
        var info = stat()
        _ = lstat(url.path, &info)
        return Int(info.st_mode & 0o777)
    }

    // MARK: the store

    @Test func aSnapshotIsKeptOwnerOnlyAndReadBackWhole() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        let snapshot = try Self.snapshot("row problems counted by kind")
        let meta = try store.save(snapshot, domain: "Example.com", label: "export.zip", sha256: "abc")
        #expect(meta.counts == snapshot.counts && meta.domain == "example.com" && meta.label == "export.zip")
        #expect(Self.mode(folder.store) == 0o700)
        let file = folder.store.appending(path: RosterStore.fileName("example.com"))
        #expect(Self.mode(file) == 0o600)
        #expect(!RosterStore.fileName("example.com").contains("example"), "a domain's spelling never becomes a path")
        #expect(RosterStore.fileName(" EXAMPLE.com ") == RosterStore.fileName("example.com"))
        let back = try #require(try store.load(domain: "example.com"))
        #expect(back == snapshot)
        #expect(try store.meta(domain: "example.com") == meta)
        #expect(try store.issues(domain: "example.com") == RosterStore.Issues(counts: snapshot.issueCounts, rows: snapshot.issueSample))
        #expect(folder.names() == [RosterStore.fileName("example.com")], "no half-written copy left")
    }

    @Test func aRosterIsKeptPerDomain() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        #expect(try store.meta(domain: "other.example.org") == nil)
        #expect(try store.meta(domain: "example.com") != nil)
    }

    @Test func aSnapshotPastItsDaysIsDeletedOnTheNextLook() throws {
        let folder = Folder(), clock = Clock()
        let store = RosterStore(root: folder.store, now: { clock.now })
        let meta = try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        #expect(meta.importedAt == "2026-11-11T00:00:00Z" && meta.expiresAt == "2026-11-25T00:00:00Z")
        clock.now += Double(RosterStore.keepDays) * 86_400 - 1
        #expect(try store.meta(domain: "example.com") != nil)
        clock.now += 1
        #expect(try store.meta(domain: "example.com") == nil)
        #expect(folder.names().isEmpty)
    }

    /// A roster the disk can never read (here, made unreadable) never shows its stored expiry: it's kept, and said, until
    /// its own file is older than its days, then deleted (GamGUI #121, found by its adversarial run).
    @Test func aRosterThatCanNeverBeReadStillEndsWithItsDays() throws {
        let folder = Folder(), clock = Clock()
        let store = RosterStore(root: folder.store, now: { clock.now })
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        let file = folder.store.appending(path: RosterStore.fileName("example.com"))
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: file.path)
        chmod(file.path, 0)
        defer { chmod(file.path, 0o600) }
        #expect(throws: RosterStore.Failure.self) { try store.meta(domain: "example.com") }
        #expect(folder.names() == [RosterStore.fileName("example.com")], "a read that failed keeps a roster in its days")
        clock.now = clock.now.addingTimeInterval(Double(RosterStore.keepDays) * 86_400 + 1)
        #expect(throws: RosterStore.Failure.self) { try store.meta(domain: "example.com") }
        #expect(folder.names().isEmpty, "past its days by its own file's age, it's deleted")
    }

    /// The date the screen promises holds for a domain nobody opens again: the launch's sweep ages every kept roster as
    /// its own look would (review 2026-11-14), and leaves one in its days.
    @Test func theLaunchSweepDeletesARosterPastItsDaysForAnyDomain() throws {
        let folder = Folder(), clock = Clock()
        let store = RosterStore(root: folder.store, now: { clock.now })
        // The sweep ages by the file's own time, so each file's is the clock's at its save.
        func save(_ domain: String) throws {
            try store.save(Self.snapshot(), domain: domain, label: "x", sha256: "")
            try FileManager.default.setAttributes([.modificationDate: clock.now],
                                                  ofItemAtPath: folder.store.appending(path: RosterStore.fileName(domain)).path)
        }
        try save("example.com")
        clock.now += Double(RosterStore.keepDays) * 86_400 - 1
        try save("other.example.org")
        store.sweepAbandoned()
        #expect(folder.names() == [RosterStore.fileName("example.com"), RosterStore.fileName("other.example.org")].sorted())
        clock.now += 1
        store.sweepAbandoned()
        #expect(folder.names() == [RosterStore.fileName("other.example.org")], "only the one past its days")
    }

    /// A damaged roster in its days is left for its own look, which deletes it and says so: the launch never turns it
    /// silently into "none kept".
    @Test func theLaunchSweepLeavesADamagedRosterInItsDaysToItsLook() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        try Data("not a roster".utf8).write(to: folder.store.appending(path: RosterStore.fileName("example.com")))
        store.sweepAbandoned()
        #expect(folder.names() == [RosterStore.fileName("example.com")])
        #expect(throws: RosterStore.Failure.self) { try store.meta(domain: "example.com") }
        #expect(folder.names().isEmpty)
    }

    /// A kept roster that can't be read just now is still there for Purge (GamGUI's `present`, gamgui#121).
    @Test func aRosterThatCantBeReadIsStillPresentForPurge() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        #expect(!store.present(domain: "example.com"))
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        let file = folder.store.appending(path: RosterStore.fileName("example.com"))
        chmod(file.path, 0)
        defer { chmod(file.path, 0o600) }
        #expect(throws: RosterStore.Failure.self) { try store.meta(domain: "example.com") }
        #expect(store.present(domain: "example.com") && !store.present(domain: "other.example.org"))
        #expect(try store.purge(domain: "example.com"))
        #expect(!store.present(domain: "example.com") && folder.names().isEmpty)
    }

    @Test func purgeDeletesItAtOnce() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        #expect(try store.purge(domain: "example.com"))
        #expect(try store.load(domain: "example.com") == nil)
        #expect(try !store.purge(domain: "example.com"))
        #expect(try !RosterStore(root: folder.url.appending(path: "never-made")).purge(domain: "example.com"))
    }

    @Test func aSaveAQuitCutOffIsSweptByTheNextSaveAndByPurge() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        let snapshot = try Self.snapshot()
        try store.save(snapshot, domain: "example.com", label: "x", sha256: "")
        let name = RosterStore.fileName("example.com")
        let stale = folder.store.appending(path: ".saving-99999-\(name)")        // another process's, holding student data
        try Data("ann.lee@example.com".utf8).write(to: stale)
        let other = folder.store.appending(path: ".saving-99999-\(RosterStore.fileName("other.example"))")
        try Data("x".utf8).write(to: other)
        #expect(try store.purge(domain: "example.com"))
        #expect(folder.names() == [other.lastPathComponent], "only that domain's copies go")
        try Data("ann.lee@example.com".utf8).write(to: stale)
        try store.save(snapshot, domain: "example.com", label: "x", sha256: "")
        #expect(folder.names() == [other.lastPathComponent, name].sorted())
    }

    /// A save the app was quit or killed during leaves its temporary file and no snapshot, so no Purge is shown for it.
    /// The next look of any domain, and the sweep at launch, delete it, whatever process its name records: every save,
    /// in any running copy of the app, holds the store's folder locked, so none is in progress while the sweep holds it.
    /// A pid that now names a live process, or a modification time ahead of the clock, keeps nothing.
    @Test func aSaveCutOffBeforeItsRenameIsSweptByTheNextLook() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try FileManager.default.createDirectory(at: folder.store, withIntermediateDirectories: true)
        let gone = Process()
        gone.executableURL = URL(filePath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let name = RosterStore.fileName("example.com"), elsewhere = RosterStore.fileName("other.example")
        func leave(_ file: String, aged: Bool = false) throws {
            let url = folder.store.appending(path: file)
            try Data("ann.lee@example.com".utf8).write(to: url)
            if aged { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: url.path) }
        }
        let live = getppid()
        try leave(".saving-\(gone.processIdentifier)-\(name)")
        try leave(".saving-\(gone.processIdentifier)-\(elsewhere)")      // a domain never opened again
        try leave(".saving-\(getpid())-\(elsewhere)")
        try leave(".saving-\(live)-\(RosterStore.fileName("aged.example"))", aged: true)
        try leave(".saving-x-\(RosterStore.fileName("odd.example"))")
        try leave(".saving-\(live)-\(name)")                               // a live pid, but no save holds the store
        try leave(".saving-1-\(RosterStore.fileName("ahead.example"))")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 7_200)],
                                              ofItemAtPath: folder.store.appending(path: ".saving-1-\(RosterStore.fileName("ahead.example"))").path)
        #expect(try store.meta(domain: "example.com") == nil)
        #expect(folder.names() == [])

        try leave(".saving-\(gone.processIdentifier)-\(elsewhere)")
        try leave(".saving-\(live)-\(elsewhere)")
        store.sweepAbandoned()
        #expect(folder.names() == [])
    }

    /// Another running copy of the app (another build, or `open -n`) shares the folder. Its save in progress holds the
    /// folder locked (`flock`), so this one's save, purge and sweep wait for it and never delete its temporary file: an
    /// in-process lock alone let them, and its rename then failed (or a purge reported success with a snapshot landing).
    @Test(arguments: ["save", "purge", "sweep"])
    func anotherAppsSaveInProgressIsWaitedFor(_ action: String) async throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        let snapshot = try Self.snapshot()
        try store.save(snapshot, domain: "example.com", label: "x", sha256: "")
        let name = RosterStore.fileName("example.com"), temporary = ".saving-\(getppid())-\(name)"
        // The other app: its own open of the folder, locked, writing its temporary file.
        let other = open(folder.store.path, O_RDONLY | O_DIRECTORY)
        #expect(other >= 0)
        defer { close(other) }
        #expect(flock(other, LOCK_EX) == 0)
        // A whole roster, as another copy writes one: the launch's sweep reads what lands, and deletes junk.
        try Data(contentsOf: folder.store.appending(path: name)).write(to: folder.store.appending(path: temporary))
        let task = Task.detached {
            switch action {
            case "save": try store.save(snapshot, domain: "example.com", label: "y", sha256: "")
            case "purge": try store.purge(domain: "example.com")
            default: store.sweepAbandoned()
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(folder.names().contains(temporary), "its file is left while it saves")
        // It finishes: its file renamed into place, and the folder unlocked.
        #expect(renameat(other, temporary, other, name) == 0)
        #expect(flock(other, LOCK_UN) == 0)
        try await task.value
        #expect(folder.names() == (action == "purge" ? [] : [name]))
    }

    /// The head rewritten with one of its metadata changed, as damage or another app would leave it.
    static func rewrite(_ file: URL, _ key: String, _ value: JSONValue) throws {
        let bytes = Array(try Data(contentsOf: file))
        let length = Int(bytes.u64(8))
        var head = try #require(JSONValue.parse(String(decoding: bytes[16..<(16 + length)], as: UTF8.self))?.object)
        var meta = try #require(head["meta"]?.object)
        meta[key] = value
        head["meta"] = .object(meta)
        let newHead = Array(JSONValue.dumps(.object(head)).utf8)
        var newLength = UInt64(newHead.count).littleEndian
        let out = Array(bytes[0..<8]) + withUnsafeBytes(of: &newLength) { Array($0) } + newHead + Array(bytes[(16 + length)...])
        try Data(out).write(to: file)
    }

    @Test(arguments: [JSONValue.string("garbage"), .string("2099-01-01T00:00:00+00:00"), .number("5"),
                      .string("9999-01-01T00:00:00Z"), .string("2026-02-30T00:00:00Z")])
    func anExpiryItCantTrustDeletesTheSnapshot(_ expires: JSONValue) throws {
        let folder = Folder(), clock = Clock()
        let store = RosterStore(root: folder.store, now: { clock.now })
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        try Self.rewrite(folder.store.appending(path: RosterStore.fileName("example.com")), "expires_at", expires)
        if expires == .string("9999-01-01T00:00:00Z") { clock.now += Double(RosterStore.keepDays + 1) * 86_400 }
        #expect(try store.meta(domain: "example.com") == nil)
        #expect(folder.names().isEmpty)
    }

    @Test func anImportDatedInTheFutureDeletesTheSnapshot() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        let file = folder.store.appending(path: RosterStore.fileName("example.com"))
        let later = RosterStore.stamp(Date().addingTimeInterval(3 * 86_400))
        try Self.rewrite(file, "imported_at", .string(later))
        #expect(try store.meta(domain: "example.com") == nil)
        #expect(folder.names().isEmpty)
    }

    @Test func aFolderWhereTheTemporaryFileGoesStopsASaveAndLeavesNothing() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        let name = RosterStore.fileName("example.com")
        try FileManager.default.createDirectory(at: folder.store.appending(path: ".saving-\(getpid())-\(name)"),
                                                withIntermediateDirectories: true)
        #expect(throws: RosterStore.Failure.self) { try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "") }
        #expect(folder.names() == [".saving-\(getpid())-\(name)"], "the folder is left; no file is")
    }

    @Test func aFolderNamedLikeALeftoverNeverBlocksAPurge() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        let name = RosterStore.fileName("example.com")
        try FileManager.default.createDirectory(at: folder.store.appending(path: ".saving-8-\(name)"), withIntermediateDirectories: true)
        #expect(try store.purge(domain: "example.com"))
        #expect(!folder.names().contains(name))
    }

    @Test(arguments: ["not a roster at all", "head"])
    func aSnapshotThatCantBeReadIsDeletedAndSaid(_ damage: String) throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        try store.save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        let file = folder.store.appending(path: RosterStore.fileName("example.com"))
        if damage == "head" {
            var bytes = Array(try Data(contentsOf: file))
            bytes[17] = UInt8(ascii: "!")                      // the head's JSON broken
            try Data(bytes).write(to: file)
        } else {
            try Data("garbage".utf8).write(to: file)
        }
        #expect(throws: RosterStore.Failure("The kept roster couldn't be read, so it was deleted. Upload the export again.")) {
            try store.meta(domain: "example.com")
        }
        #expect(folder.names().isEmpty)
    }

    @Test func theScreenReadsTheHeadAloneNeverThePeople() throws {
        let folder = Folder(), store = RosterStore(root: folder.store)
        let snapshot = try Self.snapshot("the issues the import screen groups")
        try store.save(snapshot, domain: "example.com", label: "x", sha256: "")
        let file = folder.store.appending(path: RosterStore.fileName("example.com"))
        var bytes = Array(try Data(contentsOf: file))
        bytes[bytes.count - 2] = UInt8(ascii: "!")              // the body (the people) broken: never read for the screen
        try Data(bytes).write(to: file)
        #expect(try store.meta(domain: "example.com")?.counts == snapshot.counts)
        #expect(try store.issues(domain: "example.com")?.counts == snapshot.issueCounts)
        #expect(throws: RosterStore.Failure.self) { try store.load(domain: "example.com") }
    }

    @Test func aLabelIsCappedAt200Characters() throws {
        let folder = Folder()
        let meta = try RosterStore(root: folder.store).save(Self.snapshot(), domain: "example.com",
                                                             label: String(repeating: "é", count: 300), sha256: "")
        #expect(meta.label.unicodeScalars.count == 200)
    }

    @Test func aLinkedStoreFolderIsRefused() throws {
        let folder = Folder()
        let elsewhere = folder.url.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.store, withDestinationURL: elsewhere)
        #expect(throws: RosterStore.Failure.self) {
            try RosterStore(root: folder.store).save(Self.snapshot(), domain: "example.com", label: "x", sha256: "")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func aStampIsReadStrictly() {
        #expect(RosterStore.date("2026-11-11T09:30:05Z") != nil)
        for bad in ["2026-11-11 09:30:05Z", "2026-13-01T00:00:00Z", "2026-11-11T24:00:00Z", "2026-11-11T00:00:60Z",
                    "2026-1-11T00:00:00Z", "２０２６-11-11T00:00:00Z", "2026-11-11T00:00:00z"] {
            #expect(RosterStore.date(bad) == nil, "\(bad)")
        }
    }

    // MARK: Plan an Import's pieces

    @Test func problemsAreGroupedForTheSISTeamWithAnIssuesCSV() throws {
        let snapshot = try Self.snapshot("the issues the import screen groups")
        let issues = RosterStore.Issues(counts: snapshot.issueCounts, rows: snapshot.issueSample)
        let kinds = RosterImport.kinds(issues)
        #expect(kinds.map(\.code) == ["no_email", "unknown_class"], "most frequent first")
        #expect(kinds[0].cause == "A teacher or student has no email address." && kinds[0].fix.hasPrefix("Give them"))
        let sheet = RosterImport.issuesCSV(issues)
        #expect(sheet[0] == ["kind", "cause", "fix", "file", "line", "ID", "detail", "kind_total"])
        let noEmail = sheet.filter { $0[0] == "no_email" }.map { [$0[5], $0[4], $0[7]] }
        #expect(noEmail == [["U4", "5", "2"], ["U5", "6", "2"]])
        #expect(RosterImport.issuesFileName == "roster-issues.csv")
    }

    @Test func eachKindShowsTwentyRowsAndTheCountIsWhole() {
        let rows = (1...30).map { RosterSnapshot.Issue(code: "no_email", file: "users.csv", row: $0, sourceID: "U\($0)", detail: "") }
            + [RosterSnapshot.Issue(code: "made_up", file: "x.csv", row: 2, sourceID: "", detail: "")]
        let issues = RosterStore.Issues(counts: [.init(code: "made_up", count: 30), .init(code: "no_email", count: 30)], rows: rows)
        let kinds = RosterImport.kinds(issues)
        #expect(kinds.map(\.code) == ["made_up", "no_email"], "a tie by code")
        #expect(kinds[1].rows.count == RosterImport.issuesShown && kinds[1].count == 30)
        #expect(kinds[0].cause == "made_up" && kinds[0].fix.isEmpty, "a kind without words names itself")
        #expect(RosterImport.issuesCSV(issues).count == 1 + 31)
        #expect(RosterImport.kinds(nil).isEmpty)
    }

    @Test func aLabelAndADigestName() {
        let one = [Roster.Upload(name: "export.zip", bytes: [1, 2])]
        let seven = (0..<7).map { Roster.Upload(name: "f\($0).csv", bytes: [UInt8($0)]) }
        #expect(RosterImport.label(one) == "export.zip" && RosterImport.label(seven) == "7 CSV files")
        #expect(RosterImport.digest([Roster.Upload(name: "a", bytes: Array("ab".utf8)), Roster.Upload(name: "b", bytes: Array("c".utf8))])
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of the bytes in order: abc")
    }

    @Test func aPickedFolderGivesItsOwnFilesAndLeavesItsFolders() throws {
        let folder = Folder()
        let export = folder.url.appending(path: "Export")
        try FileManager.default.createDirectory(at: export.appending(path: "inner"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: export.appending(path: "users.csv"))
        try Data("a".utf8).write(to: export.appending(path: "orgs.csv"))
        try Data("x".utf8).write(to: export.appending(path: "inner/classes.csv"))
        let picked = try RosterImport.readPicked([export])
        #expect(picked.map(\.name) == ["orgs.csv", "users.csv"] && picked.map(\.bytes) == [Array("a".utf8), Array("b".utf8)])
        #expect(try RosterImport.readPicked([export.appending(path: "users.csv")]).map(\.name) == ["users.csv"])
    }

    @Test func aLinkIsRefusedNeverFollowed() throws {
        let folder = Folder()
        try Data("secret".utf8).write(to: folder.url.appending(path: "target.csv"))
        let link = folder.url.appending(path: "users.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url.appending(path: "target.csv"))
        #expect(throws: Roster.Refusal.package("“users.csv” is a link or a special file, not a file. Choose the export's own files.")) {
            try RosterImport.readPicked([link])
        }
        #expect(throws: Roster.Refusal.self) { try RosterImport.readPicked([folder.url]) }
    }

    @Test func tooManyFilesOrBytesAreRefusedBeforeAnyIsRead() throws {
        let folder = Folder()
        for index in 0..<5 { try Data(repeating: 0x61, count: 10).write(to: folder.url.appending(path: "f\(index).csv")) }
        var caps = RosterCaps()
        caps.members = 4
        #expect(throws: Roster.Refusal.package("That's more files than a roster export holds. Choose its ZIP, or the CSV files in its folder.")) {
            try RosterImport.readPicked([folder.url], caps: caps)
        }
        caps = RosterCaps()
        caps.upload = 49
        #expect(throws: Roster.Refusal.package("That's more than 0 MB, more than a roster export should be.")) {
            try RosterImport.readPicked([folder.url], caps: caps)
        }
        caps.upload = 50
        #expect(try RosterImport.readPicked([folder.url], caps: caps).count == 5)
    }

    /// The snapshots' package (`Tests/Fixtures/demo/roster`) reads, with a problem of each kind the screen groups.
    @Test func theDemoPackageReadsWithItsProblems() throws {
        let snapshot = try Roster.read(RosterImport.readPicked([Fixtures.directory.appending(path: "demo/roster")]))
        #expect(snapshot.counts.classes == 3 && snapshot.counts.teachers == 2 && snapshot.counts.students == 2 && snapshot.others == 1)
        #expect(Set(snapshot.issueCounts.map(\.code)) == ["skipped", "no_email", "bad_email", "unknown_person", "unknown_class"])
    }

    /// One picked CSV is held for its map with the bytes as picked (GamGUI's `NeedsMap`), named by its base name.
    @Test func oneSpreadsheetIsHeldForItsMapWithItsBytes() {
        let body = Array("Class,Email,Role\r\nC1,t@x.edu,teacher\r\n".utf8)
        let result = Result { () throws(Roster.Refusal) in try Roster.read([.init(name: "folder/My Export.csv", bytes: body)]) }
        #expect(result.refusal == .needsMap(name: "My Export.csv", bytes: body))
    }
}
