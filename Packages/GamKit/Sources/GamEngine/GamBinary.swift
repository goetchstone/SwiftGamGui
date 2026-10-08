import Foundation

/// Where the `gam` executable is.
public enum GamBinary {
    /// Debug builds only. Release builds ignore it, so a same-user `launchctl setenv` can't hand the
    /// credentials to another binary (GamGUI's `locate_gam_binary()`, failure-log 2026-09-23).
    public static let overrideVariable = "SWIFTGAMGUI_GAM_BINARY"

    /// The `gam` bundled in the app's resources (`gam7/gam`).
    public static func bundled(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appending(path: "gam7/gam")
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        #if DEBUG
        if let path = environment[overrideVariable], !path.isEmpty {
            return URL(filePath: path)
        }
        #endif
        guard let url = bundled(in: bundle), FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url
    }
}
