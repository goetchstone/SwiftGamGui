import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The calendar reads the Calendars screen and a person's Calendar tab make, each when it is first needed
/// (GamGUI reads them on every open): the rooms, a person's calendar list, a calendar's rules by ID (GamGUI's
/// admin form) and a person's primary calendar's rules (its user form). GroupMembers' reviewed shape: each
/// read is kept for the tenant and generation it was read under, so a switch never shows one tenant's
/// calendars as another's, and only the last sixteen are kept (invariant 9). Every read is GamGUI's builder,
/// run with the default timeout as GamGUI runs it.
@MainActor
@Observable
public final class CalendarReads {
    public typealias Problem = DirectoryStore.Problem

    /// Reads kept by default: enough for a list and a page in each of a few windows.
    public static let kept = 16

    public enum Read: Hashable, Sendable {
        /// `print resources` (GamGUI's `list_resources`).
        case rooms
        /// `user <person> print calendars` (`list_user_calendars`).
        case calendars(of: String)
        /// `calendars <id> print calendaracls` (`list_calendar_acls_for`, the Calendars screen).
        case access(calendar: String)
        /// `user <person> print calendaracls primary` (`list_calendar_acls`, the person page).
        case primaryAccess(of: String)

        /// As `Guard` compares addresses, so `ALICE@` is `alice@`; Google compares calendar IDs that way too.
        var key: Read {
            switch self {
            case .rooms: .rooms
            case .calendars(let person): .calendars(of: Guard.normalized(person))
            case .access(let calendar): .access(calendar: Guard.normalized(calendar))
            case .primaryAccess(let person): .primaryAccess(of: Guard.normalized(person))
            }
        }

        /// GamGUI's builder for it.
        var command: GamRead {
            switch self {
            case .rooms: GamCommands.printResources()
            case .calendars(let person): GamCommands.printUserCalendars(email: person)
            case .access(let calendar): GamCommands.printCalendarACLs(calendarID: calendar)
            case .primaryAccess(let person): GamCommands.printCalendarACLs(email: person)
            }
        }

        /// What it reads, in words for a problem.
        var noun: String {
            switch self {
            case .rooms: "rooms"
            case .calendars: "calendars"
            case .access, .primaryAccess: "access rules"
            }
        }
    }

    /// What a read found.
    enum Found: Sendable {
        case rooms([ResourceCalendar])
        case calendars([UserCalendar])
        case access([CalendarACL])
    }

    private struct Key: Hashable {
        let read: Read
        let domain: Domain
        let generation: Int
    }

    private struct Loaded {
        let key: Key
        /// Which read this is: a screen announcing a load's outcome keys on it.
        let revision: Int
        /// When the read started: a slower, older read of the same thing never replaces it.
        let serial: Int
        let result: Result<Found, Problem>
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    /// The reads in hand, newest first, for the connected tenant only. Bounded (invariant 9).
    private var loaded: [Loaded] = []
    private var reading = ReadsInFlight<Key>()
    private let keep: Int
    @ObservationIgnored private var revisions = 0
    /// Tests only: the mock's state folder, so a read sees what a write just changed.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?, keep: Int = CalendarReads.kept) {
        self.setup = setup
        self.runner = runner
        self.keep = keep
    }

    private func key(_ read: Read) -> Key? {
        setup.active.map { Key(read: read.key, domain: $0, generation: setup.generation) }
    }

    private func current(_ read: Read) -> Loaded? {
        guard let key = key(read) else { return nil }
        return loaded.first { $0.key == key }
    }

    private func found(_ read: Read) -> Found? {
        guard let loaded = current(read), case .success(let found) = loaded.result else { return nil }
        return found
    }

    /// A read of it for the connected tenant is waiting or running.
    public func isReading(_ read: Read) -> Bool {
        key(read).map { reading.isRunning($0) } ?? false
    }

    /// The rooms, in GAM's order, while they belong to the connected tenant.
    public func rooms() -> [ResourceCalendar]? {
        if case .rooms(let rooms) = found(.rooms) { return rooms }
        return nil
    }

    /// GamGUI's room search over the rooms read (`ResourceCalendar.search`).
    public func rooms(matching query: String) -> [ResourceCalendar]? {
        rooms().map { ResourceCalendar.search($0, query: query) }
    }

    /// A person's calendars, in GAM's order; GamGUI lists only those with an ID.
    public func calendars(of person: String) -> [UserCalendar]? {
        if case .calendars(let calendars) = found(.calendars(of: person)) { return calendars }
        return nil
    }

    /// A calendar's rules (`.access` or `.primaryAccess`), in GAM's order; empty when it has none (exit 60).
    public func access(_ read: Read) -> [CalendarACL]? {
        if case .access(let rules) = found(read) { return rules }
        return nil
    }

    /// Why it couldn't be read, while that still applies to the connected tenant.
    public func problem(for read: Read) -> Problem? {
        guard let loaded = current(read), case .failure(let problem) = loaded.result else { return nil }
        return problem
    }

    /// Which read is in hand (nil for none): a screen speaks a load's outcome when it changes.
    public func revision(of read: Read) -> Int? {
        current(read)?.revision
    }

    /// One `gam` read as the connected domain. `delay` holds it back, reading from the start: a page opened and
    /// left within it reads nothing (arrowing down a list).
    public func load(_ read: Read, after delay: Duration = .zero) async {
        guard let domain = setup.active, let runner else { return }
        let key = Key(read: read.key, domain: domain, generation: setup.generation)
        let serial = reading.start(key)
        defer { reading.end(key, serial) }
        if delay > .zero {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
        }
        let command = read.command
        let result: Result<Found, Problem>
        do {
            let output = try await runner.run(command, as: domain, extraEnvironment: environment)
            result = .success(try await Task.detached { try Self.found(from: output, for: read, argv: command.argv) }.value)
        } catch {
            result = .failure(Self.problem(for: error, read: read, argv: command.argv))
        }
        // A switch while reading: this belongs to the old tenant, so it's dropped. A later read of the same
        // thing already in hand is kept.
        guard !Task.isCancelled, setup.active == domain, setup.generation == key.generation,
              loaded.first(where: { $0.key == key }).map({ $0.serial < serial }) ?? true
        else { return }
        revisions += 1
        loaded.removeAll { $0.key.read == key.read || $0.key.domain != domain || $0.key.generation != key.generation }
        loaded.insert(Loaded(key: key, revision: revisions, serial: serial, result: result), at: 0)
        if loaded.count > keep { loaded.removeLast(loaded.count - keep) }
    }

    /// What a finished run found, or why nothing. A calendar with no rules exits 60 with the header alone (F3),
    /// which is none, not a failure (plan Q4); a list never does. GAM's "Getting … for …" line before a failure is
    /// progress to GamError (failure-log 2026-10-13). Output the runner cut at its cap is refused.
    nonisolated static func found(from result: GamResult, for read: Read, argv: [String]) throws -> Found {
        let isAccess: Bool = switch read {
        case .access, .primaryAccess: true
        case .rooms, .calendars: false
        }
        let records = GamOutput.records(result.stdout)
        guard result.exitCode == 0 || (isAccess && result.exitCode == 60 && records.isEmpty) else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv,
                           stdout: result.stdout)
        }
        guard !result.stdoutTruncated else { throw DirectoryStore.Truncated() }
        switch read {
        case .rooms: return .rooms(records.map(ResourceCalendar.init(record:)))
        case .calendars: return .calendars(records.map(UserCalendar.init(record:)).filter { !$0.calendarID.isEmpty })
        case .access, .primaryAccess: return .access(records.map(CalendarACL.init(record:)))
        }
    }

    nonisolated static func problem(for error: any Error, read: Read, argv: [String]) -> Problem {
        guard error is DirectoryStore.Truncated else { return DirectoryStore.problem(for: error, argv: argv) }
        return Problem(summary: "There are more \(read.noun) than one call can return yet (GAM printed more than "
            + "\(GamRunner.outputCap / 1_048_576) MiB), so none are shown rather than some.", detail: nil)
    }
}
