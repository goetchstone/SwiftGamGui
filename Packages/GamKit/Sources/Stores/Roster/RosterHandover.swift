import Foundation
import GamEngine

/// Hand the Classroom change list over as files (plan 2026-11-11 C4; GamGUI's `core/roster_handover.py` at 07c505d, held
/// byte for byte to `Tests/Fixtures/handover/`, GamGUI's own `tests/fixtures/handover/`).
///
/// The app never writes to Classroom. What it hands over is for someone to run with GAM, outside this app: a review sheet
/// for people, and one CSV per kind of change with the `gam csv` line that runs it, numbered in the order they must run.
/// Pure: a `ChangeList` in, files out. Nothing here runs GAM.
///
/// - **The review sheet** (`review.csv`) is meant to be opened in a spreadsheet, so every cell is formula-safe (`csvSafe`).
/// - **The GAM files keep their values exact** (a leading `'` would change a class's name), so they must never be opened
///   and saved in a spreadsheet; the README says so. Each is plain CSV (doubled quotes, no escape character) and each
///   command says `noescapechar true`: GAM reads its CSVs with a backslash escape by default, which would misread a name
///   holding one.
/// - **Every value is a whole argument.** `gam csv` replaces an argument that is exactly `~field` with that field (grammar
///   1430), so a value reaches GAM as one argument and is never split. No `~~field~~` inside a larger argument.
/// - **A class is named by its alias** (`<CourseID> ::= <Number>|d:<CourseAlias>`), so a class created in step 3 is found
///   by later steps without its numeric ID.
/// - **The README's lines are shell-quoted** (`shlex.join`): an unquoted `~field` is a home-folder lookup in zsh.
///
/// The words stay GamGUI's, "GamGUI" included: the files are the two apps' shared contract, and a district may get them
/// from either.
public enum RosterHandover {
    public typealias Change = RosterPlan.Change
    public typealias Kind = RosterPlan.Kind

    /// One GAM file: its name, what it does, which changes it holds, its columns and values, and the GAM line after
    /// `gam csv <file> noescapechar true gam`.
    public struct Step: Sendable {
        public let file: String
        public let what: String
        let pick: @Sendable (Change) -> Bool
        public let columns: [String]
        let row: @Sendable (Change) -> [String]
        public let gam: [String]
    }

    /// GamGUI's `STEPS`, in run order.
    public static let steps: [Step] = [
        Step(file: "01-remove-teachers-changing-role.csv", what: "Remove teachers who become students in the same class",
             pick: { $0.kind == .removeTeacher && $0.swap }, columns: ["course", "email"], row: { [$0.alias, $0.person] },
             gam: ["course", "~course", "remove", "teachers", "~email"]),
        Step(file: "02-remove-students-changing-role.csv", what: "Remove students who become teachers in the same class",
             pick: { $0.kind == .removeStudent && $0.swap }, columns: ["course", "email"], row: { [$0.alias, $0.person] },
             gam: ["course", "~course", "remove", "students", "~email"]),
        Step(file: "03-create-classes.csv", what: "Create classes, active, owned by their primary teacher",
             pick: { $0.kind == .create && !$0.section.isEmpty }, columns: ["alias", "name", "section", "owner"],
             row: { [$0.alias, $0.name, $0.section, $0.person] },
             gam: ["create", "course", "alias", "~alias", "name", "~name", "section", "~section", "teacher", "~owner", "state", "active"]),
        Step(file: "03-create-classes-without-section.csv", what: "Create classes that have no section",
             pick: { $0.kind == .create && $0.section.isEmpty }, columns: ["alias", "name", "owner"],
             row: { [$0.alias, $0.name, $0.person] },
             gam: ["create", "course", "alias", "~alias", "name", "~name", "teacher", "~owner", "state", "active"]),
        // Always with its section: an empty one clears it (GAM reads `section` with no minimum length), so a class whose term
        // went from the SIS loses it in Classroom too, instead of being renamed again on every compare.
        Step(file: "04-rename-classes.csv", what: "Rename classes; an empty section clears one", pick: { $0.kind == .rename },
             columns: ["course", "name", "section"], row: { [$0.alias, $0.name, $0.section] },
             gam: ["update", "course", "~course", "name", "~name", "section", "~section"]),
        Step(file: "05-add-teachers.csv", what: "Add teachers", pick: { $0.kind == .addTeacher }, columns: ["course", "email"],
             row: { [$0.alias, $0.person] }, gam: ["course", "~course", "add", "teachers", "~email"]),
        Step(file: "06-add-students.csv", what: "Add students", pick: { $0.kind == .addStudent && !$0.late },
             columns: ["course", "email"], row: { [$0.alias, $0.person] }, gam: ["course", "~course", "add", "students", "~email"]),
        Step(file: "07-change-owners.csv", what: "Change owners; each new owner is already a teacher of the class",
             pick: { $0.kind == .owner }, columns: ["course", "owner"], row: { [$0.alias, $0.person] },
             gam: ["update", "course", "~course", "owner", "~owner"]),
        Step(file: "08-remove-teachers.csv", what: "Remove teachers, a former owner once step 7 has run",
             pick: { $0.kind == .removeTeacher && !$0.swap }, columns: ["course", "email"], row: { [$0.alias, $0.person] },
             gam: ["course", "~course", "remove", "teachers", "~email"]),
        Step(file: "09-add-former-owners-as-students.csv", what: "Add as students the former owners removed in step 8",
             pick: { $0.kind == .addStudent && $0.late }, columns: ["course", "email"], row: { [$0.alias, $0.person] },
             gam: ["course", "~course", "add", "students", "~email"]),
        Step(file: "10-remove-students.csv", what: "Remove students", pick: { $0.kind == .removeStudent && !$0.swap },
             columns: ["course", "email"], row: { [$0.alias, $0.person] }, gam: ["course", "~course", "remove", "students", "~email"]),
        Step(file: "11-archive-classes.csv", what: "Archive classes", pick: { $0.kind == .archive }, columns: ["course"],
             row: { [$0.alias] }, gam: ["update", "course", "~course", "state", "archived"]),
    ]

    /// Why a change list can't be handed over, in words fixed here: a screen says the case's `message`, never an error's
    /// own text.
    public enum Refusal: Error, Sendable, Equatable {
        case incomplete
        case nothing

        public var message: String {
            switch self {
            case .incomplete: "Part of Classroom couldn't be read, so this change list may be incomplete and isn't handed over. "
                + "Compare again."
            case .nothing: "There's nothing to hand over."
            }
        }
    }

    /// The changes handed over: all of them but a flagged kind not ticked, and what needs one (`split`).
    public static func kept(_ plan: RosterPlan.ChangeList, including flagged: [Kind] = []) -> [Change] {
        split(plan, including: flagged).kept
    }

    /// (the changes handed over, how many were left out because they need a held-back one). A flagged kind not ticked is
    /// left out, and so is what needs it: an add or owner change of someone whose removal from that class is held back
    /// (they're still in it, so the add fails), and the removal and student add of an outgoing owner whose change is.
    static func split(_ plan: RosterPlan.ChangeList, including flagged: [Kind]) -> (kept: [Change], dependent: Int) {
        let ticked = Set(flagged)
        func held(_ change: Change) -> Bool { plan.flag(change.kind) != nil && !ticked.contains(change.kind) }
        var blocked: Set<[ExactKey]> = []
        for change in plan.changes where held(change) {
            if change.kind == .removeTeacher || change.kind == .removeStudent { blocked.insert([ExactKey(change.alias), ExactKey(change.person)]) }
            if change.kind == .owner { blocked.insert([ExactKey(change.alias), ExactKey(change.before)]) }
        }
        var kept: [Change] = [], dependent = 0
        for change in plan.changes {
            if held(change) { continue }
            if blocked.contains([ExactKey(change.alias), ExactKey(change.person)]),
               [.addTeacher, .addStudent, .owner, .removeTeacher].contains(change.kind) {
                dependent += 1
                continue
            }
            kept.append(change)
        }
        return (kept, dependent)
    }

    /// The files, by name: README.txt, review.csv, and each step's CSV that has rows. `when` is the compare's time as the
    /// screen says it (`2026-11-11 18:00 UTC`). Throws for an incomplete list, or when nothing is left to hand over.
    public static func build(_ plan: RosterPlan.ChangeList, domain: String, when: String,
                             including flagged: [Kind] = []) throws(Refusal) -> [String: [UInt8]] {
        if plan.incomplete { throw .incomplete }
        let (changes, dependent) = split(plan, including: flagged)
        if changes.isEmpty { throw .nothing }
        var files: [String: [UInt8]] = [:]
        let review = [["change", "class", "alias", "person", "current", "new"]]
            + changes.map { [$0.kind.words, $0.title, $0.alias, $0.person, $0.before, $0.after].map(csvSafe) }
        files["review.csv"] = plainCSV(review)
        var counted: [(Step, Int)] = []
        for step in steps {
            let rows = changes.filter(step.pick).map(step.row)
            if !rows.isEmpty {
                files[step.file] = plainCSV([step.columns] + rows)
                counted.append((step, rows.count))
            }
        }
        let leftOut = plan.flags.map(\.kind).filter { !flagged.contains($0) }.map(\.words)
        files["README.txt"] = Array(readme(domain: domain, when: when, steps: counted, leftOut: leftOut, dependent: dependent).utf8)
        return files
    }

    /// The command that runs a step's file, as typed in a terminal (`shlex.join`). `shlex.quote` single-quotes each
    /// `~field`: zsh (and bash, when a user of that name exists) reads an unquoted leading `~word` as a home folder.
    public static func gamLine(_ step: Step) -> String {
        (["gam", "csv", step.file, "noescapechar", "true", "gam"] + step.gam).map(shellQuoted).joined(separator: " ")
    }

    static func readme(domain: String, when: String, steps: [(Step, Int)], leftOut: [String], dependent: Int) -> String {
        var lines = [
            "Classroom changes for \(domain), from GamGUI's compare at \(when).",
            "",
            "GamGUI did not make these changes and won't. You run them with GAM, outside GamGUI: they don't pass its preview,",
            "its confirmation or its audit log. GamGUI's Classroom support hasn't been checked on a real school domain, and",
            "neither have these commands. Try them on a test class first.",
            "",
            "Before you start:",
            "- Read review.csv: every change, one row each. It's safe to open in a spreadsheet.",
            "- Never open the numbered files in a spreadsheet and save them: their values must stay exactly as written.",
            "- Run the steps in order, from this folder, as an admin GAM is set up for. Each step finishes before the next.",
            "- Classes are named by GamGUI's alias (d:gg-...), so later steps find a class created in step 3.",
            "",
            "Steps:",
        ]
        for (step, count) in steps {
            lines += ["", "\(step.file.prefix(2)). \(step.what) (\(RosterPlan.grouped(count)) row\(count != 1 ? "s" : "")):",
                      "    \(gamLine(step))"]
        }
        if !leftOut.isEmpty {
            lines += ["", "Held back by the risk check and not included (tick them in GamGUI to include them): "
                      + leftOut.joined(separator: ", ") + "."]
        }
        if dependent > 0 {
            lines += ["", "Also left out: \(RosterPlan.grouped(dependent)) change\(dependent != 1 ? "s" : "") that "
                      + "need\(dependent != 1 ? "" : "s") a held-back one (adding someone whose removal from that class is held "
                      + "back would fail)."]
        }
        lines += ["", "Afterwards, open GamGUI's Plan an import and click Compare again: what's left is what didn't happen.", ""]
        return lines.joined(separator: "\n")
    }

    // MARK: CSV, as Python's csv module writes it

    /// GamGUI's `csv_safe`: a `'` before a lead a spreadsheet would read as a formula (`=`, `+`, `-`, `@`, tab, CR). The same
    /// rule as ChangeCore's `AuditExport.safe`; Stores doesn't depend on ChangeCore, so it's here too, and a test holds the
    /// two to one rule.
    public static func csvSafe(_ value: String) -> String {
        guard let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return value }
        return "'" + value
    }

    /// CSV as GAM reads it with `noescapechar true`, and as Python's `csv.writer` (`QUOTE_MINIMAL`, doubled quotes, no
    /// escape character, CRLF) writes it: a field holding a comma, a quote, a CR or an LF is quoted; a row that is one empty
    /// field is written `""`, so it isn't a blank line. Scalar by scalar: "\r\n" is one Swift Character.
    static func plainCSV(_ rows: [[String]]) -> [UInt8] {
        var out: [UInt8] = []
        for row in rows {
            if row.count == 1, row[0].isEmpty {
                out += Array("\"\"\r\n".utf8)
                continue
            }
            out += Array(row.map { field -> String in
                guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return field }
                var quoted = String.UnicodeScalarView()
                quoted.append("\"")
                for scalar in field.unicodeScalars {
                    if scalar == "\"" { quoted.append("\"") }
                    quoted.append(scalar)
                }
                quoted.append("\"")
                return String(quoted)
            }.joined(separator: ",").utf8)
            out += [0x0D, 0x0A]
        }
        return out
    }

    /// `shlex.quote`: as it is when it holds only `\w@%+=:,./-` (ASCII), else in single quotes, each `'` written `'"'"'`.
    static func shellQuoted(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let safe = word.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || "_@%+=:,./-".unicodeScalars.contains(scalar)
        }
        if safe { return word }
        var quoted = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            if scalar == "'" { quoted.append(contentsOf: "'\"'\"'".unicodeScalars) } else { quoted.append(scalar) }
        }
        return "'" + String(quoted) + "'"
    }

    // MARK: the ZIP

    /// The download's name: `classroom-changes-<domain>-<yyyymmddhhmm>.zip`, the domain's ASCII letters, digits, dots and
    /// hyphens kept ("domain" when none is), and the first twelve digits of the compare's time (GamGUI's `_zip_name`).
    public static func zipName(domain: String, when: String) -> String {
        let stamp = String(String.UnicodeScalarView(when.unicodeScalars.filter { ("0"..."9").contains($0) }.prefix(12)))
        let kept = String(String.UnicodeScalarView(domain.unicodeScalars.filter { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "." || scalar == "-"
        }))
        return "classroom-changes-\(kept.isEmpty ? "domain" : kept)-\(stamp).zip"
    }

    /// The files as one ZIP, stored (not compressed: the files are small), each entry `0600` and dated with the compare's
    /// time (`when`, `YYYY-MM-DD HH:MM UTC`), in name order, so one compare gives one set of bytes. Not GamGUI's bytes
    /// (it deflates with zlib); the files inside are.
    public static func zip(_ files: [String: [UInt8]], when: String) -> [UInt8] {
        let (date, time) = dosStamp(when)
        var out: [UInt8] = [], central: [UInt8] = []
        let names = files.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for name in names {
            let body = files[name]!, nameBytes = Array(name.utf8)
            let crc = CRC32.checksum(body), offset = UInt32(out.count)
            // A local header: version 2.0 needed, no flags, stored, the stamp, the CRC and sizes, the name.
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(time) + le16(date) + le32(crc)
                + le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + body
            // Its central record: made on Unix (so the mode is read), a regular file, 0600.
            central += le32(0x0201_4B50) + le16(0x0314) + le16(20) + le16(0) + le16(0) + le16(time) + le16(date) + le32(crc)
                + le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(UInt16(nameBytes.count)) + le16(0) + le16(0)
                + le16(0) + le16(0) + le32(UInt32(0o100600) << 16) + le32(offset) + nameBytes
        }
        let start = UInt32(out.count)
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(names.count)) + le16(UInt16(names.count))
            + le32(UInt32(central.count)) + le32(start) + le16(0)
        return out
    }

    /// MS-DOS date and time of `YYYY-MM-DD HH:MM…`; 1980-01-01 00:00 when it can't be read.
    static func dosStamp(_ when: String) -> (date: UInt16, time: UInt16) {
        let digits = when.unicodeScalars.filter { ("0"..."9").contains($0) }.map { Int($0.value - 48) }
        func number(_ range: Range<Int>) -> Int? {
            guard digits.count >= range.upperBound else { return nil }
            return digits[range].reduce(0) { $0 * 10 + $1 }
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8), let hour = number(8..<10),
              let minute = number(10..<12), (1980...2107).contains(year), (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60 else { return (0x21, 0) }
        return (UInt16((year - 1980) << 9 | month << 5 | day), UInt16(hour << 11 | minute << 5))
    }

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
}
