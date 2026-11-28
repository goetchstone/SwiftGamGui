import Foundation
import GamEngine

/// Change many people from a CSV (roadmap 4.6, GamGUI's `core/bulk_csv.py`): an `email` column plus any of title, department,
/// phone and org_unit.
///
/// - The columns are the ones Reports' fill-in sheets download, so a sheet filled in comes back as it went out: `name` is
///   there for whoever fills it in and isn't applied; `location` is said and not applied (a building has to be one Google
///   knows). **A blank cell leaves that value alone; nothing here clears one.**
/// - Google keeps a person's organizations, and their phones, each as one list a write replaces whole, so a change sends
///   every entry back as it was read with only the changed value different (`GamCommands.updateProfile`), and an entry GAM
///   couldn't send back unchanged refuses that person (`BulkProfile`). The preview plans from the directory read; the run
///   reads each person again right before their write (`WriteStep.KeepFirst.unchanged`) and changes nothing for them if
///   their organizations, phones or org unit moved since.
/// - The preview's "before" saves as a CSV of the same columns: the undo. A value that was empty before can't be put back by
///   it (a blank cell changes nothing), and the preview says so.
///
/// The file is read as GamGUI reads it: UTF-8 (a byte-order mark dropped), `csv.reader`'s defaults, `;` when the first line
/// has one and no comma. Held in memory only, never saved.
public enum BulkCSV {
    /// Applied, in this order.
    public static let columns = ["title", "department", "phone", "org_unit"]
    public static let header = ["email"] + columns
    public static let maxBytes = 1024 * 1024
    public static let maxRows = 2000
    public static let labels = ["title": "Title", "department": "Department", "phone": "Phone", "org_unit": "Org unit"]
    static let notApplied = ["name": "is there for whoever fills the sheet in",
                             "location": "isn't set from a CSV: a building has to be one Google knows, so set it in the Admin console"]
    static let same = ["org unit": "org_unit", "orgunit": "org_unit", "ou": "org_unit", "org_unit_path": "org_unit",
                       "work phone": "phone", "work_phone": "phone"]
    /// What `csv_safe` puts a `'` before.
    static let unguard: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    public struct Row: Sendable, Equatable {
        public let line: Int
        public let email: String
        /// Only the cells that say something: a blank one leaves the value alone.
        public let values: [String: String]
    }

    public struct Parsed: Sendable, Equatable {
        public var rows: [Row] = []
        public var errors: [String] = []
        public var notes: [String] = []
    }

    /// The file as text: UTF-8, a byte-order mark dropped (Excel's "CSV UTF-8" writes one). Anything else is refused rather
    /// than guessed: a wrong guess changes the names it sets. Nil with the refusal.
    public static func decode(_ bytes: [UInt8]) -> Result<[UInt8], Refusal> {
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
        guard String(validating: body, as: UTF8.self) != nil else {
            return .failure(Refusal("The file isn't UTF-8 text. In Excel, save it as “CSV UTF-8”; in Sheets, download it as CSV."))
        }
        return .success(body)
    }

    public struct Refusal: Error, Sendable, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// GamGUI's `_column`: lowercased, `-` read as a space, runs of whitespace one, a known other spelling taken as its column.
    static func column(_ name: String) -> String {
        let key = PythonText.split(PythonText.lower(PythonText.strip(name)).replacingOccurrences(of: "-", with: " ")).joined(separator: " ")
        return same[key] ?? key.replacingOccurrences(of: " ", with: "_")
    }

    /// GamGUI's `_cell`: stripped, and one `'` off where this app put one: before a formula lead (`csv_safe`), or before a
    /// value that already began with that guard (the undo file, `undoCell`).
    static func cell(_ value: String) -> String {
        let value = PythonText.strip(value)
        let scalars = Array(value.unicodeScalars)
        if scalars.first == "'", scalars.count > 1,
           unguard.contains(scalars[1]) || (scalars[1] == "'" && scalars.count > 2 && unguard.contains(scalars[2])) {
            return PythonText.string(scalars.dropFirst())
        }
        return value
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .control }

    /// GamGUI's `parse`: the rows that set something, each refused one said by its line. The whole file is refused when it
    /// can't be read. `bytes` is the decoded body (`decode`).
    public static func parse(_ bytes: [UInt8]) -> Parsed {
        var out = Parsed()
        let text = String(decoding: bytes, as: UTF8.self)
        let first = PythonText.lines(text).first ?? ""
        // A semicolon is Excel's in some regions.
        let delimiter: UInt8 = first.unicodeScalars.contains(";") && !first.unicodeScalars.contains(",") ? 0x3B : 0x2C
        var reader = RosterCSV(RosterLines(name: "The CSV", bytes: bytes, caps: .standard), delimiter: delimiter, strict: false)
        var records: [(line: Int, cells: [String])] = []
        do {
            while let fields = try reader.next() {
                reader.lines.recordDone()
                records.append((reader.lineNumber, fields.map(\.text)))
            }
        } catch let error as CSVError {
            out.errors.append("Line \(reader.lineNumber + 1): the CSV couldn't be read (\(error.message)). Nothing is offered: fix "
                              + "the file and upload it again.")
            return out
        } catch let error as PackageError {
            out.errors.append(error.message)
            return out
        } catch {
            out.errors.append("The CSV couldn't be read. Nothing is offered: fix the file and upload it again.")
            return out
        }
        guard let head = records.first else {
            out.errors.append("The file is empty.")
            return out
        }
        let names = head.cells.map(column)
        if let twice = Set(names.filter { name in header.contains(name) && names.filter { $0 == name }.count > 1 }).sorted().first {
            out.errors.append("The CSV has more than one `\(twice)` column, so which to read can't be told. Keep one.")
            return out
        }
        guard names.contains("email") else {
            out.errors.append("The CSV needs an `email` column: it says who each row is.")
            return out
        }
        guard names.contains(where: columns.contains) else {
            out.errors.append("The CSV has none of title, department, phone or org_unit, so it changes nothing.")
            return out
        }
        for name in Set(names).subtracting(header).sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
            out.notes.append("The `\(name)` column \(notApplied[name] ?? "isn’t one this reads"), so it isn't applied.")
        }
        // A record over more than one line is a quote the file never closed where it meant to: the lines after it would be read
        // as part of one cell, and one person's value land on another, so the whole file is refused.
        var start = 1
        for record in records {
            if record.line != start {
                out.errors.append("Line \(start): a cell there runs over more than one line, so where each row ends can't be told. "
                                  + "Nothing is offered: fix the file and upload it again.")
                return out
            }
            start = record.line + 1
        }
        if records.count - 1 > maxRows {
            out.errors.append("The CSV has \(records.count - 1) rows, over the \(maxRows) one file takes. Split it.")
            return out
        }
        var seen: [String: Int] = [:], nothing = 0
        for (line, raw) in records.dropFirst() {
            var given: [String: String] = [:]
            for (index, name) in names.enumerated() where header.contains(name) {
                given[name] = PythonText.strip(index < raw.count ? raw[index] : "")
            }
            let cells = given.mapValues(cell)
            if cells.values.allSatisfy(\.isEmpty) { continue }
            let email = cells["email"] ?? ""
            guard Address.looksLikeEmail(email) else {
                out.errors.append(email.isEmpty ? "Line \(line): no email." : "Line \(line): “\(email)” isn't an email address.")
                continue
            }
            let key = PythonText.lower(email)
            if let earlier = seen[key] {
                out.errors.append("Line \(line): \(email) is on line \(earlier) too. Keep one.")
                continue
            }
            seen[key] = line
            let values = cells.filter { columns.contains($0.key) && !$0.value.isEmpty }
            // A cell starting "=" is a formula a spreadsheet didn't work out; one this app guarded ("'=") is text, as written.
            if let bad = columns.first(where: { values[$0] != nil && (given[$0] ?? "").hasPrefix("=") }) {
                out.errors.append("Line \(line): \(email)'s \(PythonText.lower(labels[bad]!)) “\(values[bad]!)” looks like a spreadsheet "
                                  + "formula, not a value.")
                continue
            }
            if let bad = columns.first(where: { values[$0]?.unicodeScalars.contains(where: isControl) == true }) {
                out.errors.append("Line \(line): \(email)'s \(PythonText.lower(labels[bad]!)) runs over more than one line.")
                continue
            }
            if values.isEmpty {
                nothing += 1
                continue
            }
            out.rows.append(Row(line: line, email: email, values: values))
        }
        if nothing > 0 { out.notes.append("\(nothing) row\(nothing == 1 ? "" : "s") set nothing (every cell blank but the email).") }
        return out
    }

    /// One person's change: what the preview shows and the run sends.
    public struct Change: Sendable, Equatable {
        /// The primary address.
        public let email: String
        public let name: String
        /// Only the columns that change.
        public let before: [String: String]
        public let after: [String: String]
        /// The whole list to send, or nil: not sent.
        public let organizations: [GamCommands.Organization]?
        public let phones: [GamCommands.Phone]?
        /// Where to move them, or "".
        public let orgUnit: String
        /// `BulkProfile.held` of the record the plan was made from.
        public let was: String

        /// Every write this change runs, in order: the profile, then the move. Each built when the plan is made, so one GAM
        /// couldn't send refuses the row there, never at the run.
        public func writes() throws -> [GamWrite] {
            var out: [GamWrite] = []
            if organizations != nil || phones != nil {
                out.append(try GamCommands.updateProfile(email: email, organizations: organizations, phones: phones))
            }
            if !orgUnit.isEmpty { out.append(GamCommands.moveUserToOrgUnit(orgUnit: orgUnit, email: email)) }
            return out
        }
    }

    /// GamGUI's `plan`: each row's change against the directory as read, `(changes, refusals, unchanged)`. An unknown person,
    /// an alias, an org unit that isn't one, or a list GAM couldn't send back refuses that row, and says so.
    public static func plan(_ rows: [Row], directory: [GamUser], units: [String]) -> (changes: [Change], errors: [String], unchanged: Int) {
        var byEmail: [String: GamUser] = [:], byAlias: [String: GamUser] = [:]
        for user in directory {
            byEmail[PythonText.lower(user.primaryEmail)] = user
            for alias in user.aliases { byAlias[PythonText.lower(alias)] = user }
        }
        var changes: [Change] = [], errors: [String] = [], unchanged = 0
        for row in rows {
            guard let user = byEmail[PythonText.lower(row.email)] else {
                if let owner = byAlias[PythonText.lower(row.email)] {
                    errors.append("Line \(row.line): \(row.email) is an alias of \(owner.primaryEmail): use that address.")
                } else {
                    errors.append("Line \(row.line): \(row.email) isn't an account here.")
                }
                continue
            }
            let who = user.primaryEmail, record = user.record
            var before: [String: String] = [:], after: [String: String] = [:]
            do {
                var organizations: [GamCommands.Organization]?
                let title = row.values["title"] ?? "", department = row.values["department"] ?? ""
                if (!title.isEmpty && differs(title, user.title)) || (!department.isEmpty && differs(department, user.department)) {
                    var current = try BulkProfile.organizations(from: record)
                    var index = BulkProfile.shownIndex(current.map(\.primary))
                    if index == nil {
                        current = [GamCommands.Organization(primary: true)]
                        index = 0
                    }
                    current[index!] = BulkProfile.with(current[index!], title: title, department: department)
                    organizations = current
                    for (column, new, old) in [("title", title, user.title), ("department", department, user.department)]
                    where !new.isEmpty && differs(new, old) {
                        (before[column], after[column]) = (old, new)
                    }
                }
                var phones: [GamCommands.Phone]?
                if let typed = row.values["phone"], differs(typed, user.phone) {
                    phones = planPhone(try BulkProfile.phones(from: record), typed: typed)
                    (before["phone"], after["phone"]) = (user.phone, typed)
                }
                var unit = row.values["org_unit"] ?? ""
                if !unit.isEmpty, !units.contains(where: { $0.utf8.elementsEqual(unit.utf8) }) {
                    throw BulkProfile.Unsendable("“\(unit)” isn't an org unit here")
                }
                if unit.utf8.elementsEqual(user.orgUnitPath.utf8) { unit = "" }
                if !unit.isEmpty { (before["org_unit"], after["org_unit"]) = (user.orgUnitPath, unit) }
                let change = Change(email: who, name: user.fullName, before: before, after: after, organizations: organizations,
                                    phones: phones, orgUnit: unit, was: BulkProfile.held(record))
                let writes: [GamWrite]
                do { writes = try change.writes() } catch GamCommands.Invalid.argument(let why) { throw BulkProfile.Unsendable(why) }
                guard !writes.isEmpty else {
                    unchanged += 1
                    continue
                }
                changes.append(change)
            } catch let refused as BulkProfile.Unsendable {
                errors.append("Line \(row.line): \(who) isn't changed: \(refused.reason). Change them on their page.")
            } catch {
                errors.append("Line \(row.line): \(who) isn't changed. Change them on their page.")
            }
        }
        return (changes, errors, unchanged)
    }

    /// Python's `!=` on strings, by code point: Swift's `==` would take "é" and "e\u{301}" as one.
    static func differs(_ a: String, _ b: String) -> Bool { !a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// GamGUI's `plan_phone_change` for a typed phone that differs from the shown one: changed in place keeping its type, or
    /// for someone with none a work phone, the primary. The other phones go back as they are.
    static func planPhone(_ current: [GamCommands.Phone], typed: String) -> [GamCommands.Phone] {
        let phone = PythonText.strip(typed)
        var phones = current
        if let shown = BulkProfile.shownIndex(phones.map(\.primary)) {
            let old = phones[shown]
            phones[shown] = GamCommands.Phone(type: old.type, customType: old.customType, value: phone, primary: old.primary)
        } else {
            phones.append(GamCommands.Phone(type: "work", value: phone, primary: true))
        }
        return phones
    }

    /// GamGUI's `_undo_cell`: `value` as the undo file writes it, so `cell` reads it back as it was: formula-safe, and a value
    /// that already starts with this app's guard keeps it (one `'` is taken off on the way in).
    static func undoCell(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        if scalars.first == "'", scalars.count > 1, unguard.contains(scalars[1]) { return "'" + value }
        return RosterHandover.csvSafe(value)
    }

    /// GamGUI's `restorable`: whether the undo file can put `value` back (a blank cell changes nothing, and a cell is read
    /// trimmed, on one line).
    public static func restorable(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.elementsEqual(PythonText.strip(value).utf8) && !value.unicodeScalars.contains(where: isControl)
            && cell(undoCell(value)).utf8.elementsEqual(value.utf8)
    }

    /// GamGUI's `before_csv`: the undo, each changed person's values as they were, in the columns that change; every other
    /// cell blank. As Python's `csv.writer` writes it.
    public static func beforeCSV(_ changes: [Change]) -> [UInt8] {
        RosterHandover.plainCSV([header] + changes.map { change in
            [RosterHandover.csvSafe(change.email)] + columns.map { undoCell(change.before[$0] ?? "") }
        })
    }

    /// GamGUI's `blanks_before`: how many changed values the undo file can't put back.
    public static func blanksBefore(_ changes: [Change]) -> Int {
        changes.reduce(0) { sum, change in sum + change.after.keys.filter { !restorable(change.before[$0] ?? "") }.count }
    }
}
