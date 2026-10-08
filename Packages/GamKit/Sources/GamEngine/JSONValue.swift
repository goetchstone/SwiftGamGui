/// A JSON value as Python's `json.loads` reads one, so GAM's output parses into what GamGUI parsed.
/// Numbers keep their text (Python reads integers exactly, however long). `NaN`, `Infinity` and
/// `-Infinity` are accepted, as Python accepts them, and a duplicated key keeps its last value.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number as written: an integer exactly, `NaN`, `Infinity` or `-Infinity` as named.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var double: Double? {
        guard case .number(let text) = self else { return nil }
        return switch text {
        case "NaN": .nan
        case "Infinity": .infinity
        case "-Infinity": -.infinity
        default: Double(text)
        }
    }

    public var int: Int? {
        if case .number(let text) = self { Int(text) } else { nil }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    /// Nesting deeper than this is refused. Python's own limit is the C stack (about 87,000 on this
    /// Mac); a Swift value that deep would overflow the stack when compared or freed, and Google's
    /// data is a few levels deep.
    public static let maximumDepth = 512

    /// `json.loads(text)`, or nil where it raises (including nesting past `maximumDepth`). A lone
    /// surrogate escape (`"\ud800"`), which Python keeps, becomes U+FFFD: a Swift string can't hold one.
    public static func parse(_ text: String) -> JSONValue? {
        var reader = Reader(Array(text.unicodeScalars))
        reader.skipWhitespace()
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.atEnd ? value : nil
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index == scalars.count }
        var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        /// JSON's whitespace only: space, tab, LF, CR.
        mutating func skipWhitespace() {
            while let scalar = current, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
            }
        }

        mutating func take(_ literal: String) -> Bool {
            let target = Array(literal.unicodeScalars)
            guard scalars.count - index >= target.count,
                  scalars[index..<(index + target.count)].elementsEqual(target) else { return false }
            index += target.count
            return true
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard let scalar = current else { return nil }
            switch scalar {
            case "{": return depth < JSONValue.maximumDepth ? object(depth: depth + 1) : nil
            case "[": return depth < JSONValue.maximumDepth ? array(depth: depth + 1) : nil
            case "\"": return string().map(JSONValue.string)
            case "n": return take("null") ? .null : nil
            case "t": return take("true") ? .bool(true) : nil
            case "f": return take("false") ? .bool(false) : nil
            case "N": return take("NaN") ? .number("NaN") : nil
            case "I": return take("Infinity") ? .number("Infinity") : nil
            default:
                if take("-Infinity") { return .number("-Infinity") }
                return number()
            }
        }

        mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if take("}") { return .object(members) }
            while true {
                skipWhitespace()
                guard current == "\"", let key = string() else { return nil }
                skipWhitespace()
                guard take(":") else { return nil }
                skipWhitespace()
                guard let member = value(depth: depth) else { return nil }
                members[key] = member
                skipWhitespace()
                if take("}") { return .object(members) }
                guard take(",") else { return nil }
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var elements: [JSONValue] = []
            skipWhitespace()
            if take("]") { return .array(elements) }
            while true {
                skipWhitespace()
                guard let element = value(depth: depth) else { return nil }
                elements.append(element)
                skipWhitespace()
                if take("]") { return .array(elements) }
                guard take(",") else { return nil }
            }
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`, ASCII digits only.
        mutating func number() -> JSONValue? {
            let start = index
            func digits() -> Int {
                let first = index
                while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
                return index - first
            }
            _ = take("-")
            if take("0") {
            } else if let scalar = current, ("1"..."9").contains(scalar) {
                _ = digits()
            } else {
                index = start
                return nil
            }
            let integerEnd = index
            if take("."), digits() == 0 { index = integerEnd }
            let fractionEnd = index
            if let scalar = current, scalar == "e" || scalar == "E" {
                index += 1
                if let sign = current, sign == "+" || sign == "-" { index += 1 }
                if digits() == 0 { index = fractionEnd }
            }
            return .number(PythonText.string(scalars[start..<index]))
        }

        /// A string at `"`: escapes decoded, a raw control character refused (Python's strict mode).
        mutating func string() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                switch scalar {
                case "\"":
                    return String(out)
                case "\\":
                    guard let escaped = current else { return nil }
                    index += 1
                    switch escaped {
                    case "\"", "\\", "/": out.append(escaped)
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard let unit = hex4() else { return nil }
                        out.append(decode(unit))
                    default: return nil
                    }
                default:
                    guard scalar.value >= 0x20 else { return nil }
                    out.append(scalar)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard scalars.count - index >= 4 else { return nil }
            var value: UInt32 = 0
            for scalar in scalars[index..<(index + 4)] {
                guard let digit = hexDigit(scalar) else { return nil }
                value = value * 16 + digit
            }
            index += 4
            return value
        }

        func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
            switch scalar {
            case "0"..."9": scalar.value - 0x30
            case "a"..."f": scalar.value - 0x61 + 10
            case "A"..."F": scalar.value - 0x41 + 10
            default: nil
            }
        }

        /// A `\u` escape: a high surrogate followed by a `\u` low one is one character; any other
        /// surrogate stands alone and becomes U+FFFD.
        mutating func decode(_ unit: UInt32) -> Unicode.Scalar {
            if (0xD800...0xDBFF).contains(unit) {
                let saved = index
                if take("\\u"), let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                    return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))!
                }
                index = saved
            }
            return Unicode.Scalar(unit) ?? "\u{FFFD}"
        }
    }
}
