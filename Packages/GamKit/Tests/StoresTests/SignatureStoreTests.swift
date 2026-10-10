@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// The signature template store (design doc D2). GamGUI's half (seeds, name rules, `names()` order and
/// messages) is held to GamGUI's source, quoted here, and to what its store did when pointed at a
/// temporary path. The native half: a format number, atomic `0600` writes in a `0700` folder, an
/// unreadable file moved aside rather than replaced, replacing asked first, and the one-time copy of
/// GamGUI's templates read by descriptor.
///
/// TODO(S1a): `Tests/Fixtures/signatures.json` (seeds, `store_errors` and the `names()` order, generated
/// from frozen GamGUI by `scripts/gen_fixtures.py`) takes over from the quotes and the order below.
@Suite("Signature store")
struct SignatureStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-signatures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui")
    }

    // MARK: GamGUI's, quoted

    /// `gamgui/core/signatures.py:163-188` at GamGUI 834493c, byte for byte.
    static let seedSource = #"""
        "Classic": (
            '<div style="font-family:-apple-system,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;'
            'font-size:13px;line-height:1.5;color:#3f4a5a;">\n'
            '  <div style="font-weight:600;color:#1f2733;">{name}</div>\n'
            '  <div>[[{title} · ]]Your Company</div>\n'
            '  <div style="color:#6b7280;">{email}[[ · {phone}]]</div>\n'
            '</div>'
        ),
        "Modern accent": (
            '<table cellpadding="0" cellspacing="0" role="presentation" '
            'style="font-family:-apple-system,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;'
            'font-size:13px;color:#3f4a5a;">\n'
            '  <tr>\n'
            '    <td style="border-left:3px solid #52647B;padding:1px 0 1px 12px;line-height:1.5;">\n'
            '      <div style="font-weight:600;font-size:14px;color:#1f2733;">{name}</div>\n'
            '      <div style="color:#52647B;">[[{title} · ]]Your Company</div>\n'
            '      <div style="color:#6b7280;">{email}[[ · {phone}]]</div>\n'
            '      [[<div style="color:#6b7280;">{department}</div>]]\n'
            '    </td>\n'
            '  </tr>\n'
            '</table>'
        ),
        "Minimal": (
            '<div style="font-family:-apple-system,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;'
            'font-size:13px;color:#3f4a5a;">{name}[[ · {title}]] · Your Company · {email}</div>'
        ),
    """#

    /// `signatures.py:236-240`, with `_MAX_NAME_LEN` (191) formatted in.
    static let nameRequired = "Template name is required."
    static let nameTooLong = "Template name must be {} characters or fewer.".replacingOccurrences(of: "{}", with: "60")
    static let bodyEmpty = "Template body is empty — put some HTML in the editor before saving."

    /// The seeds as Python reads the quoted source: each key's adjacent `'…'` literals joined, with the
    /// two escapes they use (`\'` and `\n`) decoded.
    static var quotedSeeds: [(name: String, body: String)] {
        var seeds: [(name: String, body: String)] = []
        for line in seedSource.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\""), text.hasSuffix("\": (") {
                seeds.append((String(text.dropFirst().dropLast(4)), ""))
            } else if text.hasPrefix("'"), text.hasSuffix("'") {
                var decoded = "", escaped = false
                for scalar in text.dropFirst().dropLast().unicodeScalars {
                    if escaped {
                        decoded.unicodeScalars.append(scalar == "n" ? "\n" : scalar)
                        escaped = false
                    } else if scalar == "\\" {
                        escaped = true
                    } else {
                        decoded.unicodeScalars.append(scalar)
                    }
                }
                seeds[seeds.count - 1].body += decoded
            }
        }
        return seeds
    }

    static let seedNames = ["Classic", "Minimal", "Modern accent"]

    // MARK: helpers

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func bytes(_ url: URL) -> [UInt8]? {
        (try? Data(contentsOf: url)).map(Array.init)
    }

    func listing(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func makeRoot() throws {
        #expect(mkdir(root.path, 0o700) == 0)
    }

    func put(_ content: [UInt8], at url: URL) throws {
        try Data(content).write(to: url)
    }

    static func utf8(_ names: [String]) -> [[UInt8]] { names.map { Array($0.utf8) } }

    /// 2026-10-10 14:30:00 UTC, the moment the corrupt-file tests open the store.
    static let moment = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                       year: 2026, month: 10, day: 10, hour: 14, minute: 30).date!

    struct Interrupted: Error {}

    /// What the `interrupt` hook saw mid-save. Only touched synchronously, inside the save.
    final class Seen: @unchecked Sendable {
        var temporaryModes: [mode_t] = []
        var folderModes: [mode_t] = []
        var fileBytes: [[UInt8]?] = []
    }

    // MARK: seeds and names

    @Test func seedsOnFirstUse() throws {
        let quoted = Self.quotedSeeds
        #expect(quoted.map(\.name) == ["Classic", "Modern accent", "Minimal"], "the quote parsed")
        #expect(SignatureStore.seeds.map(\.name) == quoted.map(\.name))
        for (seed, expected) in zip(SignatureStore.seeds, quoted) {
            #expect(Array(seed.body.utf8) == Array(expected.body.utf8), "\(expected.name)")
        }
        let store = try SignatureStore(root: root)
        #expect(store.names == Self.seedNames)
        for (name, body) in quoted { #expect(store.body(name).map { Array($0.utf8) } == Array(body.utf8)) }
        #expect(store.quarantined == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path), "loading writes nothing, as GamGUI's doesn't")
    }

    @Test func nameIsTrimmedRequiredAndAtMost60CodePoints() throws {
        var store = try SignatureStore(root: root)
        func refusal(_ name: String, _ body: String = "x") -> String? {
            do {
                try store.save(name, body: body)
                return nil
            } catch let problem as SignatureStore.Problem {
                return problem.message
            } catch {
                return "\(error)"
            }
        }
        // What GamGUI's store said for each (its probe at 834493c).
        #expect(refusal("") == Self.nameRequired)
        #expect(refusal("  \u{3000}") == Self.nameRequired)
        #expect(refusal(String(repeating: "x", count: 61)) == Self.nameTooLong)
        #expect(refusal(String(repeating: "y", count: 61), "  ") == Self.nameTooLong, "the name is checked first")
        #expect(refusal(String(repeating: "e\u{301}", count: 31)) == Self.nameTooLong, "62 code points, 31 characters")
        #expect(refusal(String(repeating: "\u{1D400}", count: 61)) == Self.nameTooLong)
        #expect(refusal(String(repeating: "e", count: 60)) == nil)
        #expect(refusal(String(repeating: "e\u{301}", count: 30)) == nil, "60 code points")
        #expect(refusal(String(repeating: "\u{1D400}", count: 60)) == nil, "60 code points, 120 UTF-16 units")
        #expect(refusal("  \u{A0}Spaced\u{3000}\u{1F} ") == nil)
        #expect(refusal("\u{200B}") == nil, "a zero-width space isn't Python whitespace")
        #expect(store.names.contains("Spaced"), "saved under the stripped name")
        #expect(!store.names.contains { $0.unicodeScalars.count > 60 })
    }

    @Test func blankBodyRefused() throws {
        var store = try SignatureStore(root: root)
        for body in ["", "  ", "\u{A0}\n", "\u{3000}\u{1C}"] {
            #expect(throws: SignatureStore.Problem.bodyEmpty) { try store.save("Blank", body: body) }
        }
        #expect(SignatureStore.Problem.bodyEmpty.message == Self.bodyEmpty)
        #expect(SignatureStore.Problem.nameRequired.message == Self.nameRequired)
        #expect(SignatureStore.Problem.nameTooLong.message == Self.nameTooLong)
        #expect(!store.names.contains("Blank"))
        try store.save("Padded", body: "  <b>x</b>\n")
        #expect(store.body("Padded") == "  <b>x</b>\n", "the body is kept as typed")
    }

    @Test func namesAreInGamGUIsOrder() throws {
        var store = try SignatureStore(root: root)
        for name in ["b", "B", "\u{E9}", "e\u{301}", "Z", "a", "\u{FF5E}", "\u{1F600}", "classic",
                     "  \u{A0}Spaced\u{3000}\u{1F} ", "\u{200B}", String(repeating: "e", count: 60),
                     String(repeating: "\u{1D400}", count: 60), String(repeating: "e\u{301}", count: 30)] {
            try store.save(name, body: "<b>x</b>")
        }
        // GamGUI's `names()` for the same saves: Python's `sorted`, code point by code point.
        let gamGUIs = ["B", "Classic", "Minimal", "Modern accent", "Spaced", "Z", "a", "b", "classic",
                       String(repeating: "e", count: 60), "e\u{301}", String(repeating: "e\u{301}", count: 30), "\u{E9}",
                       "\u{200B}", "\u{FF5E}", String(repeating: "\u{1D400}", count: 60), "\u{1F600}"]
        #expect(Self.utf8(store.names) == Self.utf8(gamGUIs))
        #expect(Self.utf8(try SignatureStore(root: root).names) == Self.utf8(gamGUIs))
    }

    // MARK: the file

    @Test func roundTrip() throws {
        var store = try SignatureStore(root: root)
        let saved: [(String, String)] = [
            ("Caf\u{E9}", "<p class=\"a\">composed</p>"),
            ("Cafe\u{301}", "<p>decomposed: a second template, as in Python</p>"),
            ("Quotes", "<a href='x'>“curly” \\n literal, \\\\ two</a>\r\n\u{2028}\t\u{0}\u{1F}\u{7F}"),
            ("👍🏽 Thumbs", "<span>{name} 👍🏽 é 𝐀</span>"),
        ]
        for (name, body) in saved { try store.save(name, body: body) }
        let reopened = try SignatureStore(root: root)
        #expect(reopened.quarantined == nil)
        #expect(Self.utf8(reopened.names) == Self.utf8(store.names))
        #expect(reopened.names.count == 3 + saved.count)
        for (name, body) in saved {
            #expect(reopened.body(name).map { Array($0.utf8) } == Array(body.utf8), "\(name)")
        }
        #expect(reopened.body("Cafe\u{301}") != reopened.body("Caf\u{E9}"))
        // The format: a version number, then the templates, readable by Python's json.loads.
        let text = try String(contentsOf: store.url, encoding: .utf8)
        let file = try #require(JSONValue.parse(text))
        #expect(file["version"] == .number("1"))
        #expect(file["templates"]?.object?.count == 3 + saved.count)
        #expect(text.hasPrefix("{\"version\": 1, \"templates\": {"))
    }

    @Test func fileIs0600InA0700FolderFromCreation() throws {
        var store = try SignatureStore(root: root)
        let seen = Seen()
        store.interrupt = { temporary in
            seen.temporaryModes.append(mode(temporary))
            seen.folderModes.append(mode(root))
        }
        try store.save("First", body: "<b>1</b>")
        #expect(seen.temporaryModes == [0o600], "the file is 0600 from the moment it's made")
        #expect(seen.folderModes == [0o700], "inside a folder already 0700")
        #expect(mode(root) == 0o700)
        #expect(mode(store.url) == 0o600)

        // A folder and file loosened since (by hand, a restore) are private again after the next save.
        #expect(chmod(root.path, 0o755) == 0 && chmod(store.url.path, 0o644) == 0)
        try store.save("Second", body: "<b>2</b>")
        #expect(seen.folderModes == [0o700, 0o700])
        #expect(seen.temporaryModes == [0o600, 0o600])
        #expect(mode(root) == 0o700)
        #expect(mode(store.url) == 0o600)
    }

    @Test func writesAreAtomic() throws {
        var store = try SignatureStore(root: root)
        try store.save("Old", body: "<b>old</b>")
        let before = try #require(bytes(store.url))
        let seen = Seen()
        let url = store.url
        store.interrupt = { _ in
            seen.fileBytes.append((try? Data(contentsOf: url)).map(Array.init))
            throw Interrupted()
        }
        #expect(throws: Interrupted.self) { try store.save("New", body: String(repeating: "<b>new</b>", count: 5000)) }
        #expect(seen.fileBytes == [before], "mid-write, the file is still the old one")
        #expect(bytes(store.url) == before, "a failed write leaves the old file whole")
        #expect(listing(root) == [SignatureStore.fileName], "and no partial file behind")
        #expect(!store.names.contains("New"), "nor a template the file doesn't hold")

        #expect(throws: Interrupted.self) { try store.delete("Old") }
        #expect(store.names.contains("Old"))
        #expect(bytes(store.url) == before)
        #expect(listing(root) == [SignatureStore.fileName])

        store.interrupt = nil
        try store.save("New", body: "<b>new</b>")
        #expect(try SignatureStore(root: root).names.contains("New"))
    }

    @Test func aSaveLargerThanTheCapIsRefused() throws {
        var store = try SignatureStore(root: root)
        let huge = String(repeating: "x", count: SignatureStore.sizeCap)
        #expect(throws: SignatureStore.Problem.tooLarge) { try store.save("Huge", body: huge) }
        #expect(!store.names.contains("Huge"))
        #expect(!FileManager.default.fileExists(atPath: store.url.path), "nothing the next load would refuse")
    }

    // MARK: replacing and deleting

    @Test func replacingAnExistingNameMustBeAsked() throws {
        var store = try SignatureStore(root: root)
        let classic = try #require(store.body("Classic"))
        #expect(throws: SignatureStore.Problem.exists("Classic")) { try store.save("Classic", body: "<b>mine</b>") }
        #expect(throws: SignatureStore.Problem.exists("Classic")) { try store.save("  Classic\n", body: "<b>mine</b>") }
        #expect(store.body("Classic") == classic)
        #expect(!FileManager.default.fileExists(atPath: store.url.path), "a refused save writes nothing")
        #expect(SignatureStore.Problem.exists("Classic").message.contains("“Classic”"))

        // Other names, to Python: another case, another normalization.
        try store.save("classic", body: "<b>lower</b>")
        try store.save("Caf\u{E9}", body: "<b>composed</b>")
        try store.save("Cafe\u{301}", body: "<b>decomposed</b>")

        try store.save("Classic", body: "<b>mine</b>", replacing: true)
        #expect(store.body("Classic") == "<b>mine</b>")
        #expect(try SignatureStore(root: root).body("Classic") == "<b>mine</b>")
    }

    @Test func deleteRemoves() throws {
        var store = try SignatureStore(root: root)
        try store.delete("Classic")
        #expect(store.names == ["Minimal", "Modern accent"])
        #expect(try SignatureStore(root: root).names == ["Minimal", "Modern accent"])
        let written = bytes(store.url)
        try store.delete("Not there")
        #expect(bytes(store.url) == written, "deleting a name that isn't there writes nothing")

        // An emptied store stays empty, as GamGUI's does: the seeds come only with no file at all.
        try store.delete("Minimal")
        try store.delete("Modern accent")
        #expect(store.names.isEmpty)
        let reopened = try SignatureStore(root: root)
        #expect(reopened.names.isEmpty)
        #expect(reopened.quarantined == nil)
    }

    // MARK: an unreadable file

    @Test func anUnreadableFileIsQuarantinedNeverOverwritten() throws {
        let bad: [(String, [UInt8])] = [
            ("not JSON", Array("{not json".utf8)),
            ("empty", []),
            ("GamGUI's own shape, no version", Array(#"{"templates": {"A": "<b>a</b>"}}"#.utf8)),
            ("a later version", Array(#"{"version": 2, "templates": {}}"#.utf8)),
            ("a version as text", Array(#"{"version": "1", "templates": {}}"#.utf8)),
            ("a body that isn't text", Array(#"{"version": 1, "templates": {"A": 1}}"#.utf8)),
            ("templates as a list", Array(#"{"version": 1, "templates": []}"#.utf8)),
            ("a list", Array("[]".utf8)),
            ("not UTF-8", [0x7B, 0xFF, 0xFE, 0x7D]),
            ("larger than the cap", Array(#"{"version": 1, "templates": {"A": ""#.utf8)
                + Array(repeating: UInt8(ascii: "x"), count: SignatureStore.sizeCap) + Array(#""}}"#.utf8)),
        ]
        try makeRoot()
        let file = root.appending(path: SignatureStore.fileName)
        let aside = root.appending(path: "signatures.json.unreadable-2026-10-10T143000Z")
        for (label, content) in bad {
            try put(content, at: file)
            var store = try SignatureStore(root: root, now: Self.moment)
            #expect(store.quarantined == aside, "\(label)")
            #expect(bytes(aside) == content, "\(label): moved aside whole")
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(label)")
            #expect(store.names == Self.seedNames, "\(label): the starters, as GamGUI shows")

            try store.save("Mine", body: "<b>mine</b>")
            #expect(bytes(aside) == content, "\(label): the next save doesn't touch it")
            let reopened = try SignatureStore(root: root, now: Self.moment)
            #expect(reopened.quarantined == nil, "\(label)")
            #expect(reopened.names == ["Classic", "Mine", "Minimal", "Modern accent"], "\(label)")
            try FileManager.default.removeItem(at: aside)
        }

        // Moved aside twice in the same second: the first is kept, the second gets its own name.
        try put(Array("first".utf8), at: file)
        _ = try SignatureStore(root: root, now: Self.moment)
        try put(Array("second".utf8), at: file)
        let second = try SignatureStore(root: root, now: Self.moment)
        #expect(second.quarantined == root.appending(path: "signatures.json.unreadable-2026-10-10T143000Z-2"))
        #expect(bytes(aside) == Array("first".utf8))
        #expect(second.quarantined.flatMap(bytes) == Array("second".utf8))
    }

    @Test func aLinkOrOddFileInItsPlaceIsMovedAsideNotFollowed() throws {
        try makeRoot()
        let file = root.appending(path: SignatureStore.fileName)
        let elsewhere = base.appending(path: "elsewhere.json")
        let theirs = Array(#"{"version": 1, "templates": {"Theirs": "<b>t</b>"}}"#.utf8)
        try put(theirs, at: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        var store = try SignatureStore(root: root, now: Self.moment)
        let aside = try #require(store.quarantined)
        #expect(!store.names.contains("Theirs"), "never read through a link")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: aside.path)) == elsewhere.path)
        try store.save("Mine", body: "<b>mine</b>")
        #expect(bytes(elsewhere) == theirs, "never written through a link")
        #expect(mode(file) == 0o600)

        // A FIFO can't hang the load; a folder isn't a file.
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        let fifo = try SignatureStore(root: root, now: Self.moment.addingTimeInterval(1))
        #expect(fifo.quarantined != nil)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let folder = try SignatureStore(root: root, now: Self.moment.addingTimeInterval(2))
        #expect(folder.quarantined != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileItCantOpenIsNeverReplaced() throws {
        try makeRoot()
        let file = root.appending(path: SignatureStore.fileName)
        try put(Array("{\"version\": 1, \"templates\": {}}".utf8), at: file)
        #expect(chmod(file.path, 0o000) == 0)
        defer { chmod(file.path, 0o600) }
        #expect(throws: SignatureStore.Problem.unreadable(EACCES)) { try SignatureStore(root: root) }
        #expect(listing(root) == [SignatureStore.fileName], "not moved: it may be fine, only unreadable now")
        // A file where the folder should be.
        let notAFolder = base.appending(path: "plain")
        try put([], at: notAFolder)
        #expect(throws: SignatureStore.Problem.unreadable(ENOTDIR)) { try SignatureStore(root: notAFolder) }
    }

    // MARK: copying GamGUI's templates

    /// GamGUI's file as it writes one (`json.dumps(indent=2)`), with what a hand edit can leave in it.
    func gamGUIFile(_ templates: String) throws -> URL {
        let folder = base.appending(path: "GamGUI")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "signatures.json")
        try put(Array("{\n  \"templates\": {\n\(templates)\n  },\n  \"other\": 1\n}".utf8), at: url)
        return url
    }

    @Test func importCopiesNewNamesAndReportsKeptOnes() throws {
        var store = try SignatureStore(root: root)
        let classic = try #require(store.body("Classic"))
        let long = String(repeating: "L", count: 61)
        let source = try gamGUIFile("""
            "Classic": \(JSONValue.dumps(.string(classic))),
            "Minimal": "<p>GamGUI's own</p>",
            "Mine": "<b>mine</b>",
            "Cafe\\u0301": "<i>decomposed</i>",
            " padded ": "<b>x</b>",
            "": "<b>x</b>",
            "Blank": " \\n ",
            "Number": 5,
            "\(long)": "<b>x</b>"
        """)
        let original = bytes(source)
        let report = try store.copy(fromGamGUI: source)
        #expect(Self.utf8(report.copied) == Self.utf8(["Cafe\u{301}", "Mine"]))
        #expect(report.kept == ["Minimal"], "a different body keeps this app's version")
        #expect(Self.utf8(report.refused) == Self.utf8(["", " padded ", "Blank", long, "Number"]))
        #expect(store.body("Mine") == "<b>mine</b>")
        #expect(store.body("Minimal") == SignatureStore.seeds[2].body)
        #expect(store.body("Classic") == classic)
        #expect(bytes(source) == original, "GamGUI's file is only read")

        let reopened = try SignatureStore(root: root)
        #expect(Self.utf8(reopened.names) == Self.utf8(["Cafe\u{301}", "Classic", "Mine", "Minimal", "Modern accent"]))

        // A second copy finds nothing new and writes nothing.
        let written = bytes(store.url)
        let again = try store.copy(fromGamGUI: source)
        #expect(again.copied.isEmpty && again.kept == ["Minimal"])
        #expect(bytes(store.url) == written)
    }

    @Test func importRefusesASymlinkOrAnOversizeFile() throws {
        var store = try SignatureStore(root: root)
        let real = try gamGUIFile(#"    "Mine": "<b>mine</b>""#)
        let folder = real.deletingLastPathComponent()

        let link = folder.appending(path: "linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: SignatureStore.Problem.gamGUIUnreadable(.link)) { try store.copy(fromGamGUI: link) }

        let large = folder.appending(path: "large.json")
        try put(Array(#"{"templates": {"A": ""#.utf8) + Array(repeating: UInt8(ascii: "x"), count: SignatureStore.sizeCap)
                + Array(#""}}"#.utf8), at: large)
        #expect(throws: SignatureStore.Problem.gamGUIUnreadable(.tooLarge)) { try store.copy(fromGamGUI: large) }

        let fifo = folder.appending(path: "fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: SignatureStore.Problem.gamGUIUnreadable(.notAFile)) { try store.copy(fromGamGUI: fifo) }
        #expect(throws: SignatureStore.Problem.gamGUIUnreadable(.notAFile)) { try store.copy(fromGamGUI: folder) }

        let other = folder.appending(path: "other.json")
        for content in ["{not json", #"{"templates": []}"#, "[]", #"{"version": 1}"#] {
            try put(Array(content.utf8), at: other)
            #expect(throws: SignatureStore.Problem.gamGUIUnreadable(.notTemplates)) { try store.copy(fromGamGUI: other) }
        }
        #expect(throws: SignatureStore.Problem.noGamGUITemplates) {
            try store.copy(fromGamGUI: folder.appending(path: "missing.json"))
        }
        #expect(store.names == Self.seedNames)
        #expect(!FileManager.default.fileExists(atPath: root.path), "a refused copy writes nothing")
    }

    // MARK: where it lives

    @Test func neverTouchesRealAppData() throws {
        // The store has no default place: every caller names its folder, so a test or a fixture
        // generator can't reach the operator's templates by leaving it out (GamGUI failure-log
        // 2026-09-25: the fixture generator built a store on the real app data).
        let sources = Self.storesSources()
        #expect(!sources.isEmpty)
        for (name, text) in sources {
            #expect(text.firstRange(of: /=\s*(Self\.|SignatureStore\.)?(defaultRoot|gamGUIFile)\b/) == nil,
                    "\(name): a default argument would reach the real folder")
            let uses = text.matches(of: /applicationSupportDirectory/).count
            #expect(uses == (name == "SignatureStore.swift" ? 2 : 0), "\(name): only the two named locations")
        }
        #expect(SignatureStore.defaultRoot.path.hasSuffix("/Library/Application Support/SwiftGamGui"))
        #expect(SignatureStore.gamGUIFile.path.hasSuffix("/Library/Application Support/GamGUI/signatures.json"))

        // Everything a store does lands inside the folder it was given.
        var store = try SignatureStore(root: root)
        try store.save("Mine", body: "<b>mine</b>")
        try store.delete("Mine")
        _ = try store.copy(fromGamGUI: try gamGUIFile(#"    "Theirs": "<b>t</b>""#))
        try put(Array("corrupt".utf8), at: store.url)
        let quarantined = try SignatureStore(root: root, now: Self.moment)
        #expect(store.url == root.appending(path: "signatures.json"))
        #expect(quarantined.quarantined?.path.hasPrefix(root.path + "/") == true)
        #expect(listing(base) == ["GamGUI", "SwiftGamGui"])
    }

    static func storesSources() -> [(String, String)] {
        var folder = URL(filePath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() }
        folder.append(path: "Sources/Stores")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".swift") }
        return names.sorted().compactMap { name in
            (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)).map { (name, $0) }
        }
    }
}
