/// Python's reading of text, for code that must decide exactly as GamGUI's Python did: `str.isspace`,
/// `str.strip`, `str.splitlines`, and `re`'s `\w`, `\d` and IGNORECASE against an ASCII pattern. Scalar
/// by scalar, never by `Character` or Foundation's sets, which differ (Foundation's whitespace lacks
/// U+001C to U+001F; a `Character` can hold several scalars). Held to Python's own tables by the
/// fixtures' constants.
package enum PythonText {
    /// `str.isspace()`.
    package static let whitespace: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// Where `str.splitlines()` breaks; `"\r\n"` is one break.
    package static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]

    /// The non-ASCII characters `re.IGNORECASE` matches to an ASCII letter: dotted and dotless I, the
    /// long s and the Kelvin sign.
    package static let foldsToASCII: [UInt32: Unicode.Scalar] = [0x130: "i", 0x131: "i", 0x17F: "s", 0x212A: "k"]

    /// The Unicode version of the Python GamGUI runs on (`unicodedata.unidata_version`, held to the
    /// fixtures). Swift's is newer, and a character added since is unassigned to Python: neither a
    /// letter nor a digit, so a word boundary before it there. Read as a letter, one let an echoed
    /// password past the scrub (PR #5's review: U+10940, new in Unicode 17).
    package static let unicodeVersion: Unicode.Version = (major: 16, minor: 0)

    /// Assigned in `unicodeVersion`.
    package static func knownToPython(_ scalar: Unicode.Scalar) -> Bool {
        guard let age = scalar.properties.age else { return false }
        return age.major < unicodeVersion.major || (age.major == unicodeVersion.major && age.minor <= unicodeVersion.minor)
    }

    package static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        whitespace.contains(scalar.value)
    }

    /// `re`'s `\w` for a `str` pattern: a letter or a number by general category, or `_`.
    package static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        guard knownToPython(scalar) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return scalar == "_"
        }
    }

    /// `re`'s `\d` for a `str` pattern: a decimal digit of any script.
    package static func isDecimal(_ scalar: Unicode.Scalar) -> Bool {
        knownToPython(scalar) && scalar.properties.generalCategory == .decimalNumber
    }

    /// What `re.IGNORECASE` compares an ASCII pattern against: ASCII letters lowercased, and the four
    /// characters it matches to an ASCII letter mapped to it. One scalar for one, so positions carry over.
    package static func folded(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if ("A"..."Z").contains(scalar) { return Unicode.Scalar(scalar.value + 0x20)! }
        return foldsToASCII[scalar.value] ?? scalar
    }

    /// `str.strip()`.
    package static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) })
        else { return "" }
        return string(scalars[first...last])
    }

    /// `str.splitlines()`.
    package static func lines(_ text: String) -> [String] {
        var lines: [String] = [], current = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator(), pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            guard lineBreaks.contains(scalar.value) else {
                current.append(scalar)
                continue
            }
            if scalar == "\r", pending == "\n" { pending = scalars.next() }
            lines.append(String(current))
            current = String.UnicodeScalarView()
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    package static func string<Scalars: Sequence<Unicode.Scalar>>(_ scalars: Scalars) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
