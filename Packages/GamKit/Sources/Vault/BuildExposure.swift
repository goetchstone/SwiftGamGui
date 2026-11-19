/// Whether Home warns that the running build is debuggable (plan 2026-11-18, S4). A debuggable build carries
/// `get-task-allow`, so another process of the same user could read the credentials out of its memory; the daily
/// build (the GamGUI Daily scheme) doesn't. The demo never holds real credentials, so it never warns, and CI's
/// screenshots don't change. The app reads `debuggable` from its own signature (`BuildSafety`).
public enum BuildExposure {
    public static func warns(debuggable: Bool, demo: Bool) -> Bool { debuggable && !demo }
}
