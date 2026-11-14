import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Calendars page's event search (GamGUI's `/calendars/events`): one calendar's events by title and/or a date range,
/// never every event (a search needs one of them), the first `cap` kept (GamGUI's `EVENT_CAP`). One search at a time,
/// kept for the calendar, tenant and generation it ran on, so a switch never shows one tenant's events as another's.
@MainActor
@Observable
public final class CalendarEventSearch {
    /// GamGUI's `EVENT_CAP`: the most results shown; GamGUI says to narrow the search past it.
    public static let cap = 200

    /// What was asked: a title fragment (Google's `q`), and the days around it (`yyyy-mm-dd`, GAM's `after`/`before`).
    public struct Query: Equatable, Sendable {
        public let text: String
        public let after: String
        public let before: String

        public init(text: String, after: String = "", before: String = "") {
            self.text = PythonText.strip(text)
            self.after = PythonText.strip(after)
            self.before = PythonText.strip(before)
        }

        /// GamGUI's guard: no title and no date is an unbounded scan, never run.
        public var isEmpty: Bool { text.isEmpty && after.isEmpty && before.isEmpty }
    }

    public enum State: Sendable {
        case idle
        /// GamGUI's words for a search with nothing to search by.
        case needsFilter
        case searching(Query)
        /// The events found, at most `cap`; `capped` when there may be more.
        case found(Query, [CalendarEvent], capped: Bool)
        case problem(Query, DirectoryStore.Problem)
    }

    public private(set) var state: State = .idle
    /// The calendar the state is about: a page shows only its own calendar's search.
    public private(set) var calendarID: String?
    private var tenant: (domain: Domain, generation: Int)?
    private var serial = 0
    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    /// Tests only: the mock's state folder.
    var environment: [String: String] = [:]
    /// The zone a day is read in: the operator's (tests fix one).
    var timeZone: TimeZone = .current

    public init(setup: SetupModel, runner: AuthenticatedRunner?) {
        self.setup = setup
        self.runner = runner
    }

    /// The state, while it belongs to `calendarID` and the connected tenant.
    public func state(for calendarID: String) -> State {
        guard let shown = self.calendarID, Guard.normalized(shown) == Guard.normalized(calendarID),
              let tenant, setup.active == tenant.domain, setup.generation == tenant.generation else { return .idle }
        return state
    }

    /// GamGUI's `search_events`: `print events` with the query and dates given, the first `cap` kept.
    public func search(calendarID: String, _ query: Query) async {
        self.calendarID = calendarID
        tenant = setup.active.map { ($0, setup.generation) }
        serial += 1
        let mine = serial
        guard !query.isEmpty else { return state = .needsFilter }
        guard let domain = setup.active, let runner else {
            return state = .problem(query, .init(summary: "Connect a domain on Setup first.", detail: nil))
        }
        state = .searching(query)
        let command = GamCommands.printEvents(calendarID: calendarID, query: query.text, after: Self.instant(query.after, in: timeZone),
                                              before: Self.instant(query.before, in: timeZone))
        let result: State
        do {
            let output = try await runner.run(command, as: domain, extraEnvironment: environment)
            let events = try Self.events(from: output, argv: command.argv)
            result = .found(query, Array(events.prefix(Self.cap)), capped: events.count >= Self.cap)
        } catch {
            result = .problem(query, Self.problem(for: error, argv: command.argv))
        }
        // A newer search, or a switch while this one ran: this one's answer is dropped.
        guard mine == serial, setup.active == domain else { return }
        state = result
    }

    /// A `yyyy-mm-dd` day as the instant it begins in `zone`, with its offset (`2026-07-14T00:00:00-04:00`), which GAM passes
    /// to Google as it is (getTimeOrDeltaFromNow: anything `arrow.get` parses). A bare day GAM reads as midnight in its own
    /// `timezone` setting, UTC unless set, which this app never sets: "on or after" a day then began hours away from the
    /// operator's midnight, and Google keeps an event whose end is after `timeMin` and whose start is before `timeMax`, so an
    /// afternoon meeting could drop out of its own day. A deliberate difference from GamGUI, which sends the bare day.
    /// Anything else (empty, not a real day) goes as it is: GAM refuses what it can't read.
    nonisolated static func instant(_ day: String, in zone: TimeZone) -> String {
        let scalars = Array(day.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-",
              scalars.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || ("0"..."9").contains($0.element) }),
              let year = Int(String(day.prefix(4))), let month = Int(String(day.dropFirst(5).prefix(2))),
              let date = Int(String(day.suffix(2))) else { return day }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // From noon: a zone whose clocks skip midnight that day still has a start of the day.
        guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: date, hour: 12)),
              calendar.component(.year, from: noon) == year, calendar.component(.month, from: noon) == month,
              calendar.component(.day, from: noon) == date else { return day }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return formatter.string(from: calendar.startOfDay(for: noon))
    }

    /// The events a finished `print events` found. None is exit 60 with the titles alone (`_validateCalendarGetEvents`
    /// sets NO_ENTITIES_FOUND_RC), which is "No matching events.", not a failure; GamGUI's runner raised on it, so its own
    /// "No matching events." was never shown live. Output the runner cut at its cap is refused.
    nonisolated static func events(from result: GamResult, argv: [String]) throws -> [CalendarEvent] {
        let records = GamOutput.records(result.stdout)
        guard result.exitCode == 0 || (result.exitCode == 60 && records.isEmpty) else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else { throw DirectoryStore.Truncated() }
        return records.map(CalendarEvent.init(record:)).filter { !$0.eventID.isEmpty }
    }

    nonisolated static func problem(for error: any Error, argv: [String]) -> DirectoryStore.Problem {
        guard error is DirectoryStore.Truncated else { return DirectoryStore.problem(for: error, argv: argv) }
        return DirectoryStore.Problem(summary: "More events match than one call can return (GAM printed more than "
            + "\(GamRunner.outputCap / 1_048_576) MiB), so none are shown rather than some: narrow the search.", detail: nil)
    }

    /// An event was deleted: it leaves the results shown.
    public func forget(eventID: String, on calendarID: String) {
        guard let shown = self.calendarID, Guard.normalized(shown) == Guard.normalized(calendarID),
              case .found(let query, let events, let capped) = state else { return }
        state = .found(query, events.filter { $0.eventID != eventID }, capped: capped)
    }

    /// Put away (the page closed, or another calendar opened).
    public func clear() {
        serial += 1
        state = .idle
        calendarID = nil
    }
}
