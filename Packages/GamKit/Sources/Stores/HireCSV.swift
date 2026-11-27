import Foundation
import GamEngine

/// Hires from a CSV (GamGUI's `parse_hire_csv` and `HIRE_CSV_TEMPLATE`, roadmap 2.3): a spreadsheet's CSV, read in Python's
/// `excel` dialect by `RosterCSV` (GAM's own output reader, `GamOutput`, reads another dialect), a leading byte-order mark
/// dropped. It is held in memory only and never saved.
public enum HireCSV {
    /// GamGUI's `_MAX_CSV_BYTES`: a hire list is far smaller.
    public static let maxBytes = 1024 * 1024

    /// GamGUI's template, its example domains reserved ones.
    public static let template = "role,name,email,manager,assignee,create_account,first,last,send_welcome,notify\n"
        + "Salesperson,Jordan Lee,jordan@example.com,mgr@example.com,it@example.com,yes,Jordan,Lee,yes,jordan.personal@example.net\n"
        + "Salesperson,Sam Rivers,sam@example.com,mgr@example.com,it@example.com,yes,Sam,Rivers,no,\n"

    /// One row: the role it names and the hire it describes.
    public struct Row: Sendable, Equatable {
        public let role: String
        public let hire: Hire
        /// The row's line in the file.
        public let line: Int
    }

    /// GamGUI's `_truthy`.
    static func truthy(_ value: String) -> Bool {
        ["1", "true", "yes", "y", "x", "on"].contains(PythonText.lower(PythonText.strip(value)))
    }

    /// The rows and, in GamGUI's words, each row it refused ("Row N: …"). A file over `maxBytes`, not UTF-8 text, or not
    /// readable as CSV is refused whole: no rows, one error.
    public static func parse(_ bytes: [UInt8]) -> (rows: [Row], errors: [String]) {
        if bytes.count > maxBytes {
            return ([], ["That file is over 1 MB \u{2014} a hire list should be far smaller. Split it into several CSVs, or check "
                         + "you picked the right file."])
        }
        guard String(validating: bytes, as: UTF8.self) != nil else {
            return ([], ["That file isn't UTF-8 text. Save it as CSV UTF-8 and choose it again."])
        }
        var reader = RosterCSV(RosterLines(name: "The CSV", bytes: bytes, caps: .standard))
        var records: [(line: Int, cells: [String])] = []
        var header: [String]?
        do {
            while let fields = try reader.next() {
                reader.lines.recordDone()
                // `csv.DictReader` skips a record with no fields at all (a blank line).
                if fields.isEmpty { continue }
                if header == nil {
                    header = fields.map(\.text)
                } else {
                    records.append((reader.lineNumber, fields.map(\.text)))
                }
            }
        } catch let error as CSVError {
            return ([], ["Row \(reader.lineNumber): couldn't read the CSV (\(error.message)). Nothing was imported \u{2014} fix the "
                         + "file and upload it again."])
        } catch let error as PackageError {
            return ([], [error.message])
        } catch {
            return ([], ["Couldn't read the CSV. Nothing was imported."])
        }
        guard let header else { return ([], ["The CSV has no header row."]) }
        // GamGUI's `fieldmap`: each header stripped and lowercased, the last of a name winning, as a dict keeps it.
        var column: [String: Int] = [:]
        for (index, name) in header.enumerated() { column[PythonText.lower(PythonText.strip(name))] = index }
        guard column["role"] != nil else { return ([], ["The CSV needs a 'role' column \u{2014} that's what picks the template."]) }

        var rows: [Row] = [], errors: [String] = [], seen: [String: Int] = [:]
        for (line, cells) in records {
            func cell(_ key: String) -> String {
                guard let index = column[key], index < cells.count else { return "" }
                return PythonText.strip(cells[index])
            }
            let role = cell("role"), name = cell("name"), email = cell("email"), assignee = cell("assignee")
            if [role, name, email, assignee].allSatisfy(\.isEmpty) { continue }
            if role.isEmpty {
                errors.append("Row \(line): missing role.")
                continue
            }
            if email.isEmpty, assignee.isEmpty {
                errors.append("Row \(line): needs an email or an assignee.")
                continue
            }
            if let bad = [("email", email), ("assignee", assignee)].first(where: { !$0.1.isEmpty && !Address.looksLikeEmail($0.1) }) {
                errors.append("Row \(line): \(bad.0) '\(bad.1)' is not a valid email address.")
                continue
            }
            let key = PythonText.lower(email)
            if !key.isEmpty, let first = seen[key] {
                errors.append("Row \(line): duplicate email \(email) (first on row \(first)).")
                continue
            }
            if !key.isEmpty { seen[key] = line }
            rows.append(Row(role: role, hire: Hire(
                name: name, email: email, manager: cell("manager"), assignee: assignee,
                createAccount: truthy(cell("create_account")), first: cell("first"), last: cell("last"),
                sendWelcome: truthy(cell("send_welcome")), notify: cell("notify")), line: line))
        }
        return (rows, errors)
    }
}
