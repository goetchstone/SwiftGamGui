/// Gmail signatures: GamGUI's template render, its curly-quote check and its reader of
/// `gam user X show signature` (`core/signatures.py`, `gam_connector._parse_signature`), and what GAM does
/// with the signature it's given. Held to Tests/Fixtures/signatures.json, generated from frozen GamGUI and
/// from the vendored GAM's own functions. Text is compared as Python does, by Unicode scalars, never by
/// `Character`: a combining mark after `}` or `]]` joins it into one Character but not one code point.
public enum Signature {
    /// The template variables and what each holds, in GamGUI's order. `{role}` is `{title}` again.
    public static let variables: [(token: String, description: String)] = [
        ("{name}", "Full name"),
        ("{first}", "First name"),
        ("{last}", "Last name"),
        ("{email}", "Primary email"),
        ("{title}", "Job title"),
        ("{role}", "Job title (alias)"),
        ("{phone}", "Work phone"),
        ("{department}", "Department"),
        ("{location}", "Location"),
        ("{ou}", "Org unit path"),
    ]

    /// GamGUI's three starter templates: inline styles only, no external images or fonts, and `[[ … ]]`
    /// blocks so a missing title or phone drops cleanly. "Your Company" is for the operator to replace.
    public static let seeds: [(name: String, body: String)] = [
        ("Classic",
         "<div style=\"font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;"
             + "font-size:13px;line-height:1.5;color:#3f4a5a;\">\n"
             + "  <div style=\"font-weight:600;color:#1f2733;\">{name}</div>\n"
             + "  <div>[[{title} \u{B7} ]]Your Company</div>\n"
             + "  <div style=\"color:#6b7280;\">{email}[[ \u{B7} {phone}]]</div>\n"
             + "</div>"),
        ("Modern accent",
         "<table cellpadding=\"0\" cellspacing=\"0\" role=\"presentation\" "
             + "style=\"font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;"
             + "font-size:13px;color:#3f4a5a;\">\n"
             + "  <tr>\n"
             + "    <td style=\"border-left:3px solid #52647B;padding:1px 0 1px 12px;line-height:1.5;\">\n"
             + "      <div style=\"font-weight:600;font-size:14px;color:#1f2733;\">{name}</div>\n"
             + "      <div style=\"color:#52647B;\">[[{title} \u{B7} ]]Your Company</div>\n"
             + "      <div style=\"color:#6b7280;\">{email}[[ \u{B7} {phone}]]</div>\n"
             + "      [[<div style=\"color:#6b7280;\">{department}</div>]]\n"
             + "    </td>\n"
             + "  </tr>\n"
             + "</table>"),
        ("Minimal",
         "<div style=\"font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;"
             + "font-size:13px;color:#3f4a5a;\">{name}[[ \u{B7} {title}]] \u{B7} Your Company \u{B7} {email}</div>"),
    ]

    /// The template with `user`'s values in: each `[[ … ]]` block kept, or dropped when a variable in it is
    /// empty for them, then every variable replaced in one pass, so a value that itself holds `{phone}` is
    /// inserted as written. Values aren't HTML-escaped (GamGUI's render, pinned by its tests). Linear: a
    /// template full of unclosed `[[` once cost GamGUI quadratic time per mailbox.
    public static func render(_ template: String, for user: GamUser) -> String {
        let values: [(token: [Unicode.Scalar], value: String)] = [
            ("{name}", user.fullName), ("{first}", user.givenName), ("{last}", user.familyName),
            ("{email}", user.primaryEmail), ("{title}", user.title), ("{role}", user.title), ("{phone}", user.phone),
            ("{department}", user.department), ("{location}", user.location), ("{ou}", user.orgUnitPath),
        ].map { (Array($0.0.unicodeScalars), $0.1) }
        let text = expandOptional(Array(template.unicodeScalars), values: values)
        var out = String.UnicodeScalarView(), index = 0
        while index < text.count {
            // Every token is `{word}`, so at most one matches here: the alternation's order can't matter.
            if text[index] == "{", let match = values.first(where: { text[index...].starts(with: $0.token) }) {
                out.append(contentsOf: match.value.unicodeScalars)
                index += match.token.count
            } else {
                out.append(text[index])
                index += 1
            }
        }
        return String(out)
    }

    /// GamGUI's `_expand_optional`: each `[[ … ]]` keeps its inside unless a variable it names is empty;
    /// from an unclosed `[[` on, the text stays as written.
    static func expandOptional(_ text: [Unicode.Scalar], values: [(token: [Unicode.Scalar], value: String)])
        -> [Unicode.Scalar]
    {
        let open: [Unicode.Scalar] = ["[", "["], close: [Unicode.Scalar] = ["]", "]"]
        var out: [Unicode.Scalar] = [], position = 0
        while let start = find(open, in: text, from: position), let end = find(close, in: text, from: start + 2) {
            out += text[position..<start]
            let inner = Array(text[(start + 2)..<end])
            if !values.contains(where: { $0.value.isEmpty && find($0.token, in: inner, from: 0) != nil }) {
                out += inner
            }
            position = end + 2
        }
        out += text[position...]
        return out
    }

    /// GamGUI's warning when a curly quote sits inside a tag: pasted from Word or Mail, it doesn't close an
    /// attribute, so the attribute swallows what follows, `{variables}` included. Empty when clean.
    public static func smartQuoteWarning(_ template: String) -> String {
        curlyQuoteInTag(Array(template.unicodeScalars))
            ? "Heads-up: this HTML contains curly quotes (\u{201D} or \u{2019}) inside a tag \u{2014} pasted from "
                + "Word/Mail they break attributes and can swallow your {variables}. Replace them with straight "
                + "quotes (\")."
            : ""
    }

    /// Between a `<` and the first `>` after it, linearly: a `<` inside that span shares its `>`, and with no
    /// `>` left no later `<` can open a tag.
    static func curlyQuoteInTag(_ text: [Unicode.Scalar]) -> Bool {
        let curly: Set<Unicode.Scalar> = ["\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        var position = 0
        while let lt = find(["<"], in: text, from: position), let gt = find([">"], in: text, from: lt + 1) {
            if text[(lt + 1)..<gt].contains(where: curly.contains) { return true }
            position = gt + 1
        }
        return false
    }

    /// The signature in `show signature`'s text, as GamGUI reads it: the lines after the `Signature:` line,
    /// each stripped, up to the next line that isn't indented; empty for GAM's `None`. GAM prints one
    /// block, for the address asked about (`printShowSignature`, gam/__init__.py:78862-78865). Leading
    /// whitespace inside the body is lost, as it is in GamGUI.
    public static func parseShown(_ text: String) -> String {
        var body: [String] = [], capturing = false
        for line in PythonText.lines(text) {
            let stripped = PythonText.strip(line)
            if capturing {
                if !stripped.isEmpty && !line.hasScalarPrefix(" ") { break }
                body.append(stripped)
            } else if PythonText.rstrip(stripped, of: [0x3A]).unicodeScalars.elementsEqual("Signature".unicodeScalars) {
                capturing = true
            }
        }
        let signature = PythonText.strip(body.joined(separator: "\n"))
        return signature.unicodeScalars.elementsEqual("None".unicodeScalars) ? "" : signature
    }

    /// The signature as GAM stores it from `signature <body> html`: `_processSignature`
    /// (gam/__init__.py:78601-78608) removes every CR and turns each backslash-n pair into `<br/>`. So a
    /// preview of the argv alone would show the operator something else.
    public static func stored(_ body: String) -> String {
        let text = body.unicodeScalars.filter { $0 != "\r" }
        var out = String.UnicodeScalarView(), index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\\", next < text.endIndex, text[next] == "n" {
                out.append(contentsOf: "<br/>".unicodeScalars)
                index = text.index(after: next)
            } else {
                out.append(text[index])
                index = next
            }
        }
        return String(out)
    }

    /// The words GAM reads after `signature` as a file or document to load, not as the signature
    /// (SORF_FILE_ARGUMENTS, read from the vendored build into the fixture).
    public static let fileKeywords: Set<String> = ["file", "htmlfile", "textfile", "gdoc", "ghtml", "gcsdoc", "gcshtml"]

    /// The keyword GAM would read `body` as, or nil when it takes it as the signature. getStringOrFile
    /// (gam/__init__.py:1896-1899) normalizes it as checkArgumentPresent does (:892: strip, lower, `_`
    /// removed); for a keyword it then reads the next argument, `html`, as the file. Refused before a preview.
    public static func readAsKeyword(_ body: String) -> String? {
        let choice = PythonText.string(PythonText.lower(PythonText.strip(body)).unicodeScalars.filter { $0 != "_" })
        return fileKeywords.contains(where: { $0.unicodeScalars.elementsEqual(choice.unicodeScalars) }) ? choice : nil
    }

    // MARK: the preview (design doc D1)

    /// The Rendered view's page policy: nothing loads but HTTPS images (the only images Gmail shows) and
    /// inline styles; no base URL, no form target. GamGUI's sandboxed iframe also allowed `data:` images,
    /// which Gmail refuses.
    public static let previewPolicy =
        "default-src 'none'; img-src https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    /// The page the Rendered view draws: a fixed shell with `previewPolicy` in its head, then `body` as it
    /// is. The policy comes first, so one the body carries can only narrow it. Dark text on white in
    /// Gmail's default font, as a message reads there.
    public static func previewDocument(_ body: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(previewPolicy)\">"
            + "<meta name=\"color-scheme\" content=\"light\">"
            + "<style>html{background:#fff;color:#222}body{margin:8px;font:small Arial,Helvetica,sans-serif}</style>"
            + "</head><body>" + body + "</body></html>"
    }

    /// The rule list the Rendered view compiles once (a WKContentRuleList): every load blocked, then
    /// HTTPS images let through. It says what the page's policy says, and holds for loads a policy
    /// doesn't govern.
    public static let contentRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^https://","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]"#

    /// Python's `str.find`: the first index at or after `from` where `needle` starts.
    static func find(_ needle: [Unicode.Scalar], in text: [Unicode.Scalar], from: Int) -> Int? {
        guard !needle.isEmpty, from <= text.count - needle.count else { return nil }
        for index in from...(text.count - needle.count) where text[index] == needle[0] {
            if text[index..<(index + needle.count)].elementsEqual(needle) { return index }
        }
        return nil
    }
}
