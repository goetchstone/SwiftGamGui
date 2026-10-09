import Foundation

/// The repo's shared fixtures (`Tests/Fixtures`), found from this source file's location, so the package
/// tests and the app's tests read the same files.
public enum Fixtures {
    /// `<repo>/Packages/GamKit/Sources/TestSupport/Fixtures.swift` → `<repo>`.
    public static let repoRoot: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    public static var directory: URL { repoRoot.appending(path: "Tests/Fixtures") }
    public static var mockGam: URL { directory.appending(path: "mock_gam.sh") }
    public static var mockGamData: URL { directory.appending(path: "mock_gam") }
    public static var argvJSON: URL { directory.appending(path: "argv.json") }
    public static var exitCodesJSON: URL { directory.appending(path: "exit_codes.json") }
    public static var gamErrorsJSON: URL { directory.appending(path: "gam_errors.json") }
    public static var gamOutputJSON: URL { directory.appending(path: "gam_output.json") }
    public static var setupJSON: URL { directory.appending(path: "setup.json") }
    public static var vacationJSON: URL { directory.appending(path: "vacation.json") }
    public static var gamModelsJSON: URL { directory.appending(path: "gam_models.json") }
    public static var guardJSON: URL { directory.appending(path: "guard.json") }
    public static var auditJSON: URL { directory.appending(path: "audit.json") }
    public static var reportsJSON: URL { directory.appending(path: "reports.json") }
    public static var catalogJSON: URL { repoRoot.appending(path: "Vendor/gam7/command_catalog.json") }
    public static var fetchScript: URL { repoRoot.appending(path: "scripts/fetch_gam.sh") }

    /// The mock's own environment: where its canned output lives.
    public static var mockEnvironment: [String: String] {
        ["GAM_MOCK_FIXTURES": mockGamData.path]
    }

    /// A fresh temp dir holding placeholder credential files. The mock only checks that they exist and
    /// aren't empty; nothing real is ever written here.
    public static func placeholderConfigDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for name in ["oauth2service.json", "oauth2.txt"] {
            try Data("{\"placeholder\": true}".utf8).write(to: dir.appending(path: name))
        }
        return dir
    }
}
