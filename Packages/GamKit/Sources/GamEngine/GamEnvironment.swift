import Foundation

/// The environment `gam` runs with: an allowlist, never the app's whole environment.
///
/// Copied from GamGUI's `core/gam/runner.py` `ENV_ALLOWLIST`. GamGUI once copied all of `os.environ`,
/// so `DYLD_*`, `PYTHON*` or a parent PyInstaller's `_PYI_*` reached the frozen interpreter that holds
/// the credentials (failure-log 2026-09-23). Exact names only, never a prefix match.
public enum GamEnvironment {
    public static let allowlist: Set<String> = [
        "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "USER",
        "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
    ]

    /// Read only by `Tests/Fixtures/mock_gam.sh` (real GAM ignores them); passed in debug builds only.
    public static let mockOnly: Set<String> = [
        "GAM_MOCK_FIXTURES", "GAM_MOCK_REFRESH", "GAM_MOCK_ARGV_LOG", "GAM_MOCK_STATE",
    ]

    static var passthrough: Set<String> {
        #if DEBUG
        allowlist.union(mockOnly)
        #else
        allowlist
        #endif
    }

    /// `parent` and `extra` are both filtered: a caller can't add a variable the allowlist doesn't name.
    public static func build(
        from parent: [String: String],
        configDirectory: URL?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let allowed = passthrough
        var env = parent.filter { allowed.contains($0.key) }
        for (key, value) in extra where allowed.contains(key) {
            env[key] = value
        }
        if let configDirectory {
            env["GAMCFGDIR"] = configDirectory.path
        }
        env["GAM_NO_UPDATE_CHECK"] = "1"
        return env
    }
}
