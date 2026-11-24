import Testing

/// Yields while `condition` holds, for at most `limit`, then records the issue at the caller and throws.
///
/// A test that waits for a model to show a state (`isLoading`, `isRunning`) can miss it: a run that ends before its first
/// suspension sets and clears the flag between two looks. An unbounded `while … { await Task.yield() }` then spins forever, and
/// local suites sat in two such loops for two days (failure log 2026-11-24). The limit is far from the moment the state should
/// take, and on `SuspendingClock`, which stops while the Mac sleeps.
@MainActor
public func yieldWhile(
    _ condition: () -> Bool, upTo limit: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let clock = SuspendingClock(), deadline = clock.now + limit
    while condition() {
        guard clock.now < deadline else {
            Issue.record("still waiting after \(limit)", sourceLocation: sourceLocation)
            throw WaitedTooLong()
        }
        await Task.yield()
    }
}

/// What `yieldWhile` throws past its limit; the issue it recorded says where.
public struct WaitedTooLong: Error {}
