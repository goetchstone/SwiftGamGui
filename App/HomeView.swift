import ChangeCore
import Directory
import GamEngine
import Jobs
import Setup
import SwiftUI

/// Home: the connection, the bundled GAM, the directory's counts, the newest runs and the last few failed changes. It makes no
/// Google call of its own: the counts come from `DirectoryStore`, loaded on a click (GamGUI's Home, plan U4).
struct HomeView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let gamVersion: String?
    let hasGam: Bool
    let executor: Executor?
    let auditURL: URL
    let jobs: JobBoard
    /// Opens Audit on its failures.
    let openFailures: () -> Void
    let openSetup: () -> Void
    /// Writes that began and never ended (the app quit or crashed mid-call), read from the audit log.
    @State private var unfinished: [Executor.Unfinished] = []
    @State private var acknowledgeProblem: String?
    /// The last few failed changes, from the audit log; nil until read.
    @State private var failures: [AuditEntry]?

    var body: some View {
        Form {
            if !unfinished.isEmpty {
                Section("Outcome unknown — check") {
                    Text("GamGUI stopped while \(unfinished.count == 1 ? "this change was" : "these changes were") running. Check each in Google before running it again.")
                    ForEach(Array(unfinished.enumerated()), id: \.offset) { _, write in
                        Label("\(write.actionName) for \(write.target), started \(write.at)", systemImage: "questionmark.circle")
                        // Onboarding's create (design D4): its one-time password was never shown.
                        if write.action == WriteAction.createUser.rawValue {
                            Text("If the account exists, its temporary password was never shown: set a new one in the Google Admin console.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Mark as Checked") { Task { await acknowledge() } }
                        .accessibilityHint("Records that you checked these changes in Google, so they stop showing here.")
                    if let acknowledgeProblem {
                        Label(acknowledgeProblem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            Section("Connection") {
                connection
                LabeledContent("GAM") {
                    if let gamVersion {
                        Text(gamVersion == GamVersion.expected ? gamVersion : "\(gamVersion), expected \(GamVersion.expected)")
                    } else {
                        Text(hasGam ? "Checking…" : "Not found: build the app again after running scripts/fetch_gam.sh")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Directory") {
                directorySection
            }
            Section("Jobs") {
                // Its own view: a step of a run redraws the list, not all of Home.
                HomeJobs(board: jobs)
            }
            Section("Recent failures") {
                recentFailures
            }
        }
        .formStyle(.grouped)
        .task { await loadUnfinished() }
        // Read again when a run ends: by the board's counter, so a step reads nothing.
        .task(id: jobs.finishedCount) { await loadFailures() }
    }

    @ViewBuilder private var recentFailures: some View {
        if let failures {
            if failures.isEmpty {
                Text("No failed changes in the last 30 days. Older ones are in Audit.").foregroundStyle(.secondary)
            }
            ForEach(failures) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.actionName + (entry.target.isEmpty ? "" : " for \(entry.target)"), systemImage: "xmark.circle")
                    Text(entry.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? entry.time)
                        .font(.callout).foregroundStyle(.secondary)
                    if !entry.summary.isEmpty {
                        Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button(failures.isEmpty ? "Open Audit's Failures" : "All Failures in Audit", action: openFailures)
                .accessibilityHint("Opens Audit, narrowed to the changes that failed.")
        } else {
            HStack { ProgressView().controlSize(.small); Text("Reading the audit log…") }
                .accessibilityElement(children: .combine)
        }
    }

    /// The audit log can hold a million records: read it off the main actor.
    private func loadFailures() async {
        let url = auditURL
        failures = await Task.detached(priority: .utility) { AuditEntry.recentFailures(in: url) }.value
    }

    /// The audit log can hold a million records: read it off the main actor.
    private func loadUnfinished() async {
        let url = auditURL
        unfinished = await Task.detached(priority: .utility) { Executor.unfinished(in: url) }.value
    }

    private func acknowledge() async {
        do {
            let url = auditURL, checked = unfinished
            try await Task.detached { try Executor.acknowledge(checked, in: url) }.value
            acknowledgeProblem = nil
        } catch {
            acknowledgeProblem = "The audit log couldn't be written: \(error.localizedDescription)"
        }
        await loadUnfinished()
    }

    @ViewBuilder private var connection: some View {
        if let domain = setup.active {
            LabeledContent("Domain") {
                switch setup.status(of: domain) {
                case .connectedButLastCheckFailed:
                    Label("\(domain.name): the last check failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                default:
                    Label(domain.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        } else if let domain = setup.reconnecting {
            // Touch ID, then a real check: it can take a few seconds, and must not look disconnected.
            LabeledContent("Domain") {
                HStack { ProgressView().controlSize(.small); Text("Connecting to \(domain.name)…") }
            }
            .accessibilityElement(children: .combine)
        } else if let failure = setup.reconnectFailure {
            LabeledContent("Domain") {
                Label("Couldn't reconnect to \(failure.domain.name)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(failure.problem).foregroundStyle(.secondary)
            HStack {
                Button("Try Again") { Task { await setup.reconnect() } }
                    .disabled(setup.isBusy)
                Button("Open Setup…", action: openSetup)
            }
        } else {
            LabeledContent("Domain") {
                Button("Connect on Setup…", action: openSetup)
            }
        }
    }

    @ViewBuilder private var directorySection: some View {
        if let users = directory.users {
            LabeledContent("Accounts", value: users.count.formatted())
            ForEach(directory.reports ?? []) { report in
                // The description is shown, not only a tooltip: a count means little without it.
                LabeledContent {
                    Text(report.count.formatted())
                } label: {
                    Text(report.title)
                    Text(report.description)
                }
            }
            LabeledContent("As of") {
                HStack {
                    Text(directory.loadedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    Button("Refresh") { Task { await directory.load() } }
                        .keyboardShortcut("r")
                        .disabled(directory.isLoading)
                        .accessibilityIdentifier("home.refresh")
                }
            }
        } else if directory.isLoading {
            HStack { ProgressView().controlSize(.small); Text("Loading the directory…") }
                .accessibilityElement(children: .combine)
        } else if setup.active != nil {
            LabeledContent("Not loaded yet. It loads when a domain connects, or now:") {
                Button("Load the Directory") { Task { await directory.load() } }
                    .keyboardShortcut("r")
                    .accessibilityIdentifier("home.load")
            }
        } else if setup.reconnecting != nil {
            Text("Loads once connected.").foregroundStyle(.secondary)
        } else {
            Text("Connect a domain on Setup to see its counts.").foregroundStyle(.secondary)
        }
        if directory.isLoading, directory.users != nil {
            HStack { ProgressView().controlSize(.small); Text("Refreshing…") }
                .accessibilityElement(children: .combine)
        }
        if let problem = directory.problem {
            Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            if let detail = problem.detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

/// Home's Jobs card (GamGUI's): the newest few runs since launch, running first, each with where it stands. The tray in the toolbar
/// has each one's steps, its failures and Stop.
private struct HomeJobs: View {
    let board: JobBoard
    private static let shown = 4

    var body: some View {
        let tray = board.tray
        if tray.rows.isEmpty {
            Text("Nothing has run since GAM GUI started.").foregroundStyle(.secondary)
        } else {
            ForEach(tray.rows.prefix(Self.shown)) { job in
                LabeledContent(job.title, value: job.status)
                    .accessibilityElement(children: .combine)
            }
            let more = tray.more + max(0, tray.rows.count - Self.shown)
            Text((more > 0 ? "And \(more) more. " : "") + "Jobs in the toolbar has each one's steps, its failures and Stop.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
