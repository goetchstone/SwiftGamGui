import AppKit
import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI
import UniformTypeIdentifiers

/// Phishing: an email taken out of every mailbox (docs/domains/phishing.md). The operator pastes the email's
/// Message-ID, or several one per line (Pull All, D12); Find Copies runs GAM's own dry run over every active user for
/// each, which changes nothing, and lists who has a copy; Trash holds one step per email and mailbox, confirmed once on
/// `PhishingConfirmSheet` with the number of steps typed; then each step's result as it ends, Stop between steps, and
/// Find Again to see that none are left.
struct PhishingView: View {
    let setup: SetupModel
    let changes: PhishingChanges
    /// This build has GAM: a search can run. Without it nothing here can.
    let hasGam: Bool
    /// A Message-ID another screen asked for (the log reader): pasted and found at once, a read. Cleared once taken.
    @Binding var requested: String?
    @State private var pasted = ""
    @State private var sender = ""
    /// The last save's result, shown at the top and spoken.
    @State private var notice: (text: String, failed: Bool)?
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    private var canFind: Bool {
        hasGam && setup.active != nil && !changes.isFinding && !changes.isRunning
            && !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// More than one Message-ID pasted: who it was sent to is read for one at a time.
    private var several: Bool {
        ((try? PhishingChanges.messages(pasted))?.count ?? 0) > 1
    }

    private var canList: Bool {
        hasGam && setup.active != nil && !changes.isReadingRecipients && !several
            && !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The held trash, as the confirm sheet's item: closing the sheet drops it.
    private var confirming: Binding<PhishingChanges.Pending?> {
        Binding(get: { changes.pending }, set: { if $0 == nil { changes.cancelPreview() } })
    }

    private static let recipientsAnchor = "phishing.recipients"

    var body: some View {
        ScrollViewReader { scroller in
            Form {
                if let notice {
                    Section {
                        Label(notice.text, systemImage: notice.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                            .textSelection(.enabled)
                    }
                }
                if let run = changes.run {
                    PhishingRunSection(run: run, changes: changes, export: export) { message in
                        pasted = message
                        find()
                    }
                }
                Section {
                    Text("For an email that reached many mailboxes, such as phishing sent from a compromised account. Find Copies "
                         + "lists every active user who has it and changes nothing; Trash then moves those copies to each person's "
                         + "Trash, where they stay for 30 days and can be put back.")
                        .foregroundStyle(.secondary)
                    TextField("Message-ID", text: $pasted, prompt: Text(verbatim: "<…@mail.example.com>"), axis: .vertical)
                        .lineLimit(1...8)
                        .autocorrectionDisabled()
                        .onSubmit { if canFind { find() } }
                        .accessibilityLabel("Message-IDs, one per line")
                        .accessibilityHint("The email's Message-ID header, or several pasted one per line. Return finds their copies; "
                                           + "Option-Return starts a new line.")
                    Text("In Gmail, open the email, choose More › Show original, and copy the Message-ID line. For several emails "
                         + "at once, paste one per line (Option-Return starts a new one), up to \(PhishingChanges.mostAtOnce): "
                         + "Read the logs' Pull All fills them in. The "
                         + "sender's own Sent copy is kept as evidence. Copies in Spam are found too; suspended users' mailboxes "
                         + "aren't searched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Find Copies", action: find)
                            .disabled(!canFind)
                            .help(hasGam ? "Searches every active user's mailbox; changes nothing" : "This build has no GAM")
                    }
                } header: {
                    Text("Remove an email from every mailbox").accessibilityAddTraits(.isHeader)
                }
                .disabled(changes.isRunning)
                if !hasGam {
                    Section {
                        Label("This build has no GAM, so nothing can be searched. Build the app again after running scripts/fetch_gam.sh.",
                              systemImage: "eye")
                    }
                }
                results
                Section {
                    Text("The sender's own copy lists who it was addressed to. Sent from Gmail itself, it keeps its Bcc; from a mail "
                         + "client or a script, the Bcc is usually left off. Enter the address that sent it, such as the compromised account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Sender", text: $sender, prompt: Text(verbatim: "name@example.com"))
                        .autocorrectionDisabled()
                        .onSubmit { if canList { listRecipients() } }
                        .accessibilityHint("The address that sent the email. Press Return to list who it went to.")
                    if several {
                        Text("Who it was sent to is read for one email at a time: leave one Message-ID above.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("List Recipients", action: listRecipients)
                            .disabled(!canList)
                            .help("Reads the sender's copy of the email with this Message-ID; changes nothing")
                    }
                } header: {
                    Text("Who it was sent to").accessibilityAddTraits(.isHeader)
                }
                recipientsResult
            }
            .formStyle(.grouped)
            // A read the operator asked for, below the search: brought into view when it lands.
            .onChange(of: recipientsAnnouncement) { _, text in
                guard text != nil else { return }
                withAnimation { scroller.scrollTo(Self.recipientsAnchor, anchor: .top) }
            }
        }
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .sheet(item: confirming) { pending in
            PhishingConfirmSheet(pending: pending, changes: changes)
        }
        .task(id: setup.active?.name) { fillForSnapshot() }
        .onChange(of: requested, initial: true) { _, id in
            guard let id else { return }
            requested = nil
            // Mid-run the run stays as it is: Find says why it can't start.
            pasted = id
            if canFind { find() }
        }
        // Said once, from the window in front: each result on its own, so one shown doesn't silence the other.
        .onChange(of: announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: recipientsAnnouncement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    @ViewBuilder private var results: some View {
        switch changes.state {
        case .idle:
            EmptyView()
        case .finding(let messages, let searched):
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(messages.count == 1 ? "Searching every active user's mailbox… In a large domain this takes several minutes."
                         : "Searching every active user's mailbox for \(messages.count) emails: \(searched) done. Each takes a "
                            + "minute or more in a large domain.")
                    if messages.count > 1 {
                        Spacer()
                        Button("Stop") { changes.stopFinding() }
                            .accessibilityHint("Stops searching: the emails being searched finish, no more start, and nothing is "
                                               + "shown. Nothing has changed.")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        case .problem(let problem):
            Section {
                Label(problem.summary, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                if let detail = problem.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Couldn't search").accessibilityAddTraits(.isHeader)
            }
        case .found(let found):
            if found.results.count == 1, let search = found.searches.first {
                FoundSection(search: search, changes: changes, canTrash: hasGam && !changes.isRunning, export: export)
            } else {
                AllFoundSection(found: found, changes: changes, canTrash: hasGam && !changes.isRunning, export: export)
                // Each email someone has, or that a mailbox couldn't be searched for: never one that nobody has.
                ForEach(found.withCopies + found.unsure, id: \.message.id) { search in
                    FoundSection(search: search, changes: changes, canTrash: false, export: export, single: false)
                }
            }
        }
    }

    @ViewBuilder private var recipientsResult: some View {
        switch changes.recipients {
        case .idle:
            EmptyView()
        case .reading(let sender):
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading \(sender)'s copy…")
                }
                .accessibilityElement(children: .combine)
            }
        case .problem(let problem):
            Section {
                Label(problem.summary, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                if let detail = problem.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Couldn't read the recipients").accessibilityAddTraits(.isHeader)
            }
            // The anchor on the section itself: a Form scrolls to a row's id, not to a conditional builder's.
            .id(Self.recipientsAnchor)
        case .read(let recipients):
            let unnamed: [String] = if case .found(let found) = changes.state,
                                        let search = found.searches.first(where: { $0.message == recipients.message }) {
                recipients.unnamed(in: search)
            } else { [] }
            RecipientsSection(recipients: recipients, unnamed: unnamed, export: export)
                .id(Self.recipientsAnchor)
        }
    }

    /// A list saved as the Audit screen saves its log: a save panel with a dated name, then the file written private
    /// (0600) and whole, off the main actor, by the one private writer the Audit export uses (`AuditExport`).
    private func export(_ name: String, _ header: [String], _ rows: [[String]]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "It lists people's addresses, some outside the company: keep the file private."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { await write(header, rows, to: destination) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func write(_ header: [String], _ rows: [[String]], to destination: URL) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try AuditExport.writePrivately(AuditExport.csv([header] + rows), to: destination)
            }.value
            say("Saved \(rows.count) row\(rows.count == 1 ? "" : "s") to \(destination.lastPathComponent).", failed: false)
        } catch {
            say("Couldn't save \(destination.lastPathComponent): \(error.localizedDescription)", failed: true)
        }
    }

    private func say(_ text: String, failed: Bool) {
        notice = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }

    private func listRecipients() {
        let sender = sender, pasted = pasted, changes = changes
        Task { await changes.listRecipients(sender: sender, message: pasted) }
    }

    private func find() {
        let pasted = pasted, changes = changes
        Task { await changes.find(pasted) }
    }

    /// What VoiceOver hears when a search, a refusal or a mailbox's result arrives.
    private var announcement: String? {
        if let run = changes.run {
            if run.ended { return run.summary }
            let done = run.results.compactMap { $0 }.count
            guard done > 0, done <= run.pending.trashes.count else { return nil }
            return "\(PhishingRunSection.name(run.pending.trashes[done - 1], in: run.pending)): \(PhishingStatus(run.results[done - 1]).words)."
        }
        if let refusal = changes.refusal { return refusal }
        return switch changes.state {
        case .found(let found):
            found.results.count == 1 && found.searches.count == 1 ? FoundSection.headline(found.searches[0]) : AllFoundSection.headline(found)
        case .problem(let problem): problem.summary
        case .finding, .idle: nil
        }
    }

    private var recipientsAnnouncement: String? {
        switch changes.recipients {
        case .read(let recipients): RecipientsSection.headline(recipients)
        case .problem(let problem): problem.summary
        case .idle, .reading: nil
        }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` pastes that Message-ID (or several, between commas) and finds its copies in the
    /// mock, and `SWIFTGAMGUI_TAB`
    /// shows, for the snapshots, who the mock's sender sent it to (`recipients`), the confirm sheet over the copies
    /// (`confirm`) or a finished run's results (`result`, made up: nothing runs).
    private func fillForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard setup.active != nil, !debugApplied, let message = environment["SWIFTGAMGUI_SELECT"] else { return }
        debugApplied = true
        pasted = message
        let tab = environment["SWIFTGAMGUI_TAB"], changes = changes
        if tab == "recipients" { sender = "carol@example.com" }
        Task {
            await changes.find(message)
            if tab == "recipients" { await changes.listRecipients(sender: "carol@example.com", message: message) }
            guard tab == "confirm" || tab == "result" else { return }
            await changes.previewTrash()
            if tab == "result" { changes.showDemoRun() }
        }
        #endif
    }
}

/// A mailbox's result in words and a symbol, never color alone.
struct PhishingStatus {
    let words: String
    let symbol: String

    init(_ result: RunOutcome.Step?, running: Bool = false) {
        switch result {
        case nil: (words, symbol) = running ? ("Trashing", "arrow.triangle.2.circlepath") : ("Waiting", "circle.dotted")
        case .succeeded?: (words, symbol) = ("Trashed", "checkmark.circle.fill")
        case .failed?: (words, symbol) = ("Failed", "xmark.octagon.fill")
        case .skipped(let reason)?: (words, symbol) = ("Not run: \(reason.hasPrefix("Not run: ") ? String(reason.dropFirst(9)) : reason)", "minus.circle")
        case .waiting?: (words, symbol) = ("Waiting", "hourglass")
        }
    }
}

// Two ForEach in one Form section whose rows have the same id draw one row for both: alice's copy in Spam showed as her
// Inbox copy (failure log 2026-10-30). So each list beside `withCopies` keys its rows by what it lists as well as by
// whose mailbox.
private extension MessageCopies.Mailbox {
    var unusualRow: String { "unusual " + email }
}

private extension SpamCopies.Mailbox {
    var spamRow: String { "spam " + email }
}

private extension SpamCopies.Unsearched {
    var spamUnreadRow: String { "spam unread " + email }
}

/// Who has a copy: each mailbox with its count, then those with copies in Spam, those GAM couldn't search and those
/// without one, GAM's commands for an admin who wants them, and Trash from N Mailboxes.
private struct FoundSection: View {
    let search: PhishingChanges.Search
    let changes: PhishingChanges
    let canTrash: Bool
    let export: (String, [String], [[String]]) -> Void
    /// The one email searched: its own Export and Trash. One of several shares Pull All's (`AllFoundSection`).
    var single = true

    private var copies: MessageCopies { search.copies }
    private var withCopies: [MessageCopies.Mailbox] { copies.withCopies }
    private var failed: [(email: String, why: String)] {
        copies.mailboxes.compactMap { if case .failed(let why) = $0.finding { ($0.email, why) } else { nil } }
    }
    private var gmailOff: [String] { copies.mailboxes.filter { $0.finding == .gmailOff }.map(\.email) }
    private var inSpam: [SpamCopies.Mailbox] { search.spam?.mailboxes ?? [] }
    /// No copy anywhere: none outside Spam, and the Spam read searched it and found none.
    private var without: [String] { noCopyOutsideSpam(spamChecked: true) }
    /// No copy outside Spam, but its Spam wasn't checked (the read failed, or couldn't read this mailbox's): never "no copy".
    private var withoutOutsideSpam: [String] { noCopyOutsideSpam(spamChecked: false) }

    private func noCopyOutsideSpam(spamChecked: Bool) -> [String] {
        let clear = Set((search.spam?.searched ?? []).map { $0.lowercased() }), spam = Set(inSpam.map { $0.email.lowercased() })
        return copies.mailboxes.filter { $0.finding == .none && !spam.contains($0.email.lowercased())
            && clear.contains($0.email.lowercased()) == spamChecked }.map(\.email)
    }
    /// Spam unread for a mailbox the dry run did search: one it couldn't is said once, above.
    private var spamUnsearched: [SpamCopies.Unsearched] { Self.spamUnsearched(search) }

    private static func spamUnsearched(_ search: PhishingChanges.Search) -> [SpamCopies.Unsearched] {
        let said = Set(search.copies.unsearched.map { $0.email.lowercased() })
        return (search.spam?.unsearched ?? []).filter { !said.contains($0.email.lowercased()) }
    }

    /// Never "no copy" while a mailbox, or its Spam, went unsearched: a copy there is unknown (review of 2026-10-19).
    static func headline(_ search: PhishingChanges.Search) -> String {
        let copies = search.copies, count = search.mailboxesWithCopies.count, spam = search.spam?.total ?? 0
        let total = copies.totalCopies + spam, unsearched = copies.unsearched.count
        let spamUnread = search.spam == nil || !spamUnsearched(search).isEmpty
        let counts = (total > count ? ["\(total) copies in all"] : []) + (spam > 0 ? ["\(spam) in Spam"] : [])
        var text = count == 0 ? (unsearched == 0 && !spamUnread ? "No mailbox has a copy" : "No copy found")
            : "\(count) mailbox\(count == 1 ? " has a copy" : "es have a copy")" + (counts.isEmpty ? "" : " (\(counts.joined(separator: ", ")))")
        if unsearched > 0 { text += "; \(unsearched) mailbox\(unsearched == 1 ? "" : "es") couldn't be searched" }
        if spamUnread { text += "; Spam couldn't be checked everywhere" }
        return text
    }

    private static func copiesText(_ count: Int) -> String { count == 1 ? "1 copy" : "\(count) copies" }

    var body: some View {
        Section {
            LabeledContent("Message-ID") {
                Text(search.message.id).textSelection(.enabled)
            }
            if let sample = search.sample {
                LabeledContent("From") { Text(sample.copy.from).textSelection(.enabled) }
                LabeledContent("Subject") { Text(sample.copy.subject).textSelection(.enabled) }
                Text("As \(sample.mailbox)'s copy has it: check this is the email to remove before trashing it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if sample.copy.headings.count > 1 {
                    Label("\(sample.mailbox)'s copies aren't all the same email: "
                          + sample.copy.headings.map { "“\($0.subject)” from \($0.from)" }.joined(separator: "; ")
                          + ". Check the Message-ID before trashing.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .textSelection(.enabled)
                }
            } else if let problem = search.sampleProblem {
                Label("Couldn't read a copy to show what it is: \(problem)", systemImage: "questionmark.circle")
            }
            ForEach(copies.unusual, id: \.unusualRow) { mailbox in
                Label("\(mailbox.email) has \(mailbox.copies) copies of this Message-ID; one email rarely arrives more than "
                      + "twice. Check it's the phish.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if copies.looksLikeMissingScope {
                Label("Every mailbox says Gmail is off. That usually means the service account isn't authorized for Gmail: "
                      + "run Check access on Setup.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            ForEach(withCopies) { mailbox in
                LabeledContent {
                    Text(Self.copiesText(mailbox.copies))
                } label: {
                    Label(mailbox.email, systemImage: "envelope.badge.fill").textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(mailbox.email), \(Self.copiesText(mailbox.copies))")
            }
            ForEach(inSpam, id: \.spamRow) { mailbox in
                LabeledContent {
                    Text("\(Self.copiesText(mailbox.ids.count)) in Spam")
                } label: {
                    Label(mailbox.email, systemImage: "xmark.bin.fill").textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(mailbox.email), \(Self.copiesText(mailbox.ids.count)) in Spam")
            }
            if let problem = search.spamProblem {
                Label("Spam couldn't be checked, so copies there aren't listed or trashed: \(problem)",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .textSelection(.enabled)
            }
            ForEach(spamUnsearched, id: \.spamUnreadRow) { mailbox in
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(mailbox.email)'s Spam: couldn't be checked", systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor)
                    Text(mailbox.why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(failed, id: \.email) { mailbox in
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(mailbox.email): couldn't be searched", systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor)
                    Text(mailbox.why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if !gmailOff.isEmpty, !copies.looksLikeMissingScope {
                Label("Gmail is off for \(gmailOff.count == 1 ? "" : "\(gmailOff.count): ")\(gmailOff.joined(separator: ", "))",
                      systemImage: "minus.circle")
                    .textSelection(.enabled)
            }
            if !without.isEmpty {
                DisclosureGroup("No copy in \(without.count) other mailbox\(without.count == 1 ? "" : "es")") {
                    Text(without.joined(separator: "\n")).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !withoutOutsideSpam.isEmpty {
                DisclosureGroup("No copy outside Spam in \(withoutOutsideSpam.count) mailbox\(withoutOutsideSpam.count == 1 ? "" : "es"), "
                                + "whose Spam couldn't be checked") {
                    Text(withoutOutsideSpam.joined(separator: "\n")).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !(copies.otherLines + (search.spam?.otherLines ?? [])).isEmpty {
                DisclosureGroup("GAM also said") {
                    Text((copies.otherLines + (search.spam?.otherLines ?? [])).joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DisclosureGroup("Show commands") {
                Text(search.commandLine + "\n" + search.spamCommandLine).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if single, let refusal = changes.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            if single {
                HStack {
                    Spacer()
                    Button("Export CSV…") {
                        export(PhishingChanges.exportName("copies"), PhishingChanges.copiesColumns, PhishingChanges.copiesRows(search, run: nil))
                    }
                    .accessibilityLabel("Export the \(copies.mailboxes.count) mailboxes searched as a CSV file")
                    .help("Each mailbox, what was found and how many copies")
                }
            }
            if single, !search.mailboxesWithCopies.isEmpty {
                let count = search.mailboxesWithCopies.count
                HStack {
                    Spacer()
                    Button("Trash from \(count) Mailbox\(count == 1 ? "" : "es")…", role: .destructive) {
                        let changes = changes
                        Task { await changes.previewTrash() }
                    }
                    .disabled(!canTrash)
                    .help("Shows exactly what will be trashed, to confirm first")
                }
            }
        } header: {
            Text(Self.headline(search)).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }
}

/// Pull All (D12): several emails searched at once. How many some mailbox still has, those nobody has (sent and since
/// removed, or never delivered: bounced, limited), any a mailbox couldn't be searched for (never clear), any that
/// couldn't be searched at all, every email's rows as one CSV, and one Trash for every copy of every email listed below.
private struct AllFoundSection: View {
    let found: PhishingChanges.Found
    let changes: PhishingChanges
    let canTrash: Bool
    let export: (String, [String], [[String]]) -> Void

    private var mailboxes: Int {
        Set(found.withCopies.flatMap(\.mailboxesWithCopies).map { $0.lowercased() }).count
    }

    /// Each group counted on its own: never "in none" for an email a mailbox, or the whole search, couldn't read (review
    /// of 2026-10-23).
    static func headline(_ found: PhishingChanges.Found) -> String {
        let groups = [(found.withCopies.count, "still in a mailbox here"), (found.nobodyHas.count, "in no mailbox here"),
                      (found.unsure.count, "not checked everywhere"), (found.failed.count, "couldn't be searched")]
        let said = groups.enumerated().filter { $0.offset == 0 || $0.element.0 > 0 }.map { "\($0.element.0) \($0.element.1)" }
        return "\(found.results.count) emails: " + said.joined(separator: ", ")
    }

    var body: some View {
        Section {
            if !found.withCopies.isEmpty {
                Text("Each one below, with who has it. Trash moves every copy listed to each person's Trash, the sender's Sent "
                     + "copy kept, from one preview.")
                    .foregroundStyle(.secondary)
            }
            if !found.nobodyHas.isEmpty {
                DisclosureGroup("No mailbox here has \(found.nobodyHas.count) of them: sent only outside, removed since, or never "
                                + "delivered (bounced or limited)") {
                    Text(found.nobodyHas.map { "<\($0.message.id)>" }.joined(separator: "\n"))
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !found.unsure.isEmpty {
                Label("\(found.unsure.count) found in no mailbox searched, but a mailbox or its Spam couldn't be searched, so "
                      + "they aren't clear: each is below.", systemImage: "questionmark.circle")
            }
            ForEach(found.failed, id: \.message.id) { failed in
                VStack(alignment: .leading, spacing: 2) {
                    Label("<\(failed.message.id)>: couldn't be searched", systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor)
                    Text(failed.problem.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if let refusal = changes.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            HStack {
                Spacer()
                Button("Export CSV…") {
                    export(PhishingChanges.exportName("copies"), PhishingChanges.allCopiesColumns,
                           PhishingChanges.allCopiesRows(found.results, run: nil))
                }
                .accessibilityLabel("Export every email's mailboxes searched as a CSV file")
                .help("Each email, each mailbox, what was found and how many copies")
                if !found.withCopies.isEmpty {
                    Button("Trash \(found.withCopies.count) Email\(found.withCopies.count == 1 ? "" : "s") from \(mailboxes) "
                           + "Mailbox\(mailboxes == 1 ? "" : "es")…", role: .destructive) {
                        let changes = changes
                        Task { await changes.previewTrash() }
                    }
                    .disabled(!canTrash)
                    .help("Shows exactly what will be trashed, every email's, to confirm once")
                }
            }
        } header: {
            Text(Self.headline(found)).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }
}

/// Who it went to, from the sender's copy: those outside the tenant's domains first (the ones to warn), with Copy;
/// those inside; or, with no copy left, where Google's own record is. Never an all-clear: a copy sent from a mail
/// client or a script keeps no Bcc (review of 2026-10-19, R1), so Google's record is always named.
private struct RecipientsSection: View {
    let recipients: PhishingChanges.Recipients
    /// Mailboxes Find saw a copy in that the headers don't name: proof the list isn't everyone.
    let unnamed: [String]
    let export: (String, [String], [[String]]) -> Void

    static let logSearch = "Google's own record of every recipient is in the Admin console: Reporting › Email Log Search."

    static func headline(_ recipients: PhishingChanges.Recipients) -> String {
        guard recipients.copy != nil else { return "No copy left in \(recipients.sender)'s mailbox" }
        let total = recipients.inside.count + recipients.outside.count
        return "Sent to \(total) address\(total == 1 ? "" : "es"), \(recipients.outside.count) outside"
    }

    var body: some View {
        Section {
            if let copy = recipients.copy {
                LabeledContent("Subject") { Text(copy.subject).textSelection(.enabled) }
                LabeledContent("Sent") { Text(copy.date).textSelection(.enabled) }
                if !recipients.isSentCopy {
                    Label("This is a copy \(recipients.sender) received, not one they sent: it shows who it was addressed to, "
                          + "never its Bcc. Enter the address that sent it.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                } else if !copy.hasBcc {
                    Label("The sender's copy has no Bcc header. Sent from a mail client or a script, Bcc'd recipients aren't "
                          + "recorded in it.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                if !unnamed.isEmpty {
                    Label("\(unnamed.count) mailbox\(unnamed.count == 1 ? " has" : "es have") a copy but \(unnamed.count == 1 ? "isn't" : "aren't") "
                          + "named here (\(unnamed.prefix(3).joined(separator: ", "))\(unnamed.count > 3 ? ", …" : "")): they had it by "
                          + "Bcc or through a group, so people outside may be missing from this list too.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                if recipients.inTrash {
                    Label("The sender's copy is in their Trash.", systemImage: "trash")
                }
                if recipients.outside.isEmpty {
                    // Never a check mark: an address not read, a Bcc not kept, a group's outside members.
                    if copy.unreadable.isEmpty {
                        Label("No address outside your domains in its headers.", systemImage: "info.circle")
                    }
                } else {
                    Text("Outside your domains: \(recipients.outside.count)").font(.headline)
                    ForEach(recipients.outside, id: \.self) { address in
                        Label(address, systemImage: "arrow.up.forward.circle").textSelection(.enabled)
                            .accessibilityLabel("Outside: \(address)")
                    }
                    HStack {
                        Spacer()
                        Button("Copy Outside Addresses") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recipients.outside.joined(separator: ", "), forType: .string)
                        }
                        .accessibilityLabel("Copy the \(recipients.outside.count) addresses outside your domains")
                        .help("To warn them")
                    }
                    if !copy.unreadable.isEmpty {
                        Label("Copy leaves out the \(copy.unreadable.count) below that couldn't be read: check them by hand.",
                              systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                if !recipients.inside.isEmpty {
                    DisclosureGroup("Inside your domains: \(recipients.inside.count) (a group's outside members aren't listed)") {
                        Text(recipients.inside.joined(separator: "\n")).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !copy.unreadable.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Couldn't read as one address each (check by hand):", systemImage: "questionmark.circle")
                        Text(copy.unreadable.joined(separator: "\n")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                Label("Not necessarily everyone. " + Self.logSearch, systemImage: "info.circle")
                HStack {
                    Spacer()
                    Button("Export CSV…") {
                        export(PhishingChanges.exportName("recipients"), PhishingChanges.recipientsColumns,
                               PhishingChanges.recipientsRows(recipients))
                    }
                    .accessibilityLabel("Export who it was sent to as a CSV file")
                    .help("Each address, outside or inside your domains, and its header")
                }
            } else {
                Label("No copy of this email is left in \(recipients.sender)'s mailbox: deleted and emptied from Trash, or never "
                      + "there. So who it went to can't be read here. " + Self.logSearch, systemImage: "questionmark.circle")
            }
            DisclosureGroup("Show command") {
                Text(recipients.commandLine).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(Self.headline(recipients)).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }
}

/// The run: "Trashing… N of M · mailbox", each mailbox's result as it ends, and Stop between mailboxes; then the
/// summary and Find Again, which shows what's left.
private struct PhishingRunSection: View {
    let run: PhishingChanges.Run
    let changes: PhishingChanges
    let export: (String, [String], [[String]]) -> Void
    let findAgain: (String) -> Void
    @State private var askingStop = false

    private var done: Int { run.results.compactMap { $0 }.count }

    /// A step as said: its mailbox, and for several emails which one ("alice@example.com · “Shared file”").
    static func name(_ trash: PhishingChanges.Trash, in pending: PhishingChanges.Pending) -> String {
        guard pending.messages.count > 1 else { return trash.name }
        let subject = pending.search(of: trash.message)?.sample?.copy.subject ?? ""
        return trash.name + " · " + (subject.isEmpty ? "<\(trash.message.id)>" : "“\(subject)”")
    }

    var body: some View {
        Section {
            ForEach(Array(run.pending.trashes.enumerated()), id: \.element.id) { index, trash in
                let status = PhishingStatus(run.results[index], running: !run.ended && index == done)
                let name = Self.name(trash, in: run.pending)
                VStack(alignment: .leading, spacing: 2) {
                    Label(name, systemImage: status.symbol).symbolRenderingMode(.multicolor)
                    Text(detail(run.results[index]) ?? status.words).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(name): \(status.words)")
            }
            if run.ended {
                if let problem = run.auditProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                Text("Find Again searches every mailbox once more: the ones trashed no longer show a copy. A copy in someone's "
                     + "Trash can be put back for 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    // Every email of the Find, the ones not trashed (unsure, not searched) among them.
                    Button("Export CSV…") {
                        if run.pending.found.results.count == 1 {
                            export(PhishingChanges.exportName("copies"), PhishingChanges.copiesColumns,
                                   PhishingChanges.copiesRows(run.pending.searches[0], run: run))
                        } else {
                            export(PhishingChanges.exportName("copies"), PhishingChanges.allCopiesColumns,
                                   PhishingChanges.allCopiesRows(run.pending.found.results, run: run))
                        }
                    }
                    .accessibilityLabel("Export each mailbox searched and what the trash did as a CSV file")
                    Button("Find Again") { findAgain(run.pending.found.results.map(\.message.id).joined(separator: "\n")) }
                    Button("Done") { changes.dismissRun() }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(run.stopping ? "Stopping after this step…"
                         : "Trashing… \(done) of \(run.results.count)"
                            + (done < run.pending.trashes.count ? " · \(Self.name(run.pending.trashes[done], in: run.pending))" : ""))
                    Spacer()
                    Button("Stop After This Step…") { askingStop = true }
                        .disabled(run.stopping)
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(run.ended ? run.summary
                 : (run.pending.messages.count > 1 ? "Trashing \(run.pending.messages.count) emails from " : "Trashing from ")
                    + "\(run.pending.mailboxes.count) mailbox\(run.pending.mailboxes.count == 1 ? "" : "es")")
                .font(.headline)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
        .confirmationDialog("Stop after this step?", isPresented: $askingStop) {
            Button("Stop After This Step", role: .destructive) {
                let changes = changes
                Task { await changes.stop() }
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The step in progress finishes; the ones after it don't run, a mailbox's Spam among them, so those copies stay. "
                 + "Find Again shows which.")
        }
    }

    /// GAM's words for a failure, or why a mailbox wasn't reached.
    private func detail(_ result: RunOutcome.Step?) -> String? {
        switch result {
        case .failed(let message, let kind)?: [message, kind.flatMap { $0.isAccountWide ? $0.remediation : nil }]
            .compactMap { $0 }.joined(separator: " ")
        case .skipped(let reason)?: reason
        default: nil
        }
    }
}
