import Assist
import Directory
import GamEngine
import Stores
import SwiftUI

/// What a to-do item's "Do It Here" hands Incident to pick once it has read the person: a computer the attacker's sign-in
/// joined (by the Devices log's ID for it, else by when it registered), or clearing the recovery details. The screen's own
/// type, so the screens that can run gam never name the reader's module.
enum SecurePick: Equatable {
    case computer(resourceID: String, registeredAt: Date?)
    case clearRecovery
}

/// "Read the logs" (docs/plans/2026-10-19-on-device-log-reader.md): what a pull of the incident logs shows, found by
/// rules in code (`LogReading`), each finding with the fixes it points to, and on request the on-device model's
/// explanation (`LogExplainer`). It changes nothing and reaches no change: a fix only hands an address or a Message-ID
/// to its screen (Incident checks the person; Phishing finds who has the email), and that screen shows its
/// own preview, confirmed there. Its own file, apart from anything that can run gam (invariant 10, `WriteRouteTests`).
struct LogReaderView: View {
    /// Which part this is: the findings (Investigate) or where each account stands and what's left to do (Respond).
    enum Part { case findings, toDo }

    let part: Part
    let pull: IncidentLogs.Pull
    /// This app's audit log: read with the pull for the emails Phishing pulled on `domain` (`PhishingAudit`), which show done.
    let auditURL: URL
    let domain: String
    /// The emails Phishing's Find showed nobody on this domain has, which show done too.
    let nobodyHas: [NobodyHasStore.Check]
    /// Why those can't be kept (their store didn't open, or a save failed); nil when they are.
    let nobodyHasProblem: String?
    /// The reading and the model's explanation, kept by the screen across its tabs.
    let memory: Memory
    /// Opens Incident for a person and checks them, with one thing picked when a "Do It Here" asked for it.
    let secure: (String, SecurePick?) -> Void
    /// Opens Phishing with a Message-ID and finds who has the email.
    let pullEmail: (String) -> Void
    /// Sign-ins marked as the person's own on this domain ("That was them"): the reader makes no suspect of them.
    let marks: [KnownSignInStore.Mark]
    /// Why a sign-in can't be marked (the store didn't open); nil when it can.
    let marksProblem: String?
    /// Marks an account's sign-in from an address as theirs, with a note: the problem in words, or nil once saved.
    let markTheirs: (_ account: String, _ address: String, _ note: String) -> String?
    /// Undoes a mark by its ID: the problem in words, or nil once saved.
    let unmark: (String) -> String?
    /// Shows the logs narrowed to the events a to-do item is about ("Show the Events").
    let show: (IncidentLogs.Filter) -> Void
    /// Reads these logs again for these accounts, adding to what's shown ("Pull Again"): a read.
    let pullAgain: (_ logs: [ActivityLogs.Application], _ accounts: [String]) -> Void
    @State private var marking: Marking?
    @State private var markProblem: String?

    /// What the reader keeps while the screen is open, whichever tab shows: the pull's reading, made once per pull and off
    /// the main thread (the rules scan every event, and a whole pull for every account holds hundreds of thousands: read in
    /// a view's body, it stopped the app for minutes, failure log 2026-10-23), and the model's explanation of it. The screen
    /// makes a new one each time it opens, so coming back from Phishing reads its runs again.
    @MainActor
    @Observable
    final class Memory {
        fileprivate var read: (key: String, reading: LogReading.Reading)?
        /// The read under way, by its pull's key.
        @ObservationIgnored private var reading: (key: String, task: Task<Void, Never>)?
        fileprivate var explained: (reading: LogReading.Reading, state: Explaining)?
        /// A reading has come: debug snapshots wait for it before they scroll to it.
        var hasReading: Bool { read != nil }

        /// Reads `pull` for `key` in the background, once, with what the audit log shows Phishing pulled: either tab asking
        /// for the key being read waits on that read. A newer key's read replaces it, and the older one's reading is dropped
        /// when it ends.
        fileprivate func begin(_ pull: IncidentLogs.Pull, marks: [KnownSignInStore.Mark], auditURL: URL, domain: String,
                                nobodyHas: [NobodyHasStore.Check], key: String) {
            guard read?.key != key, reading?.key != key else { return }
            reading = (key, Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    LogReaderView.reading(pull, marks: marks, pulled: PhishingAudit.latestRuns(in: auditURL, on: domain), nobodyHas: nobodyHas)
                }.value
                guard let self, self.reading?.key == key else { return }
                self.read = (key, found)
                self.reading = nil
            })
        }
    }

    /// What identifies the pull read: its query, each log's outcome, and the sign-ins marked as theirs.
    private var key: String {
        "\(domain)|\(pull.query)|" + pull.logs.map { "\($0.application.rawValue):\((try? $0.rows.get().count).map(String.init) ?? "failed")" }
            .joined(separator: ",") + "|" + marks.map(\.id).joined(separator: ",")
            + "|" + nobodyHas.map { "\($0.id)@\($0.at.timeIntervalSince1970)" }.joined(separator: ",")
    }

    /// The sign-in a "That Was Them" asks a note for.
    struct Marking: Identifiable {
        let account: String
        let address: String
        var id: String { account + "|" + address }
    }

    enum Explaining {
        case asking
        case done(LogExplainer.Explanation)
        case failed(String)
    }

    /// What the rules find in `pull`, told the address it was pulled by, the logs it read, the sign-ins marked as theirs, the
    /// logs that stopped at their cap with the oldest event each read (one read for every account can stop short of the
    /// attack: what's still to do says so), each email's latest Phishing run in the audit log, and the emails Phishing's
    /// Find showed nobody here has. Off the main thread (`Memory`).
    nonisolated static func reading(_ pull: IncidentLogs.Pull, marks: [KnownSignInStore.Mark], pulled: [PhishingAudit.Run],
                                    nobodyHas: [NobodyHasStore.Check]) -> LogReading.Reading {
        let read = Set(pull.logs.filter { (try? $0.rows.get()) != nil }.map(\.application.rawValue))
        let theirs = Set(marks.map { LogReading.key(account: $0.account, address: $0.address) })
        var capped: [String: Date] = [:]
        for log in pull.logs where log.capped {
            if let oldest = ((try? log.rows.get()) ?? []).compactMap(\.date).min() { capped[log.application.rawValue] = oldest }
        }
        let runs = pulled.map { run in
            LogReading.Pulled(messageID: run.messageID, at: run.at, by: run.by, steps: run.steps, trashed: run.trashed,
                              failed: run.failed, mailboxes: run.mailboxes, searchedEverywhere: run.searchedEverywhere)
        }
        let checks = nobodyHas.map { LogReading.NobodyHas(messageID: $0.messageID, at: $0.at, by: $0.by) }
        return LogReading.read(events(pull), context: LogReading.Context(pulledBy: pull.query.ip, read: read, theirs: theirs,
                                                                         capped: capped, pulled: runs, nobodyHas: checks))
    }

    /// The logs that couldn't be read: their events aren't in the findings, and that is said.
    private var unread: [String] {
        pull.logs.filter { (try? $0.rows.get()) == nil }.map(\.application.name)
    }

    /// Every row read, as the reader sees it.
    nonisolated static func events(_ pull: IncidentLogs.Pull) -> [LogReading.Event] {
        pull.logs.flatMap { log in
            ((try? log.rows.get()) ?? []).map { row in
                LogReading.Event(log: row.application.rawValue, time: row.date, who: row.who, event: row.event, ip: row.ip,
                                 flagged: row.flagged,
                                 parameters: Dictionary(row.parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
                                 agent: row.agent, app: row.app)
            }
        }
    }

    var body: some View {
        let key = key
        Group {
            if let read = memory.read, read.key == key {
                switch part {
                case .findings: findings(read.reading)
                case .toDo: toDo(read.reading)
                }
            } else {
                readingNow
            }
        }
        .onChange(of: key, initial: true) { memory.begin(pull, marks: marks, auditURL: auditURL, domain: domain, nobodyHas: nobodyHas, key: key) }
        .sheet(item: $marking) { marking in
            MarkSheet(marking: marking, problem: $markProblem) { note in
                markProblem = markTheirs(marking.account, marking.address, note)
                if markProblem == nil { self.marking = nil }
            } cancel: {
                self.marking = nil
            }
        }
    }

    /// While the rules read the pull: the section in its place, saying how many events they're reading.
    private var readingNow: some View {
        let events = pull.logs.reduce(0) { $0 + ((try? $1.rows.get().count) ?? 0) }
        return Section {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the logs (\(events.formatted()) event\(events == 1 ? "" : "s"))…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reading the logs: \(events.formatted()) event\(events == 1 ? "" : "s")")
        } header: {
            Text(part == .findings ? "What the logs show" : "Where things stand").accessibilityAddTraits(.isHeader)
        }
    }

    /// Investigate: what the logs show, the sign-ins marked as theirs, and the model's explanation.
    private func findings(_ reading: LogReading.Reading) -> some View {
        Section {
            if !unread.isEmpty {
                Label("Not read, so not in these findings: " + unread.joined(separator: ", ") + ".", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if reading.findings.isEmpty {
                Text("Nothing in these logs matches a rule: no address Google flagged, and none named. Pull every account's logs "
                     + "by the attacker's address to see more.")
                    .foregroundStyle(.secondary)
            }
            ForEach(reading.findings) { finding in
                FindingRow(finding: finding, secure: secure, pullEmail: pullEmail, canMark: marksProblem == nil) { account, address in
                    markProblem = nil
                    marking = Marking(account: account, address: address)
                }
            }
            marked
            explanation(reading)
        } header: {
            Text("What the logs show").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Found by rules in code, from the logs above. A fix opens its screen with the person or the email filled in; "
                 + "nothing changes until you preview and confirm it there.")
        }
    }

    /// Respond: where each account stands, and what's left to do, each with a button for what can be done from here.
    private func toDo(_ reading: LogReading.Reading) -> some View {
        Section {
            if !reading.statuses.isEmpty {
                Text("Where each account stands").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                ForEach(reading.statuses, id: \.account) { status in StatusRow(status: status) }
            }
            Text("Still to do").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            // Every email still to pull at once (Pull All), never one done: Phishing finds each and lists only those someone
            // has. Only Message-IDs it can search by, at most its limit at a time: one it can't, or the rest past the limit,
            // never blocks the others.
            let pulls = reading.emailsToPull
            let searchable = pulls.filter { (try? GamCommands.MessageID(validating: $0)) != nil }
            let batch = Array(searchable.prefix(GamCommands.MessageID.mostPerFind))
            if batch.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(pulls.count) emails to pull from every mailbox.").foregroundStyle(.secondary)
                        Spacer()
                        Button(batch.count < searchable.count ? "Pull the First \(batch.count) Emails…" : "Pull All \(batch.count) Emails…") {
                            pullEmail(batch.joined(separator: "\n"))
                        }
                        .accessibilityHint("Opens Phishing with these emails and finds who has each. Nothing changes until you "
                                           + "preview and confirm there.")
                    }
                    if batch.count < searchable.count {
                        Text("Phishing searches \(GamCommands.MessageID.mostPerFind) at a time: pull these, then the rest from their "
                             + "own items below.").font(.callout).foregroundStyle(.secondary)
                    }
                    if searchable.count < pulls.count {
                        Text("\(pulls.count - searchable.count) of them \(pulls.count - searchable.count == 1 ? "has" : "have") a "
                             + "Message-ID Phishing can't search by: left out, each still listed below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if reading.toDo.isEmpty {
                Text(reading.statuses.isEmpty ? "Nothing to do that these logs show: no account the attacker touched."
                     : "Nothing left that these logs can show.").foregroundStyle(.secondary)
            }
            ForEach(reading.toDo) { task in
                TaskRow(task: task, secure: secure, pullEmail: pullEmail, show: show, pullAgain: pullAgain)
            }
            if !unread.isEmpty {
                Label("Not read, so not in this list: " + unread.joined(separator: ", ") + ".", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if !reading.done.isEmpty {
                Text("Done").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                ForEach(reading.done) { task in DoneRow(task: task) }
            }
            if let nobodyHasProblem {
                Label("An email Phishing's Find showed nobody has isn't kept, so it stays to do: \(nobodyHasProblem)",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        } header: {
            Text("Where things stand").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Worked out by rules in code from the logs on Investigate, and for the emails to pull from Phishing: its runs in "
                 + "this app's audit log, and what its Find showed nobody has. Show the Events and Pull Again only read; a fix "
                 + "opens its screen, and nothing changes until you preview and confirm it there.")
        }
    }

    /// The sign-ins marked as theirs on this domain, each with its note and an Undo: never hidden.
    @ViewBuilder private var marked: some View {
        if let marksProblem {
            Label("Sign-ins can't be marked as theirs: \(marksProblem)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        if !marks.isEmpty {
            Text("Marked as theirs").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            ForEach(marks.prefix(Self.marksShown)) { mark in
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(mark.account) from \(mark.address)").fontWeight(.semibold)
                            Text(mark.note)
                            Text("Marked \(mark.at.formatted(date: .abbreviated, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Marked as theirs: \(mark.account) from \(mark.address). \(mark.note)")
                    Spacer()
                    Button("Undo") { markProblem = unmark(mark.id) }
                        .accessibilityLabel("Undo: \(mark.account) from \(mark.address) is no longer marked as theirs")
                }
            }
            if marks.count > Self.marksShown { Text("And \(marks.count - Self.marksShown) more.").foregroundStyle(.secondary) }
            if marking == nil, let markProblem {
                Label(markProblem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        }
    }

    private static let marksShown = 20

    @ViewBuilder private func explanation(_ reading: LogReading.Reading) -> some View {
        let current = memory.explained.flatMap { $0.reading == reading ? $0.state : nil }
        if let unavailable = LogExplainer.unavailable {
            Label(unavailable, systemImage: "sparkles").foregroundStyle(.secondary)
        } else if !reading.statuses.isEmpty || !reading.findings.isEmpty {
            HStack {
                Text("Have the on-device model sum this up in plain words: what happened, what's done, what's most urgent. Nothing "
                     + "leaves this Mac.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if case .asking? = current { ProgressView().controlSize(.small) }
                Button("Explain") { explain(reading) }
                    .disabled({ if case .asking? = current { return true } else { return false } }())
                    .accessibilityLabel("Sum up the incident with the on-device model")
            }
        }
        switch current {
        case .done(let explanation)?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Written by the on-device model from what's above: check it against the timelines and the list.", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
                if !explanation.overview.isEmpty { Text(explanation.overview) }
                if !explanation.done.isEmpty {
                    Text("Done so far").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                    Text(explanation.done)
                }
                if !explanation.left.isEmpty {
                    Text("Most urgent").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                    ForEach(Array(explanation.left.enumerated()), id: \.offset) { _, point in
                        Text("• \(point.text) (\(point.cites.joined(separator: ", ")))")
                    }
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
        case .failed(let why)?:
            Label("The model couldn't explain them: \(why)", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .asking?, nil:
            EmptyView()
        }
    }

    private func explain(_ reading: LogReading.Reading) {
        let memory = memory
        memory.explained = (reading, .asking)
        Task {
            do {
                let explanation = try await LogExplainer.explain(reading, when: { $0.formatted(date: .abbreviated, time: .shortened) })
                if memory.explained?.reading == reading { memory.explained = (reading, .done(explanation)) }
            } catch {
                if memory.explained?.reading == reading { memory.explained = (reading, .failed(OnDeviceModel.failure(error))) }
            }
        }
    }
}

/// An account the attacker had, and where it stands: the lock as the logs show it, in words, with a symbol that never says
/// it alone.
private struct StatusRow: View {
    let status: LogReading.Status

    private var symbol: String {
        switch status.state {
        case .stillIn: "exclamationmark.octagon.fill"
        case .notLocked, .partlyLocked: "exclamationmark.triangle.fill"
        case .locked: "lock.fill"
        }
    }

    var body: some View {
        let words = status.words { $0.formatted(date: .abbreviated, time: .shortened) }
        VStack(alignment: .leading, spacing: 4) {
            summary(words)
            if !status.timeline.isEmpty {
                DisclosureGroup("Timeline: \(status.timeline.count) step\(status.timeline.count == 1 ? "" : "s")") {
                    ForEach(Array(status.timeline.enumerated()), id: \.offset) { _, moment in MomentRow(moment: moment) }
                }
                .padding(.leading, 28)
                .accessibilityLabel("\(status.account)'s timeline, \(status.timeline.count) steps")
            }
        }
    }

    private func summary(_ words: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.account).fontWeight(.semibold)
                Text(words)
            }
            .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).symbolRenderingMode(.multicolor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.account): \(words)")
    }
}

/// One finding: its sentence, said with what kind it is, and a button for each fix it points to.
private struct FindingRow: View {
    let finding: LogReading.Finding
    let secure: (String, SecurePick?) -> Void
    let pullEmail: (String) -> Void
    /// Sign-ins can be marked as theirs (the store opened).
    let canMark: Bool
    /// Asks the note for marking an account's sign-in from an address as theirs.
    let markTheirs: (_ account: String, _ address: String) -> Void

    private var symbol: String {
        switch finding.kind {
        case .signedInFromSuspect, .leftInPlace, .deviceAtSuspectSignIn, .appFromSuspect, .actedFromSuspect, .exportedFromSuspect,
             .passwordOnPhishingSite:
            "exclamationmark.octagon.fill"
        case .contactsTaken, .mailFromSuspect, .failedFromSuspect, .otherAppSession, .chatFromSuspect, .pastPhishingWarning,
             .breachedPassword: "exclamationmark.triangle.fill"
        case .agentActed: "sparkles"
        case .passwordOnOtherSite, .sharedAddress, .suspectAddress: "info.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(finding.id). \(finding.words)").textSelection(.enabled)
            } icon: {
                Image(systemName: symbol).symbolRenderingMode(.multicolor)
            }
            .accessibilityLabel("Finding \(finding.id): \(finding.words)")
            if !finding.drafts.isEmpty || (canMark && !finding.markable.isEmpty) {
                HStack {
                    if canMark, let address = finding.addresses.first {
                        if finding.markable.count == 1 {
                            Button("That Was Them…") { markTheirs(finding.markable[0], address) }
                                .accessibilityLabel("That was \(finding.markable[0]): mark their sign-in from \(address) as theirs")
                                .accessibilityHint(Self.markHint)
                        } else if !finding.markable.isEmpty {
                            Menu("That Was…") {
                                ForEach(finding.markable, id: \.self) { account in Button(account) { markTheirs(account, address) } }
                            }
                            .fixedSize()
                            .accessibilityLabel("Mark a sign-in from \(address) as the person's own")
                            .accessibilityHint(Self.markHint)
                        }
                    }
                    ForEach(finding.drafts, id: \.self) { draft in
                        Button(draft.title) {
                            switch draft {
                            case .secureAccount(let person): secure(person, nil)
                            case .undo(let person, let pick): secure(person, SecurePick(pick))
                            case .pullEmail(let id, _): pullEmail(id)
                            }
                        }
                        .accessibilityHint(hint(draft))
                    }
                }
                .padding(.leading, 28)
            }
        }
    }

    static let markHint = "Asks how you know. The sign-in is then listed under Marked as Theirs, and can be undone."

    private func hint(_ draft: LogReading.Draft) -> String {
        switch draft {
        case .secureAccount: "Opens Incident and checks them. Nothing changes until you preview and confirm there."
        case .undo: "Opens Incident, checks them and picks only this. Nothing changes until you preview and confirm there."
        case .pullEmail: "Opens Phishing and finds who has the email. Nothing changes until you preview and confirm there."
        }
    }
}

/// Asks how the operator knows a flagged sign-in was the person's own, then marks it: the note is kept with the mark.
private struct MarkSheet: View {
    let marking: LogReaderView.Marking
    @Binding var problem: String?
    let mark: (String) -> Void
    let cancel: () -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("That was \(marking.account)?").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Google marked a sign-in to \(marking.account) from \(marking.address) suspicious. Marked as theirs, it makes no "
                 + "suspect in Read the logs. It's listed under Marked as Theirs with your note, and can be undone.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("How you know", text: $note, prompt: Text("Their own passkey sign-in, through iCloud Private Relay"), axis: .vertical)
                .lineLimit(2...4)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Mark as Theirs") { mark(note) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Saves the mark on this Mac with your note.")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// One step of an account's timeline: when, who acted (said, and marked by a symbol that never says it alone), and what.
private struct MomentRow: View {
    let moment: LogReading.Moment

    private var symbol: String {
        switch moment.who {
        case .attacker: "exclamationmark.octagon.fill"
        case .admin: "lock.shield"
        case .google: "shield.lefthalf.filled"
        case .person: "person.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var body: some View {
        let when = moment.at.formatted(date: .abbreviated, time: .shortened)
            + (moment.until.map { " to " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(moment.words)
                Text(when).font(.callout).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).symbolRenderingMode(.multicolor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(when): \(moment.words)")
    }
}

/// One thing still to do: its number, the sentence, and a button for each fix it points to (the screen that does it).
private struct TaskRow: View {
    let task: LogReading.Task
    let secure: (String, SecurePick?) -> Void
    let pullEmail: (String) -> Void
    let show: (IncidentLogs.Filter) -> Void
    let pullAgain: ([ActivityLogs.Application], [String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(task.id). \(task.words)").textSelection(.enabled)
            } icon: {
                Image(systemName: "circle")
            }
            .accessibilityLabel("To do \(task.id): \(task.words)")
            if !task.drafts.isEmpty || task.shows != nil || !task.pullsAgain.isEmpty {
                HStack {
                    let logs = task.pullsAgain.compactMap(ActivityLogs.Application.init(rawValue:))
                    if !logs.isEmpty {
                        Button("Pull Again") { pullAgain(logs, task.accounts) }
                            .accessibilityLabel("Pull the \(logs.map(\.name).joined(separator: ", ")) logs again for these accounts")
                            .accessibilityHint("Reads them and adds what it finds to the logs shown. Nothing changes.")
                    }
                    ForEach(task.drafts, id: \.self) { draft in
                        Button(draft.title) {
                            switch draft {
                            case .secureAccount(let person): secure(person, nil)
                            case .undo(let person, let pick): secure(person, SecurePick(pick))
                            case .pullEmail(let id, _): pullEmail(id)
                            }
                        }
                        .accessibilityHint("Opens its screen with this filled in. Nothing changes until you preview and confirm there.")
                    }
                    if let shown = task.shows {
                        Button("Show the Events") { show(IncidentLogs.Filter(shown)) }
                            .accessibilityHint("Opens Investigate with the logs narrowed to the events this is about. Nothing changes.")
                    }
                }
                .padding(.leading, 28)
            }
        }
    }
}

/// Something done: its sentence, then how, when and by whom in words beside the check mark, which never says it alone.
private struct DoneRow: View {
    let task: LogReading.Task

    var body: some View {
        let when = task.done.map { done in
            let at = done.at.formatted(date: .abbreviated, time: .shortened) + (done.by.isEmpty ? "" : " by \(done.by)")
            return switch done.how {
            case .trashed: "Trashed \(at), as this app's audit log shows."
            case .nobodyHasIt: "Checked \(at), as Phishing's Find showed."
            }
        } ?? "Done."
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(task.id). \(task.words)")
                Text(when).font(.callout).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Done, \(task.id): \(task.words) \(when)")
    }
}

extension IncidentLogs.Filter {
    /// The reader's word for what a to-do item is about, as the logs' filter: the log names read as the app's logs.
    init(_ shown: LogReading.Shown) {
        self.init(accounts: shown.accounts, addresses: shown.addresses,
                  applications: shown.logs.compactMap(ActivityLogs.Application.init(rawValue:)), apps: shown.apps, agent: shown.agent)
    }
}

extension SecurePick {
    init(_ pick: LogReading.Pick) {
        switch pick {
        case .computer(let resourceID, let registeredAt): self = .computer(resourceID: resourceID, registeredAt: registeredAt)
        case .clearRecovery: self = .clearRecovery
        }
    }
}
