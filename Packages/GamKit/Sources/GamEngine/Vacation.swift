/// A mailbox's auto-reply, as GamGUI's `Vacation.from_show_text` reads `gam user X show vacation` (GAM has
/// no `formatjson` for it). Held to Tests/Fixtures/vacation.json, with one deliberate difference: the settings are read
/// only above `Message:`, which GAM's _showVacation prints last, so the reply's own text (an attacker's, say) can't
/// set them. GamGUI ends the message at a line like `Enabled: False` and takes it (failure-log 2026-10-21).
public struct Vacation: Sendable, Equatable {
    public var enabled = false
    public var subject = ""
    /// The stored body as GAM printed it, HTML or plain text (`HTMLText.autoreplyText` gives the text).
    public var message = ""
    public var contactsOnly = false
    public var domainOnly = false
    /// `YYYY-MM-DD`, or empty for none (GAM shows `Started` / `NotSpecified`): the form sends back the
    /// dates it had, since GAM keeps any setting a command leaves out.
    public var start = ""
    public var end = ""

    public init() {}

    public init(showText text: String) {
        var messageLines: [String] = [], inMessage = false
        var dates = ["Start Date:": "", "End Date:": ""]
        for line in PythonText.lines(text) {
            let s = PythonText.strip(line)
            if inMessage {
                // The message is the last thing GAM prints: a line like a setting is the reply's own text. Only GAM's
                // config banner, should one slip past the runner's filter, ends it, so it never lands in the reply.
                // Nothing after `Message:` sets a field.
                if ["Created:", "Config File:"].contains(where: s.hasScalarPrefix) { break }
                messageLines.append(s)
                continue
            }
            if s.hasScalarPrefix("Enabled:") {
                enabled = PythonText.lower(s).contains("true")
            } else if s.hasScalarPrefix("Contacts Only:") {
                contactsOnly = PythonText.lower(s).contains("true")
            } else if s.hasScalarPrefix("Domain Only:") {
                domainOnly = PythonText.lower(s).contains("true")
            } else if s.hasScalarPrefix("Subject:") {
                subject = PythonText.strip(String(s.unicodeScalars.dropFirst("Subject:".unicodeScalars.count)))
            } else if let key = dates.keys.first(where: s.hasScalarPrefix) {
                let scalars = Array(s.unicodeScalars)
                let colon = scalars.firstIndex(of: ":")!
                let value = PythonText.strip(PythonText.string(scalars[(colon + 1)...]))
                if Self.isISODate(value) { dates[key] = value }
            } else if s.hasScalarPrefix("Message:") {
                inMessage = true
            }
        }
        message = PythonText.strip(messageLines.joined(separator: "\n"))
        start = dates["Start Date:"]!
        end = dates["End Date:"]!
    }

    /// `\d{4}-\d{2}-\d{2}`, fully, with Python's `\d` (any decimal digit).
    static func isISODate(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        guard s.count == 10, s[4] == "-", s[7] == "-" else { return false }
        return [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy { PythonText.isDecimal(s[$0]) }
    }
}

extension String {
    /// `str.startswith`, by scalars: Swift's `hasPrefix` compares characters, so "Subject:\u{301}" would
    /// not start with "Subject:".
    func hasScalarPrefix(_ prefix: String) -> Bool {
        unicodeScalars.starts(with: prefix.unicodeScalars)
    }
}
