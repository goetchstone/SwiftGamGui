/// GamGUI's `looks_like_email` (`core/onboarding.py`): a non-empty local part, one `@`, a dotted domain,
/// no comma and no whitespace (Python's `\s`), after Python's `strip()`. A write that takes an address
/// checks it first: GAM reads a bare name (`oauthuser`), `@domain` or a comma-joined `<UserList>` as
/// something else (the authorizing admin, several accounts). Held to `Tests/Fixtures/setup.json`.
public enum Address {
    public static func looksLikeEmail(_ value: String) -> Bool {
        let scalars = Array(PythonText.strip(value).unicodeScalars)
        func plain(_ part: ArraySlice<Unicode.Scalar>, allowingDot: Bool) -> Bool {
            !part.isEmpty && part.allSatisfy { scalar in
                scalar != "@" && scalar != "," && (allowingDot || scalar != ".")
                    && !PythonText.whitespace.contains(scalar.value)
            }
        }
        guard let at = scalars.firstIndex(of: "@"), plain(scalars[..<at], allowingDot: true) else { return false }
        let labels = scalars[(at + 1)...].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { plain($0, allowingDot: false) }
    }

    /// An IP address as GAM's `ip` filter takes it, one argv element: IPv4's digits and dots, or IPv6's hex digits and
    /// colons (and the dots of an embedded IPv4), nothing else.
    public static func isIP(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 45, scalars.allSatisfy({ $0.isASCII && ($0.properties.isASCIIHexDigit || $0 == "." || $0 == ":") })
        else { return false }
        if text.contains(":") { return text.filter { $0 == ":" }.count >= 2 }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255 }
    }
}
