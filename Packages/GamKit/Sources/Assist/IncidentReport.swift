import Foundation

/// The incident report (docs/plans/2026-10-22-incidents.md, slice 4; asked for 2026-10-27: "a nice report I can run on the
/// incident and export", to show due diligence with "the logs to support it"). Made from the reading of the incident's saved
/// logs (`LogReading.Reading`), the changes this app's audit log shows it made, the incident's own record (what only a person
/// can say, and the review) and the directory's 2-Step Verification. Pure, as the reader is: every count and list is worked out
/// by code from those, each count with the list behind it (`Count`), and each step taken says what shows it (`Action.source`).
/// Plain text throughout: nothing an attacker wrote (a subject, a device's name) is ever read as markup.
public struct IncidentReport: Sendable, Equatable {
    /// What only a person can say, from the kept incident.
    public struct Record: Sendable, Equatable {
        public var title: String
        public var domain: String
        public var opened: Date
        public var openedBy: String
        public var reported: String
        /// Oldest first.
        public var notes: [Note]
        public var review: Review

        public init(title: String, domain: String, opened: Date, openedBy: String, reported: String, notes: [Note], review: Review) {
            (self.title, self.domain, self.opened, self.openedBy, self.reported) = (title, domain, opened, openedBy, reported)
            (self.notes, self.review) = (notes, review)
        }
    }

    public struct Note: Sendable, Equatable {
        public let at: Date
        public let text: String

        public init(at: Date, text: String) { (self.at, self.text) = (at, text) }
    }

    /// The post-incident review, as the operator writes it: the standard's type and severity, the review meeting, its lessons
    /// learned and the plan going forward. Empty until written.
    public struct Review: Sendable, Equatable {
        public var kind = ""
        public var severity = ""
        public var meeting: Date?
        public var attendees = ""
        /// How they got in, and why it worked.
        public var cause = ""
        public var wentWell = ""
        public var improve = ""
        /// What will change, one item a line, each with who and by when.
        public var plan = ""

        public init(kind: String = "", severity: String = "", meeting: Date? = nil, attendees: String = "", cause: String = "",
                    wentWell: String = "", improve: String = "", plan: String = "") {
            (self.kind, self.severity, self.meeting, self.attendees) = (kind, severity, meeting, attendees)
            (self.cause, self.wentWell, self.improve, self.plan) = (cause, wentWell, improve, plan)
        }

        public var isEmpty: Bool { self == Review() }
    }

    /// A change this app ran, as its audit log shows it: when it ended, what it was in words, whom it was done to, by whom, and
    /// whether it worked (nil: the log can't say).
    public struct Change: Sendable, Equatable {
        public let at: Date
        public let what: String
        public let target: String
        public let by: String
        public let ok: Bool?

        public init(at: Date, what: String, target: String, by: String, ok: Bool?) {
            (self.at, self.what, self.target, self.by, self.ok) = (at, what, target, by, ok)
        }
    }

    /// A saved read of the logs, by its folder's name, and what it read in words (its `about.txt`'s first line).
    public struct Evidence: Sendable, Equatable {
        public let name: String
        public let about: String

        public init(name: String, about: String) { (self.name, self.about) = (name, about) }
    }

    /// A table cell: text, or a time the screen says in words and a CSV as ISO 8601.
    public enum Cell: Sendable, Equatable {
        case text(String)
        case time(Date?)

        public func words(_ when: (Date) -> String) -> String {
            switch self {
            case .text(let text): text
            case .time(let date): date.map(when) ?? ""
            }
        }

        public var csv: String {
            switch self {
            case .text(let text): text
            case .time(let date): date?.formatted(.iso8601) ?? ""
            }
        }
    }

    public struct Table: Sendable, Equatable {
        public let columns: [String]
        public let rows: [[Cell]]

        /// Header first, for a CSV.
        public var csv: [[String]] { [columns] + rows.map { $0.map(\.csv) } }
    }

    /// A number in the report, with the list behind it: what a click on it opens, and exports.
    public struct Count: Sendable, Equatable, Identifiable {
        /// Stable: what the screen and the export name it by.
        public let id: String
        public let label: String
        public let number: Int
        /// What the list is, in a sentence.
        public let about: String
        public let table: Table
    }

    /// A step taken, when, to whom, and the record that shows it: a log of Google's, this app's audit log, or a note.
    public struct Action: Sendable, Equatable {
        public let at: Date
        public let what: String
        public let account: String
        public let source: String
    }

    /// When the attack began, was seen, and was contained.
    public struct Times: Sendable, Equatable {
        /// The first event from the attacker's addresses in the logs read.
        public let firstSign: Date?
        /// When the incident was opened (identified).
        public let opened: Date
        /// When the last account the attacker touched was locked, once every one is.
        public let contained: Date?
    }

    public let record: Record
    /// When it was made: the export sets it to when it was exported.
    public var made: Date
    public let madeBy: String
    public let times: Times
    /// The numbers, each with its list, in the order the report says them.
    public let counts: [Count]
    /// Every step taken, oldest first.
    public let actions: [Action]
    /// Where each account the attacker touched stands, in words with its times.
    public let standing: [(account: String, words: String)]
    /// Still to do, most urgent first: the reading's own words.
    public let toDo: [String]
    /// Every account's timeline, oldest first.
    public let timeline: Table
    public let evidence: [Evidence]
    /// The emails the attacker sent, each in a sentence: what it was, who sent it, and what came of it.
    public let emails: [String]

    public static func == (a: Self, b: Self) -> Bool {
        a.record == b.record && a.made == b.made && a.madeBy == b.madeBy && a.times == b.times && a.counts == b.counts
            && a.actions == b.actions && a.standing.map { [$0.account, $0.words] } == b.standing.map { [$0.account, $0.words] }
            && a.toDo == b.toDo && a.timeline == b.timeline && a.evidence == b.evidence && a.emails == b.emails
    }

    /// A count by its ID.
    public func count(_ id: String) -> Count? { counts.first { $0.id == id } }

    /// The report from `reading`. `changes` is this app's audit log's (only those to an account the attacker touched or a
    /// person here an email of theirs reached are kept); `no2SV` the directory's people here with 2-Step Verification off,
    /// lowercased (nil while the directory isn't read: nothing is said of it then); `when` says a time in words, as the screen
    /// does.
    public static func make(_ reading: LogReading.Reading, record: Record, changes: [Change], evidence: [Evidence], no2SV: Set<String>?,
                            made: Date, madeBy: String, when: (Date) -> String) -> IncidentReport {
        let statuses = reading.statuses
        let accounts = Set(statuses.map { $0.account.lowercased() })
        let firstSign = statuses.compactMap(\.attackedAt).min()
        let contained = statuses.isEmpty || statuses.contains { $0.state != .locked } ? nil : statuses.compactMap(\.lockedAt).max()

        func state(_ status: LogReading.Status) -> String {
            switch status.state {
            case .locked: "locked"
            case .partlyLocked: "partly locked"
            case .notLocked: "not locked"
            case .stillIn: "may still be in"
            }
        }
        func twoStep(_ address: String) -> Cell { .text(no2SV.map { $0.contains(address.lowercased()) ? "off" : "on" } ?? "") }

        // Who each email reached, a row per email and address, and the attacker's emails in a sentence each.
        let recipientColumns = ["email", "Message-ID", "address", "where", "reached", "when", "warned", "to warn", "first contacted after",
                                "contacted by", "contact subject", "emails from here after", "through group", "2-Step Verification"]
        var recipientRows: [(recipient: LogReading.Reach.Recipient, row: [Cell])] = []
        var emails: [String] = []
        for reach in reading.reaches {
            let subject = reach.subject.isEmpty ? "(no subject)" : reach.subject
            for recipient in reach.recipients where !recipient.expanded {
                recipientRows.append((recipient, [
                    .text(subject), .text(reach.messageID), .text(recipient.address), .text(recipient.inside ? "inside" : "outside"),
                    .text(LogReading.Reach.words(recipient)), .time(recipient.at),
                    .text(recipient.warned.map { $0 ? "yes" : "not shown" } ?? ""), .text(recipient.toWarn ? "yes" : ""),
                    .time(recipient.contacted?.at), .text(recipient.contacted?.sender ?? ""), .text(recipient.contacted?.subject ?? ""),
                    .text(recipient.contacted.map { String($0.emails) } ?? ""), .text(recipient.via ?? ""),
                    recipient.inside && recipient.mailbox ? twoStep(recipient.address) : .text(""),
                ]))
            }
            let listed = reach.recipients.filter { !$0.expanded }
            func n(_ test: (LogReading.Reach.Recipient) -> Bool) -> Int { listed.filter(test).count }
            let senders = reach.senders.isEmpty ? "" : " from \(reach.senders.joined(separator: ", "))"
            let warned = reach.warnings.filter { $0.problem == nil }
            emails.append("“\(subject)” (\(reach.messageID))\(senders): to \(listed.count) \(listed.count == 1 ? "address" : "addresses"); "
                + "\(n { $0.outcome == .received }) received it here, \(n { $0.outcome == .bounced }) bounced, "
                + "\(n { $0.outcome == .blocked }) quarantined or rejected, \(n { $0.outcome == .sent && !$0.inside }) sent outside with no "
                + "bounce seen; \(reach.toWarn.count) still to warn, \(n { $0.contacted != nil }) contacted from here after it."
                + (warned.isEmpty ? " No warning picked counts yet."
                   : " Warned by " + warned.map { "“\($0.subject.isEmpty ? "(no subject)" : $0.subject)” from \($0.sender)" + ($0.at.map { " at \(when($0))" } ?? "") }
                    .joined(separator: "; ") + "."))
        }
        let recipientTable = { (keep: (LogReading.Reach.Recipient) -> Bool) in
            Table(columns: recipientColumns, rows: recipientRows.filter { keep($0.recipient) }.map(\.row))
        }
        let addresses = Set(recipientRows.map(\.recipient.address))
        func people(_ keep: (LogReading.Reach.Recipient) -> Bool) -> Int { Set(recipientRows.filter { keep($0.recipient) }.map(\.recipient.address)).count }

        // Every step taken: what the logs show done to each account (an admin's or Google's), what this app ran, the emails
        // pulled, each warning that counted, and the notes.
        var actions: [Action] = []
        for status in statuses {
            for moment in status.timeline where moment.who == .admin || moment.who == .google {
                actions.append(Action(at: moment.at, what: moment.words + (moment.count > 1 ? " (\(moment.count) times)" : ""),
                                      account: status.account, source: moment.who == .admin ? "Google's Admin log" : "Google's sign-in log"))
            }
        }
        let reached = Set(reading.reaches.flatMap { $0.recipients.filter { $0.inside && $0.mailbox }.map { $0.address.lowercased() } })
        let since = min(firstSign ?? record.opened, record.opened)
        for change in changes where change.at >= since && (accounts.contains(change.target.lowercased()) || reached.contains(change.target.lowercased())) {
            let outcome = change.ok.map { $0 ? "" : " (failed)" } ?? " (no result recorded)"
            actions.append(Action(at: change.at, what: change.what + outcome + (change.by.isEmpty ? "" : " by \(change.by)"),
                                  account: change.target, source: "This app's audit log"))
        }
        for task in reading.done {
            guard let done = task.done, done.how != .warned else { continue }
            actions.append(Action(at: done.at, what: task.words + (done.by.isEmpty ? "" : " (by \(done.by))"), account: "",
                                  source: done.how == .trashed ? "This app's audit log (Phishing)" : "Phishing's Find, kept on this Mac"))
        }
        for reach in reading.reaches {
            let subject = reach.subject.isEmpty ? "(no subject)" : reach.subject
            for warning in reach.warnings where warning.problem == nil {
                guard let at = warning.at else { continue }
                actions.append(Action(at: at, what: "Warning “\(warning.subject.isEmpty ? "(no subject)" : warning.subject)” sent by \(warning.sender): "
                                      + "\(warning.covers) of those “\(subject)” reached have it, by the log's word", account: warning.sender,
                                      source: "Google's Gmail log"))
            }
        }
        for note in record.notes { actions.append(Action(at: note.at, what: note.text, account: "", source: "A note on the incident")) }
        actions.sort { $0.at < $1.at }

        let accountTable = Table(columns: ["account", "status", "the attacker got in", "first attacked", "locked", "2-Step Verification"],
                                 rows: statuses.map { status in
            [.text(status.account), .text(state(status)), .text(status.attackerGotIn ? "yes" : "tried only"), .time(status.attackedAt),
             .time(status.lockedAt), twoStep(status.account)]
        })
        func accountRows(_ keep: (LogReading.Status) -> Bool) -> Table {
            Table(columns: accountTable.columns, rows: zip(statuses, accountTable.rows).filter { keep($0.0) }.map(\.1))
        }
        let pulled = reading.done.filter { $0.done.map { $0.how != .warned } ?? false }
        let actionTable = Table(columns: ["when", "what", "account", "shown by"],
                                rows: actions.map { [.time($0.at), .text($0.what), .text($0.account), .text($0.source)] })
        var counts: [Count] = [
            Count(id: "accounts", label: "Accounts the attacker touched", number: statuses.count,
                  about: "Every account the attacker signed in to, tried, or Google warned of, with where it stands.", table: accountTable),
            Count(id: "notLocked", label: "Not yet locked", number: statuses.filter { $0.state != .locked }.count,
                  about: "Accounts the logs don't show locked: not locked, partly locked, or signed in to after the lock.",
                  table: accountRows { $0.state != .locked }),
        ]
        if let no2SV {
            counts.append(Count(id: "accounts2SV", label: "Touched with 2-Step Verification off",
                                number: statuses.filter { no2SV.contains($0.account.lowercased()) }.count,
                                about: "Accounts the attacker touched that the directory shows without 2-Step Verification.",
                                table: accountRows { no2SV.contains($0.account.lowercased()) }))
        }
        counts += [
            Count(id: "emails", label: "Emails the attacker sent", number: reading.reaches.count,
                  about: "Each email the attacker sent, a row for each address it went to.", table: recipientTable { _ in true }),
            Count(id: "addresses", label: "Addresses they went to", number: addresses.count,
                  about: "Every address the attacker's emails were sent to or received by, a row for each email.", table: recipientTable { _ in true }),
            Count(id: "received", label: "Received it here", number: people { $0.outcome == .received },
                  about: "Mailboxes here that received it.", table: recipientTable { $0.outcome == .received }),
            Count(id: "outside", label: "Sent outside, no bounce seen", number: people { $0.outcome == .sent && !$0.inside },
                  about: "Addresses outside it was sent to with no bounce in the logs read: the most Google's log says of outside.",
                  table: recipientTable { $0.outcome == .sent && !$0.inside }),
            Count(id: "bounced", label: "Bounced", number: people { $0.outcome == .bounced },
                  about: "Addresses a bounce notice names.", table: recipientTable { $0.outcome == .bounced }),
            Count(id: "blocked", label: "Quarantined or rejected", number: people { $0.outcome == .blocked },
                  about: "Copies quarantined, rejected, or marked failed, with no receipt after.", table: recipientTable { $0.outcome == .blocked }),
            Count(id: "toWarn", label: "Still to warn", number: people(\.toWarn),
                  about: "Reached, and not shown warned by a warning picked that counts.", table: recipientTable(\.toWarn)),
            Count(id: "warned", label: "Warned", number: people { $0.warned == true },
                  about: "Shown warned by the log's own word: their receipt of a warning picked (here), or its send (outside).",
                  table: recipientTable { $0.warned == true }),
            Count(id: "contacted", label: "Contacted from here after", number: people { $0.contacted != nil },
                  about: "Sent or received an email from an account here after the attacker's: the first, and how many.",
                  table: recipientTable { $0.contacted != nil }),
            Count(id: "notContacted", label: "Reached, no contact from here seen", number: people { $0.toWarn && $0.contacted == nil },
                  about: "Still to warn, and no email from here after the attacker's in the logs read.",
                  table: recipientTable { $0.toWarn && $0.contacted == nil }),
        ]
        if let no2SV {
            counts.append(Count(id: "reached2SV", label: "Reached here with 2-Step Verification off",
                                number: people { $0.inside && $0.mailbox && no2SV.contains($0.address.lowercased()) },
                                about: "People here an email of the attacker's reached who have 2-Step Verification off: the next accounts at risk.",
                                table: recipientTable { $0.inside && $0.mailbox && no2SV.contains($0.address.lowercased()) }))
        }
        counts += [
            Count(id: "pulled", label: "Emails pulled from every mailbox", number: pulled.count,
                  about: "Emails Phishing trashed from every mailbox that had them, or showed nobody here has.",
                  table: Table(columns: ["what", "when", "by"], rows: pulled.map { [.text($0.words), .time($0.done?.at), .text($0.done?.by ?? "")] })),
            Count(id: "actions", label: "Steps taken", number: actions.count,
                  about: "Every step taken, oldest first, with the record that shows it.", table: actionTable),
            Count(id: "toDo", label: "Still to do", number: reading.toDo.count, about: "What the logs show is left, most urgent first.",
                  table: Table(columns: ["item", "to do"], rows: reading.toDo.map { [.text($0.id), .text($0.words)] })),
        ]

        var moments: [(at: Date, account: String, who: String, what: String)] = []
        for status in statuses {
            for moment in status.timeline { moments.append((moment.at, status.account, moment.who.rawValue, moment.words)) }
        }
        moments.sort { ($0.at, $0.account) < ($1.at, $1.account) }
        let timeline = Table(columns: ["when", "account", "who", "what"],
                             rows: moments.map { [.time($0.at), .text($0.account), .text($0.who), .text($0.what)] })

        return IncidentReport(record: record, made: made, madeBy: madeBy, times: Times(firstSign: firstSign, opened: record.opened, contained: contained),
                              counts: counts, actions: actions, standing: statuses.map { ($0.account, $0.words(when)) },
                              toDo: reading.toDo.map { "\($0.id): \($0.words)" }, timeline: timeline, evidence: evidence, emails: emails)
    }

    // MARK: the report as text

    /// "2 days 3 hours", "45 minutes".
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        let (days, hours, rest) = (minutes / 1_440, minutes % 1_440 / 60, minutes % 60)
        func say(_ n: Int, _ unit: String) -> String? { n > 0 ? "\(n) \(unit)\(n == 1 ? "" : "s")" : nil }
        let parts = [say(days, "day"), say(hours, "hour"), days > 0 ? nil : say(rest, "minute")].compactMap(\.self)
        return parts.isEmpty ? "under a minute" : parts.joined(separator: " ")
    }

    /// The report as plain text, in its order: what it is, the numbers, what was done, who the emails reached, where each
    /// account stands, what's left, the timeline, the notes and the review, and the evidence. `hashes` are the evidence's files'
    /// SHA-256, when the export has worked them out.
    public func text(_ when: (Date) -> String, zone: String = "", hashes: [(file: String, sha256: String)] = []) -> String {
        var out: [String] = []
        func heading(_ text: String) { out += ["", text.uppercased(), String(repeating: "=", count: min(text.count, 72))] }
        func line(_ text: String) { out.append(text) }
        func field(_ label: String, _ value: String) { if !value.isEmpty { line("\(label): \(value)") } }

        line("INCIDENT REPORT: \(record.title)")
        line("Domain: \(record.domain)")
        line("Opened (identified): \(when(record.opened))" + (record.openedBy.isEmpty ? "" : " by \(record.openedBy)"))
        field("How it was reported", record.reported)
        field("Type", record.review.kind)
        field("Severity", record.review.severity)
        line("Report made \(when(made))" + (madeBy.isEmpty ? "" : " by \(madeBy)") + " with GAM GUI, from the evidence listed at the end.")
        if !zone.isEmpty { line("Times are in \(zone).") }
        line("Every count and list below is worked out by code from Google's logs and this app's audit log; only the notes and the "
             + "review are typed.")

        heading("At a glance")
        if let first = times.firstSign {
            line("First sign of the attacker in the logs: \(when(first))")
            line("Time to detect (first sign to opened): \(record.opened >= first ? Self.span(record.opened.timeIntervalSince(first)) : "opened before the first sign in these logs")")
        }
        if let contained = times.contained, let first = times.firstSign {
            line("Every account touched locked by: \(when(contained)) (time to contain: \(Self.span(contained.timeIntervalSince(first))))")
        } else if !standing.isEmpty {
            line("Contained: not yet: the logs don't show every account touched locked.")
        }
        for count in counts where count.id != "actions" { line("\(count.label): \(count.number)") }

        heading("What was done")
        if actions.isEmpty { line("No step taken shows in the logs read, this app's audit log, or the notes.") }
        for action in actions {
            line("\(when(action.at)): \(action.what)" + (action.account.isEmpty ? "" : " [\(action.account)]") + " (shown by \(action.source))")
        }

        heading("The attacker's emails, and who they reached")
        if emails.isEmpty { line("No email the attacker sent shows in the logs read.") }
        for email in emails { line("• " + email) }
        if let addresses = count("addresses"), addresses.number > 0 {
            line("Every address, with whether it received, bounced, was warned and was contacted from here after, is in who-it-reached.csv.")
        }

        heading("Where each account stands")
        if standing.isEmpty { line("No account the attacker touched shows in the logs read.") }
        for (account, words) in standing { line("• \(account): \(words)") }

        heading("Still to do")
        if toDo.isEmpty { line("Nothing left that the logs read can show.") }
        for item in toDo { line("• " + item) }

        heading("Timeline")
        if timeline.rows.isEmpty { line("Nothing in the logs read.") }
        for row in timeline.rows { line(row.map { $0.words(when) }.joined(separator: "  ·  ")) }

        heading("Notes")
        if record.notes.isEmpty { line("None.") }
        for note in record.notes { line("\(when(note.at)): \(note.text)") }

        heading("Post-incident review: lessons learned and the plan going forward")
        let review = record.review
        if review.isEmpty {
            line("Not written yet. For the review meeting, go through:")
        } else {
            if let meeting = review.meeting { line("Review meeting: \(when(meeting))") }
            field("Attended", review.attendees)
            field("How they got in", review.cause)
            field("What went well", review.wentWell)
            field("What to do better", review.improve)
            if !review.plan.isEmpty {
                line("The plan going forward:")
                for item in review.plan.split(whereSeparator: \.isNewline) where !item.trimmingCharacters(in: .whitespaces).isEmpty {
                    line("• " + item.trimmingCharacters(in: .whitespaces))
                }
            }
            line("")
            line("The review meeting's agenda:")
        }
        for item in Self.agenda(self) { line(item) }

        heading("Evidence")
        line("Each read of the logs kept with the incident, exactly as exported from Google's reports, is in the evidence folder.")
        for item in evidence { line("• \(item.name)" + (item.about.isEmpty ? "" : ": \(item.about)")) }
        if !hashes.isEmpty {
            line("")
            line("SHA-256 of each evidence file, to show it is unchanged:")
            for hash in hashes { line("\(hash.sha256)  \(hash.file)") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The post-incident review meeting's agenda, filled from the report's own numbers.
    public static func agenda(_ report: IncidentReport) -> [String] {
        func number(_ id: String) -> Int { report.count(id)?.number ?? 0 }
        let detect = report.times.firstSign.map { report.record.opened >= $0 ? span(report.record.opened.timeIntervalSince($0)) : "—" } ?? "—"
        let contain = report.times.contained.flatMap { contained in report.times.firstSign.map { span(contained.timeIntervalSince($0)) } }
            ?? "not yet contained"
        return [
            "1. What happened: the timeline and the attacker's emails (\(number("accounts")) accounts touched, \(number("emails")) emails sent).",
            "2. How it was found and how fast: time to detect \(detect), time to contain \(contain).",
            "3. What was done, and what shows it: \(number("actions")) steps taken.",
            "4. Who was reached and whether they were warned: \(number("addresses")) addresses, \(number("toWarn")) still to warn, "
                + "\(number("contacted")) contacted from here after.",
            "5. What's still open: \(number("toDo")) items" + (number("reached2SV") > 0 ? ", and \(number("reached2SV")) people reached here with 2-Step Verification off" : "") + ".",
            "6. How they got in, and why it worked.",
            "7. What went well, and what to do better.",
            "8. The plan going forward: each change with who owns it and by when.",
        ]
    }
}
