import Foundation
import GamEngine
@testable import Stores
import Testing
import TestSupport

/// The hand-over (plan 2026-11-11 C4; GamGUI's `tests/test_roster_handover.py` at 07c505d): its files equal GamGUI's own
/// `tests/fixtures/handover/` byte for byte (copied to `Tests/Fixtures/handover/` by `scripts/gen_fixtures.py`, which
/// refuses to write them unless GamGUI still writes the same), its `gam csv` lines are GamGUI's and the grammar's, and the
/// ZIP it saves reads back whole. Nothing here runs GAM.
@Suite("Roster hand-over")
struct RosterHandoverTests {
    typealias Change = RosterPlan.Change

    /// GamGUI's `_plan`: one of every kind, with the awkward values a district has (a quote, a comma, a formula lead, no
    /// section).
    static func plan(flags: [RosterPlan.Flag] = [], incomplete: Bool = false) -> RosterPlan.ChangeList {
        var out = RosterPlan.ChangeList(changes: [
            Change(.removeTeacher, "d:gg-C2", "Chemistry", person: "cy@x.com", swap: true),
            Change(.removeStudent, "d:gg-C2", "Chemistry", person: "di@x.com", swap: true),
            Change(.create, "d:gg-C3", #"Physics, "Lab""#, person: "ann@x.com", after: #"Physics, "Lab" · Fall 2026"#,
                   name: #"Physics, "Lab""#, section: "Fall 2026"),
            Change(.create, "d:gg-C4", "=Study hall", person: "ann@x.com", after: "=Study hall", name: "=Study hall"),
            Change(.rename, "d:gg-C1", "Biology", before: "Bio · Fall", after: "Biology · Fall 2026", courseID: "500",
                   name: "Biology", section: "Fall 2026"),
            Change(.addTeacher, "d:gg-C3", #"Physics, "Lab""#, person: "ben@x.com"),
            Change(.addStudent, "d:gg-C3", #"Physics, "Lab""#, person: "cy@x.com"),
            Change(.owner, "d:gg-C1", "Biology", person: "ben@x.com", before: "ann@x.com", after: "ben@x.com", courseID: "500"),
            Change(.removeTeacher, "d:gg-C1", "Biology", person: "ann@x.com", courseID: "500"),
            Change(.addStudent, "d:gg-C1", "Biology", person: "ann@x.com", courseID: "500", late: true),
            Change(.rename, "d:gg-C5", "Art", before: "Art · Spring", after: "Art", courseID: "501", name: "Art"),
            Change(.removeStudent, "d:gg-C1", "Biology", person: "ed@x.com", courseID: "500"),
            Change(.archive, "d:gg-OLD", "Old class", before: "Active", courseID: "700"),
        ])
        out.flags = flags
        out.incomplete = incomplete
        return out
    }

    static let held = [RosterPlan.Flag(kind: .removeStudent, why: "Would remove a lot.")]

    static func text(_ files: [String: [UInt8]], _ name: String) -> String { String(decoding: files[name] ?? [], as: UTF8.self) }

    /// Python's `csv.reader` for these files: quotes doubled, CRLF.
    static func rows(_ files: [String: [UInt8]], _ name: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var scalars = Array(text(files, name).unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if quoted {
                if scalar == "\"" {
                    if scalars.first == "\"" { field.unicodeScalars.append("\""); scalars.removeFirst() } else { quoted = false }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == "\"" {
                quoted = true
            } else if scalar == "," {
                row.append(field); field = ""
            } else if scalar == "\r" {
                continue
            } else if scalar == "\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.unicodeScalars.append(scalar)
            }
        }
        return rows
    }

    nonisolated(unsafe) static let fixture: JSONValue? = {
        guard let data = try? Data(contentsOf: Fixtures.directory.appending(path: "roster_handover.json")) else { return nil }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))
    }()

    @Test func theFilesMatchTheFixtureByteForByte() throws {
        let files = try RosterHandover.build(Self.plan(), domain: "example.com", when: "2026-11-11 18:00 UTC")
        let folder = Fixtures.directory.appending(path: "handover")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.keys.sorted() == names)
        for name in names {
            let expected = try [UInt8](Data(contentsOf: folder.appending(path: name)))
            #expect(files[name] == expected, "\(name)")
        }
    }

    @Test func oddValuesAreWrittenAsPythonWritesThem() throws {
        let odd = try #require(Self.fixture?["odd"])
        let changes = (odd["changes"]?.array ?? []).map { item -> Change in
            let f = item.array ?? []
            func s(_ i: Int) -> String { f[i].string ?? "" }
            return Change(RosterPlan.Kind(rawValue: s(0))!, s(1), s(2), person: s(3), before: s(4), after: s(5), courseID: s(6),
                          swap: f[7].bool ?? false, late: f[8].bool ?? false, name: s(9), section: s(10))
        }
        #expect(changes.count > 40)
        let files = try RosterHandover.build(RosterPlan.ChangeList(changes: changes), domain: "ex\u{E4}mple.com",
                                             when: "2026-11-11 18:00 UTC")
        let expected = try #require(odd["files"]?.object)
        #expect(files.keys.sorted() == expected.keys.sorted())
        for (name, body) in expected {
            #expect(JSONValue.string(Self.text(files, name)) == body, "\(name)")
        }
    }

    @Test func eachLineIsGamGUIs() throws {
        let lines = try #require(Self.fixture?["lines"]?.object)
        #expect(lines.count == RosterHandover.steps.count)
        for step in RosterHandover.steps {
            #expect(JSONValue.string(RosterHandover.gamLine(step)) == lines[step.file], "\(step.file)")
        }
    }

    @Test func everyStepRunsInOrderAndNamesAClassByItsAlias() throws {
        let files = try RosterHandover.build(Self.plan(), domain: "example.com", when: "now")
        let names = RosterHandover.steps.map(\.file).filter { files[$0] != nil }
        let numbers = names.map { Int($0.prefix(2))! }
        #expect(numbers == numbers.sorted())
        #expect(names.first?.hasPrefix("01-remove-teachers-changing-role") == true)
        let readme = Self.text(files, "README.txt")
        let order = ["01-remove-teachers", "05-add-teachers", "07-change-owners", "08-remove-teachers", "09-add-former-owners", "11-archive"]
        let at = order.compactMap { readme.range(of: $0)?.lowerBound }
        #expect(at.count == order.count && at == at.sorted())
        #expect(readme.contains("they don't pass its preview") && readme.contains("Never open the numbered files in a spreadsheet"))
    }

    @Test func theReviewSheetIsFormulaSafeAndTheGamFilesAreExact() throws {
        let files = try RosterHandover.build(Self.plan(), domain: "example.com", when: "now")
        let review = Self.rows(files, "review.csv")
        let row = try #require(review.first { $0.count > 2 && $0[2] == "d:gg-C4" })
        #expect(Array(row.prefix(2)) == ["Classes to create", "'=Study hall"])
        #expect(Self.rows(files, "03-create-classes-without-section.csv") == [["alias", "name", "owner"], ["d:gg-C4", "=Study hall", "ann@x.com"]])
        #expect(Self.rows(files, "03-create-classes.csv")[1] == ["d:gg-C3", #"Physics, "Lab""#, "Fall 2026", "ann@x.com"])
        #expect(!(files["03-create-classes.csv"] ?? []).contains(UInt8(ascii: "\\")), "plain CSV: quotes doubled, no escape character")
    }

    @Test func aFlaggedKindIsLeftOutUnlessTicked() throws {
        let plan = Self.plan(flags: Self.held)
        let left = try RosterHandover.build(plan, domain: "example.com", when: "now")
        #expect(left["10-remove-students.csv"] == nil && left["02-remove-students-changing-role.csv"] == nil)
        #expect(Self.text(left, "README.txt").contains("Held back by the risk check"))
        let ticked = try RosterHandover.build(plan, domain: "example.com", when: "now", including: [.removeStudent])
        #expect(ticked["10-remove-students.csv"] != nil)
    }

    @Test func whatNeedsAHeldBackRemovalIsLeftOutWithIt() throws {
        // di@ swaps student -> teacher in Chemistry: with the removal held back, adding di@ as a teacher would fail.
        var plan = Self.plan(flags: Self.held)
        plan.changes.append(Change(.addTeacher, "d:gg-C2", "Chemistry", person: "di@x.com"))
        let files = try RosterHandover.build(plan, domain: "example.com", when: "now")
        #expect(!Self.rows(files, "05-add-teachers.csv").contains(["d:gg-C2", "di@x.com"]))
        #expect(Self.text(files, "README.txt").contains("Also left out: 1 change that needs"))
        // And an outgoing owner's student add goes with their held-back removal.
        let held = try RosterHandover.build(Self.plan(flags: [.init(kind: .removeTeacher, why: "Would remove a lot.")]),
                                            domain: "example.com", when: "now")
        #expect(held["09-add-former-owners-as-students.csv"] == nil && held["08-remove-teachers.csv"] == nil)
    }

    @Test func aRenameAlwaysSendsItsSectionSoAnEmptyOneClearsIt() throws {
        let files = try RosterHandover.build(Self.plan(), domain: "example.com", when: "now")
        let rows = Self.rows(files, "04-rename-classes.csv")
        #expect(rows[0] == ["course", "name", "section"] && rows.contains(["d:gg-C5", "Art", ""]))
        #expect(!files.keys.contains { $0.hasPrefix("04-") && $0 != "04-rename-classes.csv" })
    }

    @Test func anIncompleteListOrNothingToDoHandsNothingOver() {
        #expect(throws: RosterHandover.Refusal.incomplete) {
            try RosterHandover.build(Self.plan(incomplete: true), domain: "example.com", when: "now")
        }
        #expect(RosterHandover.Refusal.incomplete.message.contains("incomplete"))
        #expect(throws: RosterHandover.Refusal.nothing) {
            try RosterHandover.build(RosterPlan.ChangeList(), domain: "example.com", when: "now")
        }
        #expect(RosterHandover.Refusal.nothing.message == "There's nothing to hand over.")
    }

    /// zsh reads an unquoted leading `~word` as a home folder and refuses the line (GamGUI's review of C4): each line, run
    /// by zsh's `print`, is the argv it says. Nothing but `print` runs.
    @Test func eachReadmeLineRunsAsWrittenInZsh() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        for step in RosterHandover.steps {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-fc", "print -rl -- " + RosterHandover.gamLine(step)]
            process.environment = ["PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(step.file)")
            let words = String(decoding: out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            #expect(words == ["gam", "csv", step.file, "noescapechar", "true", "gam"] + step.gam, "\(step.file)")
        }
    }

    // MARK: the grammar (GamGUI's test_each_command_is_one_the_grammar_has)

    static let grammar = (try? String(contentsOf: Fixtures.repoRoot.appending(path: "Vendor/gam7/GamCommands.txt"), encoding: .utf8))
        ?? (try? String(contentsOf: Fixtures.repoRoot.appending(path: "Vendor/gam7/GamCommands.txt"), encoding: .isoLatin1))

    static func words(_ text: Substring) -> [String] {
        text.matches(of: /[\w-]+/).map { String($0.output) }
    }

    /// Each `<Nonterminal> ::= …` and the words its definition (with its continuation lines) holds.
    static func definitions(_ lines: [Substring]) -> [String: Set<String>] {
        var defs: [String: Set<String>] = [:], current: String?
        for line in lines {
            if let found = line.prefixMatch(of: /(<[\w-]+>) ::=(.*)/) {
                current = String(found.output.1)
                defs[current!] = Set(words(found.output.2))
            } else if let name = current, line.hasPrefix(" ") || line.hasPrefix("\t") {
                defs[name, default: []].formUnion(words(line))
            } else {
                current = nil
            }
        }
        return defs
    }

    /// The first four words line up with a grammar line: a word is one of its choices, a `~field` sits in a `<slot>`, and a
    /// keyword in a `<Nonterminal>` slot is one that nonterminal's definition holds (`name` in <CourseAttribute>).
    static func linesUp(_ argv: [String], _ head: [String], _ defs: [String: Set<String>]) -> Bool {
        if head.count < min(4, argv.count) { return false }
        for (word, slot) in zip(argv.prefix(4), head.prefix(4)) {
            let bare = PythonText.strip(slot, of: Set("[]()+*".unicodeScalars.map(\.value)))
            if word.hasPrefix("~") {
                if !slot.contains("<") { return false }
            } else if !bare.split(separator: "|").map(String.init).contains(word), !(defs[bare] ?? []).contains(word) {
                return false
            }
        }
        return true
    }

    @Test func eachCommandIsOneTheGrammarHas() throws {
        let grammar = try #require(Self.grammar, "the GAM grammar is vendored")
        let lines = grammar.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        let known = Set(Self.words(Substring(grammar)))
        let heads = lines.filter { $0.hasPrefix("gam ") }.map { $0.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init) }
        let defs = Self.definitions(lines)
        #expect(heads.contains { Array($0.prefix(2)) == ["csv", "<CSVLoopContent>"] })
        for step in RosterHandover.steps {
            let line = RosterHandover.gamLine(step)
            #expect(line.contains("noescapechar true") && line.hasPrefix("gam csv \(step.file) noescapechar true gam "))
            for word in step.gam {
                #expect(word.hasPrefix("~") || known.contains(word), "\(step.file): \(word)")
            }
            #expect(heads.contains { Self.linesUp(step.gam, $0, defs) }, "\(step.file): \(step.gam)")
            #expect(Set(step.gam.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }).isSubset(of: Set(step.columns)), "\(step.file)")
        }
    }

    // MARK: the ZIP

    @Test func theZipReadsBackWholeAndOneCompareGivesOneSetOfBytes() throws {
        let files = try RosterHandover.build(Self.plan(), domain: "example.com", when: "2026-11-11 18:00 UTC")
        let bytes = RosterHandover.zip(files, when: "2026-11-11 18:00 UTC")
        #expect(bytes == RosterHandover.zip(files, when: "2026-11-11 18:00 UTC"))
        #expect(bytes != RosterHandover.zip(files, when: "2026-11-11 18:01 UTC"), "dated with the compare's time")
        let archive = try RosterZip.open(bytes, caps: RosterCaps())
        #expect(archive.entries.map(\.name) == files.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        for entry in archive.entries {
            let body = try archive.unpack(entry, cap: 1 << 20, capped: PackageError("capped"), broken: PackageError("broken"))
            #expect(body == files[entry.name], "\(entry.name)")
            #expect(entry.method == 0 && entry.createSystem == 3 && entry.externalAttributes >> 16 == 0o100600)
        }
        // The DOS stamp: 2026-11-11 18:00.
        #expect(RosterHandover.dosStamp("2026-11-11 18:00 UTC") == (UInt16((2026 - 1980) << 9 | 11 << 5 | 11), UInt16(18 << 11)))
        #expect(RosterHandover.dosStamp("not a time") == (0x21, 0))
    }

    @Test func theZipIsNamedForTheDomainAndTheMinute() {
        #expect(RosterHandover.zipName(domain: "example.com", when: "2026-11-11 18:00 UTC") == "classroom-changes-example.com-202611111800.zip")
        #expect(RosterHandover.zipName(domain: "ex\u{E4}m/ple;.com", when: "2026-11-11 18:00 UTC") == "classroom-changes-exmple.com-202611111800.zip")
        #expect(RosterHandover.zipName(domain: "", when: "") == "classroom-changes-domain-.zip")
    }

    @Test func shellQuotingIsShlexs() {
        #expect(["", "abc", "~course", "a'b", "a b", "d:gg-x", "x@y.com", "é"].map(RosterHandover.shellQuoted)
                == ["''", "abc", "'~course'", #"'a'"'"'b'"#, "'a b'", "d:gg-x", "x@y.com", "'é'"])
    }
}
