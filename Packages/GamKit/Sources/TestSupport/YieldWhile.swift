import Testing

/// Waits while `condition` holds, for at most `limit`, then records the issue at the caller and throws. The one way a test waits:
/// `TestWaitsTests` fails a test's own `Task.sleep` or `Task.yield` unless its line says why it isn't a wait.
///
/// A test that waits for a model to show a state (`isLoading`, `isRunning`) can miss it: a run that ends before its first
/// suspension sets and clears the flag between two looks. An unbounded `while … { await Task.yield() }` then spins forever, and
/// local suites sat in two such loops for two days (failure log 2026-11-24). The limit is far from the moment the state should
/// take, and on `SuspendingClock`, which stops while the Mac sleeps.
///
/// Between looks it yields, or sleeps `pause` when what it waits for is another process or a file (a fake `gam` starting), so
/// the wait doesn't spin a core the other process needs. It runs on the caller's actor, so `condition` reads the caller's state.
public func yieldWhile(
    isolation: isolated (any Actor)? = #isolation, every pause: Duration? = nil, upTo limit: Duration = .seconds(60),
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool
) async throws {
    let clock = SuspendingClock(), deadline = clock.now + limit
    while try await condition() {
        guard clock.now < deadline else {
            Issue.record("still waiting after \(limit)", sourceLocation: sourceLocation)
            throw WaitedTooLong()
        }
        if let pause { try await Task.sleep(for: pause) } else { await Task.yield() }
    }
}

/// What `yieldWhile` throws past its limit; the issue it recorded says where.
public struct WaitedTooLong: Error {}
