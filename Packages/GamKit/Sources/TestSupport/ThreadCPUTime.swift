import Darwin

/// The CPU time this thread spends in `body`. A test that bounds how long pure code takes measures this, never wall time:
/// a busy CI runner's other work once stretched 0.1 s to 9 s (failure-log 2026-10-16), and a Mac that slept mid-test put
/// 872 s on `ContinuousClock` for a 4 s read (failure-log 2026-10-25). A bound on blocking or waiting stays wall time, since a
/// thread that's stuck spends no CPU, on `SuspendingClock`, which stops while the Mac sleeps.
public func threadCPUTime(_ body: () -> Void) -> Duration {
    func now() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }
    let start = now()
    body()
    return now() - start
}
