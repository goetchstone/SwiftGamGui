import Directory
import GamEngine
import SwiftUI

/// Move many people to an org unit (GamGUI's `/users/bulk-ou`, roadmap 4.2), as a sheet from Users: a unit from the tree, then
/// a group's members or pasted addresses. Preview lists exactly who; Confirm moves that list once, one person at a time, in the
/// jobs tray and here with Stop, the count typed past 25; "Retry the N That Failed…" previews exactly those again.
struct OrgUnitForManySheet: View {
    let model: OrgUnitForMany
    let access: UserAccess
    let groups: GroupStore
    let close: () -> Void
    @State private var orgUnit = ""
    @State private var units: Result<[String], UserAccess.Problem>?
    @State private var byGroup = true
    @State private var group = ""
    @State private var pasted = ""
    @State private var stopAsked = false
    @AccessibilityFocusState private var resultFocused: Bool

    private var who: OrgUnitForMany.Who { byGroup ? .group(group) : .pasted(pasted) }

    var body: some View {
        Form {
            switch model.state {
            case .previewing(let pending):
                OrgUnitForManyReview(pending: pending, model: model)
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
            units = await access.orgUnits()
        }
        .onChange(of: orgUnit) { model.dismiss() }
        .onChange(of: group) { model.dismiss() }
        .onChange(of: pasted) { model.dismiss() }
        .onChange(of: byGroup) { model.dismiss() }
        .toolbar { toolbar }
        .confirmationDialog("Stop after this person?", isPresented: $stopAsked) {
            Button("Stop After This Person") { Task { await model.stop() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The move running now finishes. The rest aren't moved, and the ones already moved stay moved.")
        }
    }

    // MARK: the form

    @ViewBuilder
    private var form: some View {
        Section {
            switch units {
            case nil:
                HStack { ProgressView().controlSize(.small); Text("Reading the org units…") }
                    .accessibilityElement(children: .combine)
            case .failure(let problem)?:
                Label("Couldn't read the org units: \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            case .success(let paths)?:
                Picker("Move to", selection: $orgUnit) {
                    Text("Choose a unit…").tag("")
                    ForEach(paths, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: {
            Text("Move many people to an org unit").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Settings and policies follow the org unit. Suspended accounts move too: a leaver's holding unit is the usual case.")
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
                Text("Its members, read when you preview, suspended ones included. A group inside it isn't expanded, and the preview says so.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextEditor(text: $pasted)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .accessibilityLabel("Addresses, separated by commas or new lines")
                Text("Separated by commas or new lines. An address with no account here is listed and left out.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        switch model.state {
        case .checking:
            Section {
                HStack { ProgressView().controlSize(.small); Text("Reading the org units and the group\u{2026}") }
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
    private func running(_ pending: OrgUnitForMany.Pending) -> some View {
        let progress = model.progress ?? OrgUnitForMany.Progress(total: pending.count)
        let current = progress.done < pending.count ? pending.people[progress.done].primaryEmail : nil
        Section {
            Text(progress.stopping ? "Stopping after this person\u{2026}" : "Moving people\u{2026}")
            Text("\(progress.done) of \(progress.total) \u{B7} \(progress.applied) set"
                 + (progress.failed > 0 ? " \u{B7} \(progress.failed) failed" : "") + (current.map { " \u{B7} \($0)" } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .accessibilityLabel("People moved")
                .accessibilityValue("\(progress.done) of \(progress.total)")
            Button("Stop\u{2026}") { stopAsked = true }
                .disabled(progress.stopping)
                .accessibilityLabel("Stop moving people")
        } header: {
            Text(pending.preview.title).accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func result(_ done: OrgUnitForMany.Done) -> some View {
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
                    .accessibilityHint("Shows exactly those people, to the same unit, before anything changes.")
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
                Button("Preview") { Task { await model.preview(orgUnit: orgUnit, who: who) } }
                    .disabled(model.isBusy || orgUnit.isEmpty)
            }
        }
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
