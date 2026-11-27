import Directory
import GamEngine
import SwiftUI

/// A department for many (GamGUI's Bulk department page, roadmap 2.1), as a sheet from Users: a department, then a group's
/// active members or pasted addresses. Preview lists exactly who; Confirm runs that list once, one person at a time, in the
/// jobs tray and here with Stop; a run with failures offers "Retry the N That Failed…", which previews exactly those again.
/// Each person's title is kept.
struct DepartmentForManySheet: View {
    let model: DepartmentForMany
    let groups: GroupStore
    let close: () -> Void
    @State private var department = ""
    @State private var byGroup = true
    @State private var group = ""
    @State private var pasted = ""
    @State private var stopAsked = false
    @AccessibilityFocusState private var resultFocused: Bool

    private var who: DepartmentForMany.Who { byGroup ? .group(group) : .pasted(pasted) }

    var body: some View {
        Form {
            switch model.state {
            case .previewing(let pending):
                DepartmentForManyReview(pending: pending, model: model)
            case .running(let pending):
                running(pending)
            case .done(let done):
                result(done)
            case .idle, .checking, .problem:
                form
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .task {
            if groups.groups == nil, !groups.isLoading { await groups.load() }
            await fillForSnapshot()
        }
        .onChange(of: department) { model.dismiss() }
        .onChange(of: group) { model.dismiss() }
        .onChange(of: pasted) { model.dismiss() }
        .onChange(of: byGroup) { model.dismiss() }
        .toolbar { toolbar }
        .confirmationDialog("Stop after this person?", isPresented: $stopAsked) {
            Button("Stop After This Person") { Task { await model.stop() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The department being set now finishes. The rest aren't changed, and the ones already set stay set.")
        }
    }

    // MARK: the form

    @ViewBuilder
    private var form: some View {
        Section {
            TextField("Department", text: $department, prompt: Text(verbatim: "Sales"))
                .accessibilityHint("The department every person below gets. Each keeps their title.")
        } header: {
            Text("Set a department for many people").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Each person keeps their title: Google sets title and department together, so each one's title is sent as it is.")
        }
        Section("Who") {
            Picker("Who", selection: $byGroup) {
                Text("A group's members").tag(true)
                Text("Addresses I paste").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Who")
            if byGroup {
                let listed = groups.groups ?? []
                Picker("Group", selection: $group) {
                    Text("Choose a group\u{2026}").tag("")
                    ForEach(listed) { group in
                        Text(group.name.isEmpty || group.name == group.email ? group.email : "\(group.name) \u{2014} \(group.email)")
                            .tag(group.email)
                    }
                }
                .disabled(groups.groups == nil)
                if groups.groups == nil, groups.isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Loading the groups\u{2026}") }
                        .accessibilityElement(children: .combine)
                } else if let problem = groups.problem, groups.groups == nil {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill")
                }
                Text("Its members with an active account, read when you preview. A group inside it, and suspended accounts, are left out.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextEditor(text: $pasted)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .accessibilityLabel("Addresses, separated by commas or new lines")
                Text("Separated by commas or new lines. Anyone who isn't an active user here is left out, and the preview says how many.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        switch model.state {
        case .checking:
            Section {
                HStack { ProgressView().controlSize(.small); Text("Reading the group's members\u{2026}") }
                    .accessibilityElement(children: .combine)
            }
        case .problem(let words):
            Section {
                Label(words, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .accessibilityFocused($resultFocused)
            }
            .onAppear { resultFocused = true }
        default:
            EmptyView()
        }
    }

    // MARK: the run

    @ViewBuilder
    private func running(_ pending: DepartmentForMany.Pending) -> some View {
        let progress = model.progress ?? DepartmentForMany.Progress(total: pending.count)
        let current = progress.done < pending.count ? pending.people[progress.done].primaryEmail : nil
        Section {
            Text(progress.stopping ? "Stopping after this person\u{2026}" : "Setting the department\u{2026}")
            Text("\(progress.done) of \(progress.total) \u{B7} \(progress.applied) set"
                 + (progress.failed > 0 ? " \u{B7} \(progress.failed) failed" : "") + (current.map { " \u{B7} \($0)" } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .accessibilityLabel("Departments set")
                .accessibilityValue("\(progress.done) of \(progress.total)")
            Button("Stop\u{2026}") { stopAsked = true }
                .disabled(progress.stopping)
                .accessibilityLabel("Stop setting the department")
        } header: {
            Text(pending.preview.title).accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func result(_ done: DepartmentForMany.Done) -> some View {
        Section {
            Label(done.message, systemImage: done.partial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityFocused($resultFocused)
            if done.failedCount > 0 {
                DisclosureGroup("Failed (\(done.failedCount))") {
                    ScrollView {
                        Text(done.failures.joined(separator: "\n")
                             + (done.failedCount > done.failures.count
                                ? "\n\u{2026}and \(done.failedCount - done.failures.count) more, in the jobs tray and Audit" : ""))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            if let retry = done.retry {
                Button("Retry the \(retry.failed.count) That Failed\u{2026}") { Task { await model.previewRetry(retry) } }
                    .accessibilityHint("Shows exactly those people, with the same department, before anything changes.")
            }
        }
        .onAppear { resultFocused = true }
    }

    // MARK: buttons

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // From the review, Cancel goes back to the form; otherwise it closes the sheet.
            Button(isFinished ? "Done" : isReviewing ? "Back" : "Cancel") {
                let back = isReviewing
                model.dismiss()
                if !back { close() }
            }
            .disabled(model.isBusy)
        }
        // Not the confirmation action while reviewing: Return in a field mustn't change anyone.
        ToolbarItem(placement: .primaryAction) {
            switch model.state {
            case .previewing, .running:
                EmptyView()
            default:
                Button("Preview") { Task { await model.preview(department: department, who: who) } }
                    .disabled(model.isBusy || department.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Debug builds: `SWIFTGAMGUI_TAB=department-review` previews Sales for three of the mock's people, for the snapshot of the
    /// review (held, never run; a pasted list reads nothing).
    private func fillForSnapshot() async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"] == "department-review", case .idle = model.state else { return }
        department = "Sales"
        byGroup = false
        pasted = "alice@example.com\ncarol@example.com\ndana@example.com\nnobody@example.com"
        // After the fields' own changes have settled: each drops a preview.
        try? await Task.sleep(for: .milliseconds(300))
        await model.preview(department: department, who: who)
        #endif
    }

    private var isReviewing: Bool {
        if case .previewing = model.state { return true }
        return false
    }

    private var isFinished: Bool {
        if case .done = model.state { return true }
        return false
    }
}
