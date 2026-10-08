import GamEngine
import Setup
import SwiftUI
import UniformTypeIdentifiers
import Vault

/// Setup: the domains on this Mac, adding one (from a GAM folder or from GamGUI), Check access, and
/// removal. All logic lives in `SetupModel`; this only renders it and calls it.
struct SetupView: View {
    let model: SetupModel
    @State private var pickedFolder: URL?
    /// The picked folder when macOS granted it a security scope, to release on the next pick.
    @State private var scopedFolder: URL?
    @State private var domainText = ""
    /// What the field was last filled with from a folder, so the next pick may replace it.
    @State private var suggestedDomain: String?
    @State private var adminText = ""
    @State private var choosingFolder = false
    @State private var pendingRemoval: Domain?

    private var busy: Bool { model.isBusy }

    var body: some View {
        Form {
            Section("Domains on this Mac") {
                if model.domains.isEmpty {
                    Text("None yet. Add one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.domains, id: \.self) { domain in
                        domainRow(domain)
                    }
                    TextField("Admin address", text: $adminText,
                              prompt: Text("only needed if oauth2.txt names none"))
                        .accessibilityIdentifier("setup.admin")
                }
            }

            if let record = model.lastCheck {
                Section("Check access: \(record.domain.name)") {
                    CheckResultView(record: record)
                }
            }

            Section("Add a domain") {
                LabeledContent("From a GAM config folder") {
                    Button("Choose Folder…") { choosingFolder = true }
                        .accessibilityIdentifier("setup.chooseFolder")
                }
                if let folder = pickedFolder {
                    LabeledContent("Folder", value: folder.path(percentEncoded: false))
                    TextField("Domain", text: $domainText, prompt: Text("example.com"))
                        .accessibilityIdentifier("setup.domain")
                    Button("Import Credentials") {
                        Task { await model.importFolder(folder, as: domainText) }
                    }
                    .disabled(busy || domainText.isEmpty)
                    .accessibilityIdentifier("setup.import")
                }
                LabeledContent("From GamGUI (the Python app)") {
                    Button("Look for GamGUI's Domains") { Task { await model.lookForGamGUI() } }
                        .disabled(busy)
                        .accessibilityIdentifier("setup.lookForGamGUI")
                }
                if let entries = model.gamguiEntries {
                    ForEach(entries, id: \.spelling) { entry in
                        LabeledContent(entry.spelling) {
                            Button("Copy \(entry.spelling)") { Task { await model.copy(entry) } }
                                .disabled(busy)
                                .accessibilityIdentifier("setup.copy.\(entry.spelling)")
                        }
                    }
                }
            }

            Section {
                ActivityLine(activity: model.activity)
            }

            Section("Domain-wide delegation") {
                DisclosureGroup("Scopes to authorize in the Admin console") {
                    ForEach(DelegationScopes.all, id: \.scope) { item in
                        LabeledContent(item.purpose) {
                            Text(item.scope).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            pick(url)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "")'s credentials from this Mac?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { domain in
            Button("Remove \(domain.name)", role: .destructive) { Task { await model.remove(domain) } }
                .disabled(busy)
        } message: { _ in
            Text("GamGUI and your Google tenant aren't changed. You can import the credentials again later.")
        }
        .task { await model.refresh() }
    }

    /// A domain the field shows only because an earlier folder suggested it goes with that folder; one
    /// the operator typed stays. The new folder's suggestion fills the field only if it's still the
    /// picked folder when its read finishes (a slow read of an earlier pick must not land late).
    private func pick(_ url: URL) {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
        pickedFolder = url
        if domainText == suggestedDomain {
            domainText = ""
            suggestedDomain = nil
        }
        Task {
            guard let suggestion = await model.suggestedDomain(for: url),
                  pickedFolder == url, domainText.isEmpty
            else { return }
            domainText = suggestion
            suggestedDomain = suggestion
        }
    }

    private func domainRow(_ domain: Domain) -> some View {
        LabeledContent {
            HStack {
                Button("Check Access") { Task { await model.checkAccess(domain, typedAdmin: adminText) } }
                    .disabled(busy)
                    .accessibilityIdentifier("setup.check.\(domain.name)")
                Button("Remove…", role: .destructive) { pendingRemoval = domain }
                    .disabled(busy)
                    .accessibilityIdentifier("setup.remove.\(domain.name)")
            }
        } label: {
            HStack(spacing: 6) {
                Text(domain.name)
                switch model.status(of: domain) {
                case .notConnected:
                    EmptyView()
                case .connected:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                case .connectedButLastCheckFailed:
                    Label("Connected, but the last check failed", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }
}

private struct CheckResultView: View {
    let record: SetupModel.CheckRecord

    var body: some View {
        let failed = record.result.rows.filter { !$0.passed }
        let passed = record.result.rows.count - failed.count
        Text(SetupModel.summary(of: record.result))
        // What to do first: the link, then what failed. Passes are only counted.
        if let url = record.result.authorizationURL {
            Link("Authorize in the Google Admin console", destination: url)
                .accessibilityIdentifier("setup.authorize")
        }
        ForEach(Array(failed.enumerated()), id: \.offset) { _, row in
            Label {
                Text(row.label).font(row.isScope ? .caption.monospaced() : .body)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        LabeledContent("Checked as", value: record.admin)
        if passed > 0 {
            Label("\(passed) of \(record.result.rows.count) checks passed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActivityLine: View {
    let activity: SetupModel.Activity

    var body: some View {
        switch activity {
        case .idle:
            Text("Ready.").foregroundStyle(.secondary)
        case .working(let text):
            HStack { ProgressView().controlSize(.small); Text(text) }
        case .done(let text):
            Label(text, systemImage: "checkmark").foregroundStyle(.secondary)
        case .problem(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
