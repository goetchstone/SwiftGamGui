import AppKit
import Directory
import GamEngine
import Stores
import SwiftUI
import UniformTypeIdentifiers

/// Hires from a CSV (GamGUI's Bulk onboarding, roadmap 2.3), as a sheet from Onboard: save the template, choose a filled-in
/// CSV, review every hire it holds and every row it leaves out, then run them once, with Stop. Accounts created without a
/// `notify` address get a sign-in card here, held fifteen minutes or until Done. The file is read into memory and never kept.
struct HiresFromCSVSheet: View {
    let model: HiresFromCSV
    let roles: OnboardRoles
    let templates: SignatureTemplates
    let close: () -> Void
    @State private var stopAsked = false
    /// Files lists the template once it's saved (plan F4).
    @Environment(SavedFiles.self) private var savedFiles: SavedFiles?
    @State private var choosing = false
    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        Form {
            switch model.state {
            case .previewing(let pending):
                HiresFromCSVReview(pending: pending, model: model)
            case .running(let pending):
                running(pending)
            case .done(let done):
                result(done)
            case .idle, .problem:
                start
            }
            HireCredentialCards(model: model)
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
        .toolbar { toolbar }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            read(url)
        }
        .confirmationDialog("Stop after this step?", isPresented: $stopAsked) {
            Button("Stop After This Step") { Task { await model.stop() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The step running now finishes. The rest aren't run, and what's done stays done.")
        }
    }

    // MARK: choosing a file

    @ViewBuilder
    private var start: some View {
        Section {
            Text("One row a hire: a role (from Role templates), and an email or an assignee. With create_account yes, the account "
                 + "is made too; its sign-in goes to the row's notify address, or onto a card here.")
            HStack {
                Button("Save the Template\u{2026}") { saveTemplate() }
                    .accessibilityHint("Saves an example CSV with every column, to fill in.")
                Button("Choose a CSV\u{2026}") { choosing = true }
                    .accessibilityHint("Reads the file and shows every hire before anything changes.")
            }
        } header: {
            Text("Onboard hires from a CSV").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Columns: role, name, email, manager, assignee, create_account, first, last, send_welcome, notify. Up to 1 MB, "
                 + "UTF-8 (Excel's CSV UTF-8). The file is read once and not kept.")
        }
        if case .problem(let why, let errors) = model.state {
            Section {
                Label(why, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .accessibilityFocused($resultFocused)
                ForEach(errors, id: \.self) { Text($0).font(.callout) }
            }
            .onAppear { resultFocused = true }
        }
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let bytes = [UInt8]((try? handle.read(upToCount: HireCSV.maxBytes + 1)) ?? Data())
        let roles = roles, templates = templates
        Task {
            await model.preview(bytes, roles: HiresFromCSV.Roles(
                role: { roles.role(named: $0) }, signature: { templates.body($0) }, welcome: { roles.welcome(named: $0) }))
        }
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "onboard_template.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard (try? Data(HireCSV.template.utf8).write(to: url, options: .atomic)) != nil else { return }
        savedFiles?.record(url, what: "Hires CSV template")
    }

    // MARK: the run

    @ViewBuilder
    private func running(_ pending: HiresFromCSV.Pending) -> some View {
        let progress = model.progress ?? HiresFromCSV.Progress(total: pending.hires.count, steps: pending.preview.steps.count)
        Section {
            if progress.waitingUntil != nil {
                Text("Waiting for Google to finish setting up the new accounts, then trying what it wasn't ready for again\u{2026}")
            } else {
                Text(progress.stopping ? "Stopping after this step\u{2026}" : "Onboarding\u{2026}")
            }
            ProgressView(value: Double(progress.stepsDone), total: Double(max(progress.steps, 1)))
                .accessibilityLabel("Steps done")
                .accessibilityValue("\(progress.stepsDone) of \(progress.steps)")
            Button("Stop\u{2026}") { stopAsked = true }
                .disabled(progress.stopping)
                .accessibilityLabel("Stop onboarding")
        } header: {
            Text(pending.preview.title).accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func result(_ done: HiresFromCSV.Done) -> some View {
        Section {
            Label(done.message, systemImage: done.hires.allSatisfy(\.ok) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityFocused($resultFocused)
            ForEach(Array(done.hires.enumerated()), id: \.offset) { _, hire in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hire.name)
                    Text(hire.outcome).font(.callout).foregroundStyle(hire.ok ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Anything not done can be done from the person's page on Users, or by onboarding that hire again from Onboard.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { resultFocused = true }
    }

    // MARK: buttons

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isReviewing ? "Back" : isFinished ? "Done" : "Cancel") {
                let back = isReviewing
                model.dismiss()
                if !back { close() }
            }
            // The cards' own Done drops each password; the sheet stays until then.
            .disabled(model.isBusy || !model.credentials.isEmpty)
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
