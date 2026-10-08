import Foundation

/// The GAM release this app is built and tested against. `scripts/bump_gam.py` rewrites it, together
/// with `fetch_gam.sh`'s TAG, the mock's `gam version` and the regenerated fixtures; a test fails when
/// any of them disagree.
public enum GamVersion {
    public static let expected = "7.48.22"

    /// The version the bundled `gam` reports, or nil when it can't say. `gam version` needs no
    /// credentials, but it runs in an empty private config directory all the same: without one, GAM
    /// would read and write `~/.gam`.
    public static func running(_ runner: GamRunner, runtimeDirectory: URL) async -> String? {
        guard let config = try? EphemeralConfig.materialize(files: [:], in: runtimeDirectory) else { return nil }
        defer { _ = config.wipe() }
        guard let result = try? await runner.run(["version"], configDirectory: config.url), result.exitCode == 0 else {
            return nil
        }
        return parse(result.stdout)
    }

    /// "7.48.22" from GAM's first line, "GAM 7.48.22 - https://github.com/GAM-team/GAM - pyinstaller".
    static func parse(_ stdout: String) -> String? {
        guard let first = stdout.split(separator: "\n", maxSplits: 1).first else { return nil }
        let words = first.split(separator: " ")
        guard words.count >= 2, words[0] == "GAM" else { return nil }
        return String(words[1])
    }
}
