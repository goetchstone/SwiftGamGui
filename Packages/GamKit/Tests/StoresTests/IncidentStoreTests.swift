@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// Incidents kept on this Mac (docs/plans/2026-10-22-incidents.md, slice 3): the record is what a person says, saved
/// `0600` in `0700` folders and read back; the evidence is an export of the logs, read by descriptor and checked, then
/// copied in byte for byte.
@Suite("Incident store")
struct IncidentStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-incidents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "incidents")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    static let monday = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                       year: 2026, month: 10, day: 19, hour: 13, minute: 30).date!
    static let header = "log,time,actor,event,ip_address,flagged,via,parameters\r\n"
    static let login = header + "login,2026-10-19T13:00:00Z,carol@example.com,login_success,198.51.100.23,yes,,login_type: google_password\r\n"
    static let about = "Incident logs exported 2026-10-23 0619 UTC.\nOver the last 30 days.\nAccounts: every account.\nFrom IP address: any.\n"

    /// An export folder as Export All writes one, with a stray file beside it.
    func export(named name: String = "Incident logs 2026-10-23 0619", files: [String: String]? = nil) throws -> URL {
        let folder = base.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, text) in files ?? ["about.txt": Self.about, "login-log.csv": Self.login, "notes.txt": "not evidence"] {
            try Data(text.utf8).write(to: folder.appending(path: file))
        }
        return folder
    }

    /// Nothing is written until an incident is made; it's saved `0600` in `0700` folders, read back by a new store, kept per
    /// domain, its ID the day it was opened; details and notes saved over it, notes oldest first.
    @Test func anIncidentIsSavedAndReadBack() throws {
        var store = try IncidentStore(root: root)
        #expect(store.records.isEmpty && !FileManager.default.fileExists(atPath: root.path))
        let made = try store.create(domain: "Example.com", title: "  Account takeover ", opened: Self.monday, openedBy: "Pat",
                                    reported: "A Google alert")
        #expect(made.title == "Account takeover" && made.domain == "example.com" && IncidentStore.isID(made.id))
        #expect(made.id.hasPrefix("2026-10-19-"))
        let file = root.appending(path: made.id).appending(path: IncidentStore.fileName)
        #expect(mode(root) == 0o700 && mode(root.appending(path: made.id)) == 0o700 && mode(file) == 0o600)

        try store.addNote("Told the insurer.", at: Self.monday.addingTimeInterval(7200), to: made.id)
        try store.addNote("Reset the password.", at: Self.monday.addingTimeInterval(60), to: made.id)
        var changed = try #require(store.records.first)
        changed.reported = "The person"
        try store.save(changed)
        let reopened = try IncidentStore(root: root)
        #expect(reopened.records == store.records && reopened.records(for: "example.com").count == 1 && reopened.records(for: "example.org").isEmpty)
        #expect(reopened.records.first?.notes.map(\.text) == ["Reset the password.", "Told the insurer."])
        #expect(reopened.records.first?.reported == "The person" && reopened.records.first?.opened == Self.monday)
    }

    /// The warnings picked (Who it reached) are kept with the incident and read back; a file from before has none and still
    /// reads; one that isn't a Message-ID isn't kept.
    @Test func theWarningsPickedAreKept() throws {
        var store = try IncidentStore(root: root)
        let made = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        let file = root.appending(path: made.id).appending(path: IncidentStore.fileName)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(made.warnings.isEmpty && written.contains("\"warnings\": []"))
        var picked = made
        picked.warnings = [IncidentStore.Warning(email: "phish-1@mail.example.com", warning: "warn-1@mail.example.com")]
        try store.save(picked)
        let saved = try IncidentStore(root: root)
        #expect(saved.records.first?.warnings == picked.warnings)

        // As it was written before 2026-10-24: no "warnings" at all.
        let before = try String(contentsOf: file, encoding: .utf8)
        let old = try #require(JSONValue.parse(before)?.object)
        var stripped = GamOutput.Record()
        for (key, value) in old where key != "warnings" { stripped[key] = value }
        try Data(JSONValue.dumps(.object(stripped)).utf8).write(to: file)
        let reread = try IncidentStore(root: root)
        #expect(reread.unreadable.isEmpty && reread.records.first?.warnings == [] && reread.records.first?.title == "Takeover")

        var bad = picked
        bad.warnings = [IncidentStore.Warning(email: "phish 1", warning: "warn-1@mail.example.com")]
        #expect(throws: IncidentStore.Problem.self) { try store.save(bad) }
        var many = picked
        many.warnings = (0...IncidentStore.notesCap).map { IncidentStore.Warning(email: "phish-1@mail.example.com", warning: "w\($0)@mail.example.com") }
        #expect(throws: IncidentStore.Problem.invalid("At most \(IncidentStore.notesCap) warnings picked are kept with an incident.")) {
            try store.save(many)
        }
    }

    /// The review (Report's lessons learned and plan going forward) is kept with the incident and read back, its meeting's
    /// time too; a file from before has none and still reads; an answer past its length isn't kept.
    @Test func theReviewIsKept() throws {
        var store = try IncidentStore(root: root)
        let made = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        #expect(made.review == IncidentStore.Review())
        var reviewed = made
        reviewed.review = IncidentStore.Review(kind: "Account takeover", severity: "High", meeting: Self.monday.addingTimeInterval(86_400 * 8),
                                               attendees: "Pat, Sam", cause: "A phishing page took the password.", wentWell: "Locked in an hour.",
                                               improve: "2-Step Verification for everyone.", plan: "Enforce 2SV — Pat — Nov 15\nPhishing training — Sam — Dec 1")
        try store.save(reviewed)
        let file = root.appending(path: made.id).appending(path: IncidentStore.fileName)
        #expect(try IncidentStore(root: root).records.first?.review == reviewed.review)
        #expect(mode(file) == 0o600)

        // No meeting time: kept as none.
        reviewed.review.meeting = nil
        try store.save(reviewed)
        #expect(try IncidentStore(root: root).records.first?.review.meeting == nil)

        // As it was written before 2026-10-27: no "review" at all.
        let old = try #require(JSONValue.parse(try String(contentsOf: file, encoding: .utf8))?.object)
        var stripped = GamOutput.Record()
        for (key, value) in old where key != "review" { stripped[key] = value }
        try Data(JSONValue.dumps(.object(stripped)).utf8).write(to: file)
        let reread = try IncidentStore(root: root)
        #expect(reread.unreadable.isEmpty && reread.records.first?.review == IncidentStore.Review())

        var long = reviewed
        long.review.plan = String(repeating: "x", count: IncidentStore.reviewLength + 1)
        #expect(throws: IncidentStore.Problem.self) { try store.save(long) }
        long.review = IncidentStore.Review(severity: String(repeating: "x", count: IncidentStore.nameLength + 1))
        #expect(throws: IncidentStore.Problem.self) { try store.save(long) }
    }

    /// The email picked as where it started is kept and read back, and cleared; a file from before has none; one that isn't a
    /// Message-ID isn't kept.
    @Test func theEmailThatStartedItIsKept() throws {
        var store = try IncidentStore(root: root)
        var record = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        #expect(record.phish == nil)
        record.phish = "inv-4471@mail.vendor.example"
        try store.save(record)
        #expect(try IncidentStore(root: root).records.first?.phish == "inv-4471@mail.vendor.example")
        record.phish = nil
        try store.save(record)
        let file = root.appending(path: record.id).appending(path: IncidentStore.fileName)
        #expect(try IncidentStore(root: root).records.first?.phish == nil)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"phish\": null"))
        // As it was written before 2026-10-27: no "phish" at all.
        let old = try #require(JSONValue.parse(try String(contentsOf: file, encoding: .utf8))?.object)
        var stripped = GamOutput.Record()
        for (key, value) in old where key != "phish" { stripped[key] = value }
        try Data(JSONValue.dumps(.object(stripped)).utf8).write(to: file)
        let reread = try IncidentStore(root: root)
        #expect(reread.unreadable.isEmpty && reread.records.first?.phish == nil)
        record.phish = "not one"
        #expect(throws: IncidentStore.Problem.self) { try store.save(record) }
    }

    /// The report's export copies every saved read, byte for byte, into a new private folder (`0700`, files `0600`), each
    /// file with its SHA-256; a link in the evidence is never followed, and a folder there already isn't written into.
    @Test func theEvidenceIsCopiedWithItsFingerprints() throws {
        var store = try IncidentStore(root: root)
        let made = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        try store.keep(try IncidentStore.readExport(at: try export()), in: made.id)
        let target = base.appending(path: "report").appending(path: "evidence")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
        let hashes = try store.copyEvidence(of: made.id, to: target)
        // `shasum -a 256` of the two files as written above.
        func sha(_ text: String) throws -> String {
            let pipe = Pipe(), process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            process.arguments = ["-a", "256"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = pipe
            try process.run()
            input.fileHandleForWriting.write(Data(text.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        }
        #expect(hashes.map(\.file) == ["evidence/Incident logs 2026-10-23 0619/about.txt", "evidence/Incident logs 2026-10-23 0619/login-log.csv"])
        #expect(hashes.map(\.sha256) == [try sha(Self.about), try sha(Self.login)])
        let copied = target.appending(path: "Incident logs 2026-10-23 0619")
        #expect(mode(target) == 0o700 && mode(copied) == 0o700 && mode(copied.appending(path: "login-log.csv")) == 0o600)
        #expect(try Data(contentsOf: copied.appending(path: "login-log.csv")) == Data(Self.login.utf8))

        // A link put among the evidence: refused, never read through.
        let kept = try store.evidenceFolder(of: made.id).appending(path: "Incident logs 2026-10-23 0619")
        try FileManager.default.createSymbolicLink(at: kept.appending(path: "zz-link.csv"), withDestinationURL: base.appending(path: "elsewhere"))
        try Data("secret".utf8).write(to: base.appending(path: "elsewhere"))
        let again = base.appending(path: "again")
        #expect(throws: IncidentStore.Problem.self) { try store.copyEvidence(of: made.id, to: again) }
        // A folder by that name already: its read's folder isn't made over what's there.
        #expect(throws: IncidentStore.Problem.self) { try store.copyEvidence(of: made.id, to: target) }
    }

    /// What isn't kept: no title, a title too long, an empty note, a domain that isn't one.
    @Test func whatIsntKept() throws {
        var store = try IncidentStore(root: root)
        #expect(throws: IncidentStore.Problem.self) { try store.create(domain: "example.com", title: " ", opened: Self.monday, openedBy: "", reported: "") }
        #expect(throws: IncidentStore.Problem.self) {
            try store.create(domain: "example.com", title: String(repeating: "x", count: 201), opened: Self.monday, openedBy: "", reported: "")
        }
        #expect(throws: IncidentStore.Problem.self) { try store.create(domain: "", title: "Takeover", opened: Self.monday, openedBy: "", reported: "") }
        let made = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        #expect(throws: IncidentStore.Problem.self) { try store.addNote("  ", at: Self.monday, to: made.id) }
        #expect(store.records.count == 1 && store.records.first?.notes.isEmpty == true)
    }

    /// A file that isn't an incident's is moved aside and named, never read as one or written over.
    @Test func anUnreadableIncidentIsSetAside() throws {
        var store = try IncidentStore(root: root)
        let made = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        let file = root.appending(path: made.id).appending(path: IncidentStore.fileName)
        try Data("{\"version\": 9}".utf8).write(to: file)
        let reopened = try IncidentStore(root: root)
        #expect(reopened.records.isEmpty && reopened.unreadable == [made.id])
        #expect(!FileManager.default.fileExists(atPath: file.path), "moved aside")
    }

    /// An export is read and checked, its other files left out, and kept byte for byte in a new private folder of the
    /// incident's evidence, " (2)" when its name is taken; read back, it's the same.
    @Test func anExportIsKeptAsEvidence() throws {
        var store = try IncidentStore(root: root)
        let made = try store.create(domain: "example.com", title: "Takeover", opened: Self.monday, openedBy: "", reported: "")
        let export = try IncidentStore.readExport(at: try export())
        #expect(export.export.logs.map(\.application) == [.login] && export.export.about == Self.about)
        #expect(export.files.map(\.name) == ["about.txt", "login-log.csv"], "the stray file is left out")
        #expect(try store.keep(export, in: made.id) == "Incident logs 2026-10-23 0619")
        #expect(try store.keep(export, in: made.id) == "Incident logs 2026-10-23 0619 (2)")
        let kept = try store.evidenceFolder(of: made.id).appending(path: "Incident logs 2026-10-23 0619")
        #expect(mode(kept) == 0o700 && mode(kept.appending(path: "login-log.csv")) == 0o600)
        #expect(try Data(contentsOf: kept.appending(path: "login-log.csv")) == Data(Self.login.utf8))
        let read = store.exports(of: made.id)
        #expect(read.unreadable.isEmpty && read.exports.map(\.name) == ["Incident logs 2026-10-23 0619", "Incident logs 2026-10-23 0619 (2)"])
        #expect(read.exports.first?.logs.first?.csv == Self.login)
    }

    /// Not an export: no about.txt, no log, a log that isn't the export's table, or a log that's a link (never followed).
    @Test func notAnExportIsRefused() throws {
        #expect(throws: IncidentStore.Problem.self) { try IncidentStore.readExport(at: try export(named: "a", files: ["login-log.csv": Self.login])) }
        #expect(throws: IncidentStore.Problem.self) { try IncidentStore.readExport(at: try export(named: "b", files: ["about.txt": Self.about])) }
        #expect(throws: IncidentStore.Problem.self) {
            try IncidentStore.readExport(at: try export(named: "c", files: ["about.txt": Self.about, "login-log.csv": "name,actor.email\n"]))
        }
        let linked = try export(named: "d", files: ["about.txt": Self.about])
        let elsewhere = base.appending(path: "elsewhere.csv")
        try Data(Self.login.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "login-log.csv"), withDestinationURL: elsewhere)
        #expect(throws: IncidentStore.Problem.self) { try IncidentStore.readExport(at: linked) }
    }

    /// A pull just saved to an incident reads back last only when its name is after every other saved read's and the
    /// incident is under its count of them: only then is adding it in memory what reading every one back gives.
    @Test func aNewExportReadsBackLastOnlyWhenItWould() {
        let export = ActivityLogs.Export(name: "Incident logs 2026-10-23 0910", about: "Incident logs exported 2026-10-23 0910 UTC.",
                                         logs: [(.login, Self.login)])
        #expect(IncidentStore.readsBackLast(export, after: [], saved: 0))
        #expect(IncidentStore.readsBackLast(export, after: ["Incident logs 2026-10-22 1500", "Incident logs 2026-10-23 0909"], saved: 3))
        #expect(!IncidentStore.readsBackLast(export, after: ["Incident logs 2026-10-23 0911"], saved: 1), "an export added with a later name")
        #expect(!IncidentStore.readsBackLast(export, after: [], saved: IncidentStore.exportsCap), "past the count kept")
    }
}
