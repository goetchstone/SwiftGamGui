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
        /// The report's summary, at its top; and whether it began as the on-device model's draft, which the report says.
        public var summary = ""
        public var summaryDrafted = false

        public init(kind: String = "", severity: String = "", meeting: Date? = nil, attendees: String = "", cause: String = "",
                    wentWell: String = "", improve: String = "", plan: String = "", summary: String = "", summaryDrafted: Bool = false) {
            (self.kind, self.severity, self.meeting, self.attendees) = (kind, severity, meeting, attendees)
            (self.cause, self.wentWell, self.improve, self.plan) = (cause, wentWell, improve, plan)
            (self.summary, self.summaryDrafted) = (summary, summaryDrafted)
        }

        /// Nothing of the review written: the summary is the report's, not the review's.
        public var isEmpty: Bool {
            var review = self
            (review.summary, review.summaryDrafted) = ("", false)
            return review == Review()
        }
    }

    /// An address an email of the attacker's got to (`gotIt`): once, however many of their emails got to it.
    public struct GotIt: Sendable, Equatable {
        public let address: String
        public let inside: Bool
        /// A person's mailbox here.
        public let mailbox: Bool
        /// A receipt in its mailbox here; else sent, and nothing in the logs read says it failed.
        public let received: Bool
        /// When the first of them got to it.
        public let at: Date?
        /// The emails that got to it, by subject, each once, in the order they did.
        public let subjects: [String]
        public let emails: Int
        /// Not shown warned of one of them by a warning picked that counts.
        public let toWarn: Bool
        /// Shown warned of every one of them.
        public let warned: Bool
        /// The first email from here that reached it after one of them (`Reach.Recipient.contacted`).
        public let contacted: LogReading.Reach.Contact?
        /// The group here it was listed through, when only a group's members named it.
        public let through: String
    }

    /// Everyone the attacker's emails got to, each once, in the order they first did (the operator, 2026-10-27: "a clean way
    /// to know who actually got a message and needs to be warned", across many emails of one subject, and "if it bounced, they
    /// did not get it"): a receipt here, or a send nothing in the logs read says failed (outside, a person here whose Gmail log
    /// isn't read, a group here). A bounce, a quarantine or a rejection didn't get through, and a group whose members are
    /// listed is them.
    public static func gotIt(_ reaches: [LogReading.Reach]) -> [GotIt] {
        var order: [String] = []
        var found: [String: (inside: Bool, mailbox: Bool, received: Bool, at: Date?, subjects: [String], emails: Int, toWarn: Bool,
                             warned: Bool, contacted: LogReading.Reach.Contact?, through: String?)] = [:]
        for reach in reaches {
            let subject = reach.subject.isEmpty ? "(no subject)" : reach.subject
            for recipient in reach.recipients where !recipient.expanded && [.received, .sent, .notAMailbox].contains(recipient.outcome) {
                let contacted = recipient.contacted
                guard var seen = found[recipient.address] else {
                    order.append(recipient.address)
                    found[recipient.address] = (recipient.inside, recipient.mailbox, recipient.outcome == .received, recipient.at, [subject], 1,
                                                recipient.toWarn, recipient.warned == true, contacted, recipient.via)
                    continue
                }
                seen.received = seen.received || recipient.outcome == .received
                if let at = recipient.at { seen.at = min(seen.at ?? at, at) }
                if !seen.subjects.contains(subject) { seen.subjects.append(subject) }
                seen.emails += 1
                seen.toWarn = seen.toWarn || recipient.toWarn
                seen.warned = seen.warned && recipient.warned == true
                if let contacted, seen.contacted.map({ contacted.at < $0.at }) ?? true { seen.contacted = contacted }
                // Named itself by any of them: not only through a group.
                if recipient.via == nil { seen.through = nil }
                found[recipient.address] = seen
            }
        }
        return order.compactMap { address in
            found[address].map { GotIt(address: address, inside: $0.inside, mailbox: $0.mailbox, received: $0.received, at: $0.at,
                                       subjects: $0.subjects, emails: $0.emails, toWarn: $0.toWarn, warned: $0.warned,
                                       contacted: $0.contacted, through: $0.through ?? "") }
        }
    }

    /// The list's columns: the address first, as `Email`, so a mail merge or a contacts import finds it.
    public static let gotItColumns = ["Email", "Where", "Got it", "First got", "Emails", "Subjects", "Warned", "To warn",
                                      "First contacted after", "Contacted by", "Contact subject", "Through group", "2-Step Verification"]

    /// `got` as a table under `gotItColumns`; 2-Step Verification said for a person here only with the directory read (`no2SV`).
    public static func gotItTable(_ got: [GotIt], no2SV: Set<String>?) -> Table {
        Table(columns: gotItColumns, rows: got.map { one in
            [.text(one.address), .text(one.inside ? "inside" : "outside"),
             .text(one.received ? "received" : "sent, no bounce or failure in the logs read"), .time(one.at), .text(String(one.emails)),
             .text(one.subjects.joined(separator: "; ")), .text(one.warned ? "yes" : ""), .text(one.toWarn ? "yes" : ""),
             .time(one.contacted?.at), .text(one.contacted?.sender ?? ""), .text(one.contacted?.subject ?? ""), .text(one.through),
             .text(one.inside && one.mailbox ? no2SV.map { $0.contains(one.address.lowercased()) ? "off" : "on" } ?? "" : "")]
        })
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
    /// Every address each email was sent to or received by, bounces too, a row each email and address (Who it reached's own
    /// columns): the record beside the list of who it got to.
    public let reached: Table
    /// Where it started: the first account taken over and the email picked as the phish that got it (Investigate).
    public let wayIn: LogReading.WayIn?

    public static func == (a: Self, b: Self) -> Bool {
        a.record == b.record && a.made == b.made && a.madeBy == b.madeBy && a.times == b.times && a.counts == b.counts
            && a.actions == b.actions && a.standing.map { [$0.account, $0.words] } == b.standing.map { [$0.account, $0.words] }
            && a.toDo == b.toDo && a.timeline == b.timeline && a.evidence == b.evidence && a.emails == b.emails && a.reached == b.reached && a.wayIn == b.wayIn
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

        // Everyone the attacker's emails got to, once each, and the emails a sentence and a row each.
        let got = gotIt(reading.reaches)
        func gotTable(_ keep: (GotIt) -> Bool) -> Table { gotItTable(got.filter(keep), no2SV: no2SV) }
        var emails: [String] = [], emailRows: [[Cell]] = []
        for reach in reading.reaches {
            let subject = reach.subject.isEmpty ? "(no subject)" : reach.subject
            let listed = gotIt([reach])
            let senders = reach.senders.isEmpty ? "" : " from \(reach.senders.joined(separator: ", "))"
            let warned = reach.warnings.filter { $0.problem == nil }
            let sent = (reach.recipients.compactMap(\.at)).min()
            emails.append("“\(subject)” (\(reach.messageID))\(senders): got to \(listed.count) \(listed.count == 1 ? "address" : "addresses") "
                + "(\(listed.filter { !$0.inside }.count) outside); \(listed.filter(\.toWarn).count) still to warn, "
                + "\(listed.filter { $0.contacted != nil }.count) contacted from here after it."
                + (warned.isEmpty ? " No warning picked counts yet."
                   : " Warned by " + warned.map { "“\($0.subject.isEmpty ? "(no subject)" : $0.subject)” from \($0.sender)" + ($0.at.map { " at \(when($0))" } ?? "") }
                    .joined(separator: "; ") + "."))
            emailRows.append([.text(subject), .text(reach.messageID), .text(reach.senders.joined(separator: ", ")), .time(sent),
                              .text(String(listed.count)), .text(String(listed.filter { !$0.inside }.count)), .text(String(listed.filter(\.toWarn).count))])
        }

        // Every step taken: what the logs show done to each account (an admin's or Google's), what this app ran, the emails
        // pulled, each warning that counted, and the notes.
        var actions: [Action] = []
        for status in statuses {
            for moment in status.timeline where moment.who == .admin || moment.who == .google {
                actions.append(Action(at: moment.at, what: moment.words + (moment.count > 1 ? " (\(moment.count) times)" : ""),
                                      account: status.account, source: moment.who == .admin ? "Google's Admin log" : "Google's sign-in log"))
            }
        }
        let reached = Set(got.filter { $0.inside && $0.mailbox }.map { $0.address.lowercased() })
        let since = min(firstSign ?? record.opened, record.opened)
        for change in changes where change.at >= since && (accounts.contains(change.target.lowercased()) || reached.contains(change.target.lowercased())) {
            let outcome = change.ok.map { $0 ? "" : " (failed)" } ?? " (no result recorded)"
            actions.append(Action(at: change.at, what: change.what + outcome + (change.by.isEmpty ? "" : " by \(change.by)"),
                                  account: change.target, source: "This app's audit log"))
        }
        for task in reading.done {
            guard let done = task.done else { continue }
            let by = done.by.isEmpty ? "" : " (by \(done.by))"
            switch done.how {
            case .warned: continue   // each warning that counted is said below, from the Gmail log
            case .trashed: actions.append(Action(at: done.at, what: task.words + by, account: "", source: "This app's audit log (Phishing)"))
            case .nobodyHasIt: actions.append(Action(at: done.at, what: task.words + by, account: "", source: "Phishing's Find, kept on this Mac"))
            case .byHand(let how):
                actions.append(Action(at: done.at, what: "Done by hand" + by + ": " + task.words + " How: " + how,
                                      account: task.accounts.count == 1 ? task.accounts[0] : "", source: "Marked done on the incident"))
            }
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
        let pulled = reading.done.filter { [.trashed, .nobodyHasIt].contains($0.done?.how) }
        let byHand = reading.done.compactMap { task -> (task: LogReading.Task, how: String, at: Date, by: String)? in
            guard let done = task.done, case .byHand(let how) = done.how else { return nil }
            return (task, how, done.at, done.by)
        }
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
                  about: "Each email the attacker sent: who sent it, when, and how many it got to.",
                  table: Table(columns: ["subject", "Message-ID", "from", "sent", "got to", "outside", "still to warn"], rows: emailRows)),
            Count(id: "gotIt", label: "Got an email of the attacker's", number: got.count,
                  about: "Each address an email of the attacker's got to, once, however many: a receipt here, or a send nothing says "
                    + "failed. A bounce, a quarantine or a rejection didn't get through, so isn't listed. Export it to send the warning.",
                  table: gotTable { _ in true }),
            Count(id: "gotItOutside", label: "Got it, outside", number: got.filter { !$0.inside }.count,
                  about: "The addresses outside an email of the attacker's got to: who to warn that this app can't see into.",
                  table: gotTable { !$0.inside }),
            Count(id: "toWarn", label: "Still to warn", number: got.filter(\.toWarn).count,
                  about: "Got one, and not shown warned of it by a warning picked that counts.", table: gotTable(\.toWarn)),
            Count(id: "warned", label: "Warned", number: got.filter(\.warned).count,
                  about: "Shown warned of every one that got to them, by the log's own word: their receipt of a warning picked (here), or "
                    + "its send (outside).", table: gotTable(\.warned)),
            Count(id: "contacted", label: "Contacted from here after", number: got.filter { $0.contacted != nil }.count,
                  about: "Sent an email from an account here after one of the attacker's got to them: the first, and how many.",
                  table: gotTable { $0.contacted != nil }),
            Count(id: "notContacted", label: "Still to warn, no contact from here seen", number: got.filter { $0.toWarn && $0.contacted == nil }.count,
                  about: "Still to warn, and no email from here after the attacker's in the logs read.",
                  table: gotTable { $0.toWarn && $0.contacted == nil }),
        ]
        if let picked = reading.wayIn?.picked {
            counts.append(Count(id: "gotPhish", label: "Got the email that started it", number: picked.receivedBy.count,
                                about: "Everyone here the logs read show receiving “\(picked.subject.isEmpty ? "(no subject)" : picked.subject)” from "
                                    + "\(picked.sender): they may have fallen for it too.",
                                table: Table(columns: ["Email", "Touched by the attacker"], rows: picked.receivedBy.map { address in
                                    [.text(address), .text(accounts.contains(address.lowercased()) ? "yes" : "")]
                                })))
        }
        if let no2SV {
            counts.append(Count(id: "reached2SV", label: "Got it here with 2-Step Verification off",
                                number: got.filter { $0.inside && $0.mailbox && no2SV.contains($0.address.lowercased()) }.count,
                                about: "People here an email of the attacker's got to who have 2-Step Verification off: the next accounts at risk.",
                                table: gotTable { $0.inside && $0.mailbox && no2SV.contains($0.address.lowercased()) }))
        }
        counts += [
            Count(id: "pulled", label: "Emails pulled from every mailbox", number: pulled.count,
                  about: "Emails Phishing trashed from every mailbox that had them, or showed nobody here has.",
                  table: Table(columns: ["what", "when", "by"], rows: pulled.map { [.text($0.words), .time($0.done?.at), .text($0.done?.by ?? "")] })),
        ]
        if !byHand.isEmpty {
            counts.append(Count(id: "byHand", label: "Marked done by hand", number: byHand.count,
                                about: "What no log can show done, marked done on the incident: how, when and by whom, as typed.",
                                table: Table(columns: ["what", "how", "when", "by"], rows: byHand.map { [.text($0.task.words), .text($0.how), .time($0.at), .text($0.by)] })))
        }
        counts += [
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
                              toDo: reading.toDo.map { "\($0.id): \($0.words)" }, timeline: timeline, evidence: evidence, emails: emails,
                              reached: Table(columns: ["email", "Message-ID"] + LogReading.Reach.columns, rows: reading.reaches.flatMap { reach in
                                  reach.rows.map { [.text(reach.subject.isEmpty ? "(no subject)" : reach.subject), .text(reach.messageID)] + $0.map(Cell.text) }
                              }), wayIn: reading.wayIn)
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

    /// A piece of the report as it's drawn. The text, the Markdown and the PDF are each drawn from the same pieces, so the three
    /// always say the same; each piece holds plain text, which no format reads as markup.
    public enum Block: Sendable, Equatable {
        /// The report's title, first and once.
        case title(String)
        case heading(String)
        /// A line on its own.
        case line(String)
        /// An item of a list.
        case item(String)
        /// A table: the timeline.
        case table(columns: [String], rows: [[String]])
        /// Lines kept exactly as they are, in a fixed-width font: each evidence file's SHA-256.
        case fixed([String])
        /// A space between two parts of a section.
        case gap
    }

    /// The report, in its order: what it is, the summary, the numbers, where it started, what was done, who the emails reached,
    /// where each account stands, what's left, the timeline, the notes and the review, and the evidence. `hashes` are the
    /// evidence's files' SHA-256, when the export has worked them out.
    public func blocks(_ when: (Date) -> String, zone: String = "", hashes: [(file: String, sha256: String)] = []) -> [Block] {
        var out: [Block] = []
        func heading(_ text: String) { out.append(.heading(text)) }
        func line(_ text: String) { out.append(.line(text)) }
        func item(_ text: String) { out.append(.item(text)) }
        func field(_ label: String, _ value: String) { if !value.isEmpty { line("\(label): \(value)") } }
        func paragraphs(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let review = record.review

        out.append(.title(record.title))
        line("Domain: \(record.domain)")
        line("Opened (identified): \(when(record.opened))" + (record.openedBy.isEmpty ? "" : " by \(record.openedBy)"))
        field("How it was reported", record.reported)
        field("Type", review.kind)
        field("Severity", review.severity)
        line("Report made \(when(made))" + (madeBy.isEmpty ? "" : " by \(madeBy)") + " with GAM GUI, from the evidence listed at the end.")
        if !zone.isEmpty { line("Times are in \(zone).") }
        line("Every count and list below is worked out by code from Google's logs and this app's audit log; only "
             + (review.summary.isEmpty ? "" : "the summary, ") + "the notes, the review and what was marked done by hand are typed.")

        if !review.summary.isEmpty {
            heading("Summary")
            for paragraph in paragraphs(review.summary) { line(paragraph) }
            if review.summaryDrafted {
                line("First drafted by the on-device model from this report's counts and steps, then checked before it was kept.")
            }
        }

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
        for count in counts where count.id != "actions" { item("\(count.label): \(count.number)") }

        heading("Where it started")
        line(wayInWords(when))

        heading("What was done")
        if actions.isEmpty { line("No step taken shows in the logs read, this app's audit log, or the notes.") }
        for action in actions {
            item("\(when(action.at)): \(action.what)" + (action.account.isEmpty ? "" : " [\(action.account)]") + " (shown by \(action.source))")
        }

        heading("The attacker's emails, and who they reached")
        if emails.isEmpty { line("No email the attacker sent shows in the logs read.") }
        for email in emails { item(email) }
        if let got = count("gotIt"), got.number > 0 {
            line("Everyone they got to, once each, with whether they were warned and contacted from here after, is in who-got-it.csv; "
                 + "every address each email was sent to, bounces too, is in who-it-reached.csv.")
        }

        heading("Where each account stands")
        if standing.isEmpty { line("No account the attacker touched shows in the logs read.") }
        for (account, words) in standing { item("\(account): \(words)") }

        heading("Still to do")
        if toDo.isEmpty { line("Nothing left that the logs read can show.") }
        for task in toDo { item(task) }

        heading("Timeline")
        if timeline.rows.isEmpty { line("Nothing in the logs read.") } else {
            out.append(.table(columns: timeline.columns, rows: timeline.rows.map { $0.map { $0.words(when) } }))
        }

        heading("Notes")
        if record.notes.isEmpty { line("None.") }
        for note in record.notes { item("\(when(note.at)): \(note.text)") }

        heading("Post-incident review: lessons learned and the plan going forward")
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
                for step in paragraphs(review.plan) { item(step) }
            }
            out.append(.gap)
            line("The review meeting's agenda:")
        }
        for step in Self.agenda(self) { line(step) }

        heading("Evidence")
        line("Each read of the logs kept with the incident, exactly as exported from Google's reports, is in the evidence folder.")
        for each in evidence { item(each.name + (each.about.isEmpty ? "" : ": \(each.about)")) }
        if !hashes.isEmpty {
            out.append(.gap)
            line("SHA-256 of each evidence file, to show it is unchanged:")
            out.append(.fixed(hashes.map { "\($0.sha256)  \($0.file)" }))
        }
        return out
    }

    /// The report as plain text (`blocks`): each heading in capitals over a rule, each item after a bullet, the timeline a row
    /// a line.
    public func text(_ when: (Date) -> String, zone: String = "", hashes: [(file: String, sha256: String)] = []) -> String {
        Self.text(blocks(when, zone: zone, hashes: hashes))
    }

    public static func text(_ blocks: [Block]) -> String {
        var out: [String] = []
        for block in blocks {
            switch block {
            case .title(let title): out.append("INCIDENT REPORT: \(title)")
            case .heading(let text): out += ["", text.uppercased(), String(repeating: "=", count: min(text.count, 72))]
            case .line(let text): out.append(text)
            case .item(let text): out.append("• " + text)
            case .table(_, let rows): out += rows.map { $0.joined(separator: "  ·  ") }
            case .fixed(let lines): out += lines
            case .gap: out.append("")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The report as Markdown (`blocks`), for a wiki, a ticket or a repository: every piece escaped (`markdown(escaping:)`), so
    /// a subject an attacker wrote reads as the words it is, never a link, an image, HTML or a heading.
    public func markdown(_ when: (Date) -> String, zone: String = "", hashes: [(file: String, sha256: String)] = []) -> String {
        Self.markdown(blocks(when, zone: zone, hashes: hashes))
    }

    public static func markdown(_ blocks: [Block]) -> String {
        var out = "", last: Block?
        for block in blocks {
            let chunk: String
            switch block {
            case .title(let title): chunk = "# Incident report: " + markdown(escaping: title)
            case .heading(let text): chunk = "## " + markdown(escaping: text)
            case .line(let text): chunk = markdown(escaping: text)
            case .item(let text): chunk = "- " + markdown(escaping: text)
            case .table(let columns, let rows):
                func row(_ cells: [String]) -> String { "| " + cells.map(markdown(escaping:)).joined(separator: " | ") + " |" }
                chunk = ([row(columns), "|" + String(repeating: " --- |", count: columns.count)] + rows.map(row)).joined(separator: "\n")
            case .fixed(let lines):
                // A fence longer than any run of backticks in it, so nothing in it can close it.
                var longest = 0
                for line in lines {
                    var run = 0
                    for character in line {
                        run = character == "`" ? run + 1 : 0
                        longest = max(longest, run)
                    }
                }
                let fence = String(repeating: "`", count: max(3, longest + 1))
                chunk = ([fence] + lines + [fence]).joined(separator: "\n")
            case .gap: continue
            }
            if !out.isEmpty {
                if case .item? = last, case .item = block { out += "\n" } else { out += "\n\n" }
            }
            out += chunk
            last = block
        }
        return out + "\n"
    }

    /// `text` as Markdown that says exactly it, on one line (a line break is a space): each character CommonMark or GitHub's
    /// flavour reads as markup escaped where it would be read so: the inline ones anywhere (`\` `` ` `` `*` `_` `[` `]` `<`
    /// `>` `(` `)` `!` `|` `~` `&` `$` `{` `}` `#` `+`), and at the start a list's dash or number, or a heading's `=`.
    /// Leading spaces go, so nothing becomes code.
    static func markdown(escaping text: String) -> String {
        let flat = text.map { $0.isNewline ? " " : $0 }
        var out = ""
        var start = true, digits = false
        for character in String(flat).drop(while: { $0 == " " || $0 == "\t" }) {
            if "\\`*_[]<>()!|~&${}#+".contains(character) || (start && "-=".contains(character))
                || (digits && ".)".contains(character)) {
                out.append("\\")
            }
            out.append(character)
            digits = (start || digits) && character.isASCII && character.isNumber
            start = false
        }
        return out
    }

    /// Where it started, in words: the email picked as the phish that got the first account, and who else here received it; or
    /// what's left to pick it from.
    public func wayInWords(_ when: (Date) -> String) -> String {
        guard let wayIn else { return "No account the attacker got into shows in the logs read." }
        if let picked = wayIn.picked {
            return "The email that started it: “\(picked.subject.isEmpty ? "(no subject)" : picked.subject)” from \(picked.sender.isEmpty ? "a sender the log doesn't name" : picked.sender)"
                + " (Message-ID \(picked.messageID)). " + Self.receivedWords(picked, wayIn: wayIn, when: when)
        }
        if let unread = wayIn.pickedUnread {
            return "The email picked as where it started (\(unread)) isn't in the logs read: pull \(wayIn.account)'s Gmail log from before \(when(wayIn.attackedAt))."
        }
        return "Not picked yet: \(wayIn.candidates.count) email\(wayIn.candidates.count == 1 ? "" : "s") \(wayIn.account) received from outside in the "
            + "\(LogReading.wayInHours) hours before the attacker's first sign at \(when(wayIn.attackedAt)) are listed on Investigate, under Where it started."
    }

    /// Who received the email picked, by name, and when, against the attacker's first sign: the first account taken over is
    /// said as one of them only when the logs show it receiving it.
    public static func receivedWords(_ picked: LogReading.WayIn.Email, wayIn: LogReading.WayIn, when: (Date) -> String) -> String {
        let first = (picked.at.map { "First received \(when($0)), before" } ?? "Before") + " the attacker's first sign, on \(wayIn.account) at "
            + "\(when(wayIn.attackedAt))."
        let others = picked.receivedBy.filter { $0 != wayIn.account }
        let who: String = if picked.receivedBy.isEmpty { "No one here is shown receiving it." }
            else if others.isEmpty { "Only \(wayIn.account) is shown receiving it." }
            else if picked.receivedBy.contains(wayIn.account) {
                "\(wayIn.account) received it, and so did \(others.joined(separator: ", ")): they may have fallen for it too."
            } else { "Received here by \(others.joined(separator: ", ")): they may have fallen for it too." }
        return first + " " + who
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
            "4. Who it got to and whether they were warned: \(number("gotIt")) addresses (\(number("gotItOutside")) outside), "
                + "\(number("toWarn")) still to warn, \(number("contacted")) contacted from here after.",
            "5. What's still open: \(number("toDo")) items" + (number("reached2SV") > 0 ? ", and \(number("reached2SV")) people it got to here with 2-Step Verification off" : "") + ".",
            "6. How they got in, and why it worked" + (report.wayIn?.picked.map {
                ": the logs show it began with “\($0.subject.isEmpty ? "(no subject)" : $0.subject)” from \($0.sender)."
            } ?? "."),
            "7. What went well, and what to do better.",
            "8. The plan going forward: each change with who owns it and by when.",
        ]
    }
}
