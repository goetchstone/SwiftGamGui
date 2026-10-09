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
}
