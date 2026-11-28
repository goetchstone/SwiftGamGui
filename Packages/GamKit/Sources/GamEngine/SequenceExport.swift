import Foundation

/// A Builder sequence written out as a `gam batch` file (GamGUI's `core/sequence_export.py`, roadmap 5.3), so it can run under
/// GAM's own batch machinery. GAM 7.52.05's doBatch reads a line at a time (`\n`, `\r` and `\r\n` end one), skips a line starting
/// with `#`, and splits each with `shlex.split` (POSIX, no comments): every element is `shlex.quote`d, and a value holding a line
/// break or a NUL is refused. A batch runs lines in parallel, so a `commit-batch` between steps makes each wait for the one
/// before. The file then runs outside this app's guard, preview and audit; the export itself is audited. A step that sets a
/// password is refused, not written. Both apps write the same bytes (`Tests/Fixtures/sequence_export.txt`).
public enum SequenceExport {
    static let generated: Set<String> = ["random", "uniquerandom", "blocklogin"]

    public static let header = [
        "# A GamGUI Builder sequence, written for `gam batch <this file>`.",
        "# It runs outside GamGUI: no preview, no confirmation, no audit record. Read every line before you run it.",
        "# Each commit-batch waits for the step before it, so the steps run in this order.",
    ]

    /// Python's `shlex.quote`: as-is when every character is one of `\w@%+=:,./-` (ASCII), else single-quoted with each `'`
    /// written `'"'"'`; empty is `''`.
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = value.unicodeScalars.allSatisfy { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || "_@%+=:,./-".unicodeScalars.contains(s))
        }
        return safe ? value : "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func line(_ argv: [String]) -> String { (["gam"] + argv).map(quote).joined(separator: " ") }

    /// Why step `n` can't be written, or nil when it can.
    public static func refusal(_ n: Int, label: String, argv: [String]) -> String? {
        let words = argv.map(PythonText.lower)
        for (index, word) in words.enumerated() where word == "password" {
            if index + 1 >= words.count || !generated.contains(words[index + 1]) {
                return "Step \(n) (\(label)) sets a password, which the file would keep in plain text. Remove it to export."
            }
        }
        // By scalar: Swift reads "\r\n" as one character, which a plain `contains("\n")` misses.
        if argv.contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" } }) {
            return "Step \(n) (\(label)) has a value with a line break in it, which a gam batch file can't hold."
        }
        if argv.isEmpty { return "Step \(n) (\(label)) has no command." }
        return nil
    }

    /// Why these steps can't be written, or nil when they can.
    public static func whyNot(_ steps: [(label: String, argv: [String])]) -> String? {
        guard !steps.isEmpty else { return "The sequence is empty." }
        for (index, step) in steps.enumerated() {
            if let why = refusal(index + 1, label: step.label, argv: step.argv) { return why }
        }
        return nil
    }

    /// The batch file, or nil when `whyNot` says.
    public static func file(_ steps: [(label: String, argv: [String])]) -> String? {
        guard whyNot(steps) == nil else { return nil }
        var lines = header
        for (index, step) in steps.enumerated() {
            if index > 0 { lines.append("commit-batch") }
            let label = String(String.UnicodeScalarView("\(index + 1). \(step.label)".unicodeScalars.map { $0 == "\n" || $0 == "\r" ? " " : $0 }))
            lines.append("# " + label)
            lines.append(line(step.argv))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
