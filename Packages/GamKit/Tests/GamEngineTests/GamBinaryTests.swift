import Foundation
import Testing
import GamEngine

/// The real-Keychain path runs the bundled `gam` and nothing else (failure-log 2026-11-18): the override that the
/// demo and spikes use (`AppServices.mockGam`) never reaches `locate`, debug build or not.
@Suite("GamBinary")
struct GamBinaryTests {
    /// A folder bundle holding an executable `gam7/gam`, as the app's resources do.
    static func bundleWithGam() throws -> (bundle: Bundle, gam: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-binary-\(UUID().uuidString).bundle")
        let gam = root.appending(path: "gam7/gam")
        try FileManager.default.createDirectory(at: gam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: gam)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gam.path)
        return (try #require(Bundle(url: root)), gam)
    }

    @Test func theOverrideNeverPicksTheBinary() throws {
        let (bundle, gam) = try Self.bundleWithGam()
        defer { try? FileManager.default.removeItem(at: gam.deletingLastPathComponent().deletingLastPathComponent()) }
        // The process's own environment, as a leftover scheme variable or `launchctl setenv` would set it. Nothing else
        // in the suite reads this variable (the runner's allowlist drops it), so setting it here can't disturb a test.
        setenv(GamBinary.overrideVariable, "/bin/echo", 1)
        defer { unsetenv(GamBinary.overrideVariable) }
        let located = try #require(GamBinary.locate(bundle: bundle))
        #expect(located.resolvingSymlinksInPath().path == gam.resolvingSymlinksInPath().path)
    }

    @Test func noBundledGamIsNoGam() {
        setenv(GamBinary.overrideVariable, "/bin/echo", 1)
        defer { unsetenv(GamBinary.overrideVariable) }
        let empty = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-binary-empty-\(UUID().uuidString).bundle")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(GamBinary.locate(bundle: Bundle(url: empty)!) == nil)
    }
}
