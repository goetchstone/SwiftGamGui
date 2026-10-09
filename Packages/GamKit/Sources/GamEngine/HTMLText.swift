/// GamGUI's auto-reply text helpers (`core/lifecycle.py`): `autoreply_html`, the text an operator typed as
/// the HTML body GAM sends, and `autoreply_text`, its inverse for a form pre-filled from `show vacation`.
/// They rest on Python's `html.unescape` and `html.parser.HTMLParser` (CPython 3.14, the one that runs
/// GamGUI), ported here as far as these helpers use them, scalar for scalar (Python indexes code points).
/// Held to Tests/Fixtures/vacation.json, generated from GamGUI by scripts/gen_fixtures.py.
public enum HTMLText {
    typealias Scalars = [Unicode.Scalar]

    // MARK: autoreply_html

    /// Each line break as `<br/>`, `&`/`<`/`>` escaped (`html.escape(quote=False)`), a backslash as `&#92;`.
    public static func autoreplyHTML(_ text: String) -> String {
        var out = String.UnicodeScalarView(), scalars = Array(text.unicodeScalars), index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\r":
                if index < scalars.count, scalars[index] == "\n" { index += 1 }
                out.append(contentsOf: "<br/>".unicodeScalars)
            case "\n": out.append(contentsOf: "<br/>".unicodeScalars)
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\\": out.append(contentsOf: "&#92;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: autoreply_text

    /// An HTML body back to its text (each `<br>` a line break, a `div`/`p`/`li` edge a new line, other tags
    /// dropped, references unescaped); anything else is plain text, kept as it is (stripped).
    public static func autoreplyText(_ body: String) -> String {
        guard looksLikeHTML(body) else { return PythonText.strip(body) }
        var parser = Parser(Array(body.unicodeScalars))
        parser.run()
        return PythonText.strip(PythonText.string(parser.text.out))
    }

    /// GamGUI's `_looks_like_html`: an email tag written as a tag, or an entity that stands for something.
    static func looksLikeHTML(_ body: String) -> Bool {
        let scalars = Array(body.unicodeScalars)
        return BodyTag.found(in: scalars) || entityStandsForSomething(in: scalars)
    }

    // MARK: html.unescape

    /// Python's `html.unescape`.
    public static func unescape(_ text: String) -> String {
        PythonText.string(unescape(Array(text.unicodeScalars)))
    }

    static func unescape(_ scalars: Scalars) -> Scalars {
        guard scalars.contains("&") else { return scalars }
        var out: Scalars = [], index = 0
        while index < scalars.count {
            guard scalars[index] == "&", let end = charrefEnd(scalars, from: index + 1) else {
                out.append(scalars[index])
                index += 1
                continue
            }
            out += replaceCharref(Array(scalars[(index + 1)..<end]))
            index = end
        }
        return out
    }

    /// The end of `_charref`'s group after `&`: `#[0-9]+;?`, `#[xX][0-9a-fA-F]+;?` or `[^\t\n\f <&#;]{1,32};?`.
    private static func charrefEnd(_ s: Scalars, from start: Int) -> Int? {
        var index = start
        func semicolon() -> Int { index < s.count && s[index] == ";" ? index + 1 : index }
        if index < s.count, s[index] == "#" {
            index += 1
            if index < s.count, isDigit(s[index]) {
                while index < s.count, isDigit(s[index]) { index += 1 }
                return semicolon()
            }
            if index + 1 < s.count, s[index] == "x" || s[index] == "X", isHex(s[index + 1]) {
                index += 1
                while index < s.count, isHex(s[index]) { index += 1 }
                return semicolon()
            }
            return nil
        }
        let excluded: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", " ", "<", "&", "#", ";"]
        while index < s.count, index - start < 32, !excluded.contains(s[index]) { index += 1 }
        guard index > start else { return nil }
        return semicolon()
    }

    private static func replaceCharref(_ s: Scalars) -> Scalars {
        if s.first == "#" {
            let hex = s.count > 1 && (s[1] == "x" || s[1] == "X")
            let digits = s.dropFirst(hex ? 2 : 1).prefix { $0 != ";" }
            // Python's int() has no ceiling: anything past U+10FFFF is the replacement character anyway.
            var number: UInt64 = 0
            for digit in digits {
                number = min(number * (hex ? 16 : 10) + UInt64(hexValue(digit)), 0x1_0000_0000)
            }
            if let remapped = PythonHTMLTables.invalidCharrefs[UInt32(truncatingIfNeeded: number)], number <= 0xFFFF_FFFF {
                return Array(remapped.unicodeScalars)
            }
            if (0xD800...0xDFFF).contains(number) || number > 0x10FFFF { return ["\u{FFFD}"] }
            if PythonHTMLTables.invalidCodepoints.contains(UInt32(number)) { return [] }
            return [Unicode.Scalar(UInt32(number))!]
        }
        let name = PythonText.string(s)
        if let value = PythonHTMLTables.html5[name] { return Array(value.unicodeScalars) }
        // The longest name that prefixes it (the standard's rule for a reference missing its `;`).
        if s.count > 2 {
            for length in stride(from: s.count - 1, through: 2, by: -1) {
                if let value = PythonHTMLTables.html5[PythonText.string(s[..<length])] {
                    return Array(value.unicodeScalars) + s[length...]
                }
            }
        }
        return ["&"] + s
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
    }
    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar {
        case "0"..."9": scalar.value - 0x30
        case "a"..."f": scalar.value - 0x61 + 10
        default: scalar.value - 0x41 + 10
        }
    }

    /// `_BODY_ENTITY` (`&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);`), each match checked as GamGUI
    /// checks it: does `html.unescape` change it?
    private static func entityStandsForSomething(in s: Scalars) -> Bool {
        var index = 0
        while index < s.count {
            guard s[index] == "&", let end = bodyEntityEnd(s, from: index + 1) else {
                index += 1
                continue
            }
            let match = Array(s[index..<end])
            if unescape(match) != match { return true }
            index = end
        }
        return false
    }

    private static func bodyEntityEnd(_ s: Scalars, from start: Int) -> Int? {
        var index = start
        func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        if index < s.count, s[index] == "#" {
            index += 1
            if index < s.count, isDigit(s[index]) {
                while index < s.count, isDigit(s[index]) { index += 1 }
            } else if index + 1 < s.count, s[index] == "x" || s[index] == "X", isHex(s[index + 1]) {
                index += 1
                while index < s.count, isHex(s[index]) { index += 1 }
            } else {
                return nil
            }
        } else if index < s.count, isLetter(s[index]) {
            while index < s.count, isLetter(s[index]) || isDigit(s[index]) { index += 1 }
        } else {
            return nil
        }
        return index < s.count && s[index] == ";" ? index + 1 : nil
    }
}

// MARK: - _BODY_TAG

/// GamGUI's `_BODY_TAG`, searched case-insensitively (Python's `re.IGNORECASE`, which also matches four
/// non-ASCII letters to ASCII ones):
/// `</?(?:names)(?:\s+[a-z][\w:-]*\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'<>=`]+))*\s*/?>`.
enum BodyTag {
    static let names = ["a", "b", "blockquote", "body", "br", "center", "code", "del", "div", "em", "font",
                        "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "html", "i", "img", "ins", "li", "meta",
                        "ol", "p", "pre", "s", "small", "span", "strike", "strong", "style", "sub", "sup", "table",
                        "tbody", "td", "th", "thead", "tr", "tt", "u", "ul"].map { Array($0.unicodeScalars) }

    static func found(in original: [Unicode.Scalar]) -> Bool {
        let s = original.map(PythonText.folded)
        for start in s.indices where s[start] == "<" {
            var index = start + 1
            if index < s.count, s[index] == "/" { index += 1 }
            for name in names where s.count >= index + name.count && s[index..<(index + name.count)].elementsEqual(name) {
                if tail(s, original, index + name.count) { return true }
            }
        }
        return false
    }

    /// `(?:attribute)*\s*/?>` from `index`.
    private static func tail(_ s: [Unicode.Scalar], _ original: [Unicode.Scalar], _ index: Int) -> Bool {
        if ends(s, index) { return true }
        for next in attributeEnds(s, original, index) where tail(s, original, next) { return true }
        return false
    }

    private static func ends(_ s: [Unicode.Scalar], _ start: Int) -> Bool {
        var index = start
        while index < s.count, PythonText.isSpace(s[index]) { index += 1 }
        if index < s.count, s[index] == "/" { index += 1 }
        return index < s.count && s[index] == ">"
    }

    /// Every place one `\s+[a-z][\w:-]*\s*=\s*(value)` can end, starting at `start`.
    private static func attributeEnds(_ s: [Unicode.Scalar], _ original: [Unicode.Scalar], _ start: Int) -> [Int] {
        var index = start
        while index < s.count, PythonText.isSpace(s[index]) { index += 1 }
        guard index > start, index < s.count, ("a"..."z").contains(s[index]) else { return [] }
        index += 1
        while index < s.count, PythonText.isWord(original[index]) || s[index] == ":" || s[index] == "-" { index += 1 }
        while index < s.count, PythonText.isSpace(s[index]) { index += 1 }
        guard index < s.count, s[index] == "=" else { return [] }
        index += 1
        while index < s.count, PythonText.isSpace(s[index]) { index += 1 }
        guard index < s.count else { return [] }
        if s[index] == "\"" || s[index] == "'" {
            let quote = s[index]
            guard let close = s[(index + 1)...].firstIndex(of: quote) else { return [] }
            return [close + 1]
        }
        let excluded: Set<Unicode.Scalar> = ["\"", "'", "<", ">", "=", "`"]
        var end = index
        while end < s.count, !PythonText.isSpace(s[end]), !excluded.contains(s[end]) { end += 1 }
        return end > index ? Array((index + 1)...end).reversed() : []
    }
}

// MARK: - HTMLParser, as autoreply_text drives it

extension HTMLText {
    /// GamGUI's `_BodyText`: the text, with `<br>` a line break and a `div`/`p`/`li` edge a new line.
    struct BodyText {
        var out: [Unicode.Scalar] = []
        /// Whether anything was handed over yet, and whether the last piece ended in a line break: Python's
        /// `self.out and not self.out[-1].endswith("\n")`, where a piece can be empty.
        private var pieces = 0
        private var lastEndsInNewline = false

        mutating func data(_ piece: ArraySlice<Unicode.Scalar>) {
            out += piece
            pieces += 1
            lastEndsInNewline = piece.last == "\n"
        }

        mutating func newLine() {
            if pieces > 0, !lastEndsInNewline { data(["\n"]) }
        }

        mutating func start(_ tag: String) {
            if tag == "br" { data(["\n"]) } else if ["div", "p", "li"].contains(tag) { newLine() }
        }

        mutating func end(_ tag: String) {
            if ["div", "p", "li"].contains(tag) { newLine() }
        }
    }

    /// CPython 3.14's `HTMLParser(convert_charrefs=True)`, fed the whole body and closed: `goahead(end=True)`.
    struct Parser {
        let r: [Unicode.Scalar]
        var text = BodyText()
        private var cdataElem: [Unicode.Scalar]?
        private var escapable = true

        static let cdataContent = ["script", "style", "xmp", "iframe", "noembed", "noframes"]
        static let rcdataContent = ["textarea", "title"]

        init(_ r: [Unicode.Scalar]) { self.r = r }

        private var n: Int { r.count }

        private func startsWith(_ prefix: String, _ i: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            return i + p.count <= n && r[i..<(i + p.count)].elementsEqual(p)
        }

        private func isASCIILetter(_ i: Int) -> Bool {
            i < n && (("a"..."z").contains(r[i]) || ("A"..."Z").contains(r[i]))
        }

        private func find(_ target: String, from start: Int) -> Int? {
            let t = Array(target.unicodeScalars)
            guard start <= n - t.count else { return nil }
            return (start...(n - t.count)).first { r[$0..<($0 + t.count)].elementsEqual(t) }
        }

        private mutating func emit(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            text.data(escapable ? ArraySlice(HTMLText.unescape(Array(r[range]))) : r[range])
        }

        mutating func run() {
            var i = 0
            while i < n {
                var j: Int
                if cdataElem == nil {
                    if let k = find("<", from: i) {
                        j = k
                    } else {
                        // A reference cut at the end would wait for more text; at the end it is handled below.
                        let from = max(i, n - 34)
                        if let amp = (from..<n).last(where: { r[$0] == "&" }),
                           !r[amp...].contains(where: { ["\t", "\n", "\r", "\u{0C}", " ", ";"].contains($0) }) {
                            break
                        }
                        j = n
                    }
                } else {
                    guard let k = cdataEnd(from: i) else { break }
                    j = k
                }
                if i < j { emit(i..<j) }
                i = j
                if i == n { break }
                var k: Int
                if isASCIILetter(i + 1) {
                    k = parseStartTag(i)
                } else if startsWith("</", i) {
                    k = parseEndTag(i)
                } else if startsWith("<!--", i) {
                    k = parseComment(i)
                } else if startsWith("<?", i) {
                    k = parsePI(i)
                } else if startsWith("<!", i) {
                    k = parseHTMLDeclaration(i)
                } else {
                    text.data(["<"])
                    k = i + 1
                }
                if k < 0 {
                    if !isASCIILetter(i + 1), startsWith("</", i), i + 2 == n {
                        text.data(["<", "/"])
                    }
                    // Anything else unterminated (a tag, a comment, a declaration) is dropped with the rest.
                    k = n
                }
                i = k
            }
            if i < n { emit(i..<n) }
        }

        /// `</elem(?=[\t\n\r\f />])`, ASCII case-insensitively; `plaintext` runs to the end.
        private func cdataEnd(from start: Int) -> Int? {
            guard let elem = cdataElem else { return nil }
            if elem.elementsEqual("plaintext".unicodeScalars) { return n }
            let length = 2 + elem.count
            guard start + length < n else { return nil }
            for i in start...(n - length - 1) where r[i] == "<" && r[i + 1] == "/" {
                let name = r[(i + 2)..<(i + length)].map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 0x20)! : $0 }
                if name.elementsEqual(elem), ["\t", "\n", "\r", "\u{0C}", " ", "/", ">"].contains(r[i + length]) { return i }
            }
            return nil
        }

        private static let space: Set<Unicode.Scalar> = ["\t", "\n", "\r", "\u{0C}", " "]

        /// `locatetagend` from `p` (the tag name's first letter): the end of the match.
        private func locateTagEnd(_ p: Int) -> Int {
            var q = p + 1
            while q < n, !Self.space.contains(r[q]), r[q] != "/", r[q] != ">" { q += 1 }
            while q < n, Self.space.contains(r[q]) || r[q] == "/" { q += 1 }
            while q < n, ["'", "\"", "\t", "\n", "\r", "\u{0C}", " ", "/"].contains(r[q - 1]),
                  !Self.space.contains(r[q]), r[q] != "/", r[q] != ">" {
                q += 1
                while q < n, !Self.space.contains(r[q]), r[q] != "/", r[q] != "=", r[q] != ">" { q += 1 }
                q = value(after: q, bareStopsAtSlash: false) ?? q
                while q < n, Self.space.contains(r[q]) || r[q] == "/" { q += 1 }
            }
            if q < n, r[q] == ">" { q += 1 }
            return q
        }

        /// The optional `[\t\n\r\f ]*=[\t\n\r\f ]*(value)` group from `start`: its end, or nil if it fails.
        private func value(after start: Int, bareStopsAtSlash: Bool) -> Int? {
            var q = start
            while q < n, Self.space.contains(r[q]) { q += 1 }
            guard q < n, r[q] == "=" else { return nil }
            q += 1
            while q < n, Self.space.contains(r[q]) { q += 1 }
            if q < n, r[q] == "'" || r[q] == "\"" {
                let quote = r[q]
                guard let close = r[(q + 1)...].firstIndex(of: quote) else { return nil }
                return close + 1
            }
            while q < n, r[q] != ">", !Self.space.contains(r[q]) { q += 1 }
            return q
        }

        /// `tagfind_tolerant` from `p`: the lowercased name and the end of the match.
        private func tagFind(_ p: Int) -> (String, Int) {
            var q = p + 1
            while q < n, !Self.space.contains(r[q]), r[q] != "/", r[q] != ">" { q += 1 }
            let name = PythonText.lower(PythonText.string(r[p..<q]))
            return (name, skipSpaceOrLoneSlash(q))
        }

        /// `(?:[\t\n\r\f ]|/(?!>))*`.
        private func skipSpaceOrLoneSlash(_ start: Int) -> Int {
            var q = start
            while q < n, Self.space.contains(r[q]) || (r[q] == "/" && !(q + 1 < n && r[q + 1] == ">")) { q += 1 }
            return q
        }

        /// `attrfind_tolerant` at `k`: the end of the match, or nil.
        private func attrFind(_ k: Int) -> Int? {
            guard k < n, ["'", "\"", "\t", "\n", "\r", "\u{0C}", " ", "/"].contains(r[k - 1]),
                  !Self.space.contains(r[k]), r[k] != "/", r[k] != ">" else { return nil }
            var q = k + 1
            while q < n, !Self.space.contains(r[q]), r[q] != "/", r[q] != "=", r[q] != ">" { q += 1 }
            q = value(after: q, bareStopsAtSlash: false) ?? q
            return skipSpaceOrLoneSlash(q)
        }

        private mutating func parseStartTag(_ i: Int) -> Int {
            let endpos = locateTagEnd(i + 1)
            guard r[endpos - 1] == ">" else { return -1 }
            var (tag, k) = tagFind(i + 1)
            while k < endpos, let next = attrFind(k) { k = next }
            let end = PythonText.strip(PythonText.string(r[k..<endpos]))
            guard end == ">" || end == "/>" else {
                text.data(r[i..<endpos])
                return endpos
            }
            text.start(tag)
            if end == "/>" {
                text.end(tag)
            } else if Self.cdataContent.contains(tag) || tag == "plaintext" {
                cdataElem = Array(tag.unicodeScalars)
                escapable = false
            } else if Self.rcdataContent.contains(tag) {
                cdataElem = Array(tag.unicodeScalars)
                escapable = true
            }
            return endpos
        }

        private mutating func parseEndTag(_ i: Int) -> Int {
            guard find(">", from: i + 2) != nil else { return -1 }
            guard isASCIILetter(i + 2) else {
                if r[i + 2] == ">" { return i + 3 }
                return parseBogusComment(i)
            }
            let j = locateTagEnd(i + 2)
            guard r[j - 1] == ">" else { return -1 }
            text.end(tagFind(i + 2).0)
            cdataElem = nil
            escapable = true
            return j
        }

        /// `--!?>` anywhere after `<!--`, else `-?>` right after it.
        private func parseComment(_ i: Int) -> Int {
            var q = i + 4
            while q < n {
                if startsWith("--!>", q) { return q + 4 }
                if startsWith("-->", q) { return q + 3 }
                q += 1
            }
            if startsWith("->", i + 4) { return i + 6 }
            if startsWith(">", i + 4) { return i + 5 }
            return -1
        }

        private func parseBogusComment(_ i: Int) -> Int {
            guard let close = find(">", from: i + 2) else { return -1 }
            return close + 1
        }

        private func parsePI(_ i: Int) -> Int {
            guard let close = find(">", from: i + 2) else { return -1 }
            return close + 1
        }

        private func parseHTMLDeclaration(_ i: Int) -> Int {
            if startsWith("<!--", i) { return parseComment(i) }
            if startsWith("<![CDATA[", i) {
                guard let close = find("]]>", from: i + 9) else { return -1 }
                return close + 3
            }
            if PythonText.lower(PythonText.string(r[i..<min(i + 9, n)])) == "<!doctype" {
                guard let close = find(">", from: i + 9) else { return -1 }
                return close + 1
            }
            return parseBogusComment(i)
        }
    }
}
