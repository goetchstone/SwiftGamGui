import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// One person's storage and mail, as GamGUI's `parse_usage` reads a row of `gam report users`.
public struct UsageRow: Sendable, Equatable, Identifiable {
    public let email: String
    public let quotaMB: Int
    /// `round(mb / 1024, 1)`.
    public let storageGB: Double
    public let received: Int
    public let sent: Int
    public let driveCreated: Int
    /// The row's place, largest first.
    public let id: Int

    /// GamGUI's `"%.1f"|format(storage_gb)` and " GB".
    public var storage: String { String(format: "%.1f GB", storageGB) }
}

/// GamGUI's storage and mail usage (`core/reports.py`, the connector's `usage_report`, the route's top 25). Held
/// to `Tests/Fixtures/usage_report.json` by `UsageReportTests`.
public enum UsageReport {
    /// `USAGE_PARAMS`, in its order (one argv element, comma-joined, as GamGUI's builder joins it).
    public static let parameters = ["accounts:used_quota_in_mb", "gmail:num_emails_received", "gmail:num_emails_sent",
                                    "drive:num_items_created"]
    /// `max_lookback`: days asked for, from two days ago back.
    public static let lookback = 6
    /// The route's `[:25]`.
    public static let shown = 25

    /// `usage_report`'s dates: today in UTC less two days, then a day earlier each time, `lookback` in all.
    static func dates(today: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: today)
        return (2..<(2 + lookback)).map { back in
            let parts = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: -back, to: day)!)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
    }

    /// `_csv_from`: from the first line that starts "email," (after leading spaces, any case) to the end, lines
    /// split as `str.splitlines()` splits them and joined by "\n"; the text unchanged when no line does.
    static func csv(from stdout: String) -> String {
        let lines = PythonText.lines(stdout), header = Array("email,".unicodeScalars)
        guard let start = lines.firstIndex(where: { line in
            let trimmed = String(String.UnicodeScalarView(line.unicodeScalars.drop(while: PythonText.isSpace)))
            return Array(PythonText.lower(trimmed).unicodeScalars.prefix(header.count)) == header
        }) else { return stdout }
        return lines[start...].joined(separator: "\n")
    }

    /// `parse_usage`: each record's address and counts, largest storage first, rows alike in GAM's order (Python's
    /// sort is stable, reversed or not).
    static func rows(_ records: [GamOutput.Record]) -> [UsageRow] {
        let read = records.enumerated().map { index, record in
            (index: index, email: record["email"].map(\.pythonText) ?? "", quota: number(record["accounts:used_quota_in_mb"]),
             received: number(record["gmail:num_emails_received"]), sent: number(record["gmail:num_emails_sent"]),
             drive: number(record["drive:num_items_created"]))
        }
        let ordered = read.sorted { $0.quota != $1.quota ? $0.quota > $1.quota : $0.index < $1.index }
        return ordered.enumerated().map { rank, row in
            UsageRow(email: row.email, quotaMB: row.quota,
                     storageGB: Double(String(format: "%.1f", Double(row.quota) / 1024)) ?? 0,
                     received: row.received, sent: row.sent, driveCreated: row.drive, id: rank)
        }
    }

    /// `_int`: `int(float(value))`, or 0 where that raises TypeError or ValueError. Where Python raises
    /// OverflowError (an infinity; GamGUI's page fails) or keeps a number past `Int`'s range, this reads 0 too:
    /// GAM prints whole numbers far below either.
    static func number(_ value: JSONValue?) -> Int {
        let real: Double?
        switch value {
        case .bool(let flag): real = flag ? 1 : 0
        case .number(let text): real = Double(text)
        case .string(let text): real = pythonFloat(text)
        default: real = nil
        }
        guard let real, real.isFinite, abs(real) < 9.2e18 else { return 0 }
        return Int(real.rounded(.towardZero))
    }

    /// Python's `float(text)`, or nil where it raises. A non-ASCII space reads as a space and a decimal digit of
    /// any script as its ASCII digit (anything else non-ASCII is no number); spaces around it are dropped; single
    /// underscores may sit between digits; then a decimal, with an exponent or not, or inf, infinity or nan, signed.
    static func pythonFloat(_ text: String) -> Double? {
        var ascii: [UInt8] = []
        for scalar in text.unicodeScalars {
            if scalar.value < 127 {
                ascii.append(UInt8(scalar.value))
            } else if PythonText.isSpace(scalar) {
                ascii.append(UInt8(ascii: " "))
            } else if PythonText.isDecimal(scalar), let digit = scalar.properties.numericValue {
                ascii.append(UInt8(ascii: "0") + UInt8(digit))
            } else {
                return nil
            }
        }
        let spaces: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        while let first = ascii.first, spaces.contains(first) { ascii.removeFirst() }
        while let last = ascii.last, spaces.contains(last) { ascii.removeLast() }
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } ?? false }
        if ascii.contains(UInt8(ascii: "_")) {
            for (index, byte) in ascii.enumerated() where byte == UInt8(ascii: "_") {
                guard index > 0, isDigit(ascii[index - 1]), isDigit(index + 1 < ascii.count ? ascii[index + 1] : nil) else { return nil }
            }
            ascii.removeAll { $0 == UInt8(ascii: "_") }
        }
        var body = ascii[...]
        var negative = false
        if let sign = body.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            negative = sign == UInt8(ascii: "-")
            body = body.dropFirst()
        }
        switch String(decoding: body, as: UTF8.self).lowercased() {
        case "inf", "infinity": return negative ? -.infinity : .infinity
        case "nan": return .nan
        default: break
        }
        // digits [. [digits]] | . digits, then [e [sign] digits]
        var index = body.startIndex, whole = 0, fraction = 0
        while index < body.endIndex, isDigit(body[index]) { whole += 1; index += 1 }
        if index < body.endIndex, body[index] == UInt8(ascii: ".") {
            index += 1
            while index < body.endIndex, isDigit(body[index]) { fraction += 1; index += 1 }
        }
        guard whole + fraction > 0 else { return nil }
        if index < body.endIndex, body[index] == UInt8(ascii: "e") || body[index] == UInt8(ascii: "E") {
            index += 1
            if index < body.endIndex, body[index] == UInt8(ascii: "+") || body[index] == UInt8(ascii: "-") { index += 1 }
            var exponent = 0
            while index < body.endIndex, isDigit(body[index]) { exponent += 1; index += 1 }
            guard exponent > 0 else { return nil }
        }
        guard index == body.endIndex else { return nil }
        return Double(String(decoding: ascii, as: UTF8.self))
    }
}

/// The usage report as one walk of `gam report users` left it, for the Reports screen. It loads only when asked
/// (GamGUI loads it with the page: here, when its row is first shown for a tenant), and what it holds belongs to
/// the tenant it was read for, as the directory's users do: a switch hides it and stops a load that was running.
@MainActor
@Observable
public final class UsageStore {
    public typealias Problem = DirectoryStore.Problem

    public struct Report: Sendable, Equatable {
        /// The top `UsageReport.shown`, largest storage first.
        public let rows: [UsageRow]
        /// The day GAM's rows are for (their `date` column), "" when no day had rows. GAM walks back to the newest
        /// day with data on its own (doReport, `_checkDataRequiredServices`), so it can be earlier than `requested`.
        public let date: String
        /// The day the report asked for (GamGUI's "as of"), "" when no day had rows.
        public let requested: String
        public let loadedAt: Date
    }

    private var snapshot: (report: Report, domain: Domain, generation: Int)?
    /// The load running, and the tenant it runs for.
    private var inFlight: (task: Task<Void, Never>, domain: Domain, generation: Int)?
    /// Like the report, a problem belongs to the tenant it was met under.
    private var failure: (problem: Problem, domain: Domain?, generation: Int)?

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private let now: @Sendable () -> Date

    public init(setup: SetupModel, runner: AuthenticatedRunner?, now: @escaping @Sendable () -> Date = Date.init) {
        self.setup = setup
        self.runner = runner
        self.now = now
        setup.onTenantChange { [weak self] in self?.tenantChanged() }
    }

    /// A load runs for the connected tenant; one still running for an earlier tenant isn't this one's.
    public var isLoading: Bool {
        guard let inFlight else { return false }
        return inFlight.domain == setup.active && inFlight.generation == setup.generation
    }

    /// The old tenant's load stops (its `gam` is stopped, its credentials wiped); nothing new starts.
    private func tenantChanged() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    /// The report, while it belongs to the connected tenant.
    public var report: Report? {
        guard let snapshot, snapshot.domain == setup.active, snapshot.generation == setup.generation else { return nil }
        return snapshot.report
    }

    /// Why there is no report, while it still applies to the connected tenant.
    public var problem: Problem? {
        guard let failure, failure.domain == setup.active, failure.generation == setup.generation else { return nil }
        return failure.problem
    }

    /// Reads the connected tenant's usage; while a read for it is already running, waits for that one.
    public func load() async {
        if isLoading, let running = inFlight?.task {
            await running.value
            return
        }
        await start()?.value
    }

    @discardableResult
    private func start() -> Task<Void, Never>? {
        guard !isLoading else { return nil }
        let generation = setup.generation
        guard let domain = setup.active else {
            failure = (Problem(summary: "Connect a domain on Setup first.", detail: nil), nil, generation)
            return nil
        }
        guard let runner else {
            failure = (Problem(summary: "This build has no GAM. Build the app again after running scripts/fetch_gam.sh.",
                               detail: nil), domain, generation)
            return nil
        }
        failure = nil
        let task = Task { await perform(as: domain, generation: generation, runner: runner) }
        inFlight = (task, domain, generation)
        return task
    }

    /// GamGUI's walk: two days ago, then a day earlier while a day has no rows, six days at most; a failure stops
    /// it. The default timeout, as GamGUI's call has it.
    private func perform(as domain: Domain, generation: Int, runner: AuthenticatedRunner) async {
        defer {
            if inFlight?.domain == domain, inFlight?.generation == generation { inFlight = nil }
        }
        let today = now()
        var argv: [String] = []
        let outcome: Result<Report, any Error>
        do {
            var found: Report?
            for date in UsageReport.dates(today: today) {
                try Task.checkCancellation()
                let read = GamCommands.reportUsers(date: date, parameters: UsageReport.parameters)
                argv = read.argv
                let result = try await runner.run(read, as: domain)
                // A large tenant's report takes a while to parse: not on the main actor.
                let report: Report? = try await Task.detached {
                    let records = try Self.records(from: result, argv: read.argv)
                    guard !records.isEmpty else { return nil }
                    let day = records.lazy.compactMap { $0["date"]?.string }.first { !$0.isEmpty } ?? date
                    return Report(rows: Array(UsageReport.rows(records).prefix(UsageReport.shown)), date: day,
                                  requested: date, loadedAt: today)
                }.value
                if let report {
                    found = report
                    break
                }
            }
            outcome = .success(found ?? Report(rows: [], date: "", requested: "", loadedAt: today))
        } catch {
            outcome = .failure(error)
        }
        // A switch while loading: this belongs to the old tenant, so it's dropped.
        guard setup.active == domain, setup.generation == generation else { return }
        switch outcome {
        case .success(let report):
            snapshot = (report, domain, generation)
        case .failure(let error):
            failure = (Self.problem(for: error, argv: argv), domain, generation)
        }
    }

    /// A finished run's records, after the progress `_csv_from` drops, or why there are none. Output the runner cut
    /// at its cap is refused: the top 25 of part of the tenant isn't the tenant's top 25.
    nonisolated static func records(from result: GamResult, argv: [String]) throws -> [GamOutput.Record] {
        guard result.exitCode == 0 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else { throw DirectoryStore.Truncated() }
        return GamOutput.records(UsageReport.csv(from: result.stdout))
    }

    nonisolated static func problem(for error: any Error, argv: [String]) -> Problem {
        guard error is DirectoryStore.Truncated else { return DirectoryStore.problem(for: error, argv: argv) }
        return Problem(summary: "The usage report is larger than one call can return yet (GAM printed more than "
            + "\(GamRunner.outputCap / 1_048_576) MiB), so none of it is shown rather than part of it.", detail: nil)
    }
}
