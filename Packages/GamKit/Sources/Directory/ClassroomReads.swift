import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Classroom screen's reads, read only (plan 2026-11-11 C1.3; GamGUI's `web/routes/classroom.py` at 3c8d909): the index
/// of open classes, a teacher's classes, and one class's card (its record and roster). Each is kept for the tenant and
/// generation it was read under, so a switch never shows one domain's classes as another's, and only the last few
/// teachers and cards are kept (invariant 9). Nothing here writes.
@MainActor
@Observable
public final class ClassroomReads {
    public typealias Problem = UserAccess.Problem

    /// The index: every active and not-yet-accepted class, read without `owneremail` (owners are named from the directory
    /// as cached, by ID): one domain-wide read, made once per tenant until Refresh.
    public static let indexStates: [GamCommands.CourseState] = [.active, .provisioned]
    /// A teacher's classes: last year's archived ones too.
    public static let teacherStates: [GamCommands.CourseState] = [.active, .provisioned, .archived]
    /// A failed index read is said again, not re-run, for this long: on a domain without Classroom each look at the screen
    /// would otherwise run a domain-wide read that could only fail. Refresh reads at once.
    public static let retryAfter: TimeInterval = 60
    /// People listed on each side of a class's card, with a count past it (invariant 9).
    public static let rosterShown = 200

    public enum State<Value: Sendable>: Sendable {
        case reading
        case read(Result<Value, Problem>)

        public var value: Value? { if case .read(.success(let value)) = self { value } else { nil } }
        public var problem: Problem? { if case .read(.failure(let problem)) = self { problem } else { nil } }
        public var isReading: Bool { if case .reading = self { true } else { false } }
    }

    /// One class's card: its record and its roster, read side by side.
    public struct Card: Sendable {
        public var course: State<Classroom.Course>
        public var roster: State<Classroom.Roster>
    }

    private struct Tenant: Equatable {
        let domain: Domain
        let generation: Int
    }

    private struct Index {
        let tenant: Tenant
        let serial: Int
        var state: State<[Classroom.Course]>
        var finished: Date?
    }

    private struct Kept<Value> {
        let key: String
        let tenant: Tenant
        let serial: Int
        var value: Value
    }

    private var index: Index?
    private var teachers: [Kept<State<[Classroom.Course]>>] = []
    private var cards: [Kept<Card>] = []
    private var serial = 0
    private let keep: Int
    private let setup: SetupModel
    private let access: UserAccess
    @ObservationIgnored private let now: @MainActor () -> Date

    public init(setup: SetupModel, access: UserAccess, keep: Int = 8, now: @escaping @MainActor () -> Date = Date.init) {
        self.setup = setup
        self.access = access
        self.keep = keep
        self.now = now
    }

    private var tenant: Tenant? { setup.active.map { Tenant(domain: $0, generation: setup.generation) } }

    // MARK: the index

    /// The index's state for the connected tenant; nil before it is first read.
    public var indexState: State<[Classroom.Course]>? {
        guard let index, index.tenant == tenant else { return nil }
        return index.state
    }

    /// When the index in hand was read.
    public var indexReadAt: Date? {
        guard let index, index.tenant == tenant, index.state.value != nil else { return nil }
        return index.finished
    }

    /// Reads the index unless the connected tenant's is in hand, being read, or failed under a minute ago; `force` (Refresh,
    /// Try Again) reads at once.
    public func loadIndex(force: Bool = false) async {
        guard let tenant else { return }
        if !force, let index, index.tenant == tenant {
            switch index.state {
            case .reading, .read(.success): return
            case .read(.failure):
                if let finished = index.finished, now().timeIntervalSince(finished) < Self.retryAfter { return }
            }
        }
        serial += 1
        let mine = serial
        let before = index?.tenant == tenant ? index : nil
        index = Index(tenant: tenant, serial: mine, state: .reading, finished: nil)
        let result = await access.courses(states: Self.indexStates, ownerEmail: false, in: tenant.domain)
        guard index?.serial == mine, index?.tenant == tenant else { return }
        // Stopped (the screen left mid-read): nothing was read, so what was in hand stays (a Refresh's index), or nothing,
        // and the next look reads again.
        guard !Task.isCancelled else { index = before.flatMap { $0.state.isReading ? nil : $0 }; return }
        index = Index(tenant: tenant, serial: mine, state: .read(result), finished: now())
    }

    /// The index's classes whose name, section or room holds `text` (case aside), all of them for none.
    public func indexed(matching text: String) -> [Classroom.Course]? {
        indexState?.value.map { Classroom.matching($0, text) }
    }

    // MARK: a teacher's classes

    public func teacher(_ address: String) -> State<[Classroom.Course]>? {
        let key = Self.key(address)
        return teachers.first { $0.key == key && $0.tenant == tenant }?.value
    }

    /// Reads a teacher's classes, archived ones too, with their owners' addresses. Only when asked (Return), never as typed.
    public func readTeacher(_ address: String) async {
        guard let tenant else { return }
        let key = Self.key(address)
        serial += 1
        let mine = serial
        store(&teachers, Kept(key: key, tenant: tenant, serial: mine, value: .reading))
        let result = await access.courses(teacher: address, states: Self.teacherStates, in: tenant.domain)
        guard teachers.first(where: { $0.key == key && $0.tenant == tenant })?.serial == mine else { return }
        guard !Task.isCancelled else { teachers.removeAll { $0.serial == mine }; return }
        store(&teachers, Kept(key: key, tenant: tenant, serial: mine, value: .read(result)))
    }

    // MARK: a class's card

    public func card(_ courseID: String) -> Card? {
        cards.first { $0.key == courseID && $0.tenant == tenant }?.value
    }

    /// Reads one class's record (with its owner's address) and its roster, side by side: each time the class is opened, as
    /// GamGUI's card is, so a failure or a changed roster is read again.
    public func readCard(_ courseID: String) async {
        guard let tenant else { return }
        serial += 1
        let mine = serial
        store(&cards, Kept(key: courseID, tenant: tenant, serial: mine, value: Card(course: .reading, roster: .reading)))
        async let course = access.course(courseID, in: tenant.domain)
        async let roster = access.roster(courseID, in: tenant.domain)
        let card = Card(course: .read(await course), roster: .read(await roster))
        guard cards.first(where: { $0.key == courseID && $0.tenant == tenant })?.serial == mine else { return }
        guard !Task.isCancelled else { cards.removeAll { $0.serial == mine }; return }
        store(&cards, Kept(key: courseID, tenant: tenant, serial: mine, value: card))
    }

    /// Owner ID → address, from the directory as already cached (the index is read without `owneremail`): each person's
    /// Google account ID (`accountID`, never `GamUser.id`, which is the address), the first person kept for an ID.
    public static func owners(_ users: [GamUser]) -> [String: String] {
        Dictionary(users.compactMap { user in user.accountID.map { ($0, user.primaryEmail) } }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: keeping

    /// A teacher's address as Google compares it.
    static func key(_ address: String) -> String { PythonText.lower(PythonText.strip(address)) }

    /// Keeps `entry` first, drops what another tenant read, and keeps at most `keep`.
    private func store<Value>(_ list: inout [Kept<Value>], _ entry: Kept<Value>) {
        list.removeAll { $0.key == entry.key || $0.tenant != entry.tenant }
        list.insert(entry, at: 0)
        if list.count > keep { list.removeLast(list.count - keep) }
    }
}
