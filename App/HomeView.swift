import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI

/// Home: the connection, the bundled GAM, and the directory's counts. It makes no Google call of its
/// own: the counts come from `DirectoryStore`, loaded on a click (GamGUI's Home, plan U4).
struct HomeView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let gamVersion: String?
    let hasGam: Bool
    let executor: Executor?
    let auditURL: URL
    let openSetup: () -> Void
    /// Writes that began and never ended (the app quit or crashed mid-call), read from the audit log.
    @State private var unfinished: [Executor.Unfinished] = []
    @State private var acknowledgeProblem: String?

    var body: some View {
        Form {
            if !unfinished.isEmpty {
                Section("Outcome unknown — check") {
                    Text("GamGUI stopped while \(unfinished.count == 1 ? "this change was" : "these changes were") running. Check each in Google before running it again.")
                    ForEach(Array(unfinished.enumerated()), id: \.offset) { _, write in
                        Label("\(write.actionName) for \(write.target), started \(write.at)", systemImage: "questionmark.circle")
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
        }
        .formStyle(.grouped)
        .task { await loadUnfinished() }
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
        } else if setup.active != nil {
            LabeledContent("Not loaded yet. It loads when a domain connects, or now:") {
                Button("Load the Directory") { Task { await directory.load() } }
                    .keyboardShortcut("r")
                    .disabled(directory.isLoading)
                    .accessibilityIdentifier("home.load")
            }
        } else {
            Text("Connect a domain on Setup to see its counts.").foregroundStyle(.secondary)
        }
        if directory.isLoading {
            HStack { ProgressView().controlSize(.small); Text("Loading the directory…") }
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
