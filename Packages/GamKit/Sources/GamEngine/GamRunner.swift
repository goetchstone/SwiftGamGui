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
    /// The run outlived its timeout and was stopped; it may have done part of its work.
    case timedOut(seconds: Int64)
}

/// Runs `gam` as a child process: an explicit argv (invariant 1, never a shell), the allowlisted
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
        let process = Process()
        process.executableURL = binary
        process.arguments = argv
        process.environment = GamEnvironment.build(
            from: ProcessInfo.processInfo.environment,
            configDirectory: configDirectory,
            extra: extraEnvironment
        )
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exit = ExitSignal()
        process.terminationHandler = { finished in
            Self.children.withLock { _ = $0.removeValue(forKey: finished.processIdentifier) }
            exit.finish(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw GamRunnerError.launchFailed(String(describing: error))
        }
        let pid = process.processIdentifier
        if process.isRunning {
            Self.children.withLock { $0[pid] = binary.path }
        }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let outBuffer = CappedBuffer(cap: Self.outputCap)
        let errBuffer = CappedBuffer(cap: Self.outputCap)
        async let outDrained: Void = Self.drain(outPipe.fileHandleForReading, into: outBuffer)
        async let errDrained: Void = Self.drain(errPipe.fileHandleForReading, into: errBuffer)
        let status = await withTaskCancellationHandler {
            await Self.wait(for: exit, pid: pid, timeout: timeout)
        } onCancel: {
            kill(pid, SIGTERM)
        }
        _ = await outDrained
        _ = await errDrained
        // Keeps the Process alive until its handler has run; the object must outlive the child.
        _ = process.terminationReason

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
    /// thread), keeping at most the buffer's cap.
    private static func drain(_ handle: FileHandle, into buffer: CappedBuffer) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let reader = Thread {
                while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                }
                done.resume()
            }
            reader.start()
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
