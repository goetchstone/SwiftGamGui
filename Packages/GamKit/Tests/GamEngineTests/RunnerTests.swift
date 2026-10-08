import Foundation
import Testing
@testable import GamEngine
import TestSupport

@Suite("GamRunner")
struct RunnerTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    @Test func versionRunsThroughTheMock() async throws {
        let result = try await mock.run(["version"], extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("GAM \(GamVersion.expected) - mock"))
    }

    @Test func anUnhandledArgvFailsTheWayTheMockFailsIt() async throws {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let result = try await mock.run(["no-such-command", "x"], configDirectory: config,
                                        extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("unhandled argv"))
    }

    @Test func anAuthenticatedCallWithoutAConfigDirIsRefused() async throws {
        // The app's own GAMCFGDIR (if any) never leaks through: the environment is allowlisted.
        let result = try await mock.run(["info", "user", "alice@example.com"],
                                        extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("GAMCFGDIR is not set"))
    }

    @Test func eachValueArrivesAsExactlyOneArgument() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "argv-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let argv = ["version", "a b", "semi;colon", "$(touch /tmp/x)", "-dash", "", "Zoë"]
        _ = try await mock.run(argv, extraEnvironment: Fixtures.mockEnvironment
                                .merging(["GAM_MOCK_ARGV_LOG": log.path]) { $1 })
        // The mock logs NUL-separated: the count, then each argument.
        let fields = try String(contentsOf: log, encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false)
        #expect(fields.first == "\(argv.count)")
        #expect(Array(fields.dropFirst().prefix(argv.count)).map(String.init) == argv)
    }

    @Test func onlyAllowlistedVariablesReachGam() {
        let parent = [
            "PATH": "/usr/bin", "HOME": "/Users/example", "LANG": "en_US.UTF-8",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "PYTHONPATH": "/tmp", "_PYI_APPLICATION_HOME_DIR": "/tmp",
            "GAMCFGDIR": "/Users/example/.gam", "SWIFTGAMGUI_GAM_BINARY": "/tmp/gam",
        ]
        let config = URL(filePath: "/private/tmp/gamcfg-test")
        let env = GamEnvironment.build(from: parent, configDirectory: config,
                                       extra: ["DYLD_LIBRARY_PATH": "/tmp", "LC_ALL": "C"])
        #expect(env == [
            "PATH": "/usr/bin", "HOME": "/Users/example", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "GAMCFGDIR": config.path, "GAM_NO_UPDATE_CHECK": "1",
        ])
    }

    @Test func aRunPastItsTimeoutIsStopped() async throws {
        let sleeper = GamRunner(binary: URL(filePath: "/bin/sleep"))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: GamRunnerError.timedOut(seconds: 0)) {
            try await sleeper.run(["30"], timeout: .milliseconds(300))
        }
        #expect(clock.now - started < .seconds(10))
    }

    @Test func outputIsCappedNotUnbounded() async throws {
        let head = GamRunner(binary: URL(filePath: "/usr/bin/head"))
        let result = try await head.run(["-c", "\(GamRunner.outputCap + 1_000_000)", "/dev/zero"])
        #expect(result.exitCode == 0)
        #expect(result.stdoutTruncated)
        #expect(result.stdout.utf8.count == GamRunner.outputCap)
    }

    @Test func quittingStopsARunningChild() async throws {
        // Its own uniquely named script, so it stops only its own child, not other tests' (the app's
        // stopAll() stops every child at quit).
        let script = FileManager.default.temporaryDirectory.appending(path: "long-gam-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        defer { try? FileManager.default.removeItem(at: script) }
        let run = Task { try await GamRunner(binary: script).run([]) }
        let mine = { Set(GamRunner.children.withLock { $0.filter { $0.value == script.path }.keys }) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while mine().isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pids = mine()
        #expect(pids.count == 1)
        GamRunner.stop(pids)
        let result = try await run.value
        #expect(result.exitCode == SIGTERM)
        #expect(pids.allSatisfy { kill($0, 0) != 0 })
    }

    @Test func aMissingBinaryIsReportedNotLaunched() async {
        let missing = GamRunner(binary: URL(filePath: "/nonexistent/gam"))
        await #expect(throws: GamRunnerError.binaryNotExecutable("/nonexistent/gam")) {
            try await missing.run(["version"])
        }
    }
}
