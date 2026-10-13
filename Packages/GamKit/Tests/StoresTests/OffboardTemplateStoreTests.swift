@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// The offboarding template store: native (GamGUI has none). Its file is handled as the signature templates'
/// is (`SignatureStore.load`, `writeFile`), so these hold what that sharing must keep, the format, and the rule
/// that only a template the form could run is saved or read.
@Suite("Offboarding template store")
struct OffboardTemplateStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let root: URL
    var file: URL { root.appending(path: OffboardTemplateStore.fileName) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-offboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func bytes(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map(Array.init) }

    func listing(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    static let moment = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                       year: 2026, month: 10, day: 13, hour: 9, minute: 5).date!

    struct Interrupted: Error {}

    static let mine = Offboarding.Template(leftOut: [.calacls, .reminder], subject: "{employee} has left",
                                           message: "Write to {manager}.", days: 14, invitee: "it@example.com")

    @Test func theStartersOnFirstUseAndNothingWritten() throws {
        let store = try OffboardTemplateStore(root: root)
        #expect(store.names == ["All eight steps", "Hand-over", "Lock only"])
        #expect(store.defaultName == "Hand-over")
        #expect(store.template("Hand-over")?.leftOut == [.calacls])
        #expect(store.quarantined == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path), "nothing is written until a save")
    }

    @Test func aSavedTemplateIsReadBackAsSaved() throws {
        var store = try OffboardTemplateStore(root: root)
        try store.save("  Contractor ", Self.mine)
        try store.setDefault("Contractor")
        let reopened = try OffboardTemplateStore(root: root)
        #expect(reopened.names == ["All eight steps", "Contractor", "Hand-over", "Lock only"])
        #expect(reopened.template("Contractor") == Self.mine)
        #expect(reopened.defaultName == "Contractor")
        #expect(reopened.template("contractor") == nil, "names compare by their exact text")
    }

    /// The file's shape, pinned: the steps left out and added, each in run order, every field, the default.
    @Test func theFileIsThisFormat() throws {
        var store = try OffboardTemplateStore(root: root)
        for name in store.names { try store.delete(name) }
        var mine = Self.mine
        mine.added = [.hideFromDirectory, .clearRecovery]
        try store.save("Contractor", mine)
        let text = String(decoding: try #require(bytes(file)), as: UTF8.self)
        let parsed = try #require(JSONValue.parse(text))
        #expect(parsed["version"]?.int == 2)
        #expect(parsed["default"] == .null, "deleting the default left none")
        let saved = try #require(parsed["templates"]?["Contractor"]?.object)
        #expect(saved.keys.sorted() == ["add", "days", "invitee", "leave_out", "message", "subject"])
        #expect(saved["leave_out"] == .array([.string("calacls"), .string("reminder")]))
        #expect(saved["add"] == .array([.string("clear_recovery"), .string("hide_from_directory")]))
        #expect(try OffboardTemplateStore(root: root).template("Contractor") == mine)
        #expect(saved["days"]?.int == 14 && saved["invitee"]?.string == "it@example.com")
        #expect(saved["subject"]?.string == "{employee} has left" && saved["message"]?.string == "Write to {manager}.")
    }

    @Test func replacingIsAskedAndATemplateThatCouldntRunIsRefused() throws {
        var store = try OffboardTemplateStore(root: root)
        #expect(throws: OffboardTemplateStore.Problem.exists("Hand-over")) { try store.save("Hand-over", Self.mine) }
        #expect(store.template("Hand-over")?.leftOut == [.calacls])
        try store.save("Hand-over", Self.mine, replacing: true)
        #expect(store.template("Hand-over") == Self.mine)

        let unlocked = Offboarding.Template(leftOut: [.forward])
        #expect(throws: OffboardTemplateStore.Problem.invalid(unlocked.problem!)) { try store.save("Open", unlocked) }
        #expect(throws: OffboardTemplateStore.Problem.invalid(Offboarding.Template(days: 0).problem!)) {
            try store.save("Never", Offboarding.Template(days: 0))
        }
        #expect(throws: OffboardTemplateStore.Problem.nameRequired) { try store.save(" \n", Self.mine) }
        #expect(throws: OffboardTemplateStore.Problem.nameTooLong) {
            try store.save(String(repeating: "x", count: SignatureStore.maxNameLength + 1), Self.mine)
        }
        #expect(store.names == ["All eight steps", "Hand-over", "Lock only"])
        #expect(OffboardTemplateStore.Problem.nameRequired.message == SignatureStore.Problem.nameRequired.message)
    }

    @Test func deletingTheDefaultLeavesNoneAndADefaultMustExist() throws {
        var store = try OffboardTemplateStore(root: root)
        try store.delete("Lock only")
        #expect(store.defaultName == "Hand-over")
        try store.delete("Hand-over")
        #expect(store.defaultName == nil)
        #expect(throws: OffboardTemplateStore.Problem.notFound("Hand-over")) { try store.setDefault("Hand-over") }
        try store.setDefault("All eight steps")
        try store.delete("Nobody")
        #expect(try OffboardTemplateStore(root: root).defaultName == "All eight steps")
        try store.setDefault(nil)
        #expect(try OffboardTemplateStore(root: root).defaultName == nil)
    }

    /// The signature store's writer, shared: private from creation, and a failed write leaves the old file.
    @Test func writesArePrivateAndAtomic() throws {
        var store = try OffboardTemplateStore(root: root)
        try store.save("Contractor", Self.mine)
        #expect(mode(root) == 0o700 && mode(file) == 0o600)
        let before = try #require(bytes(file))
        store.interrupt = { _ in throw Interrupted() }
        #expect(throws: OffboardTemplateStore.Problem.self) { try store.delete("Contractor") }
        #expect(throws: OffboardTemplateStore.Problem.self) { try store.setDefault("Contractor") }
        #expect(store.names.contains("Contractor") && store.defaultName == "Hand-over", "unchanged by a failed write")
        #expect(bytes(file) == before)
        #expect(listing(root) == [OffboardTemplateStore.fileName], "no partial file behind")
    }

    /// A version 1 file, written before templates could add steps, reads as adding none and is never moved aside;
    /// the next save writes version 2 with the same templates.
    @Test func aVersionOneFileReadsAsAddingNothing() throws {
        #expect(mkdir(root.path, 0o700) == 0)
        let v1 = #"{"version": 1, "default": "A", "templates": {"A": {"leave_out": ["calacls"], "subject": "s", "message": "m", "days": 30, "invitee": ""}}}"#
        try Data(v1.utf8).write(to: file)
        var store = try OffboardTemplateStore(root: root, now: Self.moment)
        let a = Offboarding.Template(leftOut: [.calacls], subject: "s", message: "m")
        #expect(store.quarantined == nil && store.names == ["A"] && store.template("A") == a && store.defaultName == "A")
        try store.save("B", Self.mine)
        let written = try #require(bytes(file))
        let parsed = try #require(JSONValue.parse(String(decoding: written, as: UTF8.self)))
        #expect(parsed["version"]?.int == 2 && parsed["templates"]?["A"]?["add"] == .array([]))
        #expect(try OffboardTemplateStore(root: root).template("A") == a)
    }

    /// A file this format can't read is moved aside whole and the starters shown, never saved over: whatever it
    /// held stays for the operator. A template that couldn't run is such a file: nothing half-read is offered.
    @Test func aFileItCantReadIsMovedAsideNeverOverwritten() throws {
        let template = #"{"leave_out": ["calacls"], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#
        func file(_ templates: String, default name: String = "null", version: Int = 2) -> [UInt8] {
            Array(#"{"version": \#(version), "default": \#(name), "templates": {\#(templates)}}"#.utf8)
        }
        let bad: [(String, [UInt8])] = [
            ("not JSON", Array("{not json".utf8)),
            ("a later version", Array(#"{"version": 3, "default": null, "templates": {}}"#.utf8)),
            ("version 1 with an add list", file(#""A": {"leave_out": [], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#,
                                                    version: 1)),
            ("version 2 without add", file(#""A": {"leave_out": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("a GamGUI step added", file(#""A": {"leave_out": [], "add": ["calacls"], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("an added step left out", file(#""A": {"leave_out": ["clear_recovery"], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("an added step twice", file(#""A": {"leave_out": [], "add": ["clear_recovery", "clear_recovery"], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("an unknown step added", file(#""A": {"leave_out": [], "add": ["suspend"], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("the lock left out", file(#""A": {"leave_out": ["password"], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("a step GAM's routine doesn't have", file(#""A": {"leave_out": ["suspend"], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("a step twice", file(#""A": {"leave_out": ["calacls", "calacls"], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": ""}"#)),
            ("no reminder day", file(#""A": {"leave_out": [], "add": [], "subject": "s", "message": "m", "days": 0, "invitee": ""}"#)),
            ("days as text", file(#""A": {"leave_out": [], "add": [], "subject": "s", "message": "m", "days": "30", "invitee": ""}"#)),
            ("an invitee that isn't one address", file(#""A": {"leave_out": [], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": "a, b"}"#)),
            ("a field missing", file(#""A": {"leave_out": [], "add": [], "subject": "s", "message": "m", "days": 30}"#)),
            ("a field more", file(#""A": {"leave_out": [], "add": [], "subject": "s", "message": "m", "days": 30, "invitee": "", "x": 1}"#)),
            ("a padded name", file(#"" A": \#(template)"#)),
            ("a default that names none", file(#""A": \#(template)"#, default: #""B""#)),
            ("a default that isn't text", file(#""A": \#(template)"#, default: "1")),
        ]
        #expect(mkdir(root.path, 0o700) == 0)
        let aside = root.appending(path: "offboarding-templates.json.unreadable-2026-10-13T090500Z")
        for (label, content) in bad {
            try Data(content).write(to: self.file)
            var store = try OffboardTemplateStore(root: root, now: Self.moment)
            #expect(store.quarantined == aside, "\(label)")
            #expect(bytes(aside) == content, "\(label): moved aside whole")
            #expect(store.names == ["All eight steps", "Hand-over", "Lock only"], "\(label): the starters")
            try store.save("Mine", Self.mine)
            #expect(bytes(aside) == content, "\(label): the next save doesn't touch it")
            try FileManager.default.removeItem(at: aside)
        }
        // And a good one with a default reads as written.
        try Data(file(#""A": \#(template)"#, default: #""A""#)).write(to: self.file)
        let good = try OffboardTemplateStore(root: root, now: Self.moment)
        #expect(good.quarantined == nil && good.names == ["A"] && good.defaultName == "A")
    }

    @Test func aFileItCantOpenIsNeverReplaced() throws {
        #expect(mkdir(root.path, 0o700) == 0)
        try Data(#"{"version": 1, "default": null, "templates": {}}"#.utf8).write(to: file)
        #expect(chmod(file.path, 0o000) == 0)
        defer { chmod(file.path, 0o600) }
        #expect(throws: OffboardTemplateStore.Problem.file(.unreadable(EACCES))) { try OffboardTemplateStore(root: root) }
        #expect(listing(root) == [OffboardTemplateStore.fileName])
    }
}
