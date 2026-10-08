import Foundation
import GamEngine

/// GamGUI's directory reports (`core/reports.py`): what the Admin console buries, counted from the user
/// list with no GAM call of its own. Suspended accounts form their own report; every other report
/// describes active accounts only. Held to `Tests/Fixtures/reports.json` by `DirectoryReportTests`.
public struct DirectoryReport: Sendable, Identifiable {
    public let key: String
    public let title: String
    public let description: String
    public let users: [GamUser]

    public var id: String { key }
    public var count: Int { users.count }

    public static let inactiveDays = 90

    public static func build(_ users: [GamUser], now: Date = Date(), inactiveDays: Int = inactiveDays) -> [DirectoryReport] {
        // In whole microseconds, as Python compares: a Double instant rounded 59.9999999 up to the cutoff.
        let cutoffMicros = Int64((now.timeIntervalSince1970 * 1_000_000).rounded()) - Int64(inactiveDays) * 86_400_000_000
        var noTwoSV: [GamUser] = [], admins: [GamUser] = [], suspended: [GamUser] = [], inactive: [GamUser] = []
        var noRecovery: [GamUser] = [], noTitle: [GamUser] = [], noDepartment: [GamUser] = []
        var noPhone: [GamUser] = [], noLocation: [GamUser] = []
        func blank(_ text: String) -> Bool { PythonText.strip(text).isEmpty }
        for user in users {
            if user.suspended {
                suspended.append(user)
                continue
            }
            if user.isAdmin || user.isDelegatedAdmin { admins.append(user) }
            if !user.isEnrolledIn2SV { noTwoSV.append(user) }
            if user.recoveryEmail.isEmpty { noRecovery.append(user) }
            if blank(user.title) { noTitle.append(user) }
            if blank(user.department) { noDepartment.append(user) }
            if blank(user.phone) { noPhone.append(user) }
            if blank(user.location) { noLocation.append(user) }
            if let last = user.lastLoginTime.flatMap(ISOTime.microseconds), last >= cutoffMicros {} else { inactive.append(user) }
        }
        return [
            .init(key: "no_2sv", title: "No 2-step verification",
                  description: "Active users not enrolled in 2SV — a real security gap.", users: noTwoSV),
            .init(key: "inactive", title: "Inactive (\(inactiveDays)+ days)",
                  description: "Active users with no recent (or any) login.", users: inactive),
            .init(key: "admins", title: "Administrators",
                  description: "Accounts with super or delegated admin privileges.", users: admins),
            .init(key: "no_recovery", title: "No recovery info",
                  description: "Active users without a recovery email set.", users: noRecovery),
            .init(key: "suspended", title: "Suspended",
                  description: "Accounts currently suspended (sign-in blocked).", users: suspended),
            // Directory completeness: the worklist for filling profile data (before a signature rollout).
            .init(key: "no_title", title: "No job title",
                  description: "Active users with no title set — needed for role-based signatures.", users: noTitle),
            .init(key: "no_department", title: "No department",
                  description: "Active users with no department set.", users: noDepartment),
            .init(key: "no_phone", title: "No phone", description: "Active users with no work phone set.", users: noPhone),
            .init(key: "no_location", title: "No location",
                  description: "Active users with no location set.", users: noLocation),
        ]
    }
}

/// GamGUI's `_parse_dt`: Python's `datetime.fromisoformat` after `strip()` and "Z" read as UTC, a time
/// without an offset taken as UTC. Held to Python's own answers by the `logins` table in
/// `Tests/Fixtures/reports.json`. The forms read:
/// - a date, `YYYY-MM-DD` or `YYYYMMDD`;
/// - then any single separator and a time, `HH[:MM[:SS]]` or `HH[MM[SS]]`, with a fraction after `.`
///   or `,` (truncated to microseconds, as Python truncates); `24:00` is the next midnight;
/// - then an offset, `±HH`, `±HH:MM[:SS[.f]]` or `±HHMM[SS[.f]]`.
///
/// Anything else is no date, so the account reads as inactive, as in GamGUI. Three forms Python reads
/// and this doesn't, none printed by GAM: week dates (`2026-W41-4`), a space before the offset, and a
/// bare `.` before the offset.
enum ISOTime {
    static func parse(_ text: String) -> Date? {
        guard let micros = microseconds(text) else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    /// The instant as microseconds since 1970, as Python holds it.
    static func microseconds(_ text: String) -> Int64? {
        var scalars = Array(PythonText.strip(text).unicodeScalars)
        // Python's `.replace("Z", "+00:00")`: every Z, wherever it is.
        scalars = scalars.flatMap { $0 == "Z" ? Array("+00:00".unicodeScalars) : [$0] }
        var index = 0
        func number(_ width: Int) -> Int64? {
            guard scalars.count - index >= width else { return nil }
            var value: Int64 = 0
            for scalar in scalars[index..<(index + width)] {
                guard ("0"..."9").contains(scalar) else { return nil }
                value = value * 10 + Int64(scalar.value - 48)
            }
            index += width
            return value
        }
        func take(_ scalar: Unicode.Scalar) -> Bool {
            guard index < scalars.count, scalars[index] == scalar else { return false }
            index += 1
            return true
        }
        func isDigit(_ offset: Int) -> Bool {
            index + offset < scalars.count && ("0"..."9").contains(scalars[index + offset])
        }
        /// `HH[:MM[:SS[.f]]]` or `HH[MM[SS[.f]]]`, as microseconds; nil when malformed.
        func clock(hourLimit: Int64) -> (micros: Int64, hour: Int64, rest: Int64)? {
            guard let hour = number(2), hour <= hourLimit else { return nil }
            var minute: Int64 = 0, second: Int64 = 0, fraction: Int64 = 0
            let extended = index < scalars.count && scalars[index] == ":"
            if extended ? take(":") : isDigit(0) {
                guard let value = number(2), value < 60 else { return nil }
                minute = value
                if extended ? take(":") : isDigit(0) {
                    guard let value = number(2), value < 60 else { return nil }
                    second = value
                    if take(".") || take(",") {
                        var digits = 0
                        while isDigit(0) {
                            if digits < 6 { fraction = fraction * 10 + Int64(scalars[index].value - 48) }
                            digits += 1
                            index += 1
                        }
                        guard digits > 0 else { return nil }
                        for _ in digits..<max(digits, 6) { fraction *= 10 }
                    }
                }
            }
            return ((hour * 3600 + minute * 60 + second) * 1_000_000 + fraction, hour, minute * 60 + second + fraction)
        }
        guard let year = number(4) else { return nil }
        let basic = !take("-")
        guard let month = number(2), basic || take("-"), let day = number(2),
              (1...12).contains(month), year >= 1, (1...Int64(daysIn(Int(month), of: Int(year)))).contains(day)
        else { return nil }
        var micros = Int64(daysFromCivil(Int(year), Int(month), Int(day))) * 86_400_000_000
        guard index < scalars.count else { return micros }
        index += 1   // any single separator
        guard let time = clock(hourLimit: 24), time.hour < 24 || time.rest == 0 else { return nil }
        micros += time.micros
        if index < scalars.count {
            let sign = scalars[index]
            guard sign == "+" || sign == "-" else { return nil }
            index += 1
            guard let offset = clock(hourLimit: 23) else { return nil }
            micros -= sign == "+" ? offset.micros : -offset.micros
        }
        return index == scalars.count ? micros : nil
    }

    static func daysIn(_ month: Int, of year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
