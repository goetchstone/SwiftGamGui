/// The reads in flight for a store that keeps one result per key (a person's lists, a group's members).
/// Each read takes a serial number when it starts. A key is reading while any of its reads is out, so one read
/// leaving (finished, or cancelled while it waited) never ends another's: a page in a second window
/// arrowed past a group left the first window's page at "Not read." while its read still ran (PR #35's
/// review). Which result to keep is the store's: the one with the later serial.
struct ReadsInFlight<Key: Hashable> {
    private var running: [Key: Set<Int>] = [:]
    private var issued = 0

    mutating func start(_ key: Key) -> Int {
        issued += 1
        running[key, default: []].insert(issued)
        return issued
    }

    mutating func end(_ key: Key, _ serial: Int) {
        running[key]?.remove(serial)
        if running[key]?.isEmpty == true { running[key] = nil }
    }

    func isRunning(_ key: Key) -> Bool {
        running[key] != nil
    }
}
