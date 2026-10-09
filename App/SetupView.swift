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
    @State private var freshAdmin = ""
    @State private var freshDomain = ""

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

            Section("No GAM yet? Set it up from scratch") {
                Text("Run these in Terminal, one at a time and in order. Each opens a browser or asks a few questions. GAM writes its credentials into GamGUI's private setup folder; import them from there afterwards, and GamGUI wipes GAM's copies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Super admin address", text: $freshAdmin, prompt: Text("admin@example.com"))
                    .accessibilityIdentifier("setup.freshAdmin")
                if let fresh = model.freshSetup(admin: freshAdmin) {
                    ForEach(fresh.lines, id: \.self) { line in
                        CopyableLine(text: line)
                    }
                    TextField("Domain", text: $freshDomain, prompt: Text(SetupModel.suggestedDomain(forAdmin: freshAdmin)))
                        .accessibilityIdentifier("setup.freshDomain")
                    Button("I've Run These: Import Credentials") {
                        let domain = freshDomain.isEmpty ? SetupModel.suggestedDomain(forAdmin: freshAdmin) : freshDomain
                        Task { await model.importFromSetupFolder(as: domain) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("setup.importFresh")
                } else if let problem = model.setupFolderProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if model.setupFolderURL == nil {
                    Text("This build has no setup folder or no GAM.").foregroundStyle(.secondary)
                } else if !freshAdmin.isEmpty {
                    Text("Enter a plain address: letters, digits and . _ % + - only.").foregroundStyle(.secondary)
                }
            }

            Section {
                ActivityLine(activity: model.activity)
            }

            if let delegation = model.delegation {
                Section("Authorize domain-wide delegation: \(delegation.domain.name)") {
                    DelegationView(delegation: delegation)
                }
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
        .task {
            await model.refresh()
            await model.prepareSetupFolder()
        }
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
            // The red cross is the only sign it failed: say it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Failed: \(row.label)")
        }
        LabeledContent("Checked as", value: record.admin)
        if passed > 0 {
            Label("\(passed) of \(record.result.rows.count) checks passed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

/// GamGUI's delegation step (`_dwd.html`): the one manual step Google requires, with what to paste and
/// the pre-filled link.
private struct DelegationView: View {
    let delegation: Delegation

    var body: some View {
        Text("Authorize this service account's client ID in the Google Admin console. It's the one step Google makes you do by hand.")
            .font(.callout)
        if delegation.clientID.isEmpty {
            Text("oauth2service.json names no client ID.").foregroundStyle(.orange)
        } else {
            LabeledContent("Client ID") { CopyableLine(text: delegation.clientID) }
        }
        LabeledContent("Scopes (\(DelegationScopes.all.count))") { CopyableLine(text: Delegation.scopesText) }
        if let url = delegation.authorizationURL {
            Link("Authorize in the Google Admin console", destination: url)
                .accessibilityIdentifier("setup.delegation.authorize")
            Text("The link fills in the client ID and scopes. Sign in as a super admin, click Authorize, wait about 30 seconds, then use Check Access above.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let url = URL(string: DelegationScopes.adminConsoleURL) {
            Link("Open the Admin console's domain-wide delegation page", destination: url)
            Text("Paste the client ID and the scopes, and authorize. Then use Check Access above.")
                .font(.caption).foregroundStyle(.secondary)
        }
        switch delegation.grantsUserSecurity {
        case false?:
            Label("The admin token lacks the \"Directory API - User Security\" scope, so offboarding can't sign a leaver out. Create GAM's OAuth client again with that scope ticked, then import again.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case true?:
            Text("The admin token has the \"Directory API - User Security\" scope (offboarding's sign-out).")
                .font(.caption).foregroundStyle(.secondary)
        case nil:
            Text("Offboarding's sign-out uses the admin token's \"Directory API - User Security\" scope, chosen when GAM's OAuth client is created, not delegation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A line of monospaced text the operator copies: a Terminal command, a client ID, the scopes.
private struct CopyableLine: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .accessibilityLabel("Copy \(text)")
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
                .accessibilityElement(children: .combine)
        case .done(let text):
            Label(text, systemImage: "checkmark").foregroundStyle(.secondary)
        case .problem(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
