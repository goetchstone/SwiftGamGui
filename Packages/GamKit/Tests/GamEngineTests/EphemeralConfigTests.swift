import Darwin
import Foundation
import Testing
@testable import GamEngine

/// The cases GamGUI's tests/test_ephemeral.py holds its materialization to, plus the ones its
/// failure log added (symlinks, FIFOs, a planted sparse file, recycled PIDs).
@Suite("EphemeralConfig", .serialized)
struct EphemeralConfigTests {
    let base: URL

    init() throws {
        base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o777
    }

    private func gamcfgDirs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("gamcfg-") }
    }

    private func sentinel() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sentinel-\(UUID().uuidString)")
        try Data("keep me".utf8).write(to: url)
        return url
    }

    @Test func filesArePrivateAndCarryTheOwnerPID() throws {
        let config = try EphemeralConfig.materialize(files: ["oauth2.txt": Data("token".utf8)], in: base)
        defer { config.wipe() }
        #expect(mode(config.url) == 0o700)
        #expect(mode(config.url.appending(path: "oauth2.txt")) == 0o600)
        #expect(try Data(contentsOf: config.url.appending(path: "oauth2.txt")) == Data("token".utf8))
        let marker = try String(contentsOf: config.url.appending(path: EphemeralConfig.pidFileName), encoding: .utf8)
        #expect(marker == "\(getpid())")
    }

    @Test func aPathInAFileNameIsRefused() {
        for name in ["../oauth2.txt", "a/b", "..", ""] {
            #expect(throws: EphemeralConfig.Failure.invalidFileName(name)) {
                try EphemeralConfig.materialize(files: [name: Data()], in: base)
            }
        }
    }

    @Test func anUnsafeRuntimeDirectoryIsRefused() throws {
        let open = FileManager.default.temporaryDirectory.appending(path: "open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let link = FileManager.default.temporaryDirectory.appending(path: "link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        defer { try? FileManager.default.removeItem(at: open); try? FileManager.default.removeItem(at: link) }
        for unsafe in [open, link] {
            #expect(throws: EphemeralConfig.Failure.unsafeRuntimeDirectory(unsafe.path)) {
                try EphemeralConfig.materialize(files: [:], in: unsafe)
            }
        }
    }

    @Test func wipeRemovesEverythingGamLeavesIncludingItsSubfolders() throws {
        let config = try EphemeralConfig.materialize(files: ["oauth2.txt": Data("t".utf8)], in: base)
        let cache = config.url.appending(path: "gamcache/nested")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appending(path: "f"))
        #expect(config.wipe())
        #expect(!FileManager.default.fileExists(atPath: config.url.path))
        #expect(EphemeralConfig.live.withLock { !$0.contains(config.url.path) })
        #expect(config.wipe(), "wiping twice is harmless")
    }

    @Test func wipeNeverFollowsASymlink() throws {
        let outside = try sentinel()
        defer { try? FileManager.default.removeItem(at: outside) }
        let config = try EphemeralConfig.materialize(files: [:], in: base)
        try FileManager.default.createSymbolicLink(at: config.url.appending(path: "oauth2.txt"),
                                                   withDestinationURL: outside)
        #expect(config.wipe())
        #expect(try Data(contentsOf: outside) == Data("keep me".utf8))
    }

    @Test func aFIFOCannotHangTheWipe() throws {
        let config = try EphemeralConfig.materialize(files: [:], in: base)
        #expect(mkfifo(config.url.appending(path: "oauth2.txt").path, 0o600) == 0)
        #expect(config.wipe())
    }

    @Test func aPlantedHugeSparseFileIsRemovedQuickly() throws {
        let config = try EphemeralConfig.materialize(files: [:], in: base)
        let path = config.url.appending(path: "huge").path
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        #expect(ftruncate(fd, 256 << 20) == 0)
        close(fd)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(config.wipe())
        #expect(clock.now - started < .seconds(5))
    }

    @Test func readFileRefusesALinkAndAnOversizedFile() throws {
        let outside = try sentinel()
        defer { try? FileManager.default.removeItem(at: outside) }
        let config = try EphemeralConfig.materialize(files: ["big": Data(count: 100)], in: base)
        defer { config.wipe() }
        try FileManager.default.createSymbolicLink(at: config.url.appending(path: "oauth2.txt"),
                                                   withDestinationURL: outside)
        #expect(config.readFile("oauth2.txt") == nil)
        #expect(config.readFile("big", cap: 10) == nil)
        #expect(config.readFile("big")?.count == 100)
    }

    @Test func theTerminationBackstopWipesWhatWasLeft() throws {
        let config = try EphemeralConfig.materialize(files: ["oauth2.txt": Data("t".utf8)], in: base)
        #expect(EphemeralConfig.wipeAllLive(under: base).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: config.url.path))
    }

    // MARK: sweep

    private func orphan(named name: String, pid: String?, ageSeconds: TimeInterval) throws -> URL {
        let dir = base.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("secret".utf8).write(to: dir.appending(path: "oauth2service.json"))
        if let pid {
            try Data(pid.utf8).write(to: dir.appending(path: EphemeralConfig.pidFileName))
        }
        let when = Date().addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: dir.path)
        return dir
    }

    private func deadPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func theSweepRemovesOrphansAndSparesTheLiving() throws {
        let dead = try orphan(named: "gamcfg-dead", pid: "\(try deadPID())", ageSeconds: 5)
        let alive = try orphan(named: "gamcfg-alive", pid: "\(getpid())", ageSeconds: 5)
        let ancient = try orphan(named: "gamcfg-ancient", pid: "\(getpid())", ageSeconds: 2 * 24 * 3600)
        let oldUnmarked = try orphan(named: "gamcfg-old", pid: nil, ageSeconds: 3600)
        let youngUnmarked = try orphan(named: "gamcfg-young", pid: nil, ageSeconds: 5)
        let groupPID = try orphan(named: "gamcfg-group", pid: "0", ageSeconds: 5)
        let inUse = try EphemeralConfig.materialize(files: [:], in: base)
        defer { inUse.wipe() }

        let target = FileManager.default.temporaryDirectory.appending(path: "target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep me".utf8).write(to: target.appending(path: "oauth2.txt"))
        try FileManager.default.createSymbolicLink(at: base.appending(path: "gamcfg-link"), withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: target) }

        #expect(EphemeralConfig.sweepStale(in: base) == 3)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(!exists(dead) && !exists(ancient) && !exists(oldUnmarked))
        #expect(exists(alive) && exists(youngUnmarked) && exists(inUse.url))
        #expect(exists(groupPID), "a pid of 0 is not a trusted owner, but an unmarked young dir waits")
        #expect(try Data(contentsOf: target.appending(path: "oauth2.txt")) == Data("keep me".utf8))
    }
}
