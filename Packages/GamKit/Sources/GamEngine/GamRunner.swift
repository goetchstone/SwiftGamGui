import Foundation
import Synchronization

public struct GamResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
}

public enum GamRunnerError: Error, Equatable, Sendable {
    case binaryNotExecutable(String)
    case launchFailed(String)
    /// An argument or environment value GAM can't receive (a NUL byte).
    case invalidArgument(String)
    /// The run outlived its timeout and was stopped; it may have done part of its work.
    case timedOut(seconds: Int64)
}

/// Runs `gam` as a child process: an explicit argv (invariant 1, never a shell), sent as exact bytes
/// (invariant 11), the allowlisted
/// environment, a timeout, and output capture bounded per stream.
///
/// Credentials, write serialization and auditing sit above this type (Vault, ChangeCore); it only
/// executes.
public struct GamRunner: Sendable {
    public static let defaultTimeout: Duration = .seconds(120)
    /// One `all users …` call visits every user in turn; GamGUI's 120 s default killed such sweeps.
    public static let domainWideTimeout: Duration = .seconds(3600)
    public static let outputCap = 8 * 1024 * 1024
    static let terminationGrace: Duration = .seconds(5)

    public let binary: URL

    /// Every `gam` this process started that hasn't exited, so quitting can stop them: a child left
    /// running keeps acting on the tenant with nothing tracking it (GamGUI failure-log 2026-09-23).
    /// pid → executable path.
    static let children = Mutex<[pid_t: String]>([:])

    public init(binary: URL) {
        self.binary = binary
    }

    /// Stops every running child: SIGTERM, then SIGKILL for any still running after `grace`. Blocks;
    /// call at app termination, before `EphemeralConfig.wipeAllLive()`.
    public static func stopAll(grace: Duration = .seconds(2)) {
        stop(Set(children.withLock { $0.keys }), grace: grace)
    }

    /// Stops the given children (only ones this process started): SIGTERM, then SIGKILL after `grace`.
    static func stop(_ pids: Set<pid_t>, grace: Duration = .seconds(2)) {
        let mine = pids.intersection(children.withLock { $0.keys })
        guard !mine.isEmpty else { return }
        for pid in mine { kill(pid, SIGTERM) }
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while clock.now < deadline, !children.withLock({ Set($0.keys).isDisjoint(with: mine) }) {
            usleep(50_000)
        }
        for pid in mine.intersection(children.withLock { $0.keys }) { kill(pid, SIGKILL) }
    }

    public func run(
        _ argv: [String],
        configDirectory: URL? = nil,
        timeout: Duration = GamRunner.defaultTimeout,
        extraEnvironment: [String: String] = [:]
    ) async throws -> GamResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw GamRunnerError.binaryNotExecutable(binary.path)
        }
        let environment = GamEnvironment.build(from: ProcessInfo.processInfo.environment,
                                               configDirectory: configDirectory, extra: extraEnvironment)
        let (pid, outRead, errRead) = try Self.spawn(binary.path, argv, environment)
        Self.children.withLock { $0[pid] = binary.path }

        let exit = ExitSignal()
        Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            Self.children.withLock { _ = $0.removeValue(forKey: pid) }
            // Exited: its code. Killed by a signal: the signal's number (Foundation's convention).
            exit.finish(status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f)
        }.start()

        let outBuffer = CappedBuffer(cap: Self.outputCap)
        let errBuffer = CappedBuffer(cap: Self.outputCap)
        async let outDrained: Void = Self.drain(outRead, into: outBuffer)
        async let errDrained: Void = Self.drain(errRead, into: errBuffer)
        let status = await withTaskCancellationHandler {
            await Self.wait(for: exit, pid: pid, timeout: timeout)
        } onCancel: {
            kill(pid, SIGTERM)
        }
        _ = await outDrained
        _ = await errDrained

        try Task.checkCancellation()
        guard let status else {
            throw GamRunnerError.timedOut(seconds: timeout.components.seconds)
        }
        let (out, outCut) = outBuffer.contents()
        let (err, errCut) = errBuffer.contents()
        return GamResult(
            exitCode: status,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            stdoutTruncated: outCut,
            stderrTruncated: errCut
        )
    }

    /// Starts the child with `posix_spawn`, not Foundation's `Process`: `Process` passes arguments
    /// through the file-system representation, which decomposes "é" into "e" + U+0301 and aborts the
    /// app on a NUL. Here every argument and environment value goes to `gam` as its exact UTF-8 bytes
    /// (invariant 11), and a NUL is a thrown error. Only stdin (`/dev/null`), stdout and stderr are
    /// inherited; signal dispositions and the mask are reset.
    private static func spawn(_ path: String, _ argv: [String], _ environment: [String: String]) throws
        -> (pid: pid_t, out: Int32, err: Int32) {
        let entries = environment.map { "\($0.key)=\($0.value)" }
        for value in [path] + argv + entries where value.utf8.contains(0) {
            throw GamRunnerError.invalidArgument("contains a NUL byte")
        }
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw GamRunnerError.launchFailed("pipe: errno \(errno)") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw GamRunnerError.launchFailed("pipe: errno \(errno)")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        var defaults = sigset_t.max   // every signal back to its default disposition
        var mask = sigset_t(0)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes,
                                 Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let cArgv = ([path] + argv).map { strdup($0) } + [nil]
        let cEnv = entries.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, cArgv, cEnv)
        close(out[1])
        close(err[1])
        guard status == 0 else {
            close(out[0]); close(err[0])
            throw GamRunnerError.launchFailed("posix_spawn: errno \(status)")
        }
        return (pid, out[0], err[0])
    }

    private enum Outcome: Sendable {
        case exited(Int32)
        case timerFired
        case killed
    }

    /// The exit status, or nil when the timeout fired first (the process is then stopped: SIGTERM, and
    /// SIGKILL after a grace period).
    private static func wait(for exit: ExitSignal, pid: pid_t, timeout: Duration) async -> Int32? {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .exited(await exit.wait()) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timerFired
            }
            if case .exited(let status) = await group.next() {
                group.cancelAll()
                return status
            }
            kill(pid, SIGTERM)
            group.addTask {
                try? await Task.sleep(for: terminationGrace)
                kill(pid, SIGKILL)
                return .killed
            }
            while let outcome = await group.next() {
                if case .exited = outcome {
                    group.cancelAll()
                    break
                }
            }
            return nil
        }
    }

    /// Reads a pipe to EOF on a dedicated thread (a blocking read must not hold a cooperative-pool
    /// thread), keeping at most the buffer's cap, then closes it. `read(2)` reports errors as values;
    /// `FileHandle`'s reads raise an Objective-C exception that would kill the app.
    private static func drain(_ fd: Int32, into buffer: CappedBuffer) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                    if n > 0 {
                        buffer.append(Data(chunk[0..<n]))
                    } else if n < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                done.resume()
            }.start()
        }
    }
}

/// A single-use exit status that one waiter can await.
final class ExitSignal: Sendable {
    private struct State {
        var status: Int32?
        var waiter: CheckedContinuation<Int32, Never>?
    }

    private let state = Mutex(State())

    func finish(_ status: Int32) {
        let waiter = state.withLock { state -> CheckedContinuation<Int32, Never>? in
            guard state.status == nil else { return nil }
            state.status = status
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Output kept up to `cap` bytes; the rest is read and dropped so the child never blocks on a full pipe.
final class CappedBuffer: Sendable {
    private struct State {
        var data = Data()
        var truncated = false
    }

    private let state = Mutex(State())
    let cap: Int

    init(cap: Int) {
        self.cap = cap
    }

    func append(_ chunk: Data) {
        state.withLock { state in
            let room = cap - state.data.count
            if chunk.count > room {
                state.data.append(chunk.prefix(max(room, 0)))
                state.truncated = true
            } else {
                state.data.append(chunk)
            }
        }
    }

    func contents() -> (Data, Bool) {
        state.withLock { ($0.data, $0.truncated) }
    }
}
