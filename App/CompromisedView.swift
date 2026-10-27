import AppKit
import ChangeCore
import Directory
import GamEngine
import Setup
import Stores
import SwiftUI

/// Incident (docs/plans/2026-10-19-compromised-account.md): for a person who stays employed but whose account
/// was taken over. Check Account reads what an attacker commonly changes, and changes nothing; the operator ticks what
/// to undo; the lock and the picks are previewed as exact `gam` lines, then run once with the person's address typed,
/// each step's result as it ends, Stop between steps, and the account checked again.
struct CompromisedView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: CompromisedChanges
    let logs: IncidentLogs
    /// The groups the attacker's emails went to, read for whom they reach (Who it reached); a read that failed is tried again
    /// each time the screen opens.
    let groupsReached: GroupsReached
    /// Sign-ins marked as the person's own ("That was them"), which the log reader makes no suspect of.
    let known: KnownSignIns
    /// The emails Phishing's Find showed nobody here has, which the log reader shows done.
    let nobodyHas: NobodyHasChecks
    /// The incidents kept on this Mac, and the one open here.
    let incidents: Incidents
    /// The log reader's reading and explanation, kept by the window: they survive a change of tab, and of screen.
    let readerMemory: LogReaderView.Memory
    /// The directory as Who it reached reads it, built once a snapshot.
    let directoryIndex: DirectoryIndex
    /// This app's audit log, which the log reader reads for the emails Phishing pulled and the report for what was done.
    let auditURL: URL
    /// This build has GAM: a plan can run. Without it the plan is only shown.
    let hasGam: Bool
    /// A person another screen asked to secure (Users' "Secure Account…"): a new form for them, checked at once, with
    /// nothing ticked (the operator says whether the password was already reset). Cleared once taken.
    @Binding var requested: String?
    /// Opens Phishing with a Message-ID the log reader found, and finds who has that email.
    let openPhishing: (String) -> Void
    @State private var form = CompromisedChanges.Form()
    @State private var confirming: CompromisedChanges.Plan?
    @State private var debugApplied = false
    /// Debug snapshots of the reports: scrolled into view once read.
    @State private var scrollToReports = false
    /// …and to the log reader (`reading`).
    @State private var scrollToReader = false
    /// …and to a part drawn after the tab changed (`reached`: the first Who it reached section).
    @State private var scrollTarget: String?
    /// What a "Do It Here" asked to pick for a person, applied once the check has read them; only that one thing, not the
    /// full lock again.
    @State private var pendingPick: (person: String, pick: SecurePick)?
    /// The computer a "Do It Here" named matched none still signed in: the computers say so.
    @State private var pickMissed = false
    @State private var tab: Tab = .investigate
    /// The pull's form, kept here so it survives a change of tab.
    @State private var pullForm = PullForm()
    /// The events a to-do item narrowed the logs to ("Show the Events"); nil for all.
    @State private var filter: IncidentLogs.Filter?
    /// The audit log as last looked at (`LogReaderView.auditStamp`): a run since, here or on Phishing, reads the logs again.
    /// Nil until the screen appears, and then looked at as it's drawn, so the first reading is never of a stamp about to change.
    @State private var auditStamp: String?
    /// Where to scroll once a change of tab has drawn the new tab (its sections don't exist before).
    @State private var scrollAfterTab: String?
    @Environment(\.appearsActive) private var appearsActive

    /// Incident's three tabs, in the order an incident is worked: find out who's affected, act, keep the record.
    enum Tab: String, CaseIterable, Identifiable {
        case investigate = "Investigate", respond = "Respond", report = "Report"
        var id: Self { self }
    }

    private var check: CompromisedChanges.Check? { changes.check.flatMap { $0.isFor(form.person) ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            if !hasGam { NoGamBanner() }
            Picker("Part of the incident", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.top, 10)
            .help("Investigate finds who's affected; Respond secures accounts and pulls email; Report keeps the record.")
            ScrollViewReader { scroller in
                Form {
                    // The incident open, above every tab: its saved logs are what Investigate and Respond read.
                    if setup.active != nil {
                        IncidentRecordSection(part: .header, setup: setup, incidents: incidents, logs: logs).id(Self.incidentAnchor)
                    }
                    switch tab {
                    case .investigate: investigate(scroller)
                    case .respond: respond(scroller)
                    case .report: report(scroller)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: planShown) { _, shown in
                    guard shown else { return }
                    tab = .respond
                    withAnimation { scroller.scrollTo(Self.planAnchor, anchor: .top) }
                }
                .onChange(of: changes.run != nil) { _, shown in
                    guard shown else { return }
                    tab = .respond
                    withAnimation { scroller.scrollTo(Self.runAnchor, anchor: .top) }
                }
                .onChange(of: tab) {
                    guard let anchor = scrollAfterTab else { return }
                    scrollAfterTab = nil
                    withAnimation { scroller.scrollTo(anchor, anchor: .top) }
                }
                .onChange(of: scrollToReports) { _, wanted in
                    if wanted { scroller.scrollTo(scrollToReader ? Self.readerAnchor : Self.reportsAnchor, anchor: .top) }
                    #if DEBUG
                    if wanted, Spikes.isRequested { print("state: scrolled to \(scrollToReader ? "the reader" : "the logs")") }
                    #endif
                }
                .onChange(of: scrollTarget) { _, anchor in
                    if let anchor { scroller.scrollTo(anchor, anchor: .top) }
                }
            }
        }
        .sheet(item: $confirming) { plan in
            CompromisedConfirmSheet(plan: plan, changes: changes) { confirming = nil }
        }
        // An edited form drops the plan's preview: a run is never of a form other than the one shown.
        .onChange(of: form) { _, edited in changes.formChanged(edited) }
        // Another person: the ticks and the picks were the last one's.
        .onChange(of: form.person) { old, new in
            guard old.trimmingCharacters(in: .whitespaces).lowercased() != new.trimmingCharacters(in: .whitespaces).lowercased() else { return }
            (form.done, form.restOf, form.filters, form.delegates, form.sendAs, form.autoReplyOff) = ([], "", [], [], [], false)
            form.computers = [:]
            // A "Do It Here" is for its own person only (a request sets the person first, so its pick survives this).
            if let pending = pendingPick, pending.person.lowercased() != new.trimmingCharacters(in: .whitespaces).lowercased() {
                pendingPick = nil
            }
            pickMissed = false
            // The switches too: a step turned off for one person's errand is never off for the next person's lock.
            form.switchedOn = Compromised.Step.onByDefault
            form.discardDrafts = .none
            form.deleteScheduled = false
        }
        // A check again (after a run): the ticks on what's gone are dropped.
        .onChange(of: changes.check?.id) {
            guard let check = changes.check else { return }
            form.keepPicks(in: check)
            pickMissed = false
            if let pending = pendingPick {
                pendingPick = nil
                if check.isFor(pending.person), check.isFor(form.person) { pick(pending.pick, in: check) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onAppear {
            if let check = changes.check, form.person.isEmpty, requested == nil { form.person = check.asked }
            auditStamp = LogReaderView.auditStamp(auditURL)
        }
        // A run ended here: what it did is in the audit log, for the report and the emails pulled.
        .onChange(of: changes.isRunning) { _, running in
            if !running { auditStamp = LogReaderView.auditStamp(auditURL) }
        }
        // The groups read are kept with the reading, but a read that failed is tried again when the screen opens. On leaving,
        // not opening, so the first reading isn't asked twice.
        .onDisappear { groupsReached.forgetFailures() }
        .onChange(of: requested, initial: true) { _, email in
            guard let email else { return }
            requested = nil
            if tab != .respond {
                scrollAfterTab = Self.checkAnchor
                tab = .respond
            }
            // Mid-run the form stays as it is: the check says why it can't start, and a "Do It Here" is dropped, never left
            // to pick on a later check.
            if changes.isRunning { pendingPick = nil } else { form = CompromisedChanges.Form(person: email) }
            let changes = changes
            Task { await changes.check(email) }
        }
        .onChange(of: setup.generation) {
            form = CompromisedChanges.Form()
            changes.clear()
            logs.clear()
            // Another tenant: the narrowing and the reader's memory were the last one's.
            filter = nil
            readerMemory.clear()
        }
        .task(id: directory.users?.count ?? -1) { fillForSnapshot() }
        .onChange(of: announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// Investigate: what the incident is (its order of work), the logs pulled, and what they show.
    @ViewBuilder private func investigate(_ scroller: ScrollViewProxy) -> some View {
        Section {
            Text("For an account taken over: Investigate finds who's affected, Respond secures each account and pulls the email, "
                 + "Report keeps the record. Reading changes nothing; every change is previewed first and confirmed with the "
                 + "person's address.")
                .foregroundStyle(.secondary)
        }
        if setup.active != nil {
            IncidentLogsSection(person: check?.user.primaryEmail, logs: logs, directory: directory, form: $pullForm, filter: $filter,
                                readMore: read, readingSaved: incidents.loading)
                .id(Self.reportsAnchor)
            if let pull = logs.pull, pull.ended { reader(.findings, pull, scroller) }
        } else {
            Section { Text("Connect a domain on Setup first.").foregroundStyle(.secondary) }
        }
    }

    /// Respond: a run under way, where each account stands and what's left to do, securing an account, and pulling the email.
    @ViewBuilder private func respond(_ scroller: ScrollViewProxy) -> some View {
        if let run = changes.run {
            CompromisedRunSection(run: run, changes: changes) { rest in
                form = rest
                if let check = changes.check { form.keepPicks(in: check) }
                changes.dismissRun()
                let form = form, changes = changes
                Task { await changes.plan(form) }
            }
            .id(Self.runAnchor)
        }
        if setup.active != nil, let pull = logs.pull, pull.ended { reader(.toDo, pull, scroller) }
        Group {
            whoSection.id(Self.checkAnchor)
            if let check {
                FindingsSection(check: check)
                AccountSection(check: check)
                ForwardingSection(check: check, autoReplyOff: $form.autoReplyOff)
                FiltersSection(check: check, picked: $form.filters)
                DelegatesSection(check: check, picked: $form.delegates)
                SendAsSection(check: check, picked: $form.sendAs)
                ScheduledSection(check: check, delete: $form.deleteScheduled)
                DraftsSection(check: check, discard: $form.discardDrafts)
                AdminRolesSection(check: check)
                DevicesSection(check: check, picked: $form.computers, missed: pickMissed)
                AppsSection(check: check)
                ScriptsSection(check: check)
                StepsSection(form: $form, scheduledChosen: form.deleteScheduled ? check.scheduledSends.count : 0,
                             draftsChosen: check.drafts(form.discardDrafts).count)
                previewSection
            }
        }
        .disabled(changes.isRunning)
        if case .planned(let plan) = changes.planState, plan.form == form, check != nil {
            CompromisedPlanSection(plan: plan, canRun: plan.preview != nil && !changes.isRunning) { confirming = plan }
                .id(Self.planAnchor)
        }
        PullEmailSection(openPhishing: openPhishing)
    }

    /// Report: the incident report (from the saved logs, once read), the incident's evidence and notes, and what's left after.
    @ViewBuilder private func report(_ scroller: ScrollViewProxy) -> some View {
        if setup.active != nil {
            if let pull = logs.pull, pull.ended {
                reader(.report, pull, scroller)
            } else {
                Section {
                    Text(incidents.loading || logs.isPulling ? "The report follows once the logs are read."
                         : "Open or make an incident above, with its logs pulled or added, for its report.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Incident report").accessibilityAddTraits(.isHeader)
                }
            }
            IncidentRecordSection(part: .report, setup: setup, incidents: incidents, logs: logs)
        }
        AfterwardsSection()
    }

    /// The log reader's part for a tab. A fix it found is an address for this screen's own check, or a Message-ID for
    /// Phishing; Show the Events narrows Investigate's logs; Pull Again reads more.
    private func reader(_ part: LogReaderView.Part, _ pull: IncidentLogs.Pull, _ scroller: ScrollViewProxy) -> some View {
        let domain = setup.active?.name ?? ""
        // The incident open on this domain keeps the warnings picked (Who it reached); with none open, a pick can't be kept.
        let open = incidents.record(incidents.openID).flatMap { $0.domain == domain.lowercased() ? $0 : nil }
        // The domains people here have addresses at (primary and aliases, from the directory) and the connected one: inside.
        let index = directoryIndex.index(directory, domain: domain)
        // The groups the attacker's emails went to, once their members are read: each counts by them.
        let groups = groupsReached
        return LogReaderView(part: part, pull: pull, auditURL: auditURL,
                             auditStamp: auditStamp ?? LogReaderView.auditStamp(auditURL), domain: domain, nobodyHas: nobodyHas.checks(for: domain),
                             nobodyHasProblem: nobodyHas.problem, memory: readerMemory, secure: { person, pick in
            pendingPick = pick.map { (person, $0) }
            requested = person
            go(.respond, to: Self.checkAnchor, scroller)
        }, pullEmail: openPhishing, marks: known.marks(for: domain), marksProblem: known.openProblem,
        markTheirs: { account, address, note in known.mark(domain: domain, account: account, address: address, note: note) },
        unmark: { known.unmark($0) }, show: { shown in
            filter = shown
            go(.investigate, to: Self.reportsAnchor, scroller)
        }, pullAgain: { applications, accounts in
            pullAgain(applications, accounts)
            go(.investigate, to: Self.reportsAnchor, scroller)
        }, domains: index.domains, people: index.people, groups: groups.members, everyone: groups.everyone,
        directoryKey: index.key + "|" + groups.key, groupProblems: groups.problems, readingGroups: groups.isReading,
        readGroups: { addresses in Task { await groups.read(addresses) } }, warnings: open?.warnings ?? [], pickWarning: open.map { record in
            { email, warning in incidents.pickWarning(email: email, warning: warning, in: record.id) }
        }, sweep: { address in
            sweep(address)
            go(.investigate, to: Self.reportsAnchor, scroller)
        }, swept: swept(pull, open: open), phish: open?.phish, pickPhish: open.map { record in { phish in incidents.pickPhish(phish, in: record.id) } },
        incident: part == .report ? open.map { reportInputs($0, index: index) } : nil,
        anchor: part == .findings ? Self.readerAnchor : part == .toDo ? Self.toDoAnchor : Self.reportAnchor)
    }

    /// What the report of the incident `record` is made with: its saved reads, the directory's people with 2-Step Verification
    /// off, who's connected, and copying its evidence and keeping its review, both on this Mac.
    private func reportInputs(_ record: IncidentStore.Record, index: DirectoryIndex.Index) -> ReportInputs {
        let names = incidents.evidence.flatMap { $0.id == record.id ? $0.names : nil } ?? []
        let store = incidents.store, id = record.id
        return ReportInputs(record: record, evidence: names.map { ($0, incidents.abouts[$0] ?? "") }, no2SV: index.no2SV, directoryKey: index.key,
                            madeBy: setup.connectedAdmin ?? "", copyEvidence: { folder in
            guard let store else { throw IncidentStore.Problem.invalid("The incidents couldn't be opened.") }
            return try store.copyEvidence(of: id, to: folder)
        }, saveReview: { review in
            guard var kept = incidents.record(id) else { return "That incident isn't kept any more." }
            kept.review = review
            return incidents.save(kept)
        })
    }

    /// The addresses a read of every account was made from already: the open incident's saved reads (each by its `about.txt`,
    /// never the merged query, which keeps only the first address), or a read shown that isn't the evidence.
    private func swept(_ pull: IncidentLogs.Pull, open: IncidentStore.Record?) -> Set<String> {
        var swept = open.flatMap { record in incidents.evidence?.id == record.id ? incidents.swept : nil } ?? []
        if !pull.fromEvidence, pull.query.users.isEmpty, !pull.query.ip.isEmpty { swept.insert(pull.query.ip) }
        return swept
    }

    /// Reads every account's logs from `address` (the recommended logs, over the window shown), and adds what it finds to
    /// what's shown, as a Pull Again does: narrow first (slice 7). A read: nothing changes.
    private func sweep(_ address: String) {
        let shown = logs.pull?.query.hours ?? 0
        read(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: [], hours: shown > 0 ? shown : pullForm.hours, ip: address))
    }

    /// Shows `tab` scrolled to `anchor`: at once when it's shown already, else once it has drawn.
    private func go(_ tab: Tab, to anchor: String, _ scroller: ScrollViewProxy) {
        if self.tab == tab {
            withAnimation { scroller.scrollTo(anchor, anchor: .top) }
        } else {
            scrollAfterTab = anchor
            self.tab = tab
        }
    }

    /// Reads `applications` again for `accounts` (those in the directory, 20 at most) over the window shown, and adds what
    /// it finds to what's shown: an incident open saves the read and shows everything saved; otherwise the read is put
    /// together with the pull shown (`IncidentLogs.pull(adding:)`). A read: nothing changes.
    private func pullAgain(_ applications: [ActivityLogs.Application], _ accounts: [String]) {
        let known = directory.users.map { Set($0.map { $0.primaryEmail.lowercased() }) }
        let inDirectory = accounts.filter { known?.contains($0.lowercased()) ?? true }
        let users = Array((inDirectory.isEmpty ? accounts : inDirectory).prefix(20))
        guard !users.isEmpty, !applications.isEmpty else { return }
        let shown = logs.pull?.query.hours ?? 0
        read(IncidentLogs.Query(applications: applications, users: users, hours: shown > 0 ? shown : pullForm.hours, ip: ""))
    }

    /// Reads `query` and adds it to what's shown: with an incident open the read is saved to it and everything saved
    /// shown; otherwise it's put together with the pull shown (`IncidentLogs.pull(adding:)`). A read: nothing changes.
    private func read(_ query: IncidentLogs.Query) {
        filter = nil
        let open = incidents.record(incidents.openID).map { $0.domain == setup.active?.name.lowercased() } ?? false
        let logs = logs
        Task { if open { await logs.pull(query) } else { await logs.pull(adding: query) } }
    }

    private static let planAnchor = "compromised.plan"
    private static let toDoAnchor = "compromised.todo"
    private static let runAnchor = "compromised.run"
    private static let reportsAnchor = "compromised.reports"
    private static let readerAnchor = "compromised.reader"
    private static let reportAnchor = "compromised.report"
    private static let incidentAnchor = "compromised.incident"
    private static let checkAnchor = "compromised.check"

    private var planShown: Bool {
        if case .planned(let plan) = changes.planState { return plan.form == form }
        return false
    }

    /// The check's outcome, the plan's header or why there is none, and each step as a run ends it.
    private var announcement: String? {
        if let run = changes.run {
            if run.ended { return run.summary }
            let done = run.results.compactMap { $0 }.count
            guard done > 0, done <= run.plan.runningRows.count else { return nil }
            return "\(run.plan.runningRows[done - 1].label): \(StepStatus(result: run.results[done - 1]).words)."
        }
        if let problem = changes.problem { return problem }
        switch changes.planState {
        case .planned(let plan) where plan.form == form: return plan.header
        case .blocked(let blocked) where blocked.form == form: return blocked.reason
        default: break
        }
        switch changes.checkState {
        case .checked(let check): return "Checked \(check.user.primaryEmail). \(check.findings.count) things to look at."
        case .failed(_, let reason): return reason
        default: return nil
        }
    }

    private var whoSection: some View {
        Section("2. Secure an account") {
            AddressField(title: "Person whose account was taken over", prompt: "person@example.com", text: $form.person,
                         directory: directory)
                .onSubmit(checkAccount)
            HStack(alignment: .firstTextBaseline) {
                switch changes.checkState {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Reading the account, its filters, forwarding, delegates, send-as addresses and admin roles…")
                case .failed where changes.checkFailure(for: form.person) != nil:
                    Label(changes.checkFailure(for: form.person) ?? "", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                case .checked(let check) where !check.isFor(form.person):
                    Label("The address changed since the last check. Check the account again.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                default:
                    if let problem = changes.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
                Spacer()
                Button(check == nil ? "Check Account" : "Check Again", action: checkAccount)
                    .keyboardShortcut("r")
                    .disabled(changes.isChecking || changes.isRunning || setup.active == nil)
                    .help("Read what an attacker commonly changes (⌘R, or Return in the field). Nothing changes.")
                    .accessibilityHint("Reads the account's filters, forwarding, delegates, send-as addresses and admin roles. Nothing changes.")
            }
            .accessibilityElement(children: .contain)
            if setup.active == nil {
                Text("Connect a domain on Setup first.").foregroundStyle(.secondary)
            }
        }
    }

    /// Picks only what a "Do It Here" asked for, on what the check read (`Form.pickOnly`).
    private func pick(_ pick: SecurePick, in check: CompromisedChanges.Check) {
        switch pick {
        case .clearRecovery: form.pickOnlyClearRecovery()
        case .computer(let resourceID, let registeredAt):
            pickMissed = !form.pickOnly(computer: resourceID, registeredAt: registeredAt, in: check)
        }
    }

    private func checkAccount() {
        pendingPick = nil   // the operator's own check: the full lock, as ever
        let person = form.person, changes = changes
        Task { await changes.check(person) }
    }

    private var previewSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                switch changes.planState {
                case .blocked(let blocked) where blocked.form == form:
                    Label(blocked.reason, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                case .planned(let plan) where plan.form != form:
                    Label("The ticks changed since the last plan. Preview the steps again.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                case .planned(let plan) where plan.preview == nil && hasGam:
                    Label("This plan was changed after it was made. Preview the steps again to run them.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Spacer()
                Button("Preview Steps") {
                    let form = form, changes = changes
                    Task { await changes.plan(form) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(changes.isChecking || changes.isRunning)
                .help("Show every step's exact command (⌘Return). Nothing runs.")
                .accessibilityHint("Shows every step's exact command. Nothing runs.")
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` checks that person once the directory is loaded; `SWIFTGAMGUI_TAB` then shows
    /// the plan with every filter that hides or forwards mail, every delegate and every other send-as address ticked
    /// (`plan`), the confirm sheet over it (`confirm`), a finished run's panel (`result`, made up: nothing runs), the
    /// person's incident logs, then every account's by the first address on their flagged sign-in (`reports`), the
    /// person's and dana@'s logs with Chrome's, read by the log reader (`reading`: Investigate's findings; `todo`: Respond's
    /// Still to do; `reached`: Respond's first Who it reached, alice@'s and bob@'s logs too, in a demo incident with the mock's
    /// warning picked, scrolled to Everyone it got to; `report`: the same incident's report on Report, with a review written;
    /// `origin`: the same on Investigate, scrolled to Where it started with the vendor's email picked), or the person's logs saved to a
    /// demo incident kept in the demo's temporary folder, with a note, opened on Report (`incident`). A plan, the confirm sheet or
    /// a run shows on Respond.
    private func fillForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard directory.users != nil, !debugApplied, let person = environment["SWIFTGAMGUI_SELECT"] else { return }
        debugApplied = true
        form.person = person
        let asked = environment["SWIFTGAMGUI_TAB"] ?? ""
        let changes = changes
        // The log reader's pictures wait for its reading, which comes off the main thread after the pull, and for the scroll.
        let reading = ["reading", "todo", "reached", "report", "origin"].contains(asked)
        if reading { Spikes.snapshotWork += 1 }
        Task {
            defer { if reading { Spikes.snapshotWork -= 1 } }
            await changes.check(person)
            if asked == "reports", let email = changes.check?.user.primaryEmail {
                await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: [email], hours: 72, ip: ""))
                if let ip = logs.pull?.addresses.first {
                    await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: [], hours: 72, ip: ip))
                }
                scrollToReports = true
                return
            }
            if asked == "incident", let email = changes.check?.user.primaryEmail {
                await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: [email], hours: 72, ip: ""))
                if case .success(let record) = incidents.create(domain: setup.active?.name ?? "", title: "Account takeover",
                                                                 opened: Date(), openedBy: "Pat", reported: "A Google alert") {
                    if let pull = logs.pull { _ = try? await incidents.add(pull, to: record.id) }
                    _ = incidents.addNote("Told the person's manager.", at: Date(), to: record.id)
                    incidents.openID = record.id
                }
                self.tab = .report
                return
            }
            if reading, let email = changes.check?.user.primaryEmail {
                // Who it reached reads the recipients' and the warning's sender's Gmail logs too, in a demo incident with the
                // mock's warning picked: what a pick shows (warned on its send outside, not shown warned with no receipt here).
                let reached = asked == "reached" || asked == "report" || asked == "origin"
                await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault + [.chrome],
                                                   users: [email, "dana@example.com"] + (reached ? ["alice@example.com", "bob@example.com"] : []),
                                                   hours: 72, ip: ""))
                if reached, case .success(let record) = incidents.create(domain: setup.active?.name ?? "", title: "Account takeover",
                                                                         opened: Date(), openedBy: "Pat", reported: "A Google alert") {
                    if let pull = logs.pull { _ = try? await incidents.add(pull, to: record.id) }
                    _ = incidents.pickWarning(email: "phish-1@mail.example.com", warning: "warning-1@mail.example.com", in: record.id)
                    if asked == "origin" { _ = incidents.pickPhish("inv-4471@mail.vendor.example", in: record.id) }
                    if asked == "report", var reviewed = incidents.record(record.id) {
                        reviewed.review = IncidentStore.Review(kind: "Account takeover and phishing", severity: "High",
                                                               meeting: Date().addingTimeInterval(86_400 * 2), attendees: "Pat, Sam",
                                                               cause: "A look-alike sign-in page took Carol's password; she had no 2-Step Verification.",
                                                               plan: "Enforce 2-Step Verification for everyone — Pat — in two weeks")
                        _ = incidents.save(reviewed)
                        _ = incidents.addNote("Called the bank about the invoice in the phish.", at: Date(), to: record.id)
                    }
                    incidents.openID = record.id
                }
                // Scroll once the findings are drawn: an anchor that first appears in the same update doesn't scroll.
                let pulled = ContinuousClock.now
                for _ in 0..<100 where !readerMemory.hasReading { try? await Task.sleep(for: .milliseconds(50)) }
                print("state: the reading \(readerMemory.hasReading ? "came" : "hadn't come") \(ContinuousClock.now - pulled) after the pull")
                try? await Task.sleep(for: .milliseconds(300))
                if asked == "report" {
                    self.tab = .report
                } else if asked == "origin" {
                    // Where it started, on Investigate under the findings, once the reading with the pick has come.
                    for _ in 0..<100 where readerMemory.picksPhish != true { try? await Task.sleep(for: .milliseconds(50)) }
                    try? await Task.sleep(for: .milliseconds(300))
                    scrollTarget = LogReaderView.wayInAnchor
                } else if asked == "todo" || asked == "reached" {
                    self.tab = .respond
                    if asked == "reached", readerMemory.firstReach != nil {
                        // Everyone it got to, above the first Who it reached; once Respond has drawn it: an anchor that first
                        // appears in the same update doesn't scroll.
                        try? await Task.sleep(for: .milliseconds(300))
                        scrollTarget = LogReaderView.gotItAnchor
                    }
                } else {
                    scrollToReader = true
                    scrollToReports = true
                }
                try? await Task.sleep(for: .milliseconds(500))
                return
            }
            guard ["plan", "confirm", "result"].contains(asked), let check = changes.check else { return }
            form.filters = Set(((try? check.filters.get()) ?? []).filter(\.hidesOrForwards).map(\.id))
            form.delegates = Set((try? check.delegates.get()) ?? [])
            form.sendAs = Set(((try? check.sendAs.get()) ?? []).filter { !$0.isPrimary }.map(\.address))
            form.deleteScheduled = !check.scheduledSends.isEmpty
            // The drafts that share the newest one's subject: an attacker's batch.
            if let subject = (try? check.drafts.get())?.first?.subject { form.discardDrafts = .subjectContaining(subject) }
            await changes.plan(form)
            guard case .planned(let plan) = changes.planState else { return }
            if asked == "confirm" { confirming = plan }
            if asked == "result" { changes.showDemoRun() }
        }
        #endif
    }
}

// MARK: the check

/// A read's failure, in GAM's words: never shown as "none".
private struct Unread: View {
    let what: String
    let problem: UserAccess.Problem

    var body: some View {
        Label("Couldn't read \(what): \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .textSelection(.enabled)
            .accessibilityLabel("Couldn't read \(what). \(problem.summary)")
    }
}

/// What the check found worth looking at first, each in a sentence with a symbol.
private struct FindingsSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        Section {
            if check.isConnectedAdmin {
                Label("This app is connected as \(check.user.primaryEmail): it can't secure that account (the sign-out would "
                      + "delete the app's own authorization). Use another admin's setup.", systemImage: "exclamationmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if check.findings.isEmpty {
                Label("Nothing stood out in what could be read.", systemImage: "checkmark.circle")
            }
            ForEach(check.findings, id: \.self) { finding in
                Label(finding, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityLabel("To look at: \(finding)")
            }
        } header: {
            Text("What to look at").accessibilityAddTraits(.isHeader)
        }
    }
}

private struct AccountSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        let account = check.account
        Section("Account") {
            LabeledContent("Name", value: account.fullName)
            LabeledContent("Address", value: account.primaryEmail)
            LabeledContent("Suspended", value: account.suspended ? "Yes" : "No")
            LabeledContent("2-Step Verification",
                           value: account.enrolledIn2SV ? (account.enforcedIn2SV ? "On, enforced" : "On") : (account.enforcedIn2SV ? "Off, enforced" : "Off"))
            LabeledContent("Recovery email", value: account.recoveryEmail.isEmpty ? "None" : account.recoveryEmail)
            LabeledContent("Recovery phone", value: account.recoveryPhone.isEmpty ? "None" : account.recoveryPhone)
            LabeledContent("Super admin", value: account.isAdmin ? "Yes" : "No")
        }
        .textSelection(.enabled)
    }
}

private struct ForwardingSection: View {
    let check: CompromisedChanges.Check
    @Binding var autoReplyOff: Bool

    var body: some View {
        Section {
            switch check.autoReply {
            case .success(let reply) where reply.enabled:
                Toggle(isOn: $autoReplyOff) {
                    Text("Turn off the auto-reply: “\(reply.subject)”")
                    Label("On: everyone who writes gets its message. Check it's the person's own", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .accessibilityLabel("Turn off the auto-reply, “\(reply.subject)”")
            case .success: LabeledContent("Auto-reply", value: "Off")
            case .failure(let problem): Unread(what: "the auto-reply", problem: problem)
            }
            switch check.forwarding {
            case .success(let forwarding?): LabeledContent("Automatic forwarding", value: forwarding.words)
            case .success(nil): LabeledContent("Automatic forwarding", value: "Gmail didn't say")
            case .failure(let problem): Unread(what: "forwarding", problem: problem)
            }
            switch check.forwardingAddresses {
            case .success(let addresses) where addresses.isEmpty:
                Text("No forwarding addresses.").foregroundStyle(.secondary)
            case .success(let addresses):
                ForEach(addresses) { address in
                    LabeledContent(address.address, value: address.status == "accepted" ? "Verified: forwarding can go here" : address.status)
                }
            case .failure(let problem): Unread(what: "forwarding addresses", problem: problem)
            }
        } header: {
            Text("Forwarding and auto-reply")
        } footer: {
            Text("“Turn off forwarding” is a step below. The addresses stay listed: removing one is in Gmail's settings.")
        }
        .textSelection(.enabled)
    }
}

/// Every filter, what it matches and does, with a box to delete it. None is ticked to start.
private struct FiltersSection: View {
    let check: CompromisedChanges.Check
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            switch check.filters {
            case .success(let filters) where filters.isEmpty:
                Text("No filters.").foregroundStyle(.secondary)
            case .success(let filters):
                ForEach(filters) { filter in
                    Toggle(isOn: pick(filter.id)) {
                        Text(filter.words)
                        if filter.hidesOrForwards {
                            Label("Hides mail or sends it on: check it's the person's own", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    .accessibilityLabel("Delete the filter: \(filter.words)")
                    .accessibilityHint(filter.hidesOrForwards ? "Hides mail or sends it on." : "")
                }
            case .failure(let problem): Unread(what: "the filters", problem: problem)
            }
        } header: {
            Text("Gmail filters")
        } footer: {
            Text("Tick each filter to delete. The whole filter goes, with all it does. Labels the person made show as their IDs.")
        }
    }

    private func pick(_ id: String) -> Binding<Bool> {
        Binding(get: { picked.contains(id) }, set: { if $0 { picked.insert(id) } else { picked.remove(id) } })
    }
}

private struct DelegatesSection: View {
    let check: CompromisedChanges.Check
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            switch check.delegates {
            case .success(let delegates) where delegates.isEmpty:
                Text("No delegates.").foregroundStyle(.secondary)
            case .success(let delegates):
                ForEach(delegates, id: \.self) { delegate in
                    Toggle(delegate, isOn: pick(delegate))
                        .accessibilityLabel("Remove the delegate \(delegate)")
                }
            case .failure(let problem): Unread(what: "the delegates", problem: problem)
            }
        } header: {
            Text("Mail delegates")
        } footer: {
            Text("A delegate can read, send and delete the person's mail. Tick each to remove.")
        }
    }

    private func pick(_ address: String) -> Binding<Bool> {
        Binding(get: { picked.contains(address) }, set: { if $0 { picked.insert(address) } else { picked.remove(address) } })
    }
}

private struct SendAsSection: View {
    let check: CompromisedChanges.Check
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            switch check.sendAs {
            case .success(let addresses):
                ForEach(addresses) { address in
                    if address.isPrimary {
                        Text(address.words)
                    } else {
                        Toggle(address.words, isOn: pick(address.address))
                            .accessibilityLabel("Remove the send-as address \(address.words)")
                    }
                }
            case .failure(let problem): Unread(what: "the send-as addresses", problem: problem)
            }
        } header: {
            Text("Send mail as")
        } footer: {
            Text("Tick each address to take off the person's “Send mail as” list. Their own address stays.")
        }
    }

    private func pick(_ address: String) -> Binding<Bool> {
        Binding(get: { picked.contains(address) }, set: { if $0 { picked.insert(address) } else { picked.remove(address) } })
    }
}

/// The emails scheduled to send from the account, each with whom it goes to, and whether to delete every one. Keeping them
/// is the start: one may be the person's own. Only those Gmail labels scheduled are listed to delete.
private struct ScheduledSection: View {
    let check: CompromisedChanges.Check
    @Binding var delete: Bool

    var body: some View {
        Section {
            switch check.scheduled {
            case .success(let found):
                let sends = check.scheduledSends
                if sends.isEmpty {
                    Text("Gmail's search found nothing scheduled to send.").foregroundStyle(.secondary)
                } else {
                    if found.count >= Compromised.ScheduledSend.cap {
                        Text("At least \(Compromised.ScheduledSend.cap) found: after the delete, Check Again lists the rest.").font(.callout)
                    }
                    Toggle("Delete all \(sends.count) scheduled email\(sends.count == 1 ? "" : "s")", isOn: $delete)
                    if delete {
                        Text("\(sends.count == 1 ? "It" : "All \(sends.count)") will be deleted for good.").fontWeight(.semibold)
                    }
                    ForEach(sends) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                            Text(Self.recipients(message)).font(.callout).foregroundStyle(.secondary)
                            Text("Gmail's time: \(message.when?.formatted(date: .abbreviated, time: .shortened) ?? message.date)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if found.count > sends.count {
                    let other = found.count - sends.count
                    Text("\(other) more the search found \(other == 1 ? "isn't" : "aren't") labelled \(Compromised.ScheduledSend.label) by "
                         + "Gmail, so \(other == 1 ? "it's" : "they're") left alone.")
                        .font(.callout)
                }
            case .failure(let problem): Unread(what: "the scheduled emails", problem: problem)
            }
        } header: {
            Text("Scheduled to send")
        } footer: {
            Text("Gmail sends a scheduled email at its time on its own, with nobody signed in, and it isn't a draft. Deleting is "
                 + "for good. Gmail's own Scheduled, in the person's Gmail, is the record. To keep one, cancel the others there "
                 + "instead: Cancel send leaves each a draft, which Drafts below deletes after Check Again.")
        }
    }

    /// "To carol@example.com · Bcc pat@partner.example, guest@example.org and 1 more": each header's first three.
    private static func recipients(_ message: MailboxSearch.Message) -> String {
        let headers = [("To", message.to), ("Cc", message.cc), ("Bcc", message.bcc)].filter { !$0.1.isEmpty }.map { name, addresses in
            "\(name) " + addresses.prefix(3).joined(separator: ", ") + (addresses.count > 3 ? " and \(addresses.count - 3) more" : "")
        } + (message.unreadable.isEmpty ? [] : ["as GAM printed: " + message.unreadable.joined(separator: ", ")])
        return headers.isEmpty ? "No recipients in its headers." : headers.joined(separator: " · ")
    }
}

/// The person's drafts, newest first, and what to do with them: keep them, delete every one, or only those whose subject
/// holds some text (a phishing batch's subject). Keeping them is the start.
private struct DraftsSection: View {
    let check: CompromisedChanges.Check
    @Binding var discard: CompromisedChanges.Form.Discard
    @State private var subject = ""
    private let shown = 50

    private enum Choice: Hashable { case keep, all, matching }

    private var choice: Binding<Choice> {
        Binding(get: {
            switch discard {
            case .none: .keep
            case .all: .all
            case .subjectContaining: .matching
            }
        }, set: { picked in
            switch picked {
            case .keep: discard = .none
            case .all: discard = .all
            case .matching: discard = .subjectContaining(subject)
            }
        })
    }

    var body: some View {
        Section {
            switch check.drafts {
            case .success(let drafts) where drafts.isEmpty:
                Text("No drafts.").foregroundStyle(.secondary)
            case .success(let drafts):
                let chosen = check.drafts(discard).count
                Text(drafts.count >= Compromised.Draft.cap ? "The newest \(Compromised.Draft.cap) drafts, newest first."
                     : "\(drafts.count) draft\(drafts.count == 1 ? "" : "s"), newest first.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Drafts", selection: choice) {
                    Text("Keep them").tag(Choice.keep)
                    Text("Delete all \(drafts.count)").tag(Choice.all)
                    Text("Delete those whose subject contains…").tag(Choice.matching)
                }
                .pickerStyle(.radioGroup)
                if case .subjectContaining = discard {
                    TextField("Subject contains", text: $subject, prompt: Text(verbatim: drafts.first?.subject ?? ""))
                        .autocorrectionDisabled()
                        .onChange(of: subject) { _, text in discard = .subjectContaining(text) }
                        .accessibilityLabel("Delete the drafts whose subject contains")
                }
                if discard != .none {
                    Text("\(chosen) draft\(chosen == 1 ? "" : "s") will be deleted, for good.").fontWeight(.semibold)
                }
                ForEach(drafts.prefix(shown)) { draft in
                    let when = draft.when?.formatted(date: .abbreviated, time: .shortened) ?? draft.date
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                        Text(when).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if drafts.count > shown {
                    Text("Showing the newest \(shown) of \(drafts.count).").font(.callout)
                }
            case .failure(let problem): Unread(what: "the drafts", problem: problem)
            }
        } header: {
            Text("Drafts")
        } footer: {
            Text("Anyone signed in to the account can send a draft. Deleting is for good, as Gmail's Discard: Gmail's log keeps "
                 + "the record of them.")
        }
        .onAppear { if case .subjectContaining(let text) = discard { subject = text } }
    }
}

private struct AdminRolesSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        Section {
            switch check.adminRoles {
            case .success(let roles) where roles.isEmpty:
                Text(check.account.isDelegatedAdmin ? "No role assigned directly: one comes through a group. See the Admin console."
                     : "No admin roles.").foregroundStyle(.secondary)
            case .success(let roles):
                ForEach(roles) { role in Text(role.words) }
            case .failure(let problem): Unread(what: "the admin roles", problem: problem)
            }
        } header: {
            Text("Admin roles")
        } footer: {
            Text("Shown, not changed here: remove a role in the Admin console.")
        }
        .textSelection(.enabled)
    }
}

/// The apps and AI agents given access to the account, shown: the lock's sign-out revokes every one.
private struct AppsSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        Section {
            switch check.apps {
            case .success(let apps) where apps.isEmpty:
                Text("No app has access to this account.").foregroundStyle(.secondary)
            case .success(let apps):
                ForEach(apps) { app in AppRow(app: app, showsUsers: false) }
            case .failure(let problem): Unread(what: "the connected apps", problem: problem)
            }
        } header: {
            Text("Apps and agents with access")
        } footer: {
            Text("The sign-out step revokes every one. Ask the person which they use before they grant them again.")
        }
        .textSelection(.enabled)
    }
}

/// The phones and tablets syncing the account, then the computers signed in with it, shown: one the person doesn't own
/// may be the attacker's.
private struct DevicesSection: View {
    let check: CompromisedChanges.Check
    /// The computers to block or take the account off, by the person's sign-in on each.
    @Binding var picked: [String: Compromised.ComputerAction]
    /// A "Do It Here" named a computer none of these matched.
    let missed: Bool

    /// Keep it, block it, or take the account off it: what the plan does with one computer.
    private func choice(_ computer: Compromised.Computer) -> Binding<Compromised.ComputerAction?> {
        Binding(get: { picked[computer.deviceUser] }, set: { picked[computer.deviceUser] = $0 })
    }

    var body: some View {
        Section {
            switch check.devices {
            case .success(let devices) where devices.isEmpty:
                Text("No phone or tablet syncs this account.").foregroundStyle(.secondary)
            case .success(let devices):
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.words).fontWeight(.semibold)
                        Text("Last synced " + (device.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? device.lastSync)
                             + (device.firstSync.isEmpty ? "" : " · first "
                                + (device.firstSynced?.formatted(date: .abbreviated, time: .shortened) ?? device.firstSync))
                             + (device.status.isEmpty ? "" : " · \(device.status)"))
                            .font(.callout).foregroundStyle(.secondary)
                        if device.reportsCompromise {
                            Label("Reports it's rooted or jailbroken", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            case .failure(let problem): Unread(what: "the devices", problem: problem)
            }
        } header: {
            Text("Phones and tablets")
        } footer: {
            Text("Shown, not changed here: wipe the account from a device in the Admin console's Devices.")
        }
        .textSelection(.enabled)
        Section {
            if missed {
                Label("The computer the logs named matched none still signed in here, by Google's ID or by when it signed in: if "
                      + "it's listed, pick it by hand.", systemImage: "questionmark.circle")
            }
            switch check.computers {
            case .success(let computers) where computers.isEmpty:
                Text("No computer is signed in with this account in Google's endpoint management.").foregroundStyle(.secondary)
            case .success(let computers):
                ForEach(computers) { computer in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(computer.words).fontWeight(.semibold)
                        Text("Last synced " + (computer.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? computer.lastSync)
                             + (computer.firstSync.isEmpty ? "" : " · first signed in "
                                + (computer.firstSynced?.formatted(date: .abbreviated, time: .shortened) ?? computer.firstSync))
                             + (computer.ownership.isEmpty ? "" : " · \(computer.ownership)")
                             + (computer.state.isEmpty ? "" : " · \(computer.state)")
                             + (computer.serialNumber.isEmpty ? "" : " · serial \(computer.serialNumber)"))
                            .font(.callout).foregroundStyle(.secondary)
                        if computer.looksVirtual {
                            Label("A virtual machine, as a remote attacker's often is", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                        if computer.reportsCompromise {
                            Label("Reports it's compromised", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    // Only a computer still signed in, by the person's own sign-in on it, can be blocked or left.
                    if computer.isActive, !computer.deviceUser.isEmpty {
                        Picker("What to do with it", selection: choice(computer)) {
                            Text("Keep it").tag(Compromised.ComputerAction?.none)
                            Text("Block it").tag(Compromised.ComputerAction?.some(.block))
                            Text("Take the account off it").tag(Compromised.ComputerAction?.some(.delete))
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("What to do with \(computer.words)")
                        .accessibilityHint("Blocking keeps it listed, blocked, and approving it in the Admin console undoes it. Taking the "
                                           + "account off revokes its access; it shows again only if someone signs in on it.")
                    }
                }
            case .failure(let problem): Unread(what: "the computers", problem: problem)
            }
        } header: {
            Text("Computers")
        } footer: {
            Text("Block a computer that isn't the person's, or take the account off it: each is a step below, previewed and confirmed "
                 + "with the rest. Blocking keeps it listed, blocked, which approving it in the Admin console undoes.")
        }
        .textSelection(.enabled)
    }
}

/// The Apps Script projects the person owns, the latest changed first: one made or changed lately may be the attacker's.
private struct ScriptsSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        let now = Date()
        Section {
            switch check.scripts {
            case .success(let scripts) where scripts.isEmpty:
                Text("No Apps Script project in this person's Drive.").foregroundStyle(.secondary)
            case .success(let scripts):
                ForEach(scripts) { script in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(script.name.isEmpty ? "Untitled" : script.name).fontWeight(.semibold)
                        Text("Changed " + (script.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? script.modified)
                             + (script.lastChangedBy.isEmpty ? "" : " by \(script.lastChangedBy)")
                             + (script.created.isEmpty ? "" : " · made "
                                + (script.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? script.created))
                             + (script.inTrash ? " · in the bin" : ""))
                            .font(.callout).foregroundStyle(.secondary)
                        if script.isRecent(at: now) {
                            Label("Made or changed in the last two weeks", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            case .failure(let problem): Unread(what: "the Apps Script projects", problem: problem)
            }
        } header: {
            Text("Apps Script projects")
        } footer: {
            Text("Shown, not changed here. A script inside a Sheet or Doc, or in a shared drive, isn't listed: once authorized it "
                 + "shows as a connected app. The person can open one at script.google.com, and delete one they don't recognise "
                 + "from their Drive.")
        }
        .textSelection(.enabled)
    }
}

/// Every lock step a switch, the full lock on to start, and the picks above said in a line.
private struct StepsSection: View {
    @Binding var form: CompromisedChanges.Form
    /// How many scheduled emails and drafts the form's choices delete.
    let scheduledChosen: Int
    let draftsChosen: Int

    var body: some View {
        Section {
            HStack {
                Text("The full lock is on to start. Every step is a switch: turn them all off to run one thing alone.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button("All Off") { form.switchedOn = [] }
                    .disabled(form.switchedOn.isEmpty)
                    .accessibilityLabel("Turn every step off")
                Button("The Lock") { form.switchedOn = Compromised.Step.onByDefault }
                    .disabled(form.switchedOn == Compromised.Step.onByDefault)
                    .accessibilityLabel("Turn the full lock back on")
            }
            ForEach(Compromised.Step.switchable, id: \.self) { step in
                if form.done.contains(step) {
                    Toggle(isOn: done(step)) {
                        Text("\(step.name): already done")
                        Text("It succeeded in the last run, so it isn't run again. Untick to run it.")
                    }
                    .accessibilityLabel("Already done: \(step.name)")
                } else {
                    Toggle(isOn: switched(step)) {
                        Text(step.name)
                        if let note = step.note { Text(note) }
                    }
                    .accessibilityLabel("Runs: \(step.name)")
                    .accessibilityHint(step.note ?? "")
                }
            }
            let picks = [(form.filters.count, "filter", "delete"), (form.delegates.count, "delegate", "remove"),
                         (form.sendAs.count, "send-as address", "remove"), (form.autoReplyOff ? 1 : 0, "auto-reply", "turn off"),
                         (form.computers.values.filter { $0 == .block }.count, "computer", "block"),
                         (form.computers.values.filter { $0 == .delete }.count, "computer", "take the account off"),
                         (scheduledChosen, "scheduled email", "delete"), (draftsChosen, "draft", "delete")]
                .filter { $0.0 > 0 }
            Text(picks.isEmpty ? "Nothing ticked to undo above."
                 : "Also: " + picks.map { "\($0.2) \($0.0) \($0.1)\($0.0 == 1 ? "" : ($0.1.hasSuffix("s") ? "es" : "s"))" }
                    .joined(separator: ", ") + ".")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Steps")
        } footer: {
            Text("Every step runs only once you preview the plan and confirm it with the person's address.")
        }
    }

    private func done(_ step: Compromised.Step) -> Binding<Bool> {
        Binding(get: { form.done.contains(step) }, set: { if $0 { form.done.insert(step) } else { form.done.remove(step) } })
    }

    private func switched(_ step: Compromised.Step) -> Binding<Bool> {
        Binding(get: { form.switchedOn.contains(step) }, set: { if $0 { form.switchedOn.insert(step) } else { form.switchedOn.remove(step) } })
    }
}

// MARK: the plan and the run

/// Every step in order with its exact command, or struck through when already done; what a failure stops; then Secure.
private struct CompromisedPlanSection: View {
    let plan: CompromisedChanges.Plan
    let canRun: Bool
    let run: () -> Void

    var body: some View {
        Section {
            Text("Each step shows the exact gam command it would run, in order.").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(plan.rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    switch row.status {
                    case .runs(let full):
                        // Thousands of draft IDs would be a page of text, and spoken one by one: the start, then how much.
                        let commandLine = full.count > 400 ? String(full.prefix(400)) + "… (\(full.count.formatted()) characters in all)" : full
                        Text("\(index + 1). \(row.label)").fontWeight(.semibold)
                        Text(row.summary).foregroundStyle(.secondary)
                        Text(commandLine)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel("Command: \(commandLine)")
                    case .alreadyDone:
                        Text("\(index + 1). \(Text(row.label).strikethrough())")
                        Text("Already done: not run, and counts as succeeded.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            Text(plan.whatStopsWhat)
            if canRun {
                HStack {
                    Spacer()
                    Button("Secure \(plan.person.primaryEmail)…", action: run)
                        .help("Asks you to type the person's address, then runs exactly these steps")
                        .accessibilityHint("Opens the confirmation: type the person's address to run exactly these steps.")
                }
            }
        } header: {
            Text(plan.header).font(.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
        }
    }
}

/// The run: each step as it ends and Stop between steps; then the summary, what to do next, and Preview the Rest.
private struct CompromisedRunSection: View {
    let run: CompromisedChanges.Run
    let changes: CompromisedChanges
    let previewTheRest: (CompromisedChanges.Form) -> Void
    @State private var askingStop = false

    private var done: Int { run.results.compactMap { $0 }.count }

    var body: some View {
        Section {
            ForEach(Array(run.plan.runningRows.enumerated()), id: \.element.id) { index, row in
                let status = StepStatus(result: run.results[index], running: !run.ended && index == done)
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(index + 1). \(row.label)", systemImage: status.symbol).symbolRenderingMode(.multicolor)
                    Text(detail(run.results[index]) ?? status.words).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1), \(row.label): \(status.words)")
            }
            if run.ended {
                if let problem = run.auditProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                if run.mayStillBeSignedIn {
                    Label("The attacker may still be signed in, and app passwords and connected apps may still work: "
                          + "“\(Compromised.Step.revoke.name)” didn't run to completion. Fix what it reports and run it again (it is "
                          + "safe to repeat).", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                Text(run.isComplete
                     ? "The account was checked again below: anything made before the sign-out shows there. Next: give the person "
                        + "a new password if the reset ran here, and have them turn on 2-Step Verification and re-grant the apps "
                        + "they use."
                     : "To finish: fix what the failed step reports, then Preview the Rest: it ticks the lock steps that succeeded "
                        + "as already done. The account was checked again below.")
                HStack {
                    Spacer()
                    if !run.isComplete {
                        Button("Preview the Rest") { previewTheRest(run.rest) }
                            .help("A new plan with the steps that succeeded left out")
                    }
                    Button("Done") { changes.dismissRun() }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(run.stopping ? "Stopping after this step…" : "Securing… \(done) of \(run.plan.runningRows.count)"
                         + (done < run.plan.runningRows.count ? " · \(run.plan.runningRows[done].label)" : ""))
                    Spacer()
                    Button("Stop After This Step…") { askingStop = true }.disabled(run.stopping)
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(run.ended ? run.summary : "Securing \(run.plan.person.primaryEmail)")
                .font(.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
        }
        .confirmationDialog("Stop after this step?", isPresented: $askingStop) {
            Button("Stop After This Step", role: .destructive) {
                let changes = changes
                Task { await changes.stop() }
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The step running now finishes; the ones after it don't run. Preview the Rest runs them later.")
        }
    }

    private func detail(_ result: RunOutcome.Step?) -> String? {
        switch result {
        case .failed(let message, _)?: message
        case .skipped(let reason)?: reason
        default: nil
        }
    }
}


// MARK: steps 3 and 4

/// Step 3: the phishing email out of every mailbox, on the Phishing screen (its dry run finds who has a copy, a read; the
/// trash is previewed and confirmed there). The log reader's “Pull … from Every Mailbox…” opens it with the Message-ID.
private struct PullEmailSection: View {
    let openPhishing: (String) -> Void

    var body: some View {
        Section {
            HStack {
                Text("If the account sent phishing, take it out of every mailbox by its Message-ID. Phishing finds who has a copy "
                     + "first, and keeps the sender's own copy as evidence.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Phishing…") { openPhishing("") }
                    .accessibilityHint("Opens the Phishing screen. Nothing changes until you preview and confirm there.")
            }
        } header: {
            Text("3. Pull the email from every mailbox").accessibilityAddTraits(.isHeader)
        }
    }
}

/// Step 4: what's left once the accounts are secured, each said with where it's done.
private struct AfterwardsSection: View {
    static let items = [
        ("key", "Give each secured person a new password: Users → their page → Actions → Set Temporary Password…, then tell them "
            + "in person or by phone. It shows once."),
        ("lock.shield", "Turn on 2-Step Verification for anyone who doesn't have it (the check says who)."),
        ("globe", "Check their Chrome profiles (Users → their page → Security → Check Chrome): passwords saved in a Chrome "
            + "signed in with the work account were within the attacker's reach; change the important ones."),
        ("clock.arrow.circlepath", "Pull the logs again later, by the accounts: Read the logs says where each one stands, "
            + "whether the lock is holding, and any sign-in after it."),
        ("folder", "Export All the logs into a folder, for the record."),
    ]

    var body: some View {
        Section {
            ForEach(Self.items, id: \.1) { symbol, text in
                Label(text, systemImage: symbol)
            }
        } header: {
            Text("4. Afterwards").accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: the incident logs

/// Pull Incident Logs: the activity logs an incident needs, for a window, some accounts (none: every one) and an IP
/// address, each a table in the one shape with its CSV. Reads only; the field starts with the checked person.
private struct IncidentLogsSection: View {
    let person: String?
    let logs: IncidentLogs
    let directory: DirectoryStore
    /// The pull's form, the screen's: kept across its tabs.
    @Binding var form: PullForm
    /// The events a to-do item narrowed the logs to ("Show the Events"); nil for all.
    @Binding var filter: IncidentLogs.Filter?
    /// Reads more and adds it to what's shown (Read the Rest), as the screen reads: saved to an incident open.
    let readMore: (IncidentLogs.Query) -> Void
    /// The open incident's saved logs are being read: said with the logs.
    let readingSaved: Bool
    private var hours: Int { form.hours }
    private var accounts: String { form.accounts }
    private var ip: String { form.ip }
    private var chosen: Set<ActivityLogs.Application> { form.chosen }
    private var flaggedOnly: Bool { form.flaggedOnly }
    @State private var exported: (text: String, failed: Bool)?
    @Environment(\.appearsActive) private var appearsActive

    private var typedAccounts: [String] { IncidentLogs.Query.accounts(accounts) }

    private var problem: String? {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        if !ip.isEmpty, !Address.isIP(ip) { return "“\(ip)” isn't one IP address." }
        if let odd = typedAccounts.first(where: { !Address.looksLikeEmail($0) }) { return "“\(odd)” isn't one email address." }
        if typedAccounts.count > 20 { return "At most 20 accounts at once: leave the field empty for every account." }
        // GAM fails the whole log for one address that isn't a user (its entityUnknownWarning): said here first. Chrome's reads
        // one with no events at all, as if nothing happened, so with Chrome picked the directory must be there to check.
        if !typedAccounts.isEmpty, directory.users == nil, chosen.contains(.chrome) {
            return "Chrome's log checks the accounts against the directory first: load it on Home."
        }
        if !typedAccounts.isEmpty, let users = directory.users {
            let known = Set(users.map { $0.primaryEmail.lowercased() })
            if let stranger = typedAccounts.first(where: { !known.contains($0.lowercased()) }) {
                return "“\(stranger)” isn't an account's primary address in the directory."
            }
        }
        if chosen.isEmpty { return "Pick at least one log." }
        return nil
    }

    var body: some View {
        Section {
            Picker("Over the last", selection: $form.hours) {
                ForEach(ActivityLogs.hours, id: \.self) { hours in Text(Self.window(hours)).tag(hours) }
            }
            .fixedSize()
            TextField("Accounts (empty for every account)", text: $form.accounts, prompt: Text(verbatim: "person@example.com, other@example.com"))
                .autocorrectionDisabled()
            HStack {
                TextField("Only from IP address (optional)", text: $form.ip, prompt: Text(verbatim: "198.51.100.23"))
                    .autocorrectionDisabled()
                if let addresses = logs.pull?.addresses, !addresses.isEmpty {
                    Menu("Seen in the sign-ins") {
                        ForEach(addresses.prefix(20), id: \.self) { address in Button(address) { form.ip = address } }
                    }
                    .fixedSize()
                    .accessibilityLabel("Addresses seen in the last pull's sign-ins, flagged ones first")
                }
            }
            DisclosureGroup("Logs: \(ActivityLogs.Application.allCases.filter(chosen.contains).map(\.name).joined(separator: ", "))") {
                HStack {
                    Button("All") { form.chosen = Set(ActivityLogs.Application.allCases) }
                        .accessibilityLabel("Pick every log")
                    Button("Recommended") { form.chosen = Set(ActivityLogs.incidentDefault) }
                        .accessibilityLabel("Pick the recommended logs")
                    Button("None") { form.chosen = [] }
                        .accessibilityLabel("Pick no logs")
                }
                ForEach(ActivityLogs.Application.allCases, id: \.self) { application in
                    Toggle(isOn: pick(application)) {
                        Text(application.name)
                        Text(application.about)
                    }
                    .accessibilityLabel("Read the \(application.name) log")
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor) }
            HStack {
                Toggle("Only what Google flagged", isOn: $form.flaggedOnly)
                Spacer()
                if logs.isPulling { ProgressView().controlSize(.small) }
                Button("Pull Incident Logs") {
                    let query = IncidentLogs.Query(applications: ActivityLogs.Application.allCases.filter(chosen.contains), users: typedAccounts,
                                                   hours: hours, ip: ip.trimmingCharacters(in: .whitespaces))
                    filter = nil
                    let logs = logs
                    Task { await logs.pull(query) }
                }
                .disabled(problem != nil || logs.isPulling)
                .help("Read each log picked, for these accounts and that address. Nothing changes.")
            }
            if let exported {
                Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
            if let pull = logs.pull {
                HStack {
                    Text(Self.describe(pull.query) + (pull.ended ? "" : " Reading…")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export All…") { exportAll(pull) }
                        .disabled(!pull.ended || !pull.logs.contains { (try? $0.rows.get()) != nil })
                        .help("Save every log that was read as CSV files in a new folder, with a note of what was pulled")
                        .accessibilityLabel("Export every log as CSV files into a new folder")
                }
                if let filter {
                    let shown = pull.logs.compactMap(filter.applied)
                    HStack(alignment: .firstTextBaseline) {
                        Label("Showing only \(filter.words).", systemImage: "line.3.horizontal.decrease.circle")
                            .textSelection(.enabled)
                        Spacer()
                        Button("Show All") { self.filter = nil }
                            .accessibilityHint("Shows every event of every log again.")
                    }
                    if shown.isEmpty { Text("None of the logs shown has these events.").foregroundStyle(.secondary) }
                    // Each log's Export CSV saves just these events: the evidence for what the to-do item was about.
                    ForEach(shown) { log in
                        LogGroup(log: log, asked: pull.query.hours, flaggedOnly: flaggedOnly, startsOpen: true) { export(log, of: pull.query) }
                    }
                } else {
                    if !pull.ended {
                        // Where each log is, after every read: a busy log takes a dozen reads a day, oldest day first.
                        ForEach(pull.query.applications, id: \.self) { application in
                            if let progress = logs.progress[application] {
                                Label(Self.words(application, progress), systemImage: Self.symbol(progress))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(pull.logs) { log in
                        LogGroup(log: log, asked: pull.query.hours, flaggedOnly: flaggedOnly, startsOpen: log.application == .login,
                                 readRest: log.through.map { through in {
                                     readMore(IncidentLogs.Query(applications: [log.application], users: pull.query.users, hours: pull.query.hours,
                                                                 ip: pull.query.ip, from: through, to: .now))
                                 } }) {
                            export(log, of: pull.query)
                        }
                    }
                    // Each step after the pull, under the logs: then Read the logs below says it's reading them.
                    if logs.isKeeping { step("Saving this pull to the incident, and putting it together with what the incident holds…") }
                }
            }
            if readingSaved { step("Reading the incident's saved logs…") }
        } header: {
            Text("1. Find who's affected: pull the incident logs").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("From Google's audit logs, which can lag by up to a few hours. The phish may have reached others: filter every "
                 + "log by the attacker's address to find each account they reached. Failed sign-ins from it show who typed "
                 + "their password into the fake page.")
        }
        .onChange(of: person, initial: true) { _, person in
            if let person, accounts.isEmpty { form.accounts = person }
        }
    }

    /// "Gmail: reading, 12,345 events so far in 37 reads, whole through 14 Oct 2026 at 9:05 AM".
    static func words(_ application: ActivityLogs.Application, _ progress: IncidentLogs.Progress) -> String {
        let events = "\(progress.events.formatted()) event\(progress.events == 1 ? "" : "s")"
        switch progress.state {
        case .waiting: return "\(application.name): waiting its turn"
        case .reading where progress.reads == 0: return "\(application.name): reading…"
        case .reading:
            return "\(application.name): reading, \(events) so far in \(progress.reads) read\(progress.reads == 1 ? "" : "s")"
                + (progress.through.map { ", whole through \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                + (progress.estimate.map { ". " + estimateWords($0) } ?? "")
        case .done: return progress.failed ? "\(application.name): couldn't be read" : "\(application.name): done, \(events)"
        }
    }

    /// "About 9,000 events an hour: it will read the oldest 22 hours of the 30 days whole, in about 200 reads (about 7
    /// minutes), then stop. Narrow it (an account, or the attacker's address) to read it all."
    static func estimateWords(_ estimate: IncidentLogs.Estimate) -> String {
        let rate = "About \(estimate.perHour.formatted()) events an hour"
        if estimate.tooBusy {
            return rate + ": too busy to read even its first day whole within the bounds. Narrow it (an account, or the attacker's "
                + "address) to read it."
        }
        let minutes = max(1, (estimate.seconds + 59) / 60)
        let time = "in about \(estimate.reads.formatted()) read\(estimate.reads == 1 ? "" : "s") (about \(minutes) minute\(minutes == 1 ? "" : "s"))"
        if estimate.whole { return rate + ": it will read all \(window(estimate.windowHours)) whole, \(time)." }
        return rate + ": it will read the oldest \(window(estimate.hours)) of the \(window(estimate.windowHours)) whole, \(time), then stop. "
            + "Narrow it (an account, or the attacker's address) to read it all."
    }

    static func symbol(_ progress: IncidentLogs.Progress) -> String {
        switch progress.state {
        case .waiting: "hourglass"
        case .reading: "arrow.down.circle"
        case .done: progress.failed ? "exclamationmark.triangle" : "checkmark.circle"
        }
    }

    /// A step under way after a pull, said where the logs are.
    private func step(_ words: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(words).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words)
    }

    private func pick(_ application: ActivityLogs.Application) -> Binding<Bool> {
        Binding(get: { chosen.contains(application) }, set: { if $0 { form.chosen.insert(application) } else { form.chosen.remove(application) } })
    }

    static func window(_ hours: Int) -> String { IncidentLogs.window(hours) }

    static func describe(_ query: IncidentLogs.Query) -> String {
        (query.from.map { "From \($0.formatted(date: .abbreviated, time: .shortened)) to "
            + "\((query.to ?? .now).formatted(date: .abbreviated, time: .shortened)), " } ?? "Over the last \(window(query.hours)), ")
            + (query.users.isEmpty ? "every account" : query.users.joined(separator: ", "))
            + (query.ip.isEmpty ? "" : ", from \(query.ip)") + ", newest first."
    }

    /// The log as a CSV in the one shape, to a file the operator picks: private (0600), whole or not at all.
    private func export(_ log: IncidentLogs.Log, of query: IncidentLogs.Query) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(log.application.rawValue)-log.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "The \(log.application.name) log. " + Self.describe(query)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            // Made and written off the main thread: a whole log is hundreds of thousands of rows (failure log 2026-10-23).
            Task {
                do {
                    try await Task.detached { try AuditExport.writePrivately(IncidentLogs.csv(log), to: destination) }.value
                    say("Exported the \(log.application.name) log to \(destination.lastPathComponent).", failed: false)
                } catch {
                    say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// Every log that was read, into a new private folder in the folder the operator picks (`IncidentLogs.exportAll`).
    private func exportAll(_ pull: IncidentLogs.Pull) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "A new folder of every log that was read goes here. " + Self.describe(pull.query)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let parent = panel.url else { return }
            // Off the main thread, as each log's Export CSV is.
            Task {
                do {
                    let exported = try await Task.detached { try IncidentLogs.exportAll(pull, into: parent) }.value
                    let skipped = exported.unread.isEmpty ? ""
                        : " Not read, so not exported: " + exported.unread.map(\.name).joined(separator: ", ") + "."
                    say("Exported \(exported.written.count) logs to “\(exported.folder.lastPathComponent)”.\(skipped)", failed: !exported.unread.isEmpty)
                } catch {
                    say("Couldn't export to \(parent.lastPathComponent): \(error.localizedDescription). Nothing was left there.", failed: true)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func say(_ text: String, failed: Bool) {
        exported = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }
}

/// The pull's form (Pull Incident Logs), kept by the screen across its tabs.
struct PullForm: Equatable {
    var hours = ActivityLogs.defaultHours
    var accounts = ""
    var ip = ""
    var chosen = Set(ActivityLogs.incidentDefault)
    var flaggedOnly = false
}

/// One log of a pull: its name, how many events and how many flagged, the table, and Export CSV.
private struct LogGroup: View {
    let log: IncidentLogs.Log
    let asked: Int
    let flaggedOnly: Bool
    /// Reads the rest of a log that stopped at its bound, from where it stopped to now.
    let readRest: (() -> Void)?
    let export: () -> Void
    @State private var open: Bool

    init(log: IncidentLogs.Log, asked: Int, flaggedOnly: Bool, startsOpen: Bool, readRest: (() -> Void)? = nil, export: @escaping () -> Void) {
        self.log = log
        self.asked = asked
        self.flaggedOnly = flaggedOnly
        self.readRest = readRest
        self.export = export
        _open = State(initialValue: startsOpen)
    }

    private var title: String {
        switch log.rows {
        case .failure: return "\(log.application.name): couldn't be read"
        case .success(let rows):
            // Counted once as the log was made (a big log's took a tenth of a second at every redraw).
            let flagged = log.flagged, people = log.accounts
            return "\(log.application.name): \(rows.count) event\(rows.count == 1 ? "" : "s")"
                + (flagged > 0 ? ", \(flagged) flagged" : "") + (rows.isEmpty ? "" : ", \(people) account\(people == 1 ? "" : "s")")
                + (log.hours < asked ? " (the last \(IncidentLogsSection.window(log.hours)): the most the Gmail log reads)" : "")
        }
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $open) {
            if let through = log.through {
                // Read oldest first and stopped at its bound: the older part is whole, the newer part unread.
                HStack(alignment: .firstTextBaseline) {
                    Label("Read completely through \(through.formatted(date: .abbreviated, time: .shortened)): the later events "
                          + "weren't read yet, and the CSV doesn't have them either.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor).font(.callout)
                    Spacer()
                    if let readRest {
                        Button("Read the Rest", action: readRest)
                            .accessibilityHint("Reads this log from there to now, oldest first, and adds it to what's shown. Nothing changes.")
                    }
                }
            }
            ActivityList(result: log.rows.map { flaggedOnly ? $0.filter(\.flagged) : $0 }, capped: log.capped && log.through == nil,
                         what: "\(log.application.name) events", showsWho: true)
            if case .success(let rows) = log.rows, !rows.isEmpty {
                HStack {
                    Spacer()
                    Button("Export CSV…", action: export)
                        .help("Save this log's events as a CSV file")
                        .accessibilityLabel("Export the \(log.application.name) log as a CSV file")
                }
            }
        }
    }
}

/// A log's events as rows: when, who, what in words with Google's flag said, the IP address, and what else it says.
/// At most `shown` rows, and the rest counted.
private struct ActivityList: View {
    let result: Result<[ActivityLogs.Row], UserAccess.Problem>
    let capped: Bool
    let what: String
    let showsWho: Bool
    private let shown = 300

    var body: some View {
        switch result {
        case .failure(let problem):
            Label("Couldn't read the \(what): \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).textSelection(.enabled)
        case .success(let rows) where rows.isEmpty:
            Text("None.").foregroundStyle(.secondary)
        case .success(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("When")
                    if showsWho { Text("Who") }
                    Text("What")
                    Text("IP address")
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
                ForEach(rows.prefix(shown)) { row in
                    let when = row.date?.formatted(date: .abbreviated, time: .shortened) ?? row.time
                    GridRow {
                        Text(when)
                        if showsWho { Text(row.who) }
                        VStack(alignment: .leading, spacing: 2) {
                            if row.flagged {
                                Label(row.words + " · flagged", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                            } else {
                                Text(row.words)
                            }
                            if !row.details.isEmpty {
                                Text(row.details.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text(row.ip.isEmpty ? "—" : row.ip)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([when, showsWho ? row.who : nil, row.words, row.flagged ? "flagged by Google" : nil,
                                         row.details.isEmpty ? nil : row.details.joined(separator: ", "),
                                         row.ip.isEmpty ? nil : "from \(row.ip)"].compactMap(\.self).joined(separator: ", "))
                }
            }
            if rows.count > shown {
                Text("Showing the newest \(shown) of \(rows.count). Export the CSV for all of them, or narrow the window or the address.")
                    .font(.callout)
            }
            if capped {
                // A log reads further back until it's whole (IncidentLogs.paged), within a bound: past it, the rest is unread.
                Label("Not all of the window was read: older \(what) weren't, and the CSV doesn't have them either. Narrow the "
                      + "window, or pull just the accounts that matter.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
        }
    }
}

/// The directory as Who it reached reads it: each person's addresses (their own, their aliases, and the domain aliases Google
/// adds, `nonEditableAliases`, which GAM returns with the aliases asked for) to their own, a person's own address never taken
/// by another's alias; and every domain those are at, with the connected one. Built once a snapshot (`DirectoryStore.revision`),
/// never at every redraw (review 2026-10-24); nil people until the directory is read.
@MainActor
final class DirectoryIndex {
    /// The directory as Who it reached and the report read it.
    struct Index {
        let key: String
        let people: [String: String]?
        let domains: Set<String>
        /// The people Reports lists without 2-Step Verification (active, not enrolled), lowercased; nil until the directory is read.
        let no2SV: Set<String>?
    }

    private var built: (revision: String, key: String, people: [String: String]?, domains: Set<String>, no2SV: Set<String>?)?

    func index(_ directory: DirectoryStore, domain: String) -> Index {
        let revision = "\(domain.lowercased())|\(directory.revision.map(String.init) ?? "-")"
        if let built, built.revision == revision { return Index(key: built.key, people: built.people, domains: built.domains, no2SV: built.no2SV) }
        var people: [String: String]?
        if let users = directory.users {
            var map: [String: String] = [:]
            for user in users { map[user.primaryEmail.lowercased()] = user.primaryEmail.lowercased() }
            for user in users {
                let aliases = user.aliases + (user.record["nonEditableAliases"]?.array ?? []).compactMap(\.string)
                for alias in aliases where map[alias.lowercased()] == nil { map[alias.lowercased()] = user.primaryEmail.lowercased() }
            }
            people = map
        }
        let domains = Set(((people.map { Array($0.keys) } ?? []) + ["@" + domain])
            .compactMap { $0.split(separator: "@").last.map { String($0).lowercased() } }.filter { !$0.isEmpty })
        // A revision that changes nothing read here keeps its key: a password reset or a suspension elsewhere re-reads no pull
        // (final review 2026-10-25).
        let key = built.flatMap { $0.people == people && $0.domains == domains ? $0.key : nil } ?? revision
        let no2SV = directory.reports?.first { $0.key == "no_2sv" }.map { Set($0.users.map { $0.primaryEmail.lowercased() }) }
        built = (revision, key, people, domains, no2SV)
        return Index(key: key, people: people, domains: domains, no2SV: no2SV)
    }
}
