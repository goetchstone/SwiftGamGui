import AppKit
import Assist
import ChangeCore
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
    /// The tenant's domains, lowercased: an address at one is inside (Who it reached).
    let domains: Set<String>
    /// Every person's address and alias here, lowercased, to their own; nil while the directory isn't read (Who it reached).
    let people: [String: String]?
    /// Which directory snapshot those come from: what the reading is keyed by, never the map hashed at every redraw.
    let directoryKey: String
    /// The warnings picked for the emails the attacker sent, kept with the open incident (Who it reached).
    let warnings: [IncidentStore.Warning]
    /// Keeps a warning picked for an email (nil clears that email's): the problem in words, or nil once kept. Nil with no
    /// incident open, where a pick couldn't be kept.
    let pickWarning: ((_ email: String, _ warning: String?) -> String?)?
    @State private var marking: Marking?
    @State private var markProblem: String?
    /// The warnings were cleared, so Respond reads again with nothing shown: VoiceOver hears when it's back (final review
    /// 2026-10-25: the sections came back in silence).
    @State private var announceReread: String?
    @Environment(\.appearsActive) private var appearsActive

    /// What the reader keeps while the screen is open, whichever tab shows: the pull's reading, made once per pull and off
    /// the main thread (the rules scan every event, and a whole pull for every account holds hundreds of thousands: read in
    /// a view's body, it stopped the app for minutes, failure log 2026-10-23), and the model's explanation of it. The screen
    /// makes a new one each time it opens, so coming back from Phishing reads its runs again.
    @MainActor
    @Observable
    final class Memory {
        fileprivate var read: (key: String, reading: LogReading.Reading)?
        /// The read under way, by its pull's key, and whether it's still wanted (not, once the reading shown is asked again).
        @ObservationIgnored private var reading: (key: String, task: Task<Void, Never>, wanted: Bool)?
        /// The newest read asked while another is under way, started when that one ends: picks in a row run one reading at a
        /// time, each of a whole pull, not one each at once (final review 2026-10-25: three quick picks ran three).
        @ObservationIgnored private var queued: (key: String, start: () -> Void)?
        fileprivate var explained: (reading: LogReading.Reading, state: Explaining)?
        /// A reading has come: debug snapshots wait for it before they scroll to it.
        var hasReading: Bool { read != nil }
        /// The first Who it reached section's anchor, for debug snapshots to scroll to.
        var firstReach: String? { read?.reading.reaches.first.map { LogReaderView.reachAnchor($0.messageID) } }

        /// Reads `pull` for `key` in the background, once, with what the audit log shows Phishing pulled: either tab asking
        /// for the key being read waits on that read. One read runs at a time: a newer key asked while one runs waits in
        /// `queued` (the newest only) and starts when it ends; the one that ends still lands, and the body shows it only if
        /// it's the key asked or `staleIsSafe` allows; one no longer wanted ends unshown.
        fileprivate func begin(_ pull: IncidentLogs.Pull, marks: [KnownSignInStore.Mark], auditURL: URL, domain: String,
                                nobodyHas: [NobodyHasStore.Check], domains: Set<String>, people: [String: String]?,
                                warnings: [IncidentStore.Warning], key: String) {
            // The reading shown is the one asked for again (a pick, then its clear): a read still under way is for a key no
            // longer asked, and must never land over it (review 2026-10-24); it runs on unwanted, so a pick after it still
            // waits for it (final review 2026-10-25: it ran beside the next).
            if read?.key == key {
                reading?.wanted = false
                queued = nil
                return
            }
            guard reading?.key != key else {
                reading?.wanted = true
                queued = nil
                return
            }
            if reading != nil {
                queued = (key, { [weak self] in
                    self?.begin(pull, marks: marks, auditURL: auditURL, domain: domain, nobodyHas: nobodyHas, domains: domains, people: people,
                                warnings: warnings, key: key)
                })
                return
            }
            reading = (key, Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    LogReaderView.reading(pull, marks: marks, pulled: PhishingAudit.latestRuns(in: auditURL, on: domain), nobodyHas: nobodyHas,
                                          domains: domains, people: people, warnings: warnings)
                }.value
                guard let self, let reading = self.reading, reading.key == key else { return }
                if reading.wanted { self.read = (key, found) }
                self.reading = nil
                if let next = self.queued {
                    self.queued = nil
                    next.start()
                }
            }, true)
        }
    }

    /// Where an email's Who it reached section is, to scroll to.
    static func reachAnchor(_ messageID: String) -> String { "reader.reach.\(messageID)" }

    /// What identifies the pull read: its query, each log's outcome, and the sign-ins marked as theirs.
    private var key: String {
        "\(domain)|\(pull.query)|" + pull.logs.map { "\($0.application.rawValue):\((try? $0.rows.get().count).map(String.init) ?? "failed")" }
            .joined(separator: ",") + "|" + marks.map(\.id).joined(separator: ",")
            + "|" + nobodyHas.map { "\($0.id)@\($0.at.timeIntervalSince1970)" }.joined(separator: ",")
            + "|" + Self.reachKey(warnings: warnings, directoryKey: directoryKey)
    }

    /// What only Who it reached reads: a change of these keeps the reading shown until the new one comes, rather than swap
    /// both tabs for "Reading the logs…" at every pick (review 2026-10-24).
    static func reachKey(warnings: [IncidentStore.Warning], directoryKey: String) -> String {
        // A space between the two: a Message-ID holds none (`IncidentStore.isMessageID`), though it can hold ">" (final review
        // 2026-10-25: split there, an email's section never said it was updating).
        "reach:" + warnings.map { "\($0.email) \($0.warning)" }.joined(separator: "\n") + "\u{1F}" + directoryKey
    }

    /// The emails whose picks differ between two keys: the sections updating while the last reading stays on screen, not
    /// every email's (final review 2026-10-25).
    static func picksChanged(shown: String, asked: String) -> Set<String> {
        func picks(_ key: String) -> Set<Substring> {
            guard let range = key.range(of: "|reach:") else { return [] }
            return Set(key[range.upperBound...].split(separator: "\u{1F}", omittingEmptySubsequences: false).first?.split(separator: "\n") ?? [])
        }
        return Set(picks(shown).symmetricDifference(picks(asked)).compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    /// The last reading may stay on screen while the new one comes only when that's safe: the same pull and directory, and
    /// only picks added, which can only add to who's shown warned. A pick cleared, or the directory changed, could leave
    /// someone shown warned who isn't (review 2026-10-24): then "Reading the logs…" until it comes.
    static func staleIsSafe(shown: String, asked: String) -> Bool {
        guard let shownReach = shown.range(of: "|reach:"), let askedReach = asked.range(of: "|reach:"),
              shown[..<shownReach.lowerBound] == asked[..<askedReach.lowerBound] else { return false }
        let old = shown[shownReach.upperBound...].split(separator: "\u{1F}", omittingEmptySubsequences: false)
        let new = asked[askedReach.upperBound...].split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard old.count == 2, new.count == 2, old[1] == new[1] else { return false }
        return Set(old[0].split(separator: "\n")).isSubset(of: Set(new[0].split(separator: "\n")))
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
                                    nobodyHas: [NobodyHasStore.Check], domains: Set<String> = [], people: [String: String]? = nil,
                                    warnings: [IncidentStore.Warning] = []) -> LogReading.Reading {
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
        // The warnings picked, by the email they warn about (Who it reached).
        var picked: [String: Set<String>] = [:]
        for warning in warnings { picked[warning.email, default: []].insert(warning.warning) }
        return LogReading.read(events(pull), context: LogReading.Context(pulledBy: pull.query.ip, read: read, theirs: theirs,
                                                                         capped: capped, pulled: runs, nobodyHas: checks,
                                                                         domains: domains, people: people,
                                                                         warnings: picked))
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
            // The reading for this pull, or while only picks were added, the last one until the new one comes.
            if let read = memory.read, read.key == key || Self.staleIsSafe(shown: read.key, asked: key) {
                switch part {
                case .findings: findings(read.reading)
                case .toDo: toDo(read.reading, updating: read.key == key ? [] : Self.picksChanged(shown: read.key, asked: key))
                }
            } else {
                readingNow
            }
        }
        .onChange(of: key, initial: true) {
            memory.begin(pull, marks: marks, auditURL: auditURL, domain: domain, nobodyHas: nobodyHas, domains: domains, people: people,
                         warnings: warnings, key: key)
        }
        .onChange(of: memory.read?.key) { _, read in
            guard let named = announceReread, part == .toDo, read == key else { return }
            announceReread = nil
            if appearsActive { AccessibilityNotification.Announcement("Who \(named) reached is read again, its warnings cleared.").post() }
        }
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
    @ViewBuilder private func toDo(_ reading: LogReading.Reading, updating: Set<String> = []) -> some View {
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
        ForEach(reading.reaches, id: \.messageID) { reach in
            ReachSection(reach: reach, updating: updating.contains(reach.messageID), pick: pickWarning.map { pick in { warning in
                let problem = pick(reach.messageID, warning)
                if warning == nil, problem == nil { announceReread = "“\(reach.subject.isEmpty ? "(no subject)" : reach.subject)”" }
                return problem
            } })
                .id(Self.reachAnchor(reach.messageID))
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
/// Who one email the attacker sent reached (`LogReading.Reach`): a line said in numbers, every recipient with where they
/// are, what the Gmail log shows reached them and whether a picked warning went to them, the warning to pick from code's
/// candidates (kept with the open incident), and the list as a CSV. Reads only: nothing here sends anything.
private struct ReachSection: View {
    let reach: LogReading.Reach
    /// A newer reading (a pick, the directory) is on its way: this one is shown until it comes.
    let updating: Bool
    /// Keeps a warning picked (nil clears them): the problem in words, or nil once kept. Nil with no incident open.
    let pick: ((String?) -> String?)?
    @State private var problem: String?
    @State private var exported: (text: String, failed: Bool)?
    /// The list starts closed (300 rows can follow); a debug snapshot of `reached` opens it.
    @State private var listOpen: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"] == "reached"
        #else
        false
        #endif
    }()
    @Environment(\.appearsActive) private var appearsActive
    private static let shown = 300

    /// The list as a CSV, to a file the operator picks: private (0600), whole or not at all, written off the main thread.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "who-it-reached-\(reach.messageID.prefix(40).map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "Who \(named) reached, from the Gmail log's own events for it."
        let rows = [LogReading.Reach.columns] + reach.rows
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let text: String, failed: Bool
                do {
                    try await Task.detached { try AuditExport.writePrivately(AuditExport.csv(rows), to: destination) }.value
                    (text, failed) = ("Exported who it reached to \(destination.lastPathComponent).", false)
                } catch {
                    (text, failed) = ("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", true)
                }
                exported = (text, failed)
                if appearsActive { AccessibilityNotification.Announcement(text).post() }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private var named: String { "“\(reach.subject.isEmpty ? "(no subject)" : reach.subject)”" }

    private var summary: String {
        let all = reach.recipients
        func count(_ test: (LogReading.Reach.Recipient) -> Bool) -> Int { all.filter(test).count }
        var parts: [String] = []
        func say(_ n: Int, _ words: String) { if n > 0 { parts.append("\(n) \(words)") } }
        say(count { $0.outcome == .received }, "received it here")
        say(count { $0.outcome == .sent && !$0.inside }, "outside with no bounce in the logs read")
        say(count { $0.outcome == .sent && $0.inside }, "here with no receipt in the logs read")
        say(count { $0.outcome == .bounced }, "bounced")
        say(count { $0.outcome == .blocked }, "quarantined or rejected")
        say(count { $0.outcome == .notAMailbox }, "no one's mailbox here (a group, or an address no account has)")
        var text = "It went to \(all.count) \(all.count == 1 ? "address" : "addresses")" + (parts.isEmpty ? "." : ": " + parts.joined(separator: ", ") + ".")
        if reach.unreadable > 0 { text += " \(reach.unreadable) more the log names don't read as an address: see the Admin console's Gmail log events." }
        if reach.unnamed > 0 {
            text += " \(reach.unnamed == 1 ? "A send of it names" : "\(reach.unnamed) sends of it name") no recipient: who that went to isn't in the logs read."
        }
        let counted = reach.warnings.filter { $0.problem == nil }
        if reach.warnings.isEmpty { return text + " No warning picked yet." }
        if counted.isEmpty { return text + " No warning picked counts yet, so who was warned can't be told." }
        let left = reach.toWarn.count
        let whole = reach.unnamed == 0 && reach.unreadable == 0
        return text + (left == 0 ? (whole ? " The log shows the warnings picked reaching everyone to warn."
                                    : " The log shows the warnings picked reaching everyone listed, but the list isn't whole (above).")
                       : " The log doesn't show the warnings picked reaching \(left) of the people to warn.")
    }

    private func words(_ recipient: LogReading.Reach.Recipient) -> String { LogReading.Reach.words(recipient) }

    private func candidateButton(_ candidate: LogReading.Reach.Candidate) -> some View {
        Button("\(candidate.sender): “\(candidate.subject)”" + (candidate.at.map { ", \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
               + ", to \(candidate.covers) of them") {
            problem = pick?(candidate.messageID)
            if problem == nil, appearsActive {
                AccessibilityNotification.Announcement("Warning picked. Updating who \(named) reached.").post()
            }
        }
    }

    var body: some View {
        Section {
            if updating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating with the warnings picked…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text(summary)
            if reach.recipients.isEmpty {
                Text("The logs read have no send of it naming its recipients: pull the sender's Gmail log over the day it went out.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Every address it went to (\(reach.recipients.count))", isExpanded: $listOpen) {
                    ForEach(reach.recipients.prefix(Self.shown)) { recipient in
                        let warned = recipient.warned.map { $0 ? "warned" : "not shown warned" }, toWarn = recipient.toWarn ? "to warn" : nil
                        HStack(alignment: .firstTextBaseline) {
                            Text(recipient.address).textSelection(.enabled)
                            Spacer()
                            // What's left to warn stands out, said in words too (a person here whose copy bounced is to warn).
                            Text([recipient.inside ? "inside" : "outside", words(recipient), warned, toWarn].compactMap(\.self).joined(separator: " · "))
                                .foregroundStyle(recipient.toWarn ? .primary : .secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel([recipient.address, recipient.inside ? "inside" : "outside", words(recipient), warned, toWarn]
                            .compactMap(\.self).joined(separator: ", "))
                    }
                    if reach.recipients.count > Self.shown {
                        Text("Showing \(Self.shown) of \(reach.recipients.count). Export the CSV for all of them.").font(.callout)
                    }
                }
            }
            if !reach.warnings.isEmpty {
                ForEach(reach.warnings) { warning in
                    let named = warning.sender.isEmpty ? warning.messageID : "\(warning.sender)'s “\(warning.subject)”"
                        + (warning.at.map { ", \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                    if let problem = warning.problem {
                        Label("Warning picked, \(named), doesn't count: \(problem).", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor).textSelection(.enabled)
                    } else {
                        Label("Warning picked: \(named), shown reaching \(warning.covers) of the people to warn.", systemImage: "envelope.badge")
                            .textSelection(.enabled)
                    }
                }
            }
            if !reach.unread.isEmpty {
                Text("Whether \(reach.unread.count == 1 ? "1 person here" : "\(reach.unread.count) people here") got a warning is in their "
                     + "own Gmail log, which the pull doesn't have: Pull Again on the to-do item reads it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Menu("Pick the Warning") {
                    if reach.candidates.isEmpty {
                        Text("No \(reach.warnings.isEmpty ? "" : "other ")email sent after it, from an account here, went to these "
                             + "people in the logs read.")
                    }
                    ForEach(reach.candidates.prefix(10)) { candidate in candidateButton(candidate) }
                    if reach.candidates.count > 10 {
                        Menu("More Emails Sent After It (\(reach.candidates.count - 10))") {
                            ForEach(reach.candidates.dropFirst(10)) { candidate in candidateButton(candidate) }
                        }
                    }
                    Divider()
                    // Said every time: other emails can fill the menu while the real warning's sender isn't read (final review).
                    Text("A warning shows here once its sender's Gmail log is in the pull: add their Gmail log on Investigate.")
                    if !reach.warnings.isEmpty {
                        Divider()
                        Button("Clear the Warnings Picked") {
                            problem = pick?(nil)
                            if problem == nil, appearsActive { AccessibilityNotification.Announcement("Warnings cleared. Reading who \(named) reached again.").post() }
                        }
                    }
                }
                .fixedSize()
                .disabled(pick == nil)
                .accessibilityHint("Picks the email that warned the people this one reached: each of them then shows warned or not. "
                                   + "Kept with the incident. Nothing is sent.")
                Spacer()
                Button("Export CSV…", action: export)
                    .disabled(reach.recipients.isEmpty || updating)
                    .accessibilityLabel("Export who \(named) reached as a CSV file")
            }
            if pick == nil {
                Text("Open an incident to keep the warning you pick.").font(.callout).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            if let exported {
                Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
        } header: {
            Text("Who \(named) reached").accessibilityAddTraits(.isHeader)
                .onChange(of: updating) { was, now in
                    if was, !now, appearsActive { AccessibilityNotification.Announcement("Who \(named) reached is updated. " + summary).post() }
                }
        } footer: {
            Text("From the Gmail log's own events for this email: its sends (every address, Bcc too), a mailbox here receiving it, a "
                 + "bounce, a quarantine or a rejection. Everyone it was sent to is to warn but an address that bounced and isn't a "
                 + "person's mailbox here: warning too many is safe, too few isn't. A warning picked counts for someone here once the "
                 + "logs' last word of it in their mailbox is a receipt, and for an outside address or a group where its send went with "
                 + "nothing failing; done needs that for everyone to warn.")
        }
    }
}

private struct DoneRow: View {
    let task: LogReading.Task

    var body: some View {
        let when = task.done.map { done in
            let at = done.at.formatted(date: .abbreviated, time: .shortened) + (done.by.isEmpty ? "" : " by \(done.by)")
            return switch done.how {
            case .trashed: "Trashed \(at), as this app's audit log shows."
            case .nobodyHasIt: "Checked \(at), as Phishing's Find showed."
            case .warned: "Sent \(at), as the Gmail log shows."
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
