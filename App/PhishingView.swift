import AppKit
import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI

/// Phishing: one email taken out of every mailbox (docs/domains/phishing.md). The operator pastes the email's
/// Message-ID; Find Copies runs GAM's own dry run over every active user, which changes nothing, and lists who has a
/// copy; Trash holds one step per mailbox, confirmed on `PhishingConfirmSheet` with the number of mailboxes typed;
/// then each mailbox's result as it ends, Stop between mailboxes, and Find Again to see that none are left.
struct PhishingView: View {
    let setup: SetupModel
    let changes: PhishingChanges
    /// This build has GAM: a search can run. Without it nothing here can.
    let hasGam: Bool
    @State private var pasted = ""
    @State private var sender = ""
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    private var canFind: Bool {
        hasGam && setup.active != nil && !changes.isFinding && !changes.isRunning
            && !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canList: Bool {
        hasGam && setup.active != nil && !changes.isReadingRecipients
            && !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The held trash, as the confirm sheet's item: closing the sheet drops it.
    private var confirming: Binding<PhishingChanges.Pending?> {
        Binding(get: { changes.pending }, set: { if $0 == nil { changes.cancelPreview() } })
    }

    var body: some View {
        Form {
            if let run = changes.run {
                PhishingRunSection(run: run, changes: changes) { message in
                    pasted = message
                    find()
                }
            }
            Section {
                Text("For an email that reached many mailboxes, such as phishing sent from a compromised account. Find Copies "
                     + "lists every active user who has it and changes nothing; Trash then moves those copies to each person's "
                     + "Trash, where they stay for 30 days and can be put back.")
                    .foregroundStyle(.secondary)
                TextField("Message-ID", text: $pasted, prompt: Text(verbatim: "<…@mail.example.com>"))
                    .autocorrectionDisabled()
                    .onSubmit { if canFind { find() } }
                    .accessibilityHint("The email's Message-ID header. Press Return to find its copies.")
                Text("In Gmail, open the email, choose More › Show original, and copy the Message-ID line. The sender's own "
                     + "Sent copy is kept as evidence. Copies already in Spam, and suspended users' mailboxes, aren't searched.")
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
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .sheet(item: confirming) { pending in
            PhishingConfirmSheet(pending: pending, changes: changes)
        }
        .task(id: setup.active?.name) { fillForSnapshot() }
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
        case .finding:
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching every active user's mailbox… In a large domain this takes several minutes.")
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
                Text("Couldn't search").accessibilityAddTraits(.isHeader)
            }
        case .found(let search):
            FoundSection(search: search, changes: changes, canTrash: hasGam && !changes.isRunning)
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
        case .read(let recipients):
            let unnamed: [String] = if case .found(let search) = changes.state { recipients.unnamed(in: search) } else { [] }
            RecipientsSection(recipients: recipients, unnamed: unnamed)
        }
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
            guard done > 0, done <= run.pending.mailboxes.count else { return nil }
            return "\(run.pending.mailboxes[done - 1].email): \(PhishingStatus(run.results[done - 1]).words)."
        }
        if let refusal = changes.refusal { return refusal }
        return switch changes.state {
        case .found(let search): FoundSection.headline(search.copies)
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

    /// Debug builds: `SWIFTGAMGUI_SELECT` pastes that Message-ID and finds its copies in the mock, and `SWIFTGAMGUI_TAB`
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

/// Who has a copy: each mailbox with its count, then those GAM couldn't search and those without one, GAM's command
/// for an admin who wants it, and Trash from N Mailboxes.
private struct FoundSection: View {
    let search: PhishingChanges.Search
    let changes: PhishingChanges
    let canTrash: Bool

    private var copies: MessageCopies { search.copies }
    private var withCopies: [MessageCopies.Mailbox] { copies.withCopies }
    private var failed: [(email: String, why: String)] {
        copies.mailboxes.compactMap { if case .failed(let why) = $0.finding { ($0.email, why) } else { nil } }
    }
    private var gmailOff: [String] { copies.mailboxes.filter { $0.finding == .gmailOff }.map(\.email) }
    private var without: [String] { copies.mailboxes.filter { $0.finding == .none }.map(\.email) }

    /// Never "no copy" while a mailbox went unsearched: a copy there is unknown (review of 2026-10-19).
    static func headline(_ copies: MessageCopies) -> String {
        let count = copies.withCopies.count, total = copies.totalCopies, unsearched = copies.unsearched.count
        var text = count == 0 ? (unsearched == 0 ? "No mailbox has a copy" : "No copy found")
            : "\(count) mailbox\(count == 1 ? " has a copy" : "es have a copy")" + (total > count ? " (\(total) copies in all)" : "")
        if unsearched > 0 { text += "; \(unsearched) mailbox\(unsearched == 1 ? "" : "es") couldn't be searched" }
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
            ForEach(copies.unusual) { mailbox in
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
            if !copies.otherLines.isEmpty {
                DisclosureGroup("GAM also said") {
                    Text(copies.otherLines.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DisclosureGroup("Show command") {
                Text(search.commandLine).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let refusal = changes.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            if !withCopies.isEmpty {
                HStack {
                    Spacer()
                    Button("Trash from \(withCopies.count) Mailbox\(withCopies.count == 1 ? "" : "es")…", role: .destructive) {
                        let changes = changes
                        Task { await changes.previewTrash() }
                    }
                    .disabled(!canTrash)
                    .help("Shows exactly what will be trashed, to confirm first")
                }
            }
        } header: {
            Text(Self.headline(copies)).font(.headline).accessibilityAddTraits(.isHeader)
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
    let findAgain: (String) -> Void
    @State private var askingStop = false

    private var done: Int { run.results.compactMap { $0 }.count }

    var body: some View {
        Section {
            ForEach(Array(run.pending.mailboxes.enumerated()), id: \.element.id) { index, mailbox in
                let status = PhishingStatus(run.results[index], running: !run.ended && index == done)
                VStack(alignment: .leading, spacing: 2) {
                    Label(mailbox.email, systemImage: status.symbol).symbolRenderingMode(.multicolor)
                    Text(detail(run.results[index]) ?? status.words).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(mailbox.email): \(status.words)")
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
                    Button("Find Again") { findAgain(run.pending.search.message.id) }
                    Button("Done") { changes.dismissRun() }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(run.stopping ? "Stopping after this mailbox…"
                         : "Trashing… \(done) of \(run.results.count)"
                            + (done < run.pending.mailboxes.count ? " · \(run.pending.mailboxes[done].email)" : ""))
                    Spacer()
                    Button("Stop After This Mailbox…") { askingStop = true }
                        .disabled(run.stopping)
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(run.ended ? run.summary : "Trashing from \(run.results.count) mailbox\(run.results.count == 1 ? "" : "es")")
                .font(.headline)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
        .confirmationDialog("Stop after this mailbox?", isPresented: $askingStop) {
            Button("Stop After This Mailbox", role: .destructive) {
                let changes = changes
                Task { await changes.stop() }
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The mailbox in progress finishes; the ones after it keep their copy. Find Again shows which.")
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
