import Foundation
import Testing
@testable import GamEngine
import TestSupport

@Suite("GamRunner")
struct RunnerTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    @Test func versionRunsThroughTheMock() async throws {
        let result = try await mock.runRaw(["version"], extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("GAM \(GamVersion.expected) - mock"))
    }

    @Test func anUnhandledArgvFailsTheWayTheMockFailsIt() async throws {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let result = try await mock.runRaw(["no-such-command", "x"], configDirectory: config,
                                        extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("unhandled argv"))
    }

    @Test func anAuthenticatedCallWithoutAConfigDirIsRefused() async throws {
        // The app's own GAMCFGDIR (if any) never leaks through: the environment is allowlisted.
        let result = try await mock.runRaw(["info", "user", "alice@example.com"],
                                        extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("GAMCFGDIR is not set"))
    }

    @Test func eachValueArrivesAsExactlyOneArgument() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "argv-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        // Precomposed and decomposed "é" must arrive as the different bytes they are.
        let argv = ["version", "a b", "semi;colon", "$(touch /tmp/x)", "-dash", "", "Zo\u{EB}", "e\u{301}"]
        _ = try await mock.runRaw(argv, extraEnvironment: Fixtures.mockEnvironment
                                .merging(["GAM_MOCK_ARGV_LOG": log.path]) { $1 })
        // The mock logs NUL-separated: the count, then each argument.
        let fields = try Data(contentsOf: log).split(separator: 0, omittingEmptySubsequences: false).map(Array.init)
        #expect(fields.first == Array("\(argv.count)".utf8))
        #expect(Array(fields.dropFirst().prefix(argv.count)) == argv.map { Array($0.utf8) })
    }

    @Test func aNULIsAnErrorNotACrash() async {
        await #expect(throws: GamRunnerError.invalidArgument("contains a NUL byte")) {
            try await mock.runRaw(["version", "admin@example.com\0"])
        }
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

    /// The timeout stops the process: a 10-minute sleep ends long before it would. The bound is wall time, as it must
    /// be, but far from both ends, so a busy CI runner can't cross it (failure-log 2026-10-20), and on `SuspendingClock`,
    /// so a Mac asleep mid-test doesn't either (failure-log 2026-10-25).
    @Test func aRunPastItsTimeoutIsStopped() async throws {
        let sleeper = GamRunner(binary: URL(filePath: "/bin/sleep"))
        let clock = SuspendingClock()
        let started = clock.now
        await #expect(throws: GamRunnerError.timedOut(seconds: 0)) {
            try await sleeper.runRaw(["600"], timeout: .milliseconds(300))
        }
        #expect(clock.now - started < .seconds(60))
    }

    @Test func outputIsCappedNotUnbounded() async throws {
        let head = GamRunner(binary: URL(filePath: "/usr/bin/head"))
        let result = try await head.runRaw(["-c", "\(GamRunner.outputCap + 1_000_000)", "/dev/zero"])
        #expect(result.exitCode == 0)
        #expect(result.stdoutTruncated)
        #expect(result.stdout.utf8.count == GamRunner.outputCap)
    }

    /// Stopping a running child cuts its run off. The child is looked for for up to 60 s and sleeps 600 s, far from both
    /// ends, so a busy CI runner that starts it late still finds it running (failure-log 2026-11-03).
    @Test func quittingStopsARunningChild() async throws {
        // Its own uniquely named script, so it stops only its own child, not other tests' (the app's
        // stopAll() stops every child at quit).
        let script = FileManager.default.temporaryDirectory.appending(path: "long-gam-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexec /bin/sleep 600\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        defer { try? FileManager.default.removeItem(at: script) }
        let run = Task { try await GamRunner(binary: script).runRaw([]) }
        defer { run.cancel() }   // a child never found isn't left sleeping
        let mine = { Set(GamRunner.children.withLock { $0.filter { $0.value == script.path }.keys }) }
        try await yieldWhile(every: .milliseconds(20)) { mine().isEmpty }
        let pids = mine()
        try #require(pids.count == 1)
        GamRunner.stop(pids)
        // Cut off, as a cancelled run is: never a failure of gam's own with SIGTERM's exit code.
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(pids.allSatisfy { kill($0, 0) != 0 })
        #expect(GamRunner.stopped.withLock { $0.isDisjoint(with: pids) }, "nothing kept once read")
    }

    @Test func aMissingBinaryIsReportedNotLaunched() async {
        let missing = GamRunner(binary: URL(filePath: "/nonexistent/gam"))
        await #expect(throws: GamRunnerError.binaryNotExecutable("/nonexistent/gam")) {
            try await missing.runRaw(["version"])
        }
    }

    // A cut-off takes gam's workers with it (failure-log 2026-11-28, GamGUI #197). GAM's parallel loops (`csv`, `batch`,
    // auto-batch) fork workers that each load the credentials; killing gam alone left them running while the directory was
    // wiped, and since they hold gam's pipes, the run waited them out: a "timed out" run went on to its end. The stand-in
    // forks a worker that sleeps 600 s and records its pid; each run must return far sooner, and the worker must be gone.
    // The bounds are far from both ends, on `SuspendingClock` (failure-log 2026-10-20 and 2026-10-25).

    /// A stand-in gam that forks a long-lived worker, records its pid in `pidFile`, then `then` (waits on it, or exits).
    private func gamWithAWorker(then: String) throws -> (gam: GamRunner, pidFile: URL, cleanUp: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gam-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appending(path: "worker.pid"), script = dir.appending(path: "gam")
        try Data("#!/bin/sh\n/bin/sleep 600 &\necho $! > '\(pidFile.path)'\n\(then)\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        return (GamRunner(binary: script), pidFile, { try? FileManager.default.removeItem(at: dir) })
    }

    private func worker(_ pidFile: URL) throws -> pid_t {
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text), "the stand-in never recorded its worker")
    }

    /// Gone, once launchd has reaped it (a killed orphan is a zombie for a moment, and `kill(_, 0)` still finds a zombie).
    private func expectGone(_ pid: pid_t, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await yieldWhile(every: .milliseconds(20), sourceLocation: sourceLocation) { kill(pid, 0) == 0 }
    }

    @Test func aTimeoutStopsGamsWorkersToo() async throws {
        let (gam, pidFile, cleanUp) = try gamWithAWorker(then: "wait")
        defer { cleanUp() }
        let clock = SuspendingClock(), started = clock.now
        await #expect(throws: GamRunnerError.timedOut(seconds: 5)) { try await gam.runRaw([], timeout: .seconds(5)) }
        #expect(clock.now - started < .seconds(60), "the run waited out gam's worker")
        try await expectGone(try worker(pidFile))
    }

    @Test func aCancelStopsGamsWorkersToo() async throws {
        let (gam, pidFile, cleanUp) = try gamWithAWorker(then: "wait")
        defer { cleanUp() }
        let run = Task { try await gam.runRaw([]) }
        defer { run.cancel() }
        try await yieldWhile(every: .milliseconds(20)) { (try? worker(pidFile)) == nil }
        let pid = try worker(pidFile)
        let clock = SuspendingClock(), started = clock.now
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(clock.now - started < .seconds(60), "the cancel waited out gam's worker")
        try await expectGone(pid)
    }

    /// Stronger than GamGUI, which kills the group only on a cut-off: whatever is left in gam's group when gam exits is
    /// killed too, so a worker gam left behind can't run on, or hold the pipes open, after its run.
    @Test func whatGamLeavesRunningWhenItExitsIsStopped() async throws {
        let (gam, pidFile, cleanUp) = try gamWithAWorker(then: "exit 0")
        defer { cleanUp() }
        let clock = SuspendingClock(), started = clock.now
        let result = try await gam.runRaw([])
        #expect(result.exitCode == 0)
        #expect(clock.now - started < .seconds(60), "the run waited out the worker gam left behind")
        try await expectGone(try worker(pidFile))
    }
}
