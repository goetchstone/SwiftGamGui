import Foundation

/// Where the `gam` executable is.
public enum GamBinary {
    /// The strict mock, for debug builds' demo and spikes only: `AppServices.mockGam` reads it and holds it to
    /// the mock script. `locate` never reads it, in any build: it is the real-Keychain path, and a leftover scheme
    /// variable or a same-user `launchctl setenv` would hand both credentials to a program of its choosing
    /// (GamGUI's `locate_gam_binary()`, failure-log 2026-09-23; here 2026-11-18).
    public static let overrideVariable = "SWIFTGAMGUI_GAM_BINARY"

    /// The `gam` bundled in the app's resources (`gam7/gam`), copied and signed at build time by
    /// `scripts/embed_gam.sh` (Xcode's "Embed GAM" phase).
    public static func bundled(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appending(path: "gam7/gam")
    }

    /// The bundled binary, or nil when it isn't there or isn't executable. Nothing in the environment changes it.
    public static func locate(bundle: Bundle = .main) -> URL? {
        guard let url = bundled(in: bundle), FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url
    }
}
