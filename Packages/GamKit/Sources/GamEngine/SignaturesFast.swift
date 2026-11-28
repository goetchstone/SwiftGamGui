import Foundation

/// The GAM-native fast path for a signature run (GamGUI's `core/signatures_fast.py`, roadmap 5.4): one GAM call reads everyone's
/// current signature, one sets them all. The per-person loop stays the default (its live count and Stop); this is opt-in.
///
/// - **Backup read:** `file - print signature`, the addresses on standard input. A person is read only when their one row came
///   back whole and GAM said "Getting Signature(s) for" them; anyone else is unread, never "no signature".
/// - **Write:** `csv - … gam user ~User signature ~signature html`, the rows on standard input. GAM reads them with
///   csv.DictReader after `sys.stdin.read()`, so each body has its line breaks made `\n` and every non-ASCII character written as
///   an HTML character reference: the bytes GAM reads are ASCII whatever its locale.
/// - **Results:** GAM's csv parent takes none of its children's exit codes, so only GAM's own "User: <u>, Signature: <u>, Set"
///   says a person was set; anyone else is listed as failed and Retry runs them one at a time.
///
/// Same argv, same CSV bytes (`Tests/Fixtures/signatures_fast.csv`) and same parse as GamGUI.
public enum SignaturesFast {
    /// Python's csv.field_size_limit default, which GAM never raises: one longer cell ends its whole read.
    public static let fieldLimit = 131_072
    public static let notSaid = "GAM didn't say it set this one, so it may not have happened."

    /// GamGUI's `as_sent`: `\n` line breaks, non-ASCII as HTML character references (`xmlcharrefreplace`).
    public static func asSent(_ body: String) -> String {
        var out = ""
        var scalars = Array(body.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if scalar == "\r" {
                if scalars.first == "\n" { scalars.removeFirst() }
                out += "\n"
            } else if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else {
                out += "&#\(scalar.value);"
            }
        }
        return out
    }

    private static func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// GamGUI's `rows_csv`: a `User,signature` header, then each row as sent, every field quoted, `"` doubled, `\n` between rows.
    public static func rowsCSV(_ items: [(email: String, body: String)]) -> String {
        ([field("User") + "," + field("signature")] + items.map { field($0.email) + "," + field(asSent($0.body)) })
            .joined(separator: "\n") + "\n"
    }

    /// GamGUI's `emails_stdin`: one address a line.
    public static func emailsStdin(_ emails: [String]) -> String { emails.map { $0 + "\n" }.joined() }

    private static func saidGetting(_ stderr: String, _ email: String) -> Bool {
        let wanted = PythonText.lower(email)
        return PythonText.lines(stderr).contains { raw in
            var line = PythonText.lower(PythonText.strip(raw))
            if let range = line.range(of: #" \(\d+/\d+\)$"#, options: .regularExpression) { line.removeSubrange(range) }
            // GAM's word is the entity's plural ("Signatures", printGettingEntityItemForWhom); GamGUI's reader says the
            // singular. Either names the person.
            return line == "getting signatures for \(wanted)" || line == "getting signature for \(wanted)"
        }
    }

    /// GamGUI's `read_signatures`: each person's stored signature, only for those read whole (their one row, every cell
    /// present, and GAM's "Getting" line). Missing from the result is unread, never "".
    public static func readSignatures(stdout: String, stderr: String, emails: [String]) -> [String: String] {
        var rows: [String: [GamOutput.Record]] = [:]
        for record in GamOutput.records(stdout) {
            rows[PythonText.lower(PythonText.strip(record["User"]?.string ?? "")), default: []].append(record)
        }
        var read: [String: String] = [:]
        for email in emails {
            let mine = rows[PythonText.lower(PythonText.strip(email))] ?? []
            guard mine.count == 1, mine[0].allSatisfy({ $0.value != .null }), saidGetting(stderr, email) else { continue }
            read[email] = mine[0]["signature"]?.string ?? ""
        }
        return read
    }

    /// GamGUI's `updated`: the people GAM's own line says it set, matched on the whole address without case.
    public static func updated(stdout: String) -> Set<String> {
        var said: Set<String> = []
        for raw in PythonText.lines(stdout) {
            var line = PythonText.strip(raw)
            if let range = line.range(of: #" \(\d+/\d+\)$"#, options: .regularExpression) { line.removeSubrange(range) }
            guard line.hasPrefix("User: "), line.hasSuffix(", Set") else { continue }
            let parts = line.dropFirst("User: ".count).dropLast(", Set".count).components(separatedBy: ", Signature: ")
            guard parts.count == 2, !parts[0].contains(where: { $0 == "," || $0.isWhitespace }),
                  PythonText.lower(parts[0]) == PythonText.lower(parts[1]) else { continue }
            said.insert(PythonText.lower(parts[0]))
        }
        return said
    }
}
