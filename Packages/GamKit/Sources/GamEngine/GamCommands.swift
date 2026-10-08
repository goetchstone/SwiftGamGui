/// GAM argv builders: Swift ports of GamGUI's `GAMCommands` (`core/gam/commands.py`). Each returns the
/// argv **byte-identical** to GamGUI's live-proven builder for the same inputs, held to
/// `Tests/Fixtures/argv.json` by `GoldenArgvTests` (invariants 1 and 11). Every operator value is one
/// element; nothing is ever joined into a command line.
public enum GamCommands {
    public enum Invalid: Error, Equatable, Sendable {
        case argument(String)
    }

    public static func version() -> [String] {
        ["version"]
    }

    /// Verifies domain-wide delegation for exactly `scopes`:
    /// `gam <UserTypeEntity> check serviceaccount (scope|scopes <APIScopeURLList>)*`, the list one
    /// comma-joined element. Without it GAM checks its own, larger default set and refuses an operator
    /// who authorized only the scopes the app asked for (GamGUI failure-log 2026-09-25). The noun is
    /// `serviceaccount` here, though GAM says `create svcacct`.
    public static func checkServiceAccount(admin: String, scopes: [String]) throws -> [String] {
        guard !scopes.isEmpty else { throw Invalid.argument("check_svcacct needs the scopes to check") }
        return ["user", admin, "check", "serviceaccount", "scopes", scopes.joined(separator: ",")]
    }
}
