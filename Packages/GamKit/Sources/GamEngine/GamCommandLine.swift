/// GamGUI's `command_line` (`core/lifecycle.py`): an argv as the `gam …` line the operator reads before a
/// run. Each element is shell-quoted so its bounds show (a subject with spaces is one argument), a value
/// after a sensitive keyword is masked as the audit masks it, and GAM's own password keywords (`password
/// random`) are shown as they run: GAM makes that password, so there is nothing secret in the word. Display
/// only: nothing is ever run through a shell. Held to Tests/Fixtures/offboarding.json; compared by Unicode
/// scalars, as Python compares, never by `Character`.
public enum GamCommandLine {
    /// GAM's password generators (grammar `<UserBasicAttribute>`): keywords, not secrets.
    public static let passwordKeywords = ["random", "uniquerandom", "blocklogin", "prompt", "uniqueprompt"]

    /// `argv` with only the positional masks (`ArgvRedaction`), as GamGUI's `command_line` masks it.
    public static func text(_ argv: [String]) -> String {
        text(argv, masked: ArgvRedaction.redact(argv))
    }

    /// `argv` shown with `masked`'s values (the same argv with its sensitive values masked), except a
    /// password keyword straight after `password`, which is shown as it is.
    public static func text(_ argv: [String], masked: [String]) -> String {
        precondition(argv.count == masked.count, "masked is the same argv, masked")
        let shown = argv.indices.map { index in
            index > 0 && same(PythonText.lower(argv[index - 1]), "password")
                && passwordKeywords.contains { same(argv[index], $0) } ? argv[index] : masked[index]
        }
        return "gam " + shown.map(quote).joined(separator: " ")
    }

    /// GamGUI's `_quote`: `shlex.quote`, except that an element holding an apostrophe goes in POSIX double
    /// quotes (with `\`, `"`, `$` and a backtick escaped), which reads far better than `'"'"'`.
    static func quote(_ element: String) -> String {
        let scalars = element.unicodeScalars
        if !scalars.contains("'") {
            if scalars.isEmpty { return "''" }
            return scalars.allSatisfy(isShellSafe) ? element : "'" + element + "'"
        }
        var quoted = String.UnicodeScalarView(["\""])
        for scalar in scalars {
            if ["\\", "\"", "$", "`"].contains(scalar) { quoted.append("\\") }
            quoted.append(scalar)
        }
        quoted.append("\"")
        return String(quoted)
    }

    /// `shlex`'s safe characters (`[\w@%+=:,./-]` under `re.ASCII`): left unquoted.
    static func isShellSafe(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "_@%+=:,./-".unicodeScalars.contains(scalar))
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }
}
